use std::{
    collections::{BTreeMap, HashMap},
    fs::File,
    future::Future,
    io::{Seek, SeekFrom, Write},
    net::IpAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use once_cell::sync::{Lazy, OnceCell};
use reqwest::{
    cookie::{CookieStore, Jar},
    header::{ACCEPT, ACCEPT_ENCODING, COOKIE, LOCATION, ORIGIN, REFERER, USER_AGENT},
    redirect::Policy,
    Client as AsyncClient, RequestBuilder as AsyncRequestBuilder, Response as AsyncResponse, Url,
};

use crate::{
    acw,
    error::{CoreError, CoreResult},
    operation::OperationHandle,
};

use super::{
    transfer::{
        inspect_payload_prefix, inspect_range_response, RangeRequest, RangeResponseAction,
        RangeTransferResult, TransferControl, WorkerDirective, WorkerLease,
    },
    url::{
        reject_explicit_port_reference, validate_direct_target_with_resolver, validate_page_url,
        validate_verification_hop, validate_verification_url, SecurityPolicy,
        ValidatedDirectTarget,
    },
};

pub(crate) const ANDROID_USER_AGENT: &str = "Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro) AppleWebKit/537.36 Chrome/138 Mobile Safari/537.36";
pub(crate) const DESKTOP_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36";
pub(crate) const DESKTOP_EDGE_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36 Edg/138.0.0.0";
pub(crate) const MOBILE_HUAWEI_USER_AGENT: &str = "Mozilla/5.0 (Linux; Android 15; BRQ-AN00) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36";
pub(crate) const MOBILE_FIREFOX_USER_AGENT: &str =
    "Mozilla/5.0 (Android 15; Mobile; rv:138.0) Gecko/138.0 Firefox/138.0";
const MAX_TEXT_BYTES: u64 = 2 * 1024 * 1024;
const DOWNLOAD_IDLE_TIMEOUT: Duration = Duration::from_secs(15);
const CONSTRAINT_POLL_INTERVAL: Duration = Duration::from_millis(25);

// Tokio's DNS resolver and parts of reqwest use spawn_blocking. Keeping the
// bounded runtime process-wide means cancelling a call can detach work that the
// OS has already started without making LibraryTransport::drop wait for it.
static LIBRARY_RUNTIME: OnceCell<tokio::runtime::Runtime> = OnceCell::new();

static USER_VERIFICATION_COOKIES: Lazy<Mutex<HashMap<String, String>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
const VERIFICATION_COOKIE_ANY: &str = "*";

pub(crate) fn import_user_verification_cookie(raw_url: &str, cookie: &str) -> CoreResult<usize> {
    let url =
        Url::parse(raw_url.trim()).map_err(|_| CoreError::invalid("蓝奏验证 Cookie 地址无效"))?;
    let host = normalize_cookie_host(url.host_str().unwrap_or_default())
        .ok_or_else(|| CoreError::invalid("蓝奏验证 Cookie 主机无效"))?;
    if !is_lanzou_cookie_host(&host) {
        return Err(CoreError::invalid("仅允许导入蓝奏验证 Cookie"));
    }
    let value = cookie.trim();
    if value.is_empty() || value.chars().any(|ch| ch == '\r' || ch == '\n') {
        return Err(CoreError::invalid("蓝奏验证 Cookie 为空或格式无效"));
    }
    let mut store = USER_VERIFICATION_COOKIES
        .lock()
        .map_err(|_| CoreError::new("internal_error", "蓝奏验证 Cookie 池不可用", true))?;
    let mut written = 0usize;
    for key in verification_cookie_keys(&host) {
        store.insert(key, value.to_owned());
        written += 1;
    }
    Ok(written)
}

fn verification_cookie_for_url(url: &Url) -> String {
    let Some(host) = url.host_str().and_then(normalize_cookie_host) else {
        return String::new();
    };
    let Ok(store) = USER_VERIFICATION_COOKIES.lock() else {
        return String::new();
    };
    let mut values = Vec::new();
    for key in verification_cookie_keys(&host) {
        if let Some(value) = store.get(&key) {
            if !value.is_empty() && !values.iter().any(|item: &String| item == value) {
                values.push(value.clone());
            }
        }
    }
    merge_cookie_header_values(values)
}

fn verification_cookie_keys(host: &str) -> Vec<String> {
    let mut keys = Vec::new();
    if !host.is_empty() {
        keys.push(host.to_owned());
        if let Some(site) = lanzou_site_cookie_key(host) {
            if !keys.iter().any(|value| value == &site) {
                keys.push(site);
            }
        }
    }
    keys.push(VERIFICATION_COOKIE_ANY.to_owned());
    keys
}

fn normalize_cookie_host(host: &str) -> Option<String> {
    let mut value = host.trim().trim_end_matches('.').to_ascii_lowercase();
    if value.is_empty() || !value.is_ascii() || value.contains('/') || value.contains(':') {
        return None;
    }
    if !value.contains('.') && is_lanzou_cookie_prefix(&value) {
        value.push_str(".com");
    }
    Some(value)
}

fn lanzou_site_cookie_key(host: &str) -> Option<String> {
    let mut parts = host.rsplit('.');
    let tld = parts.next()?;
    let stem = parts.next()?;
    Some(format!("{stem}.{tld}"))
}

fn is_lanzou_cookie_host(host: &str) -> bool {
    if host.ends_with('.') || !host.is_ascii() {
        return false;
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 || labels.iter().any(|label| label.is_empty()) {
        return false;
    }
    let stem = labels[labels.len().saturating_sub(2)];
    labels.last().is_some_and(|value| *value == "com") && is_lanzou_cookie_prefix(stem)
}

fn is_lanzou_cookie_prefix(value: &str) -> bool {
    matches!(
        value,
        "lanzouw"
            | "lanzoui"
            | "lanzoub"
            | "lanzouq"
            | "lanzoux"
            | "lanzouy"
            | "lanzoup"
            | "lanzout"
            | "lanzous"
            | "lanzouj"
            | "lanzov"
            | "laozouw"
    )
}

fn merge_cookie_header_values(values: Vec<String>) -> String {
    let mut pairs = BTreeMap::<String, String>::new();
    for value in values {
        for part in value.split(';') {
            let trimmed = part.trim();
            let Some((name, cookie_value)) = trimmed.split_once('=') else {
                continue;
            };
            let name = name.trim();
            let cookie_value = cookie_value.trim();
            if !name.is_empty() && !cookie_value.is_empty() {
                pairs.insert(name.to_owned(), cookie_value.to_owned());
            }
        }
    }
    pairs
        .into_iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join("; ")
}

#[derive(Clone, Debug)]
pub(crate) struct Page {
    pub url: String,
    pub html: String,
}

#[derive(Clone)]
pub(crate) struct LibraryTransport {
    text_client: AsyncClient,
    download_client: AsyncClient,
    runtime_handle: tokio::runtime::Handle,
    download_idle_timeout: Duration,
    cookies: Arc<Jar>,
    pub policy: SecurityPolicy,
}

#[derive(Clone, Copy)]
enum UrlScope {
    Page,
    Verification,
}

#[derive(Clone, Copy)]
struct RequestConstraints<'a> {
    operation: Option<&'a OperationHandle>,
    deadline: Option<Instant>,
}

impl LibraryTransport {
    #[cfg(test)]
    pub(crate) fn for_test(origin: String) -> CoreResult<Self> {
        Self::build(SecurityPolicy::Test { origin })
    }

    #[cfg(test)]
    pub(crate) fn for_test_with_download_idle_timeout(
        origin: String,
        download_idle_timeout: Duration,
    ) -> CoreResult<Self> {
        Self::build_with_download_idle_timeout(
            SecurityPolicy::Test { origin },
            download_idle_timeout,
        )
    }

    pub(crate) fn build(policy: SecurityPolicy) -> CoreResult<Self> {
        Self::build_with_download_idle_timeout(policy, DOWNLOAD_IDLE_TIMEOUT)
    }

    fn build_with_download_idle_timeout(
        policy: SecurityPolicy,
        download_idle_timeout: Duration,
    ) -> CoreResult<Self> {
        let cookies = Arc::new(Jar::default());
        let runtime_handle = library_runtime()?.handle().clone();
        let (text_client, download_client) = {
            let _runtime_guard = runtime_handle.enter();
            let text_client = AsyncClient::builder()
                .use_rustls_tls()
                .cookie_provider(cookies.clone())
                .redirect(Policy::none())
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(35))
                .build()
                .map_err(CoreError::from_reqwest)?;
            let download_client = AsyncClient::builder()
                .use_rustls_tls()
                .cookie_provider(cookies.clone())
                .redirect(Policy::none())
                .connect_timeout(Duration::from_secs(10))
                .read_timeout(download_idle_timeout)
                .build()
                .map_err(CoreError::from_reqwest)?;
            (text_client, download_client)
        };
        Ok(Self {
            text_client,
            download_client,
            runtime_handle,
            download_idle_timeout,
            cookies,
            policy,
        })
    }

    fn apply_user_verification_cookie(&self, url: &Url) {
        let cookie = verification_cookie_for_url(url);
        if cookie.is_empty() {
            return;
        }
        for part in cookie.split(';') {
            let pair = part.trim();
            if pair.is_empty() || !pair.contains('=') {
                continue;
            }
            self.cookies.add_cookie_str(&format!("{pair}; Path=/"), url);
        }
    }

    pub(crate) fn get_guarded(&self, value: &str, referer: &str) -> CoreResult<Page> {
        self.get_guarded_constrained(value, referer, None, None)
    }

    pub(crate) fn get_guarded_constrained(
        &self,
        value: &str,
        referer: &str,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<Page> {
        self.get_guarded_with_agent_constrained(
            value,
            referer,
            ANDROID_USER_AGENT,
            operation,
            deadline,
        )
    }

    pub(crate) fn get_guarded_verification_constrained(
        &self,
        value: &str,
        referer: &str,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<Page> {
        self.get_guarded_scoped(
            value,
            referer,
            ANDROID_USER_AGENT,
            UrlScope::Verification,
            operation,
            deadline,
        )
    }

    pub(crate) fn get_guarded_with_agent_constrained(
        &self,
        value: &str,
        referer: &str,
        user_agent: &str,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<Page> {
        self.get_guarded_scoped(
            value,
            referer,
            user_agent,
            UrlScope::Page,
            operation,
            deadline,
        )
    }

    fn get_guarded_scoped(
        &self,
        value: &str,
        referer: &str,
        user_agent: &str,
        scope: UrlScope,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<Page> {
        check_constraints(operation, deadline)?;
        let mut page =
            self.get_following_validated(value, referer, user_agent, scope, operation, deadline)?;
        if let Some(cookie) = acw::challenge_cookie(&page.html)? {
            check_constraints(operation, deadline)?;
            let parsed =
                Url::parse(&page.url).map_err(|_| CoreError::parse("蓝奏验证页面地址无效"))?;
            self.cookies
                .add_cookie_str(&format!("acw_sc__v2={cookie}; Path=/"), &parsed);
            page = self.get_following_validated(
                &page.url, referer, user_agent, scope, operation, deadline,
            )?;
            if acw::challenge_cookie(&page.html)?.is_some() {
                return Err(CoreError::remote("蓝奏 ACW 验证失败", true));
            }
        }
        Ok(page)
    }

    pub(crate) fn post_form_constrained(
        &self,
        value: &str,
        form: &BTreeMap<String, String>,
        referer: &str,
        user_agent: &str,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<String> {
        self.post_form_scoped(
            value,
            form,
            referer,
            user_agent,
            UrlScope::Page,
            RequestConstraints {
                operation,
                deadline,
            },
        )
    }

    pub(crate) fn post_form_verification_constrained(
        &self,
        value: &str,
        form: &BTreeMap<String, String>,
        referer: &str,
        user_agent: &str,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<String> {
        self.post_form_scoped(
            value,
            form,
            referer,
            user_agent,
            UrlScope::Verification,
            RequestConstraints {
                operation,
                deadline,
            },
        )
    }

    #[cfg(test)]
    pub(crate) fn download_guarded_to(
        &self,
        value: &str,
        referer: &str,
        destination: &mut File,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<u64> {
        self.download_guarded_range_to(
            value,
            referer,
            destination,
            &RangeRequest::default(),
            operation,
            None,
        )
        .map(|result| result.response_bytes)
    }

    #[cfg(test)]
    pub(crate) fn download_guarded_range_to(
        &self,
        value: &str,
        referer: &str,
        destination: &mut File,
        range: &RangeRequest,
        operation: Option<&OperationHandle>,
        control: Option<(&TransferControl, WorkerLease)>,
    ) -> CoreResult<RangeTransferResult> {
        self.download_guarded_range_to_with_agent(
            value,
            referer,
            destination,
            range,
            ANDROID_USER_AGENT,
            operation,
            control,
        )
    }

    pub(crate) fn download_guarded_range_to_with_agent(
        &self,
        value: &str,
        referer: &str,
        destination: &mut File,
        range: &RangeRequest,
        user_agent: &str,
        operation: Option<&OperationHandle>,
        control: Option<(&TransferControl, WorkerLease)>,
    ) -> CoreResult<RangeTransferResult> {
        check_download_constraints(operation, control)?;
        let existing_length = destination.metadata()?.len();
        if range.offset > 0 && existing_length != range.offset {
            return Err(CoreError::new(
                "range_invalid",
                "本地断点长度与 Range 偏移不一致",
                false,
            ));
        }
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        let mut current = self.validate_direct_target_constrained(value, operation, None)?;
        let referer = validate_page_url(referer, &self.policy)?;
        for _ in 0..=5 {
            check_download_constraints(operation, control)?;
            let cookie_header = self
                .cookies
                .cookies(&current.url)
                .and_then(|value| value.to_str().ok().map(ToOwned::to_owned))
                .filter(|value| !value.trim().is_empty())
                .map_or_else(
                    || "down_ip=1".to_owned(),
                    |value| format!("{value}; down_ip=1"),
                );
            let client = self.download_client_for(&current)?;
            let request = client
                .get(current.url.clone())
                .header(USER_AGENT, user_agent)
                .headers(range.headers()?)
                .header(COOKIE, cookie_header)
                .header(REFERER, referer.as_str());
            let mut response = match self.wait_for_download_request(request, operation, control) {
                Ok(response) => response,
                Err(error) => {
                    check_download_constraints(operation, control)?;
                    return Err(error);
                }
            };
            if response.status().is_redirection() {
                let location = response
                    .headers()
                    .get(LOCATION)
                    .and_then(|value| value.to_str().ok())
                    .ok_or_else(|| CoreError::parse("下载跳转缺少地址"))?;
                if matches!(self.policy, SecurityPolicy::Production) {
                    reject_explicit_port_reference(location)
                        .map_err(|_| CoreError::parse("下载跳转地址不受信任"))?;
                }
                let next = current
                    .url
                    .join(location)
                    .map_err(|_| CoreError::parse("下载跳转地址无效"))?;
                current =
                    self.validate_direct_target_constrained(next.as_str(), operation, None)?;
                continue;
            }
            let response_plan =
                inspect_range_response(range, response.status(), response.headers())?;
            if response_plan.action == RangeResponseAction::AlreadyComplete {
                destination.sync_all()?;
                if let Some(operation) = operation {
                    operation.set_transfer_progress(range.offset, range.offset);
                }
                return Ok(RangeTransferResult {
                    committed_bytes: range.offset,
                    response_bytes: 0,
                    total_bytes: Some(range.offset),
                    validator: response_plan.validator,
                    restarted: false,
                });
            }
            let base_offset = if response_plan.action == RangeResponseAction::Append {
                range.offset
            } else {
                0
            };
            let total = response_plan.validator.total_bytes;
            if let Some(operation) = operation {
                operation.set_transfer_progress(base_offset, total.unwrap_or(0));
            }
            let mut received = 0_u64;
            let mut written = 0_u64;
            let mut prefix = Vec::with_capacity(512);
            let mut prepared = false;
            loop {
                check_download_constraints(operation, control)?;
                let chunk =
                    match self.wait_for_download_future(response.chunk(), operation, control) {
                        Ok(chunk) => chunk,
                        Err(error) => {
                            destination.sync_all()?;
                            check_download_constraints(operation, control)?;
                            return Err(error);
                        }
                    };
                let Some(chunk) = chunk else {
                    break;
                };
                check_download_constraints(operation, control)?;
                received = received.saturating_add(chunk.len() as u64);
                if !prepared {
                    let needed = 512_usize.saturating_sub(prefix.len());
                    let prefix_bytes = needed.min(chunk.len());
                    prefix.extend_from_slice(&chunk[..prefix_bytes]);
                    if prefix.len() == 512 {
                        inspect_payload_prefix(&prefix)?;
                        prepare_range_destination(destination, response_plan.action, range.offset)?;
                        destination.write_all(&prefix)?;
                        written = written.saturating_add(prefix.len() as u64);
                        if prefix_bytes < chunk.len() {
                            destination.write_all(&chunk[prefix_bytes..])?;
                            written = written.saturating_add((chunk.len() - prefix_bytes) as u64);
                        }
                        prepared = true;
                    }
                } else {
                    destination.write_all(chunk.as_ref())?;
                    written = written.saturating_add(chunk.len() as u64);
                }
                if let Some(operation) = operation {
                    operation.set_transfer_progress(
                        base_offset.saturating_add(written),
                        total.unwrap_or(0),
                    );
                }
            }
            if !prepared {
                inspect_payload_prefix(&prefix)?;
                prepare_range_destination(destination, response_plan.action, range.offset)?;
                destination.write_all(&prefix)?;
                written = prefix.len() as u64;
            }
            if response_plan
                .expected_body_bytes
                .is_some_and(|expected| expected != received)
                || received != written
            {
                destination.sync_all()?;
                return Err(CoreError::new(
                    "range_invalid",
                    "文件下载长度与 Range 响应不一致",
                    true,
                ));
            }
            destination.sync_all()?;
            let committed = base_offset.saturating_add(written);
            if let Some(operation) = operation {
                operation.set_transfer_progress(committed, total.unwrap_or(committed));
            }
            return Ok(RangeTransferResult {
                committed_bytes: committed,
                response_bytes: received,
                total_bytes: total,
                validator: response_plan.validator,
                restarted: response_plan.action == RangeResponseAction::RestartFromZero,
            });
        }
        Err(CoreError::remote("文件下载跳转次数过多", false))
    }

    fn wait_for_download_request(
        &self,
        request: AsyncRequestBuilder,
        operation: Option<&OperationHandle>,
        control: Option<(&TransferControl, WorkerLease)>,
    ) -> CoreResult<AsyncResponse> {
        let future = {
            let _runtime_guard = self.runtime_handle.enter();
            request.send()
        };
        self.wait_for_download_future(future, operation, control)
    }

    fn wait_for_download_future<T, F>(
        &self,
        future: F,
        operation: Option<&OperationHandle>,
        control: Option<(&TransferControl, WorkerLease)>,
    ) -> CoreResult<T>
    where
        F: Future<Output = Result<T, reqwest::Error>>,
    {
        check_download_constraints(operation, control)?;
        if control.is_none() {
            return self.wait_for_reqwest(future, operation, None);
        }
        self.runtime_handle.block_on(async move {
            let mut future = Box::pin(future);
            loop {
                match tokio::time::timeout(CONSTRAINT_POLL_INTERVAL, future.as_mut()).await {
                    Ok(result) => return result.map_err(CoreError::from_reqwest),
                    Err(_) => check_download_constraints(operation, control)?,
                }
            }
        })
    }

    fn download_client_for(&self, target: &ValidatedDirectTarget) -> CoreResult<AsyncClient> {
        let Some(addresses) = target.pinned_addresses.as_deref() else {
            return Ok(self.download_client.clone());
        };
        let host = target
            .url
            .host_str()
            .ok_or_else(|| CoreError::parse("蓝奏直链缺少主机名"))?;
        // An explicit resolver override plus no-proxy is required here: without
        // both, reqwest or a configured proxy could perform a second DNS lookup
        // after the SSRF check and rebind the hostname to a private address.
        let _runtime_guard = self.runtime_handle.enter();
        AsyncClient::builder()
            .use_rustls_tls()
            .cookie_provider(self.cookies.clone())
            .redirect(Policy::none())
            .connect_timeout(Duration::from_secs(10))
            .read_timeout(self.download_idle_timeout)
            .no_proxy()
            .resolve_to_addrs(host, addresses)
            .build()
            .map_err(CoreError::from_reqwest)
    }

    pub(crate) fn validate_direct_url_constrained(
        &self,
        value: &str,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<Url> {
        self.validate_direct_target_constrained(value, operation, deadline)
            .map(|target| target.url)
    }

    fn validate_direct_target_constrained(
        &self,
        value: &str,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<ValidatedDirectTarget> {
        validate_direct_target_with_resolver(value, &self.policy, |host| {
            self.resolve_direct_host_constrained(host, operation, deadline)
        })
    }

    fn resolve_direct_host_constrained(
        &self,
        host: &str,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<Vec<IpAddr>> {
        check_constraints(operation, deadline)?;
        let lookup = {
            let _runtime_guard = self.runtime_handle.enter();
            tokio::net::lookup_host((host.to_owned(), 443))
        };
        self.wait_for_result(lookup, operation, deadline, |_| {
            CoreError::remote("无法验证蓝奏直链主机", true)
        })
        .map(|addresses| addresses.map(|address| address.ip()).collect())
    }

    fn post_form_scoped(
        &self,
        value: &str,
        form: &BTreeMap<String, String>,
        referer: &str,
        user_agent: &str,
        scope: UrlScope,
        constraints: RequestConstraints<'_>,
    ) -> CoreResult<String> {
        let RequestConstraints {
            operation,
            deadline,
        } = constraints;
        check_constraints(operation, deadline)?;
        let url = self.validate_url(value, scope)?;
        self.apply_user_verification_cookie(&url);
        let referer_url = self.validate_url(referer, scope)?;
        self.apply_user_verification_cookie(&referer_url);
        if matches!(scope, UrlScope::Verification) {
            validate_verification_hop(&referer_url, url.as_str(), &self.policy)?;
        }
        let request_origin = referer_url.origin().ascii_serialization();
        let request = self
            .text_client
            .post(url)
            .header(USER_AGENT, user_agent)
            .header(ACCEPT, "application/json, text/javascript, */*")
            .header(ACCEPT_ENCODING, "gzip")
            .header(REFERER, referer_url.as_str())
            .header(ORIGIN, request_origin)
            .header("X-Requested-With", "XMLHttpRequest")
            .form(form);
        let response = self.wait_for_request(request, operation, deadline)?;
        check_constraints(operation, deadline)?;
        if response.status().is_redirection() {
            return Err(CoreError::remote("蓝奏接口尝试了非预期跳转", false));
        }
        if !response.status().is_success() {
            return Err(CoreError::remote(
                format!("蓝奏接口 HTTP {}", response.status().as_u16()),
                response.status().is_server_error(),
            ));
        }
        self.read_text_constrained(response, operation, deadline)
    }

    fn get_following_validated(
        &self,
        value: &str,
        referer: &str,
        user_agent: &str,
        scope: UrlScope,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<Page> {
        check_constraints(operation, deadline)?;
        let mut current = self.validate_url(value, scope)?;
        let initial = current.clone();
        let mut current_referer = if referer.is_empty() {
            None
        } else {
            Some(self.validate_url(referer, scope)?)
        };
        for _ in 0..=5 {
            check_constraints(operation, deadline)?;
            self.apply_user_verification_cookie(&current);
            if let Some(referer) = &current_referer {
                self.apply_user_verification_cookie(referer);
            }
            let mut request = self
                .text_client
                .get(current.clone())
                .header(USER_AGENT, user_agent)
                .header(ACCEPT_ENCODING, "gzip");
            if let Some(referer) = &current_referer {
                request = request.header(REFERER, referer.as_str());
            }
            let response = self.wait_for_request(request, operation, deadline)?;
            check_constraints(operation, deadline)?;
            if response.status().is_redirection() {
                let location = response
                    .headers()
                    .get(LOCATION)
                    .and_then(|value| value.to_str().ok())
                    .ok_or_else(|| CoreError::parse("蓝奏页面跳转缺少地址"))?;
                if matches!(self.policy, SecurityPolicy::Production) {
                    reject_explicit_port_reference(location)
                        .map_err(|_| CoreError::parse("蓝奏页面跳转包含显式端口"))?;
                }
                let next = current
                    .join(location)
                    .map_err(|_| CoreError::parse("蓝奏页面跳转地址无效"))?;
                if matches!(scope, UrlScope::Verification) {
                    validate_verification_hop(&initial, next.as_str(), &self.policy)?;
                } else {
                    self.validate_url(next.as_str(), scope)?;
                }
                current_referer = Some(current);
                current = next;
                continue;
            }
            if !response.status().is_success() {
                return Err(CoreError::remote(
                    format!("蓝奏页面 HTTP {}", response.status().as_u16()),
                    response.status().is_server_error(),
                ));
            }
            let final_url = response.url().to_string();
            if matches!(scope, UrlScope::Verification) {
                validate_verification_hop(&initial, &final_url, &self.policy)?;
            } else {
                self.validate_url(&final_url, scope)?;
            }
            return Ok(Page {
                url: final_url,
                html: self.read_text_constrained(response, operation, deadline)?,
            });
        }
        Err(CoreError::parse("蓝奏页面跳转次数过多"))
    }

    fn validate_url(&self, value: &str, scope: UrlScope) -> CoreResult<Url> {
        match scope {
            UrlScope::Page => validate_page_url(value, &self.policy),
            UrlScope::Verification => validate_verification_url(value, &self.policy),
        }
    }

    fn wait_for_reqwest<T, F>(
        &self,
        future: F,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<T>
    where
        F: Future<Output = Result<T, reqwest::Error>>,
    {
        self.wait_for_result(future, operation, deadline, CoreError::from_reqwest)
    }

    fn wait_for_result<T, E, F, M>(
        &self,
        future: F,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
        map_error: M,
    ) -> CoreResult<T>
    where
        F: Future<Output = Result<T, E>>,
        M: Fn(E) -> CoreError,
    {
        check_constraints(operation, deadline)?;
        if operation.is_none() && deadline.is_none() {
            return self.runtime_handle.block_on(future).map_err(map_error);
        }
        self.runtime_handle.block_on(async move {
            let mut future = Box::pin(future);
            loop {
                let interval = constraint_poll_interval(deadline)?;
                match tokio::time::timeout(interval, future.as_mut()).await {
                    Ok(result) => return result.map_err(&map_error),
                    Err(_) => check_constraints(operation, deadline)?,
                }
            }
        })
    }

    fn wait_for_request(
        &self,
        request: AsyncRequestBuilder,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<AsyncResponse> {
        let future = {
            // reqwest creates its timeout sleep when `send` is called, so the
            // future must be constructed while this transport's runtime is
            // entered, not merely polled by it afterwards.
            let _runtime_guard = self.runtime_handle.enter();
            request.send()
        };
        self.wait_for_reqwest(future, operation, deadline)
    }

    fn read_text_constrained(
        &self,
        mut response: AsyncResponse,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<String> {
        let mut bytes = Vec::new();
        loop {
            check_constraints(operation, deadline)?;
            let Some(chunk) = self.wait_for_reqwest(response.chunk(), operation, deadline)? else {
                break;
            };
            if bytes.len().saturating_add(chunk.len()) as u64 > MAX_TEXT_BYTES {
                return Err(CoreError::remote("蓝奏响应内容过大", false));
            }
            bytes.extend_from_slice(&chunk);
        }
        String::from_utf8(bytes).map_err(|_| CoreError::parse("蓝奏返回了非 UTF-8 文本"))
    }
}

fn prepare_range_destination(
    destination: &mut File,
    action: RangeResponseAction,
    offset: u64,
) -> CoreResult<()> {
    match action {
        RangeResponseAction::Append => {
            if destination.metadata()?.len() != offset {
                return Err(CoreError::new(
                    "range_invalid",
                    "本地断点在写入前发生变化",
                    false,
                ));
            }
            destination.seek(SeekFrom::Start(offset))?;
        }
        RangeResponseAction::WriteFromStart | RangeResponseAction::RestartFromZero => {
            destination.set_len(0)?;
            destination.seek(SeekFrom::Start(0))?;
        }
        RangeResponseAction::AlreadyComplete => {}
    }
    Ok(())
}

fn check_download_constraints(
    operation: Option<&OperationHandle>,
    control: Option<(&TransferControl, WorkerLease)>,
) -> CoreResult<()> {
    if let Some(operation) = operation {
        operation.check_cancelled()?;
    }
    let Some((control, worker)) = control else {
        return Ok(());
    };
    match control.directive(worker) {
        WorkerDirective::Continue => Ok(()),
        WorkerDirective::Pause => Err(CoreError::new("transfer_paused", "下载已暂停", false)),
        WorkerDirective::Cancel => Err(CoreError::cancelled()),
        WorkerDirective::Stale => Err(CoreError::new(
            "transfer_stale",
            "旧下载工作线程已失效",
            false,
        )),
    }
}

fn library_runtime() -> CoreResult<&'static tokio::runtime::Runtime> {
    LIBRARY_RUNTIME.get_or_try_init(|| {
        let async_workers = crate::parallelism::runtime_async_workers();
        let blocking_workers = crate::parallelism::runtime_blocking_workers();
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(async_workers)
            .max_blocking_threads(blocking_workers)
            .thread_name("lanzou-library-runtime")
            .enable_all()
            .build()
            .map_err(|_| CoreError::new("internal_error", "无法启动下载运行时", false))
    })
}

pub(crate) fn wait_cooperatively(
    duration: Duration,
    operation: Option<&OperationHandle>,
    deadline: Option<Instant>,
) -> CoreResult<()> {
    check_constraints(operation, deadline)?;
    if duration.is_zero() {
        return Ok(());
    }
    let finish = Instant::now()
        .checked_add(duration)
        .unwrap_or_else(Instant::now);
    loop {
        check_constraints(operation, deadline)?;
        let now = Instant::now();
        if now >= finish {
            return Ok(());
        }
        let mut interval = finish.saturating_duration_since(now);
        if operation.is_some() || deadline.is_some() {
            interval = interval.min(CONSTRAINT_POLL_INTERVAL);
        }
        if let Some(deadline) = deadline {
            interval = interval.min(deadline.saturating_duration_since(now));
        }
        if interval.is_zero() {
            check_constraints(operation, deadline)?;
            continue;
        }
        std::thread::sleep(interval);
    }
}

fn check_constraints(
    operation: Option<&OperationHandle>,
    deadline: Option<Instant>,
) -> CoreResult<()> {
    if let Some(operation) = operation {
        operation.check_cancelled()?;
    }
    if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        return Err(CoreError::new("timeout", "请求超时", true));
    }
    Ok(())
}

fn constraint_poll_interval(deadline: Option<Instant>) -> CoreResult<Duration> {
    let Some(deadline) = deadline else {
        return Ok(CONSTRAINT_POLL_INTERVAL);
    };
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(CoreError::new("timeout", "请求超时", true))
    } else {
        Ok(remaining.min(CONSTRAINT_POLL_INTERVAL))
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs::{self, OpenOptions},
        io::{Read, Write},
        net::TcpListener,
        sync::{mpsc, Arc},
        thread,
        time::Instant,
    };

    use super::*;

    #[test]
    fn test_guarded_get_blocks_redirect_outside_test_origin() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            stream
                .write_all(b"HTTP/1.1 302 Found\r\nLocation: https://evil.example/\r\nContent-Length: 0\r\n\r\n")
                .unwrap();
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();
        let error = transport
            .get_guarded(&format!("{origin}/source"), "")
            .unwrap_err();
        assert_eq!(error.code, "invalid_argument");
        server.join().unwrap();
    }

    #[test]
    fn test_guarded_get_never_requests_an_invalid_redirect_hop() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let forbidden = TcpListener::bind("127.0.0.1:0").unwrap();
        forbidden.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let forbidden_url = format!("http://{}/stolen", forbidden.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            let response = format!(
                "HTTP/1.1 302 Found\r\nLocation: {forbidden_url}\r\nContent-Length: 0\r\n\r\n"
            );
            stream.write_all(response.as_bytes()).unwrap();
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();
        assert!(transport
            .get_guarded(&format!("{origin}/source"), "")
            .is_err());
        server.join().unwrap();
        thread::sleep(Duration::from_millis(30));
        assert!(matches!(
            forbidden.accept(),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock
        ));
    }

    #[test]
    fn test_wait_cooperatively_observes_cancellation_without_full_delay() {
        let operation_id = "library-cooperative-wait-cancel-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let started = Instant::now();
        let worker = thread::spawn(move || {
            wait_cooperatively(Duration::from_secs(5), Some(&worker_operation), None)
        });
        thread::sleep(Duration::from_millis(40));
        crate::operation::cancel(operation_id).unwrap();

        let error = worker.join().unwrap().unwrap_err();
        assert_eq!(error.code, "cancelled");
        assert!(started.elapsed() < Duration::from_millis(500));
        operation.finish_cancelled();
        crate::operation::forget(operation_id).unwrap();
    }

    #[test]
    fn test_constrained_future_interrupts_stalled_dns_lookup() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let operation_id = "library-dns-cancel-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let worker = thread::spawn(move || {
            let transport = LibraryTransport::for_test(origin).unwrap();
            transport.wait_for_result(
                std::future::pending::<Result<(), std::io::Error>>(),
                Some(&worker_operation),
                None,
                |_| CoreError::remote("无法验证蓝奏直链主机", true),
            )
        });
        thread::sleep(Duration::from_millis(40));
        let started = Instant::now();
        crate::operation::cancel(operation_id).unwrap();

        let error = worker.join().unwrap().unwrap_err();
        assert_eq!(error.code, "cancelled");
        assert!(started.elapsed() < Duration::from_millis(500));
        operation.finish_cancelled();
        crate::operation::forget(operation_id).unwrap();
    }

    #[test]
    fn test_cancelled_call_drop_is_bounded_while_tokio_blocking_work_is_still_running() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let operation_id = "library-blocking-runtime-cancel-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let (blocking_started_tx, blocking_started_rx) = mpsc::sync_channel(1);
        let (release_blocking_tx, release_blocking_rx) = mpsc::sync_channel(1);
        let (blocking_finished_tx, blocking_finished_rx) = mpsc::sync_channel(1);
        let (call_finished_tx, call_finished_rx) = mpsc::sync_channel(1);
        let worker_origin = origin.clone();
        let worker = thread::spawn(move || {
            let transport = LibraryTransport::for_test(worker_origin).unwrap();
            let blocking_work = {
                let _runtime_guard = transport.runtime_handle.enter();
                tokio::task::spawn_blocking(move || {
                    let _ = blocking_started_tx.send(());
                    let _ = release_blocking_rx.recv();
                    let _ = blocking_finished_tx.send(());
                })
            };
            let result =
                transport.wait_for_result(blocking_work, Some(&worker_operation), None, |_| {
                    CoreError::remote("无法验证蓝奏直链主机", true)
                });
            drop(transport);
            let _ = call_finished_tx.send(result);
        });
        blocking_started_rx
            .recv_timeout(Duration::from_secs(1))
            .unwrap();

        let cancel_started = Instant::now();
        crate::operation::cancel(operation_id).unwrap();
        let cancelled_result = call_finished_rx.recv_timeout(Duration::from_millis(300));
        if cancelled_result.is_err() {
            let _ = release_blocking_tx.send(());
            let _ = blocking_finished_rx.recv_timeout(Duration::from_secs(1));
            let _ = worker.join();
            operation.finish_cancelled();
            crate::operation::forget(operation_id).unwrap();
            panic!("transport drop waited for still-running Tokio blocking work");
        }
        let error = cancelled_result.unwrap().unwrap_err();
        assert_eq!(error.code, "cancelled");
        assert!(cancel_started.elapsed() < Duration::from_millis(300));

        // A detached, still-running resolver job must not prevent an unrelated
        // operation from using the shared runtime.
        let next_transport = LibraryTransport::for_test(origin).unwrap();
        let next_work = {
            let _runtime_guard = next_transport.runtime_handle.enter();
            tokio::task::spawn_blocking(|| 7_u8)
        };
        let next_value = next_transport
            .wait_for_result(
                next_work,
                None,
                Some(Instant::now() + Duration::from_millis(300)),
                |_| CoreError::remote("后续解析任务失败", true),
            )
            .unwrap();
        assert_eq!(next_value, 7);

        release_blocking_tx.send(()).unwrap();
        blocking_finished_rx
            .recv_timeout(Duration::from_secs(1))
            .unwrap();
        worker.join().unwrap();
        operation.finish_cancelled();
        crate::operation::forget(operation_id).unwrap();
    }

    #[test]
    fn test_constrained_get_cancel_is_bounded_while_headers_stall() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let (accepted_tx, accepted_rx) = mpsc::sync_channel(1);
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            accepted_tx.send(()).unwrap();
            thread::sleep(Duration::from_millis(700));
        });
        let operation_id = "library-constrained-get-cancel-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let worker_origin = origin.clone();
        let worker = thread::spawn(move || {
            let transport = LibraryTransport::for_test(worker_origin.clone()).unwrap();
            transport.get_guarded_with_agent_constrained(
                &format!("{worker_origin}/share"),
                "",
                ANDROID_USER_AGENT,
                Some(&worker_operation),
                None,
            )
        });
        accepted_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let started = Instant::now();
        crate::operation::cancel(operation_id).unwrap();

        let error = worker.join().unwrap().unwrap_err();
        assert_eq!(error.code, "cancelled");
        assert!(started.elapsed() < Duration::from_millis(500));
        operation.finish_cancelled();
        crate::operation::forget(operation_id).unwrap();
        server.join().unwrap();
    }

    #[test]
    fn test_constrained_get_cancel_is_bounded_while_text_body_stalls() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let (headers_tx, headers_rx) = mpsc::sync_channel(1);
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 64\r\nConnection: close\r\n\r\n")
                .unwrap();
            headers_tx.send(()).unwrap();
            thread::sleep(Duration::from_millis(700));
        });
        let operation_id = "library-constrained-body-cancel-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let worker_origin = origin.clone();
        let worker = thread::spawn(move || {
            let transport = LibraryTransport::for_test(worker_origin.clone()).unwrap();
            transport.get_guarded_with_agent_constrained(
                &format!("{worker_origin}/share"),
                "",
                ANDROID_USER_AGENT,
                Some(&worker_operation),
                None,
            )
        });
        headers_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let started = Instant::now();
        crate::operation::cancel(operation_id).unwrap();

        let error = worker.join().unwrap().unwrap_err();
        assert_eq!(error.code, "cancelled");
        assert!(started.elapsed() < Duration::from_millis(500));
        operation.finish_cancelled();
        crate::operation::forget(operation_id).unwrap();
        server.join().unwrap();
    }

    #[test]
    fn test_constrained_get_deadline_is_hard_bound() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            thread::sleep(Duration::from_millis(500));
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();
        let started = Instant::now();

        let error = transport
            .get_guarded_with_agent_constrained(
                &format!("{origin}/share"),
                "",
                ANDROID_USER_AGENT,
                None,
                Some(Instant::now() + Duration::from_millis(70)),
            )
            .unwrap_err();

        assert_eq!(error.code, "timeout");
        assert!(started.elapsed() < Duration::from_millis(400));
        server.join().unwrap();
    }

    #[test]
    fn test_pinned_direct_client_connects_only_to_prevalidated_address() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let count = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..count]);
            assert!(request.starts_with("GET /bound "));
            assert!(request
                .to_ascii_lowercase()
                .contains("host: dns-must-not-run.invalid"));
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nbound",
                )
                .unwrap();
        });
        let origin = format!("http://{address}");
        let transport = LibraryTransport::for_test(origin).unwrap();
        let url = Url::parse(&format!(
            "http://dns-must-not-run.invalid:{}/bound",
            address.port()
        ))
        .unwrap();
        let target = ValidatedDirectTarget {
            url: url.clone(),
            pinned_addresses: Some(vec![address]),
        };

        let client = transport.download_client_for(&target).unwrap();
        let response = transport
            .wait_for_request(client.get(url), None, None)
            .unwrap();
        let body = transport
            .read_text_constrained(response, None, None)
            .unwrap();

        assert_eq!(body, "bound");
        server.join().unwrap();
    }

    #[test]
    fn test_guarded_download_writes_real_bytes_and_publishes_progress() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let count = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..count]);
            assert!(request.starts_with("GET /file/app.apk "));
            let request_lower = request.to_ascii_lowercase();
            assert!(request_lower.contains("session=kept"));
            assert!(request_lower.contains("down_ip=1"));
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\npayload",
                )
                .unwrap();
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();
        transport
            .cookies
            .add_cookie_str("session=kept; Path=/", &Url::parse(&origin).unwrap());
        let directory = tempfile::tempdir().unwrap();
        let destination = directory.path().join("payload.part");
        let mut destination_file = File::create(&destination).unwrap();
        let operation = crate::operation::begin(
            Some("library-transport-download-test"),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();

        let bytes = transport
            .download_guarded_to(
                &format!("{origin}/file/app.apk"),
                &format!("{origin}/share"),
                &mut destination_file,
                Some(&operation),
            )
            .unwrap();
        drop(destination_file);

        assert_eq!(bytes, 7);
        assert_eq!(std::fs::read(destination).unwrap(), b"payload");
        let status = crate::operation::status("library-transport-download-test").unwrap();
        assert_eq!(status["bytesTransferred"], 7);
        assert_eq!(status["totalBytes"], 7);
        operation.finish_success();
        crate::operation::forget("library-transport-download-test").unwrap();
        server.join().unwrap();
    }

    #[test]
    fn test_guarded_download_never_follows_redirect_outside_trusted_test_origin() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let forbidden = TcpListener::bind("127.0.0.1:0").unwrap();
        forbidden.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let forbidden_url = format!("http://{}/stolen", forbidden.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            write!(
                stream,
                "HTTP/1.1 302 Found\r\nLocation: {forbidden_url}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let mut destination = File::create(directory.path().join("payload.part")).unwrap();

        let error = transport
            .download_guarded_to(
                &format!("{origin}/file/app.apk"),
                &format!("{origin}/share"),
                &mut destination,
                None,
            )
            .unwrap_err();

        assert_eq!(error.code, "invalid_argument");
        server.join().unwrap();
        thread::sleep(Duration::from_millis(30));
        assert!(matches!(
            forbidden.accept(),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock
        ));
    }

    #[test]
    fn test_guarded_download_cancel_is_bounded_when_body_stalls() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let (headers_sent, headers_received) = mpsc::sync_channel(1);
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\n")
                .unwrap();
            headers_sent.send(()).unwrap();
            thread::sleep(Duration::from_millis(500));
        });
        let transport = LibraryTransport::for_test_with_download_idle_timeout(
            origin.clone(),
            Duration::from_millis(60),
        )
        .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let destination = File::create(directory.path().join("payload.part")).unwrap();
        let operation_id = "library-download-idle-cancel-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let file_url = format!("{origin}/file/app.apk");
        let referer = format!("{origin}/share");
        let (result_sent, result_received) = mpsc::sync_channel(1);
        let worker = thread::spawn(move || {
            let mut destination = destination;
            let result = transport.download_guarded_to(
                &file_url,
                &referer,
                &mut destination,
                Some(&worker_operation),
            );
            result_sent.send(result).unwrap();
        });

        headers_received
            .recv_timeout(Duration::from_secs(1))
            .unwrap();
        let started = Instant::now();
        crate::operation::cancel(operation_id).unwrap();
        let error = result_received
            .recv_timeout(Duration::from_millis(300))
            .expect("stalled download cancellation exceeded the idle timeout bound")
            .unwrap_err();

        assert_eq!(error.code, "cancelled");
        assert!(started.elapsed() < Duration::from_millis(300));
        operation.finish_cancelled();
        crate::operation::forget(operation_id).unwrap();
        worker.join().unwrap();
        server.join().unwrap();
    }

    #[test]
    fn test_guarded_download_stall_returns_timeout_within_idle_bound() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\n")
                .unwrap();
            thread::sleep(Duration::from_millis(250));
        });
        let transport = LibraryTransport::for_test_with_download_idle_timeout(
            origin.clone(),
            Duration::from_millis(60),
        )
        .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let mut destination = File::create(directory.path().join("payload.part")).unwrap();

        let started = Instant::now();
        let error = transport
            .download_guarded_to(
                &format!("{origin}/file/app.apk"),
                &format!("{origin}/share"),
                &mut destination,
                None,
            )
            .unwrap_err();

        assert_eq!(error.code, "timeout");
        assert!(started.elapsed() < Duration::from_millis(300));
        server.join().unwrap();
    }

    #[test]
    fn test_guarded_download_idle_timeout_allows_long_segmented_transfer() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nab")
                .unwrap();
            thread::sleep(Duration::from_millis(180));
            stream.write_all(b"cd").unwrap();
            thread::sleep(Duration::from_millis(180));
            stream.write_all(b"ef").unwrap();
        });
        let idle_timeout = Duration::from_millis(300);
        let transport =
            LibraryTransport::for_test_with_download_idle_timeout(origin.clone(), idle_timeout)
                .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let destination_path = directory.path().join("payload.part");
        let mut destination = File::create(&destination_path).unwrap();

        let started = Instant::now();
        let bytes = transport
            .download_guarded_to(
                &format!("{origin}/file/app.apk"),
                &format!("{origin}/share"),
                &mut destination,
                None,
            )
            .unwrap();
        let elapsed = started.elapsed();
        drop(destination);

        assert_eq!(bytes, 6);
        assert_eq!(std::fs::read(destination_path).unwrap(), b"abcdef");
        assert!(elapsed > idle_timeout);
        server.join().unwrap();
    }

    #[test]
    fn test_guarded_range_download_sends_if_range_and_appends_exact_206() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 4096];
            let count = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..count]).to_ascii_lowercase();
            assert!(request.starts_with("get /file/app.apk "));
            assert!(request.contains("range: bytes=4-"));
            assert!(request.contains("if-range: \"v1\""));
            assert!(request.contains("accept-encoding: identity"));
            stream
                .write_all(
                    b"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 4-9/10\r\nContent-Length: 6\r\nETag: \"v1\"\r\nConnection: close\r\n\r\nefghij",
                )
                .unwrap();
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("payload.part");
        fs::write(&path, b"abcd").unwrap();
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let request = RangeRequest {
            offset: 4,
            validator: super::super::transfer::EntityValidator {
                etag: Some("\"v1\"".to_owned()),
                last_modified: None,
                total_bytes: Some(10),
            },
        };

        let result = transport
            .download_guarded_range_to(
                &format!("{origin}/file/app.apk"),
                &format!("{origin}/share"),
                &mut file,
                &request,
                None,
                None,
            )
            .unwrap();
        drop(file);

        assert_eq!(result.committed_bytes, 10);
        assert_eq!(result.response_bytes, 6);
        assert!(!result.restarted);
        assert_eq!(fs::read(path).unwrap(), b"abcdefghij");
        server.join().unwrap();
    }

    #[test]
    fn test_guarded_range_download_200_restarts_without_appending() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 4096];
            let count = stream.read(&mut request).unwrap();
            assert!(String::from_utf8_lossy(&request[..count])
                .to_ascii_lowercase()
                .contains("range: bytes=4-"));
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nETag: \"v2\"\r\nConnection: close\r\n\r\nnew",
                )
                .unwrap();
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("payload.part");
        fs::write(&path, b"old!").unwrap();
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();

        let result = transport
            .download_guarded_range_to(
                &format!("{origin}/file/app.apk"),
                &format!("{origin}/share"),
                &mut file,
                &RangeRequest {
                    offset: 4,
                    validator: super::super::transfer::EntityValidator {
                        etag: Some("\"v1\"".to_owned()),
                        last_modified: None,
                        total_bytes: Some(9),
                    },
                },
                None,
                None,
            )
            .unwrap();
        drop(file);

        assert!(result.restarted);
        assert_eq!(result.committed_bytes, 3);
        assert_eq!(fs::read(path).unwrap(), b"new");
        server.join().unwrap();
    }

    #[test]
    fn test_guarded_range_download_rejects_html_without_destroying_resume_part() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 1024];
            let _ = stream.read(&mut request);
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 18\r\nConnection: close\r\n\r\n<html>expired</html>",
                )
                .unwrap();
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("payload.part");
        fs::write(&path, b"keep").unwrap();
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();

        let error = transport
            .download_guarded_range_to(
                &format!("{origin}/file/app.apk"),
                &format!("{origin}/share"),
                &mut file,
                &RangeRequest {
                    offset: 4,
                    validator: Default::default(),
                },
                None,
                None,
            )
            .unwrap_err();
        drop(file);

        assert_eq!(error.code, "unexpected_payload");
        assert_eq!(fs::read(path).unwrap(), b"keep");
        server.join().unwrap();
    }

    #[test]
    fn test_guarded_range_pause_interrupts_stalled_body_within_poll_bound() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let (headers_tx, headers_rx) = mpsc::sync_channel(1);
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 1024];
            let _ = stream.read(&mut request);
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\n")
                .unwrap();
            headers_tx.send(()).unwrap();
            thread::sleep(Duration::from_millis(500));
        });
        let transport = LibraryTransport::for_test_with_download_idle_timeout(
            origin.clone(),
            Duration::from_secs(1),
        )
        .unwrap();
        let control = Arc::new(TransferControl::new("range-pause-test").unwrap());
        let lease = control.begin_resolution().unwrap();
        control.begin_downloading(lease).unwrap();
        let worker_control = control.clone();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("payload.part");
        let file = File::create(&path).unwrap();
        let worker_origin = origin.clone();
        let worker = thread::spawn(move || {
            let mut file = file;
            transport.download_guarded_range_to(
                &format!("{worker_origin}/file/app.apk"),
                &format!("{worker_origin}/share"),
                &mut file,
                &RangeRequest::default(),
                None,
                Some((&worker_control, lease)),
            )
        });
        headers_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let started = Instant::now();
        control.request_pause();

        let error = worker.join().unwrap().unwrap_err();
        assert_eq!(error.code, "transfer_paused");
        assert!(started.elapsed() < Duration::from_millis(300));
        assert!(control.acknowledge_paused(lease, 0).unwrap());
        assert_eq!(
            control.status().state,
            super::super::transfer::TransferState::Paused
        );
        assert_eq!(fs::metadata(path).unwrap().len(), 0);
        server.join().unwrap();
    }

    #[test]
    fn test_user_verification_cookie_pool_reuses_site_and_global_keys() {
        import_user_verification_cookie("https://wwc.lanzouw.com/s/demo", "x5sec=ok; acw_tc=kept")
            .unwrap();
        let exact = Url::parse("https://wwc.lanzouw.com/s/other").unwrap();
        let sibling = Url::parse("https://www.lanzouw.com/b1").unwrap();
        let other = Url::parse("https://www.lanzoux.com/b1").unwrap();
        assert!(verification_cookie_for_url(&exact).contains("x5sec=ok"));
        assert!(verification_cookie_for_url(&sibling).contains("acw_tc=kept"));
        assert!(verification_cookie_for_url(&other).contains("x5sec=ok"));
    }

    #[test]
    fn test_user_verification_cookie_rejects_non_lanzou_hosts() {
        assert!(import_user_verification_cookie("https://example.com/", "x5sec=bad").is_err());
        assert!(import_user_verification_cookie("https://www.lanzouw.com/", "bad\nvalue").is_err());
    }
}
