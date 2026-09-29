use std::{
    collections::BTreeMap,
    fs::File,
    io::{Read, Write},
    path::Path,
    sync::Arc,
    thread,
    time::Duration,
};

use reqwest::{
    blocking::{multipart, Client, RequestBuilder},
    cookie::{CookieStore, Jar},
    header::{HeaderMap, CONTENT_TYPE, COOKIE, ORIGIN, REFERER, USER_AGENT},
    redirect::Policy,
    Method,
};

use crate::{
    acw,
    error::{CoreError, CoreResult},
    operation::OperationHandle,
};

const USER_AGENT_VALUE: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 LanzouYOU/0.1";

#[derive(Debug, Clone)]
pub struct Bases {
    pub pc: String,
    pub up: String,
}

impl Default for Bases {
    fn default() -> Self {
        Self {
            pc: "https://pc.woozooo.com".to_owned(),
            up: "https://up.woozooo.com".to_owned(),
        }
    }
}

#[derive(Debug)]
pub struct ResponseData {
    pub status: u16,
    pub headers: HeaderMap,
    pub body: Vec<u8>,
}

impl ResponseData {
    pub fn text(&self) -> CoreResult<&str> {
        std::str::from_utf8(&self.body).map_err(|_| CoreError::parse("蓝奏云返回了非 UTF-8 文本"))
    }
}

enum RequestData<'a> {
    Get(&'a [(String, String)]),
    Form(&'a BTreeMap<String, String>),
}

#[derive(Default)]
struct RequestOptions<'a> {
    no_redirect: bool,
    referer: Option<&'a str>,
    ajax: bool,
}

pub struct HttpClient {
    follow: Client,
    no_redirect: Client,
    pub bases: Bases,
    cookies: Arc<Jar>,
    trusted_oss_host: String,
    allow_insecure_oss: bool,
}

impl HttpClient {
    pub fn new() -> CoreResult<Self> {
        Self::with_bases(Bases::default(), "imgup.woozooo.com".to_owned(), false)
    }

    fn with_bases(
        bases: Bases,
        trusted_oss_host: String,
        allow_insecure_oss: bool,
    ) -> CoreResult<Self> {
        let cookies = Arc::new(Jar::default());
        let follow = Client::builder()
            .use_rustls_tls()
            .http1_only()
            .cookie_provider(cookies.clone())
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(10))
            .build()
            .map_err(CoreError::from_reqwest)?;
        let no_redirect = Client::builder()
            .use_rustls_tls()
            .http1_only()
            .cookie_provider(cookies.clone())
            .redirect(Policy::none())
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(10))
            .build()
            .map_err(CoreError::from_reqwest)?;
        Ok(Self {
            follow,
            no_redirect,
            bases,
            cookies,
            trusted_oss_host,
            allow_insecure_oss,
        })
    }

    #[cfg(test)]
    pub fn for_test(base: String) -> CoreResult<Self> {
        let host = reqwest::Url::parse(&base)
            .ok()
            .and_then(|url| url.host_str().map(ToOwned::to_owned))
            .unwrap_or_else(|| "127.0.0.1".to_owned());
        Self::with_bases(
            Bases {
                pc: base.clone(),
                up: base,
            },
            host,
            true,
        )
    }

    pub fn get(
        &self,
        url: &str,
        cookie: &str,
        query: &[(String, String)],
    ) -> CoreResult<ResponseData> {
        self.request(
            Method::GET,
            url,
            cookie,
            RequestData::Get(query),
            RequestOptions::default(),
        )
    }

    pub fn get_no_redirect_with_referer(
        &self,
        url: &str,
        cookie: &str,
        query: &[(String, String)],
        referer: &str,
    ) -> CoreResult<ResponseData> {
        self.request(
            Method::GET,
            url,
            cookie,
            RequestData::Get(query),
            RequestOptions {
                no_redirect: true,
                referer: Some(referer),
                ..RequestOptions::default()
            },
        )
    }

    pub fn post_form(
        &self,
        url: &str,
        cookie: &str,
        form: &BTreeMap<String, String>,
    ) -> CoreResult<ResponseData> {
        self.request(
            Method::POST,
            url,
            cookie,
            RequestData::Form(form),
            RequestOptions::default(),
        )
    }

    pub fn post_form_ajax(
        &self,
        url: &str,
        cookie: &str,
        form: &BTreeMap<String, String>,
        referer: &str,
    ) -> CoreResult<ResponseData> {
        self.request(
            Method::POST,
            url,
            cookie,
            RequestData::Form(form),
            RequestOptions {
                referer: Some(referer),
                ajax: true,
                ..RequestOptions::default()
            },
        )
    }

    pub fn post_form_no_redirect(
        &self,
        url: &str,
        cookie: &str,
        form: &BTreeMap<String, String>,
    ) -> CoreResult<ResponseData> {
        self.request(
            Method::POST,
            url,
            cookie,
            RequestData::Form(form),
            RequestOptions {
                no_redirect: true,
                ..RequestOptions::default()
            },
        )
    }

    fn request(
        &self,
        method: Method,
        url: &str,
        cookie: &str,
        data: RequestData<'_>,
        options: RequestOptions<'_>,
    ) -> CoreResult<ResponseData> {
        let RequestOptions {
            no_redirect,
            referer,
            ajax,
        } = options;
        let safe_to_retry = method == Method::GET;
        let client = if no_redirect {
            &self.no_redirect
        } else {
            &self.follow
        };
        let mut last_error = None;
        for attempt in 0..3 {
            let mut request = client.request(method.clone(), url);
            request = self.common_headers(request, cookie, url, referer)?;
            if ajax {
                let referer = referer.ok_or_else(|| CoreError::invalid("AJAX 请求缺少来源地址"))?;
                request = request
                    .header(ORIGIN, request_origin(referer)?)
                    .header("X-Requested-With", "XMLHttpRequest");
            }
            request = match data {
                RequestData::Get(query) => request.query(query),
                RequestData::Form(form) => request.form(form),
            };
            match request.send() {
                Ok(response) => {
                    let status = response.status();
                    let headers = response.headers().clone();
                    let body = match response.bytes() {
                        Ok(body) => body.to_vec(),
                        Err(error) if safe_to_retry => {
                            last_error = Some(CoreError::from_reqwest(error));
                            if attempt < 2 {
                                continue;
                            }
                            return Err(last_error
                                .unwrap_or_else(|| CoreError::remote("响应读取失败", true)));
                        }
                        Err(_) => {
                            return Err(CoreError::ambiguous(
                                "响应中断导致操作结果未知，未自动重放",
                            ))
                        }
                    };
                    if status.is_server_error() {
                        if safe_to_retry && attempt < 2 {
                            thread::sleep(Duration::from_millis(200 * (attempt + 1) as u64));
                            continue;
                        }
                        if !safe_to_retry {
                            return Err(CoreError::ambiguous(
                                "请求结果未知，未自动重放以避免重复操作",
                            ));
                        }
                    }
                    if is_remote_busy(&body) {
                        if safe_to_retry && attempt < 2 {
                            thread::sleep(Duration::from_millis(300 * (attempt + 1) as u64));
                            continue;
                        }
                        if !safe_to_retry {
                            return Err(CoreError::ambiguous("服务繁忙且操作结果未知，未自动重放"));
                        }
                        return Err(CoreError::remote("蓝奏云服务繁忙", true));
                    }
                    if let Some(value) = acw::challenge_cookie(&String::from_utf8_lossy(&body))? {
                        self.store_cookie(url, &format!("acw_sc__v2={value}; Path=/"))?;
                        if attempt < 2 {
                            continue;
                        }
                        return Err(CoreError::remote("acw_sc__v2 验证失败", true));
                    }
                    if !status.is_success() && !status.is_redirection() {
                        return Err(CoreError::remote(
                            format!("蓝奏云 HTTP 状态异常: {}", status.as_u16()),
                            status.is_server_error(),
                        ));
                    }
                    return Ok(ResponseData {
                        status: status.as_u16(),
                        headers,
                        body,
                    });
                }
                Err(error) => {
                    if !safe_to_retry {
                        return Err(CoreError::ambiguous("网络中断导致操作结果未知，未自动重放"));
                    }
                    last_error = Some(CoreError::from_reqwest(error));
                    if attempt < 2 {
                        thread::sleep(Duration::from_millis(200 * (attempt + 1) as u64));
                    }
                }
            }
        }
        Err(last_error.unwrap_or_else(|| CoreError::remote("请求失败", true)))
    }

    pub fn upload(
        &self,
        url: &str,
        cookie: &str,
        fields: &BTreeMap<String, String>,
        file_path: &Path,
        remote_name: &str,
    ) -> CoreResult<ResponseData> {
        self.upload_with_operation(url, cookie, fields, file_path, remote_name, None)
    }

    pub fn upload_with_operation(
        &self,
        url: &str,
        cookie: &str,
        fields: &BTreeMap<String, String>,
        file_path: &Path,
        remote_name: &str,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<ResponseData> {
        self.upload_with_progress_window(
            url,
            cookie,
            fields,
            file_path,
            remote_name,
            operation,
            None,
        )
    }

    pub(crate) fn upload_with_progress_window(
        &self,
        url: &str,
        cookie: &str,
        fields: &BTreeMap<String, String>,
        file_path: &Path,
        remote_name: &str,
        operation: Option<&OperationHandle>,
        progress_window: Option<UploadProgressWindow>,
    ) -> CoreResult<ResponseData> {
        for attempt in 0..3 {
            if let Some(operation) = operation {
                operation.check_cancelled()?;
            }
            let file = File::open(file_path)?;
            let length = file.metadata()?.len();
            if let Some(operation) = operation {
                let window = progress_window.unwrap_or(UploadProgressWindow {
                    base_bytes: 0,
                    total_bytes: length,
                });
                operation.set_transfer_progress(
                    window.base_bytes,
                    window
                        .total_bytes
                        .max(window.base_bytes.saturating_add(length)),
                );
            }
            let reader = ProgressReader::new(file, operation.cloned());
            let part = multipart::Part::reader_with_length(reader, length)
                .file_name(remote_name.to_owned())
                .mime_str("application/octet-stream")
                .map_err(CoreError::from_reqwest)?;
            let mut form = multipart::Form::new().part("upload_file", part);
            for (key, value) in fields {
                form = form.text(key.clone(), value.clone());
            }
            let request = self
                .common_headers(self.follow.post(url), cookie, url, None)?
                .timeout(Duration::from_secs(3600))
                .multipart(form);
            match request.send() {
                Ok(response) => {
                    let status = response.status();
                    let headers = response.headers().clone();
                    let body = response
                        .bytes()
                        .map_err(|_| CoreError::ambiguous("上传响应中断导致结果未知，未自动重放"))?
                        .to_vec();
                    if status.is_server_error() {
                        return Err(CoreError::ambiguous(
                            "上传结果未知，未自动重放以避免重复文件",
                        ));
                    }
                    if is_remote_busy(&body) {
                        return Err(CoreError::ambiguous("上传服务繁忙且结果未知，未自动重放"));
                    }
                    if let Some(value) = acw::challenge_cookie(&String::from_utf8_lossy(&body))? {
                        self.store_cookie(url, &format!("acw_sc__v2={value}; Path=/"))?;
                        if attempt < 2 {
                            continue;
                        }
                        return Err(CoreError::remote("上传 acw_sc__v2 验证失败", true));
                    }
                    if !status.is_success() {
                        return Err(CoreError::remote(
                            format!("上传 HTTP 状态异常: {}", status.as_u16()),
                            status.is_server_error(),
                        ));
                    }
                    return Ok(ResponseData {
                        status: status.as_u16(),
                        headers,
                        body,
                    });
                }
                Err(_) if operation.is_some_and(OperationHandle::is_cancellation_requested) => {
                    return Err(CoreError::cancelled())
                }
                Err(_) => return Err(CoreError::ambiguous("网络中断导致上传结果未知，未自动重放")),
            }
        }
        Err(CoreError::remote("上传 acw_sc__v2 验证失败", true))
    }

    pub fn upload_icon_oss(
        &self,
        url: &str,
        fields: &BTreeMap<String, String>,
        file_path: &Path,
        extension: &str,
        media_type: &str,
    ) -> CoreResult<ResponseData> {
        self.validate_icon_oss_url(url)?;
        let file = File::open(file_path)?;
        let length = file.metadata()?.len();
        let part = multipart::Part::reader_with_length(file, length)
            .file_name(format!("icon.{extension}"))
            .mime_str(media_type)
            .map_err(CoreError::from_reqwest)?;
        let mut form = multipart::Form::new();
        for (key, value) in fields {
            form = form.text(key.clone(), value.clone());
        }
        // Aliyun OSS POST policies require form fields before the file part;
        // browsers and `requests` also serialize the file last.
        form = form.part("file", part);
        let response = self
            .no_redirect
            .post(url)
            .header(USER_AGENT, USER_AGENT_VALUE)
            .header(ORIGIN, &self.bases.pc)
            .header(REFERER, format!("{}/", self.bases.pc.trim_end_matches('/')))
            .timeout(Duration::from_secs(120))
            .multipart(form)
            .send()
            .map_err(|_| CoreError::ambiguous("OSS 图标上传结果未知，未自动重放"))?;
        let status = response.status();
        let headers = response.headers().clone();
        let body = response
            .bytes()
            .map_err(|_| CoreError::ambiguous("OSS 上传响应中断导致结果未知"))?
            .to_vec();
        if matches!(status.as_u16(), 200 | 203) {
            return Ok(ResponseData {
                status: status.as_u16(),
                headers,
                body,
            });
        }
        if status.is_server_error() {
            return Err(CoreError::ambiguous("OSS 图标上传结果未知，未自动重放"));
        }
        if status.is_redirection() {
            return Err(CoreError::remote("OSS 图标上传拒绝跨域重定向", false));
        }
        Err(CoreError::remote(
            format!("OSS 图标上传 HTTP 状态异常: {}", status.as_u16()),
            false,
        ))
    }

    pub fn validate_icon_oss_url(&self, value: &str) -> CoreResult<reqwest::Url> {
        let url = reqwest::Url::parse(value).map_err(|_| CoreError::invalid("图标上传地址无效"))?;
        let scheme_ok =
            url.scheme() == "https" || (self.allow_insecure_oss && url.scheme() == "http");
        let port_ok = if self.allow_insecure_oss {
            true
        } else {
            matches!(url.port(), None | Some(443))
        };
        if !scheme_ok
            || url.host_str() != Some(self.trusted_oss_host.as_str())
            || !url.username().is_empty()
            || url.password().is_some()
            || !port_ok
        {
            return Err(CoreError::invalid("图标上传地址不是受信 OSS 主机"));
        }
        Ok(url)
    }

    pub fn download(&self, url: &str, cookie: &str, destination: &Path) -> CoreResult<u64> {
        self.download_with_operation(url, cookie, destination, None)
    }

    pub fn download_with_operation(
        &self,
        url: &str,
        cookie: &str,
        destination: &Path,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<u64> {
        for attempt in 0..3 {
            if let Some(operation) = operation {
                operation.check_cancelled()?;
            }
            let request = self
                .common_headers(self.follow.get(url), cookie, url, None)?
                .timeout(Duration::from_secs(3600));
            let mut response = match request.send() {
                Ok(response) => response,
                Err(_) if operation.is_some_and(OperationHandle::is_cancellation_requested) => {
                    return Err(CoreError::cancelled())
                }
                Err(error) => return Err(CoreError::from_reqwest(error)),
            };
            if !response.status().is_success() {
                if response.status().is_server_error() && attempt < 2 {
                    continue;
                }
                return Err(CoreError::remote(
                    format!("下载 HTTP 状态异常: {}", response.status().as_u16()),
                    response.status().is_server_error(),
                ));
            }
            if let Some(operation) = operation {
                operation.check_cancelled()?;
            }
            let is_html = response
                .headers()
                .get(CONTENT_TYPE)
                .and_then(|value| value.to_str().ok())
                .map(|value| value.to_ascii_lowercase().contains("text/html"))
                .unwrap_or(false);
            if is_html {
                let body = response.bytes().map_err(|error| {
                    if operation.is_some_and(OperationHandle::is_cancellation_requested) {
                        CoreError::cancelled()
                    } else {
                        CoreError::from_reqwest(error)
                    }
                })?;
                if let Some(value) = acw::challenge_cookie(&String::from_utf8_lossy(&body))? {
                    self.store_cookie(url, &format!("acw_sc__v2={value}; Path=/"))?;
                    if attempt < 2 {
                        continue;
                    }
                    return Err(CoreError::remote("下载 acw_sc__v2 验证失败", true));
                }
                return Err(CoreError::remote("下载地址返回了网页而非文件", true));
            }
            let mut file = File::create(destination)?;
            let declared_total = response.content_length().unwrap_or(0);
            if let Some(operation) = operation {
                operation.set_transfer_progress(0, declared_total);
            }
            let bytes = copy_stream_with_operation(&mut response, &mut file, operation)?;
            if let Some(operation) = operation {
                operation.set_transfer_progress(bytes, declared_total.max(bytes));
            }
            return Ok(bytes);
        }
        Err(CoreError::remote("下载重试次数已用尽", true))
    }

    fn common_headers(
        &self,
        request: RequestBuilder,
        cookie: &str,
        url: &str,
        referer: Option<&str>,
    ) -> CoreResult<RequestBuilder> {
        let mut cookies = cookie.trim().to_owned();
        if url.contains("/file/") {
            append_cookie(&mut cookies, "down_ip=1");
        }
        let stored = self.cookies_for_url(url)?;
        if !stored.is_empty() {
            cookies = merge_cookie_headers(&cookies, &stored);
        }
        let mut request = request
            .header(USER_AGENT, USER_AGENT_VALUE)
            .header(REFERER, referer.unwrap_or(&self.bases.pc));
        if !cookies.is_empty() {
            request = request.header(COOKIE, cookies);
        }
        Ok(request)
    }

    pub fn cookies_for_url(&self, url: &str) -> CoreResult<String> {
        let parsed = reqwest::Url::parse(url).map_err(|_| CoreError::invalid("HTTP 地址无效"))?;
        Ok(self
            .cookies
            .cookies(&parsed)
            .and_then(|value| value.to_str().ok().map(ToOwned::to_owned))
            .unwrap_or_default())
    }

    fn store_cookie(&self, url: &str, cookie: &str) -> CoreResult<()> {
        let parsed = reqwest::Url::parse(url).map_err(|_| CoreError::invalid("HTTP 地址无效"))?;
        self.cookies.add_cookie_str(cookie, &parsed);
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct UploadProgressWindow {
    pub(crate) base_bytes: u64,
    pub(crate) total_bytes: u64,
}

struct ProgressReader<R> {
    inner: R,
    operation: Option<OperationHandle>,
}

impl<R> ProgressReader<R> {
    fn new(inner: R, operation: Option<OperationHandle>) -> Self {
        Self { inner, operation }
    }
}

impl<R: Read> Read for ProgressReader<R> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if self
            .operation
            .as_ref()
            .is_some_and(OperationHandle::is_cancellation_requested)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "operation cancelled",
            ));
        }
        let read = self.inner.read(buffer)?;
        if let Some(operation) = &self.operation {
            operation.add_transferred_bytes(read);
        }
        Ok(read)
    }
}

fn copy_stream_with_operation(
    reader: &mut impl Read,
    writer: &mut impl Write,
    operation: Option<&OperationHandle>,
) -> CoreResult<u64> {
    let mut buffer = [0_u8; 64 * 1024];
    let mut copied = 0_u64;
    loop {
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        let read = match reader.read(&mut buffer) {
            Ok(read) => read,
            Err(_) if operation.is_some_and(OperationHandle::is_cancellation_requested) => {
                return Err(CoreError::cancelled())
            }
            Err(error) => return Err(CoreError::from(error)),
        };
        if read == 0 {
            break;
        }
        if let Err(error) = writer.write_all(&buffer[..read]) {
            if operation.is_some_and(OperationHandle::is_cancellation_requested) {
                return Err(CoreError::cancelled());
            }
            return Err(CoreError::from(error));
        }
        copied = copied.saturating_add(u64::try_from(read).unwrap_or(u64::MAX));
        if let Some(operation) = operation {
            operation.add_transferred_bytes(read);
        }
    }
    if let Some(operation) = operation {
        operation.check_cancelled()?;
    }
    if let Err(error) = writer.flush() {
        if operation.is_some_and(OperationHandle::is_cancellation_requested) {
            return Err(CoreError::cancelled());
        }
        return Err(CoreError::from(error));
    }
    Ok(copied)
}

fn append_cookie(target: &mut String, value: &str) {
    if !target.is_empty() {
        target.push_str("; ");
    }
    target.push_str(value);
}

fn request_origin(value: &str) -> CoreResult<String> {
    let url = reqwest::Url::parse(value).map_err(|_| CoreError::invalid("HTTP 来源地址无效"))?;
    let host = url
        .host_str()
        .ok_or_else(|| CoreError::invalid("HTTP 来源地址缺少域名"))?;
    let port = url
        .port()
        .map(|value| format!(":{value}"))
        .unwrap_or_default();
    Ok(format!("{}://{}{}", url.scheme(), host, port))
}

fn is_remote_busy(body: &[u8]) -> bool {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|value| value.get("zt").cloned())
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
        })
        == Some(4)
}

pub fn response_cookies(headers: &HeaderMap) -> String {
    headers
        .get_all(reqwest::header::SET_COOKIE)
        .iter()
        .filter_map(|header| header.to_str().ok())
        .filter_map(|cookie| cookie.split(';').next())
        .filter(|cookie| cookie.contains('='))
        .collect::<Vec<_>>()
        .join("; ")
}

pub fn merge_cookie_headers(first: &str, second: &str) -> String {
    let mut values = BTreeMap::new();
    for header in [first, second] {
        for cookie in header
            .split(';')
            .map(str::trim)
            .filter(|item| !item.is_empty())
        {
            let Some((name, value)) = cookie.split_once('=') else {
                continue;
            };
            if !name.is_empty() {
                values.insert(name.to_owned(), value.to_owned());
            }
        }
    }
    values
        .into_iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join("; ")
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::mpsc,
        time::Duration,
    };

    use super::*;

    #[test]
    fn test_http_mock_retries_acw_challenge_without_exposing_body() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (sender, receiver) = mpsc::channel();
        let server = std::thread::spawn(move || {
            for index in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buffer = [0_u8; 4096];
                let read = stream.read(&mut buffer).unwrap();
                let request = String::from_utf8_lossy(&buffer[..read]).to_string();
                sender.send(request).unwrap();
                let body = if index == 0 {
                    "<script>var arg1='0123456789ABCDEF0123456789ABCDEF01234567';</script>"
                } else {
                    r#"{"zt":1,"text":[]}"#
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\n{}Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                    if index == 0 {
                        "Set-Cookie: acw_tc=preflight; Path=/; HttpOnly\r\n"
                    } else {
                        ""
                    },
                    body.len(),
                    body
                )
                .unwrap();
            }
        });
        let base = format!("http://{address}");
        let client = HttpClient::for_test(base.clone()).unwrap();
        let response = client.get(&base, "", &[]).unwrap();
        assert_eq!(response.status, 200);
        let _first = receiver.recv().unwrap();
        let second = receiver.recv().unwrap();
        assert!(second.contains("acw_tc=preflight"));
        assert!(second.contains("acw_sc__v2=d2c7186598ab1a508a4f6064e4fa746323ab17c6"));
        server.join().unwrap();
    }

    #[test]
    fn test_http_mock_retries_remote_busy_status() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            for index in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buffer = [0_u8; 1024];
                let _ = stream.read(&mut buffer).unwrap();
                let body = if index < 2 {
                    r#"{"zt":4}"#
                } else {
                    r#"{"zt":1,"text":[]}"#
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                )
                .unwrap();
            }
        });
        let base = format!("http://{address}");
        let client = HttpClient::for_test(base.clone()).unwrap();
        assert_eq!(client.get(&base, "", &[]).unwrap().status, 200);
        server.join().unwrap();
    }

    #[test]
    fn test_get_decodes_gzip_authenticated_html() {
        const GZIP_HTML: &[u8] = &[
            31, 139, 8, 0, 0, 0, 0, 0, 2, 10, 179, 201, 40, 201, 205, 177, 43, 205, 76, 177, 53,
            180, 86, 40, 75, 205, 180, 85, 55, 82, 183, 209, 7, 11, 2, 0, 100, 228, 176, 154, 27,
            0, 0, 0,
        ];
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0_u8; 1024];
            let _ = stream.read(&mut buffer).unwrap();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                GZIP_HTML.len()
            )
            .unwrap();
            stream.write_all(GZIP_HTML).unwrap();
        });
        let base = format!("http://{address}");
        let client = HttpClient::for_test(base.clone()).unwrap();

        let response = client.get(&base, "", &[]).unwrap();

        assert_eq!(response.text().unwrap(), "<html>uid=1; vei='2'</html>");
        server.join().unwrap();
    }

    #[test]
    fn test_download_http_mock_retries_acw_before_writing_file() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            for index in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buffer = [0_u8; 2048];
                let _ = stream.read(&mut buffer).unwrap();
                let (content_type, body): (&str, &[u8]) = if index == 0 {
                    (
                        "text/html",
                        b"<script>var arg1='0123456789ABCDEF0123456789ABCDEF01234567';</script>",
                    )
                } else {
                    ("application/octet-stream", b"payload")
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                )
                .unwrap();
                stream.write_all(body).unwrap();
            }
        });
        let base = format!("http://{address}");
        let client = HttpClient::for_test(base.clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let destination = directory.path().join("download.bin");
        assert_eq!(client.download(&base, "", &destination).unwrap(), 7);
        assert_eq!(std::fs::read(destination).unwrap(), b"payload");
        server.join().unwrap();
    }

    #[test]
    fn test_post_form_does_not_replay_ambiguous_server_error() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0_u8; 2048];
            let _ = stream.read(&mut buffer).unwrap();
            let body = "server failure";
            write!(
                stream,
                "HTTP/1.1 500 Error\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let base = format!("http://{address}");
        let client = HttpClient::for_test(base.clone()).unwrap();

        let error = client.post_form(&base, "", &BTreeMap::new()).unwrap_err();

        assert_eq!(error.code, "ambiguous_result");
        server.join().unwrap();
    }

    #[test]
    fn test_upload_does_not_replay_ambiguous_server_error() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0_u8; 4096];
            let _ = stream.read(&mut buffer).unwrap();
            let body = "server failure";
            write!(
                stream,
                "HTTP/1.1 500 Error\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let base = format!("http://{address}");
        let client = HttpClient::for_test(base.clone()).unwrap();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("payload.bin");
        std::fs::write(&path, b"payload").unwrap();

        let error = client
            .upload(&base, "", &BTreeMap::new(), &path, "payload.bin")
            .unwrap_err();

        assert_eq!(error.code, "ambiguous_result");
        server.join().unwrap();
    }

    #[test]
    fn test_post_form_maps_truncated_response_to_ambiguous_result() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0_u8; 2048];
            let _ = stream.read(&mut buffer).unwrap();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort"
            )
            .unwrap();
        });
        let base = format!("http://{address}");
        let client = HttpClient::for_test(base.clone()).unwrap();

        let error = client.post_form(&base, "", &BTreeMap::new()).unwrap_err();

        assert_eq!(error.code, "ambiguous_result");
        server.join().unwrap();
    }

    struct SlowReader {
        remaining: usize,
    }

    impl Read for SlowReader {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            if self.remaining == 0 {
                return Ok(0);
            }
            std::thread::sleep(Duration::from_millis(5));
            let read = self.remaining.min(buffer.len()).min(1_024);
            buffer[..read].fill(7);
            self.remaining -= read;
            Ok(read)
        }
    }

    #[test]
    fn test_slow_stream_copy_reports_progress_and_honors_cancellation() {
        let operation = crate::operation::begin(
            Some("slow-download-stream-test"),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        operation.set_transfer_progress(0, 512 * 1_024);
        let worker_operation = operation.clone();
        let worker = std::thread::spawn(move || {
            let mut reader = SlowReader {
                remaining: 512 * 1_024,
            };
            let mut output = Vec::new();
            let result =
                copy_stream_with_operation(&mut reader, &mut output, Some(&worker_operation));
            worker_operation.finish_result(&result);
            result
        });

        std::thread::sleep(Duration::from_millis(25));
        let cancelling = crate::operation::cancel("slow-download-stream-test").unwrap();
        assert_eq!(cancelling["state"], "cancelling");
        let error = worker.join().unwrap().unwrap_err();
        assert_eq!(error.code, "cancelled");
        let status = crate::operation::status("slow-download-stream-test").unwrap();
        assert_eq!(status["state"], "cancelled");
        assert!(status["bytesTransferred"].as_u64().unwrap() > 0);
        assert!(status["bytesTransferred"].as_u64().unwrap() < 512 * 1_024);
        crate::operation::forget("slow-download-stream-test").unwrap();
    }

    #[test]
    fn test_upload_reader_counts_bytes_and_interrupts_after_cancel() {
        let operation = crate::operation::begin(
            Some("upload-reader-test"),
            crate::operation::OperationKind::Upload,
        )
        .unwrap()
        .unwrap();
        operation.set_transfer_progress(0, 6);
        let mut reader = ProgressReader::new(
            std::io::Cursor::new(b"abcdef".to_vec()),
            Some(operation.clone()),
        );
        let mut buffer = [0_u8; 3];
        assert_eq!(reader.read(&mut buffer).unwrap(), 3);
        assert_eq!(
            crate::operation::status("upload-reader-test").unwrap()["bytesTransferred"],
            3
        );
        crate::operation::cancel("upload-reader-test").unwrap();
        let error = reader.read(&mut buffer).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::Interrupted);
        operation.finish_cancelled();
        crate::operation::forget("upload-reader-test").unwrap();
    }

    #[test]
    fn test_directory_upload_progress_windows_never_regress_between_files() {
        let operation = crate::operation::begin(
            Some("directory-upload-window-test"),
            crate::operation::OperationKind::DirectoryUpload,
        )
        .unwrap()
        .unwrap();
        operation.set_transfer_progress(0, 6);
        let mut first = ProgressReader::new(
            std::io::Cursor::new(b"abc".to_vec()),
            Some(operation.clone()),
        );
        std::io::copy(&mut first, &mut std::io::sink()).unwrap();
        let first_status = operation.status();
        assert_eq!(first_status.bytes_transferred, 3);

        operation.set_transfer_progress(3, 6);
        let mut second = ProgressReader::new(
            std::io::Cursor::new(b"def".to_vec()),
            Some(operation.clone()),
        );
        std::io::copy(&mut second, &mut std::io::sink()).unwrap();
        let second_status = operation.status();
        assert_eq!(second_status.bytes_transferred, 6);
        assert!(second_status.bytes_transferred >= first_status.bytes_transferred);

        operation.finish_success();
        crate::operation::forget("directory-upload-window-test").unwrap();
    }
}
