use std::{
    collections::{BTreeMap, HashMap, HashSet, VecDeque},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use once_cell::sync::Lazy;
use reqwest::Url;

use crate::{
    error::{CoreError, CoreResult},
    operation::OperationHandle,
};

use super::{
    api::{self, ItemContext, PageState},
    html::{self, ParsedPage},
    model::{
        LibraryCollectResult, LibraryFolder, LibraryItem, LibraryProbeResult, LibrarySource,
        LibrarySourceKind, PublicLibrarySource,
    },
    rate_limit::RateLimiter,
    security::sanitize_access_code_error,
    session::{LibraryTransport, ANDROID_USER_AGENT, DESKTOP_USER_AGENT},
    url::{
        join_page_url, normalize_public_share_url, origin, parse_folder_target, safe_asset_url,
        same_origin_endpoint, validate_page_url, FolderTarget, SecurityPolicy,
    },
};

const PAGE_SIZE: usize = 50;
const MAX_RECURSIVE_PAGES: u32 = 100;
const MAX_LIBRARY_SOURCES: usize = 4_096;
const MAX_COLLECT_ROOTS: usize = 1_000;
const MAX_COLLECT_FOLDERS: usize = 10_000;
const MAX_COLLECT_FILES: usize = 50_000;
const UNKNOWN_INITIAL_INTERVAL_MS: u64 = 2_100;
const UNKNOWN_NEXT_INTERVAL_MS: u64 = 1_000;
const MAX_PAGE_INTERVAL_MS: u64 = 8_400;
const MAX_SOURCE_PROFILES: usize = 512;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DirectoryAgent {
    Android,
    Desktop,
}

impl DirectoryAgent {
    fn other(self) -> Self {
        match self {
            Self::Android => Self::Desktop,
            Self::Desktop => Self::Android,
        }
    }

    fn user_agent(self) -> &'static str {
        match self {
            Self::Android => ANDROID_USER_AGENT,
            Self::Desktop => DESKTOP_USER_AGENT,
        }
    }

    fn key(self) -> &'static str {
        match self {
            Self::Android => "android",
            Self::Desktop => "desktop",
        }
    }
}

#[derive(Clone, Debug)]
struct SourceProfile {
    preferred_directory: Option<DirectoryAgent>,
    android_template: html::PageTemplate,
    desktop_template: html::PageTemplate,
    android_initial_ms: u64,
    android_next_ms: u64,
    desktop_initial_ms: u64,
    desktop_next_ms: u64,
}

impl Default for SourceProfile {
    fn default() -> Self {
        Self {
            preferred_directory: None,
            android_template: html::PageTemplate::Unknown,
            desktop_template: html::PageTemplate::Unknown,
            android_initial_ms: UNKNOWN_INITIAL_INTERVAL_MS,
            android_next_ms: UNKNOWN_NEXT_INTERVAL_MS,
            desktop_initial_ms: UNKNOWN_INITIAL_INTERVAL_MS,
            desktop_next_ms: UNKNOWN_NEXT_INTERVAL_MS,
        }
    }
}

impl SourceProfile {
    fn observe_template(&mut self, agent: DirectoryAgent, template: html::PageTemplate) {
        if template == html::PageTemplate::Unknown {
            return;
        }
        let target = match agent {
            DirectoryAgent::Android => &mut self.android_template,
            DirectoryAgent::Desktop => &mut self.desktop_template,
        };
        if *target == template {
            return;
        }
        *target = template;
        self.refresh_intervals();
    }

    fn refresh_intervals(&mut self) {
        self.android_initial_ms = template_initial_ms(
            DirectoryAgent::Android,
            self.android_template,
            self.desktop_template,
        );
        self.android_next_ms = template_next_ms(
            DirectoryAgent::Android,
            self.android_template,
            self.desktop_template,
        );
        self.desktop_initial_ms = template_initial_ms(
            DirectoryAgent::Desktop,
            self.desktop_template,
            self.android_template,
        );
        self.desktop_next_ms = template_next_ms(
            DirectoryAgent::Desktop,
            self.desktop_template,
            self.android_template,
        );
    }

    fn interval_ms(&self, agent: DirectoryAgent, page: u32) -> u64 {
        match (agent, page <= 1) {
            (DirectoryAgent::Android, true) => self.android_initial_ms,
            (DirectoryAgent::Android, false) => self.android_next_ms,
            (DirectoryAgent::Desktop, true) => self.desktop_initial_ms,
            (DirectoryAgent::Desktop, false) => self.desktop_next_ms,
        }
    }

    fn backoff_ms(&mut self, agent: DirectoryAgent, page: u32) -> u64 {
        let current = self.interval_ms(agent, page);
        let next = current
            .saturating_mul(2)
            .max(current.saturating_add(300))
            .min(MAX_PAGE_INTERVAL_MS);
        match (agent, page <= 1) {
            (DirectoryAgent::Android, true) => self.android_initial_ms = next,
            (DirectoryAgent::Android, false) => self.android_next_ms = next,
            (DirectoryAgent::Desktop, true) => self.desktop_initial_ms = next,
            (DirectoryAgent::Desktop, false) => self.desktop_next_ms = next,
        }
        next
    }
}

fn template_initial_ms(
    agent: DirectoryAgent,
    template: html::PageTemplate,
    peer_template: html::PageTemplate,
) -> u64 {
    match (agent, template) {
        (DirectoryAgent::Desktop, html::PageTemplate::Minimal) => 2_100,
        (DirectoryAgent::Android, html::PageTemplate::Minimal)
            if peer_template == html::PageTemplate::Minimal =>
        {
            1_800
        }
        (DirectoryAgent::Android, html::PageTemplate::Minimal) => 2_100,
        (_, html::PageTemplate::Classic) => 1_800,
        (_, html::PageTemplate::Unknown) => UNKNOWN_INITIAL_INTERVAL_MS,
    }
}

fn template_next_ms(
    agent: DirectoryAgent,
    template: html::PageTemplate,
    peer_template: html::PageTemplate,
) -> u64 {
    match (agent, template) {
        (DirectoryAgent::Desktop, html::PageTemplate::Minimal) => 1_000,
        (DirectoryAgent::Android, html::PageTemplate::Minimal)
            if peer_template == html::PageTemplate::Minimal =>
        {
            500
        }
        (DirectoryAgent::Android, html::PageTemplate::Minimal) => 800,
        (_, html::PageTemplate::Classic) => 500,
        (_, html::PageTemplate::Unknown) => UNKNOWN_NEXT_INTERVAL_MS,
    }
}

#[derive(Default)]
struct SourceProfileStore {
    profiles: HashMap<String, SourceProfile>,
    recency: VecDeque<String>,
}

impl SourceProfileStore {
    fn with_profile<R>(&mut self, key: &str, operation: impl FnOnce(&mut SourceProfile) -> R) -> R {
        if self.profiles.contains_key(key) {
            self.touch(key);
        } else {
            while self.profiles.len() >= MAX_SOURCE_PROFILES {
                let candidate = self.recency.pop_front().or_else(|| {
                    self.profiles
                        .keys()
                        .filter(|candidate| candidate.as_str() != key)
                        .min()
                        .cloned()
                });
                let Some(candidate) = candidate else {
                    break;
                };
                if candidate != key && self.profiles.remove(&candidate).is_some() {
                    break;
                }
            }
            self.profiles
                .insert(key.to_owned(), SourceProfile::default());
            self.recency.push_back(key.to_owned());
        }
        operation(
            self.profiles
                .get_mut(key)
                .expect("current source profile must exist"),
        )
    }

    fn preferred(&mut self, key: &str) -> Option<DirectoryAgent> {
        let preferred = self
            .profiles
            .get(key)
            .and_then(|profile| profile.preferred_directory);
        if self.profiles.contains_key(key) {
            self.touch(key);
        }
        preferred
    }

    fn touch(&mut self, key: &str) {
        if let Some(index) = self.recency.iter().position(|candidate| candidate == key) {
            self.recency.remove(index);
        }
        self.recency.push_back(key.to_owned());
    }
}

static SOURCE_PROFILES: Lazy<Mutex<SourceProfileStore>> =
    Lazy::new(|| Mutex::new(SourceProfileStore::default()));

fn normalize_source_for_policy(
    mut source: LibrarySource,
    policy: &SecurityPolicy,
) -> CoreResult<LibrarySource> {
    if matches!(policy, SecurityPolicy::Production) {
        source.share_url = normalize_public_share_url(&source.share_url, policy)?;
    }
    Ok(source)
}

fn source_profile_key(value: &str) -> String {
    let root = parse_folder_target(value).root_url;
    let Ok(mut parsed) = Url::parse(root.trim()) else {
        return root.trim().to_owned();
    };
    parsed.set_fragment(None);
    parsed.to_string()
}

fn with_source_profile<R>(key: &str, operation: impl FnOnce(&mut SourceProfile) -> R) -> R {
    SOURCE_PROFILES
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .with_profile(key, operation)
}

fn preferred_directory_agent(key: &str) -> DirectoryAgent {
    SOURCE_PROFILES
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .preferred(key)
        .unwrap_or(DirectoryAgent::Android)
}

fn observe_source_template(key: &str, agent: DirectoryAgent, template: html::PageTemplate) {
    with_source_profile(key, |profile| profile.observe_template(agent, template));
}

fn learn_directory_agent(key: &str, agent: DirectoryAgent) {
    with_source_profile(key, |profile| profile.preferred_directory = Some(agent));
}

fn source_interval(key: &str, agent: DirectoryAgent, page: u32) -> Duration {
    Duration::from_millis(with_source_profile(key, |profile| {
        profile.interval_ms(agent, page)
    }))
}

fn source_backoff(key: &str, agent: DirectoryAgent, page: u32) -> Duration {
    Duration::from_millis(with_source_profile(key, |profile| {
        profile.backoff_ms(agent, page)
    }))
}

fn share_cancelled_error() -> CoreError {
    CoreError::new("share_cancelled", "分享已取消", false)
}

fn password_required_error() -> CoreError {
    CoreError::new("password_required", "分享需要正确的访问码", false)
}

fn is_share_cancelled_error(error: &CoreError) -> bool {
    error.code == "share_cancelled"
}

fn is_terminal_source_error(error: &CoreError) -> bool {
    matches!(
        error.code,
        "share_cancelled" | "password_required" | "cancelled"
    )
}

fn is_password_required_page(html: &str) -> bool {
    if html.contains("filemoreajax.php") {
        return false;
    }
    let normalized = html.to_lowercase();
    let has_password_control = [
        "pwdload",
        "passwddiv",
        "type=\"password\"",
        "type='password'",
        "name=\"pwd\"",
        "name='pwd'",
    ]
    .into_iter()
    .any(|marker| normalized.contains(marker));
    let asks_for_code = [
        "请输入访问密码",
        "请输入密码",
        "请输入访问码",
        "请输入提取码",
        "password required",
        "enter password",
    ]
    .into_iter()
    .any(|marker| normalized.contains(marker));
    has_password_control && asks_for_code
}

fn sanitize_source_error(error: CoreError, has_access_code: bool) -> CoreError {
    if is_share_cancelled_error(&error) {
        error
    } else {
        sanitize_access_code_error(error, has_access_code)
    }
}

fn load_directory_page(
    source: &LibrarySource,
    target: &FolderTarget,
    transport: &LibraryTransport,
    profile_key: &str,
    agent: DirectoryAgent,
) -> CoreResult<LoadedDirectoryPage> {
    load_directory_page_with_constraints(source, target, transport, profile_key, agent, None, None)
}

#[allow(clippy::too_many_arguments)]
fn load_directory_page_with_constraints(
    source: &LibrarySource,
    target: &FolderTarget,
    transport: &LibraryTransport,
    profile_key: &str,
    agent: DirectoryAgent,
    operation: Option<&OperationHandle>,
    deadline: Option<Instant>,
) -> CoreResult<LoadedDirectoryPage> {
    let response = transport.get_guarded_with_agent_constrained(
        &target.root_url,
        "",
        agent.user_agent(),
        operation,
        deadline,
    )?;
    let mut parsed = html::parse_page(&response.html);
    if parsed.cancelled {
        return Err(share_cancelled_error());
    }
    observe_source_template(profile_key, agent, parsed.template);
    if parsed.listing_endpoint.is_empty() {
        if let Some(single) = html::parse_single_file_page(&response.html) {
            let item = single_file_item(source, &response.url, single)?;
            parsed.title.clone_from(&item.title);
            parsed.publisher.clone_from(&item.title);
            parsed.avatar_url.clone_from(&item.icon_url);
            parsed.description.clone_from(&item.description);
            return Ok(LoadedDirectoryPage {
                page_url: response.url,
                page: parsed,
                listing_endpoint: String::new(),
                folder_endpoint: String::new(),
                search_endpoint: String::new(),
                single_item: Some(item),
            });
        }
        if is_password_required_page(&response.html) {
            return Err(password_required_error());
        }
        return Err(CoreError::parse("未找到蓝奏目录或单文件接口"));
    }
    let listing_endpoint = same_origin_endpoint(
        &response.url,
        &parsed.listing_endpoint,
        "/filemoreajax.php",
        &transport.policy,
    )?
    .to_string();
    let folder_endpoint = if parsed.folder_endpoint.is_empty() {
        String::new()
    } else {
        same_origin_endpoint(
            &response.url,
            &parsed.folder_endpoint,
            "/foldermoreajax.php",
            &transport.policy,
        )?
        .to_string()
    };
    let search_endpoint = if parsed.search_endpoint.is_empty() {
        String::new()
    } else {
        same_origin_endpoint(
            &response.url,
            &parsed.search_endpoint,
            "/search/s.php",
            &transport.policy,
        )?
        .to_string()
    };
    if !target.title.is_empty() {
        parsed.title.clone_from(&target.title);
    }
    if !target.description.is_empty() {
        parsed.description.clone_from(&target.description);
    }
    if parsed.title.is_empty() {
        parsed.title = if source.title.is_empty() {
            source.share_url.clone()
        } else {
            source.title.clone()
        };
    }
    Ok(LoadedDirectoryPage {
        page_url: response.url,
        page: parsed,
        listing_endpoint,
        folder_endpoint,
        search_endpoint,
        single_item: None,
    })
}

fn single_file_item(
    source: &LibrarySource,
    page_url: &str,
    single: html::ParsedSingleFile,
) -> CoreResult<LibraryItem> {
    if single.title.chars().count() > 512
        || single.size.chars().count() > 128
        || single.time.chars().count() > 64
        || single.description.chars().count() > 4_096
        || single.description.contains('\0')
    {
        return Err(CoreError::remote("单文件分享信息过大或格式无效", false));
    }
    let icon_url = if single.icon_url.is_empty() {
        String::new()
    } else {
        Url::parse(page_url)
            .ok()
            .and_then(|base| base.join(&single.icon_url).ok())
            .and_then(|url| safe_asset_url(url.as_str()))
            .unwrap_or_default()
    };
    Ok(LibraryItem {
        source_id: source.source_id.clone(),
        title: single.title,
        url: page_url.to_owned(),
        share_url: page_url.to_owned(),
        size: single.size,
        time: single.time,
        icon_url,
        source: source.title.clone(),
        description: single.description,
        is_folder: false,
        ..LibraryItem::default()
    })
}

struct LoadedDirectoryPage {
    page_url: String,
    page: ParsedPage,
    listing_endpoint: String,
    folder_endpoint: String,
    search_endpoint: String,
    single_item: Option<LibraryItem>,
}

pub(crate) struct Browser {
    source: LibrarySource,
    target: FolderTarget,
    profile_key: String,
    agent: DirectoryAgent,
    transport: LibraryTransport,
    limiter: Arc<RateLimiter>,
    page_url: String,
    page: ParsedPage,
    listing_endpoint: String,
    folder_endpoint: String,
    search_endpoint: String,
    single_item: Option<LibraryItem>,
}

impl Browser {
    pub(crate) fn open(
        source: LibrarySource,
        transport: LibraryTransport,
        limiter: Arc<RateLimiter>,
    ) -> CoreResult<Self> {
        Self::open_with_constraints(source, transport, limiter, None, None)
    }

    pub(crate) fn open_with_constraints(
        source: LibrarySource,
        transport: LibraryTransport,
        limiter: Arc<RateLimiter>,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<Self> {
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        let source = normalize_source_for_policy(source, &transport.policy)?;
        validate_source(&source)?;
        let target = parse_folder_target(&source.share_url);
        let profile_key = source_profile_key(&target.root_url);
        let first = preferred_directory_agent(&profile_key);
        let mut last_error = None;
        for agent in [first, first.other()] {
            if let Some(operation) = operation {
                operation.check_cancelled()?;
            }
            match load_directory_page_with_constraints(
                &source,
                &target,
                &transport,
                &profile_key,
                agent,
                operation,
                deadline,
            ) {
                Ok(loaded) => {
                    return Ok(Self::from_loaded(
                        source,
                        target,
                        profile_key,
                        agent,
                        transport,
                        limiter,
                        loaded,
                    ));
                }
                Err(error) if is_terminal_source_error(&error) => return Err(error),
                Err(error) => last_error = Some(error),
            }
        }
        Err(last_error.unwrap_or_else(|| CoreError::remote("蓝奏目录暂不可用", true)))
    }

    fn open_for_agent(
        source: LibrarySource,
        transport: LibraryTransport,
        limiter: Arc<RateLimiter>,
        agent: DirectoryAgent,
    ) -> CoreResult<Self> {
        let source = normalize_source_for_policy(source, &transport.policy)?;
        validate_source(&source)?;
        let target = parse_folder_target(&source.share_url);
        let profile_key = source_profile_key(&target.root_url);
        let loaded = load_directory_page(&source, &target, &transport, &profile_key, agent)?;
        Ok(Self::from_loaded(
            source,
            target,
            profile_key,
            agent,
            transport,
            limiter,
            loaded,
        ))
    }

    fn from_loaded(
        source: LibrarySource,
        target: FolderTarget,
        profile_key: String,
        agent: DirectoryAgent,
        transport: LibraryTransport,
        limiter: Arc<RateLimiter>,
        loaded: LoadedDirectoryPage,
    ) -> Self {
        Self {
            source,
            target,
            profile_key,
            agent,
            transport,
            limiter,
            page_url: loaded.page_url,
            page: loaded.page,
            listing_endpoint: loaded.listing_endpoint,
            folder_endpoint: loaded.folder_endpoint,
            search_endpoint: loaded.search_endpoint,
            single_item: loaded.single_item,
        }
    }

    pub(crate) fn browse_page(&mut self, requested_page: u32) -> CoreResult<LibraryFolder> {
        self.browse_page_with_constraints(requested_page, None, None)
    }

    pub(crate) fn browse_page_with_constraints(
        &mut self,
        requested_page: u32,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<LibraryFolder> {
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        let page_number = requested_page.max(1);
        if page_number > MAX_RECURSIVE_PAGES {
            return Err(CoreError::invalid("目录分页不能超过 100 页"));
        }
        if self.single_item.is_some() {
            return self.browse_page_once_with_constraints(page_number, operation, deadline);
        }
        let first_agent = self.agent;
        let mut empty = None;
        match self.browse_page_once_with_constraints(page_number, operation, deadline) {
            Ok(folder) if !folder.items.is_empty() => {
                learn_directory_agent(&self.profile_key, self.agent);
                return Ok(folder);
            }
            Ok(folder) => empty = Some(folder),
            Err(error) if is_terminal_source_error(&error) => return Err(error),
            Err(_) => {}
        }

        let alternate = first_agent.other();
        match load_directory_page_with_constraints(
            &self.source,
            &self.target,
            &self.transport,
            &self.profile_key,
            alternate,
            operation,
            deadline,
        ) {
            Ok(loaded) => self.apply_loaded_page(alternate, loaded),
            Err(error) if is_terminal_source_error(&error) => return Err(error),
            Err(error) => return empty.ok_or(error),
        }
        match self.browse_page_once_with_constraints(page_number, operation, deadline) {
            Ok(folder) if !folder.items.is_empty() => {
                learn_directory_agent(&self.profile_key, self.agent);
                Ok(folder)
            }
            Ok(folder) => Ok(empty.unwrap_or(folder)),
            Err(error) if is_terminal_source_error(&error) => Err(error),
            Err(error) => empty.ok_or(error),
        }
    }

    fn browse_page_once(&self, page_number: u32) -> CoreResult<LibraryFolder> {
        self.browse_page_once_with_constraints(page_number, None, None)
    }

    fn browse_page_once_with_constraints(
        &self,
        page_number: u32,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<LibraryFolder> {
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        if let Some(item) = &self.single_item {
            return Ok(LibraryFolder {
                source_id: self.source.source_id.clone(),
                kind: LibrarySourceKind::SingleSoftware,
                title: self.page.title.clone(),
                publisher: self.page.publisher.clone(),
                avatar_url: self.page.avatar_url.clone(),
                description: self.page.description.clone(),
                save_url: String::new(),
                url: self.source.share_url.clone(),
                folder_id: String::new(),
                page: page_number,
                has_more: false,
                next_page_ready_at_ms: 0,
                remote_search: false,
                items: if page_number == 1 {
                    vec![item.clone()]
                } else {
                    Vec::new()
                },
                api_folder_count: 0,
            });
        }
        let mut items = Vec::new();
        let mut seen = HashSet::new();
        let mut api_folder_count = 0;
        if page_number == 1 {
            if self.target.folder_id.is_empty() {
                for item in self.static_folders()? {
                    if seen.insert(item.url.clone()) {
                        items.push(item);
                    }
                }
            }
            let (folders, raw_count) = self.folder_page_with_constraints(1, operation, deadline)?;
            api_folder_count = raw_count;
            for item in folders {
                if seen.insert(item.url.clone()) {
                    items.push(item);
                }
            }
        }
        let (files, raw_count) =
            self.file_page_with_constraints(page_number, operation, deadline)?;
        let valid_files = files.len();
        for item in files {
            if seen.insert(item.url.clone()) {
                items.push(item);
            }
        }
        let has_more = raw_count >= PAGE_SIZE && valid_files > 0;
        let kind = if page_number == 1
            && !has_more
            && items.len() == 1
            && !items[0].is_folder
            && api_folder_count == 0
        {
            LibrarySourceKind::SingleSoftware
        } else {
            LibrarySourceKind::Directory
        };
        let key = self.directory_rate_key();
        Ok(LibraryFolder {
            source_id: self.source.source_id.clone(),
            kind,
            title: self.page.title.clone(),
            publisher: self.page.publisher.clone(),
            avatar_url: self.page.avatar_url.clone(),
            description: self.page.description.clone(),
            save_url: self.page.save_url.clone(),
            url: self.source.share_url.clone(),
            folder_id: self.target.folder_id.clone(),
            page: page_number,
            has_more,
            next_page_ready_at_ms: if has_more {
                self.limiter.ready_at_ms(&key)
            } else {
                0
            },
            remote_search: self.searchable(),
            items,
            api_folder_count,
        })
    }

    fn apply_loaded_page(&mut self, agent: DirectoryAgent, loaded: LoadedDirectoryPage) {
        self.agent = agent;
        self.page_url = loaded.page_url;
        self.page = loaded.page;
        self.listing_endpoint = loaded.listing_endpoint;
        self.folder_endpoint = loaded.folder_endpoint;
        self.search_endpoint = loaded.search_endpoint;
        self.single_item = loaded.single_item;
    }

    pub(crate) fn searchable(&self) -> bool {
        !self.search_endpoint.is_empty() && !self.page.search_sign.is_empty()
    }

    pub(crate) fn ensure_search_capability_with_constraints(
        &mut self,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<bool> {
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        if self.single_item.is_some() {
            return Ok(false);
        }
        if self.searchable() {
            return Ok(true);
        }
        let response = self.transport.get_guarded_with_agent_constrained(
            &self.target.root_url,
            "",
            DESKTOP_USER_AGENT,
            operation,
            deadline,
        )?;
        let parsed = html::parse_page(&response.html);
        if parsed.cancelled {
            return Err(share_cancelled_error());
        }
        if is_password_required_page(&response.html) {
            return Err(password_required_error());
        }
        observe_source_template(&self.profile_key, DirectoryAgent::Desktop, parsed.template);
        if parsed.search_endpoint.is_empty() || parsed.search_sign.is_empty() {
            return Ok(false);
        }
        self.search_endpoint = same_origin_endpoint(
            &response.url,
            &parsed.search_endpoint,
            "/search/s.php",
            &self.transport.policy,
        )?
        .to_string();
        self.page.search_sign = parsed.search_sign;
        self.page_url = response.url;
        Ok(true)
    }

    pub(crate) fn search_page_with_constraints(
        &self,
        query: &str,
        page: u32,
        deadline: Option<Instant>,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<PageState> {
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        if !self.searchable() {
            return Ok(PageState::End);
        }
        let mut form = BTreeMap::new();
        form.insert("wd".to_owned(), query.to_owned());
        form.insert("sign".to_owned(), self.page.search_sign.clone());
        form.insert("pg".to_owned(), page.to_string());
        if !self.source.password.is_empty() {
            form.insert("pwd".to_owned(), self.source.password.clone());
        }
        let context = self.item_context()?;
        let agent = DirectoryAgent::Desktop;
        let key = self.search_rate_key(agent);
        for _ in 0..3 {
            self.limiter.wait_with_interval_constrained(
                &key,
                deadline,
                source_interval(&self.profile_key, agent, page),
                operation,
            )?;
            let raw = self.transport.post_form_constrained(
                &self.search_endpoint,
                &form,
                &self.page_url,
                DESKTOP_USER_AGENT,
                operation,
                deadline,
            )?;
            match api::parse_search_page(&raw, &context)? {
                PageState::Busy => self
                    .limiter
                    .defer(&key, source_backoff(&self.profile_key, agent, page))?,
                state => return Ok(state),
            }
        }
        Err(CoreError::remote("源内搜索请求过快，请稍后重试", true))
    }

    pub(crate) fn source_title(&self) -> &str {
        &self.page.title
    }

    fn file_page_with_constraints(
        &self,
        page: u32,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<(Vec<LibraryItem>, usize)> {
        let mut form = self.base_form(page);
        if !self.target.folder_id.is_empty() {
            form.insert("folder_id".to_owned(), self.target.folder_id.clone());
            form.insert("ls".to_owned(), "1".to_owned());
        }
        if !self.source.password.is_empty() {
            form.insert("pwd".to_owned(), self.source.password.clone());
            form.insert("ls".to_owned(), "1".to_owned());
        }
        let context = self.item_context()?;
        let key = self.directory_rate_key();
        for _ in 0..3 {
            self.limiter.wait_with_interval_constrained(
                &key,
                deadline,
                source_interval(&self.profile_key, self.agent, page),
                operation,
            )?;
            let raw = self.transport.post_form_constrained(
                &self.listing_endpoint,
                &form,
                &self.page_url,
                self.agent.user_agent(),
                operation,
                deadline,
            )?;
            match api::parse_file_page(&raw, &context)? {
                PageState::Items {
                    items, raw_count, ..
                } => return Ok((items, raw_count)),
                PageState::End => return Ok((Vec::new(), 0)),
                PageState::Busy => self
                    .limiter
                    .defer(&key, source_backoff(&self.profile_key, self.agent, page))?,
            }
        }
        Err(CoreError::remote("目录请求过快，请稍后重试", true))
    }

    pub(crate) fn folder_page(&self, page: u32) -> CoreResult<(Vec<LibraryItem>, usize)> {
        self.folder_page_with_constraints(page, None, None)
    }

    pub(crate) fn folder_page_with_constraints(
        &self,
        page: u32,
        operation: Option<&OperationHandle>,
        deadline: Option<Instant>,
    ) -> CoreResult<(Vec<LibraryItem>, usize)> {
        if self.folder_endpoint.is_empty() {
            return Ok((Vec::new(), 0));
        }
        let mut form = self.base_form(page);
        if !self.target.folder_id.is_empty() {
            form.insert("folder_id".to_owned(), self.target.folder_id.clone());
            form.insert("ls".to_owned(), "1".to_owned());
        }
        if !self.source.password.is_empty() {
            form.insert("pwd".to_owned(), self.source.password.clone());
            form.insert("ls".to_owned(), "1".to_owned());
        }
        let context = self.item_context()?;
        let key = self.directory_rate_key();
        for _ in 0..3 {
            self.limiter.wait_with_interval_constrained(
                &key,
                deadline,
                source_interval(&self.profile_key, self.agent, page),
                operation,
            )?;
            let raw = self.transport.post_form_constrained(
                &self.folder_endpoint,
                &form,
                &self.page_url,
                self.agent.user_agent(),
                operation,
                deadline,
            )?;
            match api::parse_folder_page(&raw, &context, &self.target.root_url)? {
                PageState::Items {
                    items, raw_count, ..
                } => return Ok((items, raw_count)),
                PageState::End => return Ok((Vec::new(), 0)),
                PageState::Busy => self
                    .limiter
                    .defer(&key, source_backoff(&self.profile_key, self.agent, page))?,
            }
        }
        Err(CoreError::remote("目录子文件夹请求过快，请稍后重试", true))
    }

    fn static_folders(&self) -> CoreResult<Vec<LibraryItem>> {
        let mut output = Vec::new();
        for folder in &self.page.static_folders {
            let url = join_page_url(&self.page_url, &folder.href, &self.transport.policy)?;
            output.push(LibraryItem {
                source_id: self.source.source_id.clone(),
                title: folder.title.clone(),
                url: url.to_string(),
                share_url: url.to_string(),
                size: folder.description.clone(),
                icon_url: "https://images.bakstotre.com/assets/images/type/folder.gif".to_owned(),
                source: self.page.title.clone(),
                description: folder.description.clone(),
                is_folder: true,
                ..LibraryItem::default()
            });
        }
        Ok(output)
    }

    fn base_form(&self, page: u32) -> BTreeMap<String, String> {
        let mut form = self.page.form.clone();
        form.insert("pg".to_owned(), page.to_string());
        form
    }

    fn item_context(&self) -> CoreResult<ItemContext> {
        Ok(ItemContext {
            source_id: self.source.source_id.clone(),
            source_title: self.page.title.clone(),
            base_origin: origin(&self.page_url, &self.transport.policy)?,
        })
    }

    fn directory_rate_key(&self) -> String {
        format!(
            "directory|{}|{}|{}|{}",
            self.page_url,
            self.page.fid,
            self.target.folder_id,
            self.agent.key()
        )
    }

    fn search_rate_key(&self, agent: DirectoryAgent) -> String {
        format!("search|{}|{}|{}", self.page_url, self.page.fid, agent.key())
    }
}

pub(crate) fn probe(
    source: LibrarySource,
    policy: SecurityPolicy,
    limiter: Arc<RateLimiter>,
) -> CoreResult<LibraryProbeResult> {
    let has_access_code = !source.password.is_empty();
    probe_inner(source, policy, limiter)
        .map_err(|error| sanitize_source_error(error, has_access_code))
}

fn probe_inner(
    source: LibrarySource,
    policy: SecurityPolicy,
    limiter: Arc<RateLimiter>,
) -> CoreResult<LibraryProbeResult> {
    let source = normalize_source_for_policy(source, &policy)?;
    let profile_key = source_profile_key(&source.share_url);
    let mut best: Option<(DirectoryAgent, LibraryFolder, Duration)> = None;
    let mut searchable = false;
    let mut last_error = None;
    for agent in [DirectoryAgent::Android, DirectoryAgent::Desktop] {
        let started = Instant::now();
        let result = (|| {
            let browser = Browser::open_for_agent(
                source.clone(),
                LibraryTransport::build(policy.clone())?,
                limiter.clone(),
                agent,
            )?;
            let supports_search = browser.searchable();
            let folder = browser.browse_page_once(1)?;
            Ok((folder, supports_search))
        })();
        match result {
            Ok((folder, supports_search)) => {
                searchable |= supports_search;
                let elapsed = started.elapsed();
                let replace = best.as_ref().is_none_or(|(_, current, current_elapsed)| {
                    folder.items.len() > current.items.len()
                        || folder.items.len() == current.items.len() && elapsed < *current_elapsed
                });
                if replace {
                    best = Some((agent, folder, elapsed));
                }
            }
            Err(error) if is_terminal_source_error(&error) => return Err(error),
            Err(error) => last_error = Some(error),
        }
    }
    let (agent, mut folder, _) = best
        .ok_or_else(|| last_error.unwrap_or_else(|| CoreError::remote("蓝奏目录暂不可用", true)))?;
    learn_directory_agent(&profile_key, agent);
    folder.remote_search = searchable;
    Ok(LibraryProbeResult {
        source: PublicLibrarySource {
            source_id: source.source_id,
            title: folder.title.clone(),
            share_url: source.share_url,
            searchable,
            kind: folder.kind,
        },
        folder,
    })
}

pub(crate) fn browse(
    source: LibrarySource,
    page: u32,
    policy: SecurityPolicy,
    limiter: Arc<RateLimiter>,
) -> CoreResult<LibraryFolder> {
    let has_access_code = !source.password.is_empty();
    let result =
        (|| Browser::open(source, LibraryTransport::build(policy)?, limiter)?.browse_page(page))();
    result.map_err(|error| sanitize_source_error(error, has_access_code))
}

pub(crate) fn collect(
    roots: Vec<LibraryItem>,
    sources: Vec<LibrarySource>,
    policy: SecurityPolicy,
    limiter: Arc<RateLimiter>,
) -> CoreResult<LibraryCollectResult> {
    let has_access_code = sources.iter().any(|source| !source.password.is_empty());
    collect_inner(roots, sources, policy, limiter)
        .map_err(|error| sanitize_source_error(error, has_access_code))
}

fn collect_inner(
    roots: Vec<LibraryItem>,
    sources: Vec<LibrarySource>,
    policy: SecurityPolicy,
    limiter: Arc<RateLimiter>,
) -> CoreResult<LibraryCollectResult> {
    if roots.len() > MAX_COLLECT_ROOTS {
        return Err(CoreError::invalid("一次最多选择 1000 个项目"));
    }
    if sources.len() > MAX_LIBRARY_SOURCES {
        return Err(CoreError::invalid("软件源数量不能超过 4096 个"));
    }
    let mut source_map = HashMap::with_capacity(sources.len());
    for source in sources {
        validate_source(&source)?;
        if source_map
            .insert(source.source_id.clone(), source)
            .is_some()
        {
            return Err(CoreError::invalid("软件源 sourceId 重复"));
        }
    }
    let mut files = Vec::new();
    let mut file_keys = HashSet::new();
    let mut folders = VecDeque::new();
    let mut folder_keys = HashSet::new();
    for item in roots {
        validate_collect_item(&item, &policy)?;
        if item.is_folder {
            enqueue_folder(&mut folders, &mut folder_keys, item);
        } else {
            add_file(&mut files, &mut file_keys, item);
            if files.len() > MAX_COLLECT_FILES {
                return Err(CoreError::invalid("一次最多收集 50000 个文件"));
            }
        }
    }
    let mut scanned = 0usize;
    while let Some(folder) = folders.pop_front() {
        scanned += 1;
        if scanned > MAX_COLLECT_FOLDERS {
            return Err(CoreError::remote("目录数量超过 10000 个，停止展开", false));
        }
        let base_source = source_map
            .get(&folder.source_id)
            .ok_or_else(|| CoreError::invalid("选中项目缺少对应软件源"))?;
        let mut nested_source = base_source.clone();
        nested_source.share_url = folder.url.clone();
        let mut browser = Browser::open(
            nested_source,
            LibraryTransport::build(policy.clone())?,
            limiter.clone(),
        )?;
        let mut first_folder_count = 0;
        for page in 1..=MAX_RECURSIVE_PAGES {
            let listing = browser.browse_page(page)?;
            if page == 1 {
                first_folder_count = listing.api_folder_count;
            }
            for item in listing.items {
                if item.is_folder {
                    enqueue_folder(&mut folders, &mut folder_keys, item);
                } else {
                    add_file(&mut files, &mut file_keys, item);
                    if files.len() > MAX_COLLECT_FILES {
                        return Err(CoreError::remote("文件数量超过 50000 个，停止展开", false));
                    }
                }
            }
            if !listing.has_more {
                break;
            }
            if page == MAX_RECURSIVE_PAGES {
                return Err(CoreError::remote("目录文件超过 100 页，未完整展开", false));
            }
        }
        if first_folder_count >= PAGE_SIZE {
            for page in 2..=MAX_RECURSIVE_PAGES {
                let (items, raw_count) = browser.folder_page(page)?;
                for item in items {
                    enqueue_folder(&mut folders, &mut folder_keys, item);
                }
                if raw_count < PAGE_SIZE {
                    break;
                }
                if page == MAX_RECURSIVE_PAGES {
                    return Err(CoreError::remote(
                        "目录子文件夹超过 100 页，未完整展开",
                        false,
                    ));
                }
            }
        }
    }
    Ok(LibraryCollectResult {
        files,
        folders_scanned: scanned,
    })
}

pub(crate) fn validate_source(source: &LibrarySource) -> CoreResult<()> {
    static SOURCE_ID: once_cell::sync::Lazy<regex::Regex> = once_cell::sync::Lazy::new(|| {
        regex::Regex::new(r"^[a-z][a-z0-9_-]{1,63}$").expect("source id regex is valid")
    });
    if !SOURCE_ID.is_match(&source.source_id) {
        return Err(CoreError::invalid("sourceId 格式无效"));
    }
    if source.title.chars().count() > 80 || source.title.chars().any(char::is_control) {
        return Err(CoreError::invalid("软件源标题格式无效"));
    }
    if source.password.chars().count() > 64 || source.password.chars().any(char::is_control) {
        return Err(CoreError::invalid("软件源密码格式无效"));
    }
    Ok(())
}

fn validate_collect_item(item: &LibraryItem, policy: &SecurityPolicy) -> CoreResult<()> {
    if item.source_id.chars().count() > 64
        || item.source_id.chars().any(char::is_control)
        || item.title.chars().count() > 512
        || item.title.chars().any(char::is_control)
        || item.url.len() > 4_096
        || item.share_url.len() > 4_096
        || item.description.chars().count() > 4_096
    {
        return Err(CoreError::invalid("选中项目字段过长或格式无效"));
    }
    if item.url.trim().is_empty() || validate_page_url(&item.url, policy).is_err() {
        return Err(CoreError::invalid("选中项目地址不受信任"));
    }
    Ok(())
}

fn enqueue_folder(
    queue: &mut VecDeque<LibraryItem>,
    keys: &mut HashSet<String>,
    item: LibraryItem,
) {
    if item.url.is_empty() {
        return;
    }
    let target = parse_folder_target(&item.url);
    let key = format!(
        "{}\n{}\n{}",
        item.source_id, target.root_url, target.folder_id
    );
    if keys.insert(key) {
        queue.push_back(item);
    }
}

fn add_file(files: &mut Vec<LibraryItem>, keys: &mut HashSet<String>, item: LibraryItem) {
    let key = if item.share_url.is_empty() {
        &item.url
    } else {
        &item.share_url
    };
    if !key.is_empty() && keys.insert(key.clone()) {
        files.push(item);
    }
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::Mutex,
        thread,
        time::Duration,
    };

    use super::*;

    fn source(origin: &str, password: &str) -> LibrarySource {
        LibrarySource {
            source_id: "one".to_owned(),
            title: "测试库".to_owned(),
            share_url: format!("{origin}/source"),
            password: password.to_owned(),
        }
    }

    fn read_request(stream: &mut std::net::TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut bytes = Vec::new();
        let mut buffer = [0_u8; 1024];
        let mut expected = None;
        loop {
            let read = stream.read(&mut buffer).unwrap_or(0);
            if read == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..read]);
            if let Some(header_end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                let header_len = header_end + 4;
                if expected.is_none() {
                    let headers = String::from_utf8_lossy(&bytes[..header_len]);
                    let content_length = headers.lines().find_map(|line| {
                        let lower = line.to_ascii_lowercase();
                        lower
                            .strip_prefix("content-length:")
                            .and_then(|value| value.trim().parse::<usize>().ok())
                    });
                    expected = Some(header_len + content_length.unwrap_or(0));
                }
                if bytes.len() >= expected.unwrap_or(header_len) {
                    break;
                }
            }
        }
        String::from_utf8_lossy(&bytes).into_owned()
    }

    #[test]
    fn test_browse_mock_contract_posts_password_and_maps_page() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            for index in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let text = read_request(&mut stream);
                let body = if index == 0 {
                    r#"<title>测试软件库</title><script>url:'/filemoreajax.php?file=9';var t='x';const data={'t':t,'uid':'1'};</script>"#.to_owned()
                } else {
                    assert!(text.contains("pwd=secret"));
                    r#"{"zt":1,"text":[{"id":"app1","name_all":"工具.apk","size":"1 M"}]}"#
                        .to_owned()
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    if index == 0 { "text/html" } else { "application/json" },
                    body.len(),
                    body
                );
                stream.write_all(response.as_bytes()).unwrap();
            }
        });
        let folder = browse(
            source(&origin, "secret"),
            1,
            SecurityPolicy::Test {
                origin: origin.clone(),
            },
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap();
        assert_eq!(folder.title, "测试软件库");
        assert_eq!(folder.items.len(), 1);
        assert_eq!(folder.items[0].source_id, "one");
        assert_eq!(
            folder.kind,
            super::super::model::LibrarySourceKind::SingleSoftware
        );
        let json = serde_json::to_string(&folder).unwrap();
        assert!(!json.contains("secret"));
        assert!(!json.to_ascii_lowercase().contains("password"));
        server.join().unwrap();
    }

    #[test]
    fn test_browse_single_file_share_returns_one_real_software_item_without_posting() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_request(&mut stream);
            assert!(request.starts_with("GET /s/tool "));
            let body = r#"<title>工具.apk - 蓝奏云</title>
                <meta property="og:image" content="https://image.dmpdmp.com/image/ico/tool.png">
                <div class="appfile"><div id="filenajax">工具.apk</div>
                <span class="filesize">3 M</span><div class="appdes">真实简介</div>
                <a id="downurl" href="/tp/tool">下载</a></div><time>2026-07-15</time>"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            stream.write_all(response.as_bytes()).unwrap();
        });
        let mut single = source(&origin, "never-serialize");
        single.share_url = format!("{origin}/s/tool");

        let folder = browse(
            single,
            1,
            SecurityPolicy::Test {
                origin: origin.clone(),
            },
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap();

        assert_eq!(folder.title, "工具.apk");
        assert_eq!(folder.publisher, "工具.apk");
        assert_eq!(folder.description, "真实简介");
        assert_eq!(
            folder.kind,
            super::super::model::LibrarySourceKind::SingleSoftware
        );
        assert!(!folder.has_more);
        assert!(!folder.remote_search);
        assert_eq!(folder.items.len(), 1);
        assert_eq!(folder.items[0].title, "工具.apk");
        assert_eq!(folder.items[0].share_url, format!("{origin}/s/tool"));
        assert_eq!(folder.items[0].size, "3 M");
        assert_eq!(folder.items[0].time, "2026-07-15");
        assert_eq!(folder.items[0].description, "真实简介");
        assert!(!folder.items[0].is_folder);
        let json = serde_json::to_string(&folder).unwrap();
        assert!(!json.contains("never-serialize"));
        assert!(!json.to_ascii_lowercase().contains("password"));
        server.join().unwrap();
    }

    #[test]
    fn test_collect_keeps_files_without_sources_and_rejects_unknown_folder_source() {
        let file = LibraryItem {
            source_id: "one".to_owned(),
            title: "one.apk".to_owned(),
            url: "https://www.lanzouw.com/a".to_owned(),
            ..LibraryItem::default()
        };
        let result = collect(
            vec![file.clone()],
            vec![],
            SecurityPolicy::Production,
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap();
        assert_eq!(result.files, vec![file]);

        let folder = LibraryItem {
            is_folder: true,
            ..result.files[0].clone()
        };
        assert!(collect(
            vec![folder],
            vec![],
            SecurityPolicy::Production,
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .is_err());

        let untrusted_file = LibraryItem {
            source_id: "one".to_owned(),
            title: "advertisement.apk".to_owned(),
            url: "https://evil.example/advertisement.apk".to_owned(),
            ..LibraryItem::default()
        };
        let error = collect(
            vec![untrusted_file],
            vec![],
            SecurityPolicy::Production,
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap_err();
        assert_eq!(error.code, "invalid_argument");
        assert_eq!(error.message, "选中项目地址不受信任");
    }

    #[test]
    fn test_browse_error_with_access_code_uses_fixed_safe_message() {
        let error = CoreError::remote("first=alpha second=bravo", false);
        let redacted = sanitize_access_code_error(error, true);
        assert_eq!(
            redacted.message,
            super::super::security::ACCESS_CODE_REMOTE_ERROR
        );
    }

    #[test]
    fn test_source_profile_matches_current_template_interval_matrix() {
        let unknown = SourceProfile::default();
        assert_eq!(unknown.interval_ms(DirectoryAgent::Android, 1), 2_100);
        assert_eq!(unknown.interval_ms(DirectoryAgent::Android, 2), 1_000);
        assert_eq!(unknown.interval_ms(DirectoryAgent::Desktop, 1), 2_100);
        assert_eq!(unknown.interval_ms(DirectoryAgent::Desktop, 2), 1_000);

        let mut minimal = SourceProfile::default();
        minimal.observe_template(DirectoryAgent::Android, html::PageTemplate::Minimal);
        minimal.observe_template(DirectoryAgent::Desktop, html::PageTemplate::Minimal);
        assert_eq!(minimal.interval_ms(DirectoryAgent::Android, 1), 1_800);
        assert_eq!(minimal.interval_ms(DirectoryAgent::Android, 2), 500);
        assert_eq!(minimal.interval_ms(DirectoryAgent::Desktop, 1), 2_100);
        assert_eq!(minimal.interval_ms(DirectoryAgent::Desktop, 2), 1_000);

        let mut classic = SourceProfile::default();
        classic.observe_template(DirectoryAgent::Android, html::PageTemplate::Classic);
        classic.observe_template(DirectoryAgent::Desktop, html::PageTemplate::Classic);
        assert_eq!(classic.interval_ms(DirectoryAgent::Android, 1), 1_800);
        assert_eq!(classic.interval_ms(DirectoryAgent::Android, 2), 500);
        assert_eq!(classic.interval_ms(DirectoryAgent::Desktop, 1), 1_800);
        assert_eq!(classic.interval_ms(DirectoryAgent::Desktop, 2), 500);

        let mut reflow = SourceProfile::default();
        reflow.observe_template(DirectoryAgent::Android, html::PageTemplate::Minimal);
        reflow.observe_template(DirectoryAgent::Desktop, html::PageTemplate::Classic);
        assert_eq!(reflow.interval_ms(DirectoryAgent::Android, 1), 2_100);
        assert_eq!(reflow.interval_ms(DirectoryAgent::Android, 2), 800);
    }

    #[test]
    fn test_source_profile_busy_backoff_is_isolated_by_ua_and_page_phase_and_caps() {
        let mut profile = SourceProfile::default();
        assert_eq!(profile.backoff_ms(DirectoryAgent::Android, 1), 4_200);
        assert_eq!(profile.backoff_ms(DirectoryAgent::Android, 1), 8_400);
        assert_eq!(profile.backoff_ms(DirectoryAgent::Android, 1), 8_400);
        assert_eq!(profile.interval_ms(DirectoryAgent::Android, 2), 1_000);
        assert_eq!(profile.interval_ms(DirectoryAgent::Desktop, 1), 2_100);
        assert_eq!(profile.backoff_ms(DirectoryAgent::Android, 2), 2_000);
        assert_eq!(profile.interval_ms(DirectoryAgent::Android, 1), 8_400);
    }

    #[test]
    fn test_collect_accepts_606_sources_and_rejects_more_than_4096() {
        let make_sources = |count: usize| {
            (0..count)
                .map(|index| LibrarySource {
                    source_id: format!("s{index}"),
                    title: format!("源 {index}"),
                    share_url: "https://www.lanzouw.com/source".to_owned(),
                    password: String::new(),
                })
                .collect::<Vec<_>>()
        };
        let policy = SecurityPolicy::Production;
        assert!(collect(
            Vec::new(),
            make_sources(606),
            policy.clone(),
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .is_ok());
        let error = collect(
            Vec::new(),
            make_sources(4_097),
            policy,
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap_err();
        assert_eq!(error.message, "软件源数量不能超过 4096 个");
    }

    #[test]
    fn test_browse_falls_back_to_desktop_and_learns_preference_for_source_key() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::<String>::new()));
        let server_requests = requests.clone();
        let server = thread::spawn(move || {
            for _ in 0..6 {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_request(&mut stream);
                let is_android = request.contains("Android 15");
                let is_get = request.starts_with("GET ");
                server_requests.lock().unwrap().push(format!(
                    "{}:{}",
                    if is_get { "GET" } else { "POST" },
                    if is_android { "android" } else { "desktop" }
                ));
                let body = if is_get {
                    r#"<title>双 UA</title><script>url:'/filemoreajax.php?file=9'</script>"#
                } else if is_android {
                    r#"{"zt":0,"info":"mobile layout unavailable"}"#
                } else {
                    r#"{"zt":1,"text":[{"id":"desktop-app","name_all":"桌面结果.apk"}]}"#
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    if is_get { "text/html" } else { "application/json" },
                    body.len(),
                    body
                );
                stream.write_all(response.as_bytes()).unwrap();
            }
        });
        let policy = SecurityPolicy::Test {
            origin: origin.clone(),
        };
        let first = browse(
            source(&origin, ""),
            1,
            policy.clone(),
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap();
        let mut nested_source = source(&origin, "");
        nested_source.share_url = format!("{origin}/source#lanzou-folder=child&title=Nested");
        let second = browse(
            nested_source,
            1,
            policy,
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap();
        assert_eq!(first.items[0].title, "桌面结果.apk");
        assert_eq!(second.items[0].title, "桌面结果.apk");
        server.join().unwrap();
        assert_eq!(
            *requests.lock().unwrap(),
            [
                "GET:android",
                "POST:android",
                "GET:desktop",
                "POST:desktop",
                "GET:desktop",
                "POST:desktop",
            ]
        );
    }

    #[test]
    fn test_cancelled_share_returns_stable_safe_error_before_interface_parsing() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let _request = read_request(&mut stream);
            let body = "<html><main>文件 已取消分享，无法访问</main></html>";
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            stream.write_all(response.as_bytes()).unwrap();
        });
        let error = browse(
            source(&origin, "secret"),
            1,
            SecurityPolicy::Test {
                origin: origin.clone(),
            },
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap_err();
        server.join().unwrap();
        assert_eq!(error.code, "share_cancelled");
        assert_eq!(error.message, "分享已取消");
        assert!(!error.retriable);
        assert!(!error.message.contains("secret"));
    }

    #[test]
    fn test_password_gate_detection_is_terminal_and_template_specific() {
        assert!(is_password_required_page(
            r#"<form id="pwdload"><input type="password" name="pwd"><p>请输入访问密码</p></form>"#
        ));
        assert!(is_password_required_page(
            r#"<div id="passwddiv">请输入提取码</div>"#
        ));
        assert!(!is_password_required_page(
            r#"<script>url:'/filemoreajax.php?file=9'; const passwordHint='设置访问码';</script>"#
        ));
        assert!(is_terminal_source_error(&CoreError::new(
            "password_required",
            "分享需要正确的访问码",
            false,
        )));
    }

    #[test]
    fn test_password_gate_page_returns_stable_code_without_ua_retry() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let _request = read_request(&mut stream);
            let body = r#"<form id="pwdload"><input type="password" name="pwd"><p>请输入访问密码</p></form>"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            stream.write_all(response.as_bytes()).unwrap();
        });
        let error = browse(
            source(&origin, "not-serialized"),
            1,
            SecurityPolicy::Test {
                origin: origin.clone(),
            },
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap_err();
        server.join().unwrap();
        assert_eq!(error.code, "password_required");
        assert_eq!(
            error.message,
            super::super::security::ACCESS_CODE_REMOTE_ERROR
        );
        assert!(!error.message.contains("not-serialized"));
    }

    #[test]
    fn test_directory_busy_response_learns_dynamic_backoff_for_same_ua_page_phase() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            for index in 0..4 {
                let (mut stream, _) = listener.accept().unwrap();
                let _request = read_request(&mut stream);
                let body = if index == 0 {
                    r#"<link href="/assets/share/folder2.css"><link href="/assets/share/folder3.css"><div class="user-top"><div class="fileview"></div></div><script>url:'/filemoreajax.php?file=9'</script>"#
                } else if index < 3 {
                    r#"{"zt":4,"info":"busy"}"#
                } else {
                    r#"{"zt":1,"text":[{"id":"ok","name_all":"恢复.apk"}]}"#
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    if index == 0 { "text/html" } else { "application/json" },
                    body.len(),
                    body
                );
                stream.write_all(response.as_bytes()).unwrap();
            }
        });
        let folder = browse(
            source(&origin, ""),
            1,
            SecurityPolicy::Test {
                origin: origin.clone(),
            },
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap();
        server.join().unwrap();
        assert_eq!(folder.items[0].title, "恢复.apk");
        let key = source_profile_key(&format!("{origin}/source"));
        with_source_profile(&key, |profile| {
            assert_eq!(profile.interval_ms(DirectoryAgent::Android, 1), 8_400);
            assert_eq!(profile.interval_ms(DirectoryAgent::Android, 2), 800);
            assert_eq!(profile.interval_ms(DirectoryAgent::Desktop, 1), 2_100);
        });
    }

    #[test]
    fn test_probe_checks_both_user_agents_and_learns_richer_directory() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::<String>::new()));
        let server_requests = requests.clone();
        let server = thread::spawn(move || {
            for _ in 0..6 {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_request(&mut stream);
                let android = request.contains("Android 15");
                let get = request.starts_with("GET ");
                server_requests.lock().unwrap().push(format!(
                    "{}:{}",
                    if get { "GET" } else { "POST" },
                    if android { "android" } else { "desktop" }
                ));
                let body = if get {
                    r#"<title>探测库</title><script>url:'/filemoreajax.php?file=9'</script>"#
                } else if android {
                    r#"{"zt":1,"text":[{"id":"a","name_all":"安卓结果.apk"}]}"#
                } else {
                    r#"{"zt":1,"text":[{"id":"a","name_all":"共同.apk"},{"id":"b","name_all":"桌面独有.apk"}]}"#
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    if get { "text/html" } else { "application/json" },
                    body.len(),
                    body
                );
                stream.write_all(response.as_bytes()).unwrap();
            }
        });
        let policy = SecurityPolicy::Test {
            origin: origin.clone(),
        };
        let result = probe(
            source(&origin, ""),
            policy.clone(),
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap();
        assert_eq!(result.folder.items.len(), 2);
        assert_eq!(result.folder.items[1].title, "桌面独有.apk");

        let learned = browse(
            source(&origin, ""),
            1,
            policy,
            Arc::new(RateLimiter::new(Duration::ZERO)),
        )
        .unwrap();
        assert_eq!(learned.items.len(), 2);
        server.join().unwrap();
        assert_eq!(
            *requests.lock().unwrap(),
            [
                "GET:android",
                "POST:android",
                "GET:desktop",
                "POST:desktop",
                "GET:desktop",
                "POST:desktop",
            ]
        );
    }

    #[test]
    fn test_source_profile_store_evicts_oldest_deterministically_without_dropping_current_key() {
        let mut store = SourceProfileStore::default();
        for index in 0..MAX_SOURCE_PROFILES {
            store.with_profile(&format!("source-{index}"), |profile| {
                profile.preferred_directory = Some(DirectoryAgent::Android);
            });
        }
        store.with_profile("source-0", |profile| {
            profile.preferred_directory = Some(DirectoryAgent::Desktop);
        });
        store.with_profile("source-overflow", |profile| {
            profile.preferred_directory = Some(DirectoryAgent::Desktop);
        });

        assert_eq!(store.profiles.len(), MAX_SOURCE_PROFILES);
        assert!(store.profiles.contains_key("source-0"));
        assert!(store.profiles.contains_key("source-overflow"));
        assert!(!store.profiles.contains_key("source-1"));
        assert_eq!(store.preferred("source-0"), Some(DirectoryAgent::Desktop));
    }

    #[test]
    fn test_production_source_normalization_canonicalizes_current_legacy_host_families() {
        let policy = SecurityPolicy::Production;
        assert_eq!(
            normalize_public_share_url(
                "http://share.LanZouB.com/path/to/source?ignored=yes#ordinary",
                &policy,
            )
            .unwrap(),
            "https://www.lanzouw.com/path/to/source"
        );
        assert_eq!(
            normalize_public_share_url(
                "https://cdn.laozouw.com/legacy#lanzou-folder=42&title=%E5%B7%A5%E5%85%B7",
                &policy,
            )
            .unwrap(),
            "https://www.lanzouw.com/legacy#lanzou-folder=42&title=%E5%B7%A5%E5%85%B7"
        );
        assert_eq!(
            normalize_public_share_url("https://www。lanzouq．com/fullwidth", &policy).unwrap(),
            "https://www.lanzouw.com/fullwidth"
        );
    }

    #[test]
    fn test_production_source_normalization_rejects_unsafe_or_non_share_inputs() {
        let policy = SecurityPolicy::Production;
        for value in [
            "https://evil-lanzouw.com/source",
            "https://www.lanzouxx.com/source",
            "https://user@www.lanzouw.com/source",
            "https://www.lanzouw.com:443/source",
            "https://www.lanzouw.com/",
            "ftp://www.lanzouw.com/source",
        ] {
            assert!(
                normalize_public_share_url(value, &policy).is_err(),
                "{value}"
            );
        }
    }

    #[test]
    fn test_source_normalization_leaves_test_policy_mock_url_unchanged() {
        let original = source("http://127.0.0.1:34567", "");
        let normalized = normalize_source_for_policy(
            original.clone(),
            &SecurityPolicy::Test {
                origin: "http://127.0.0.1:34567".to_owned(),
            },
        )
        .unwrap();
        assert_eq!(normalized.share_url, original.share_url);
    }
}
