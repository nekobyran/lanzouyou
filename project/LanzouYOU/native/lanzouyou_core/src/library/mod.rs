mod api;
mod asset;
mod browse;
mod catalog;
mod direct_link;
mod download;
mod handle_registry;
mod html;
mod link_router;
mod model;
mod rate_limit;
mod repackage_android;
mod repackage_common;
mod repackage_windows;
mod resolve;
mod search;
mod security;
mod session;
mod source_registry;
mod transfer;
mod url;

use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};

use serde_json::{json, to_value, Value};

use crate::{
    error::{CoreError, CoreResult},
    model::Command,
    operation::OperationHandle,
};

pub(crate) use catalog::{CatalogItemRef, CatalogPageRequest};
pub(crate) use link_router::LinkPreference;
pub(crate) use model::{BrowseRequest, LibraryItem, LibrarySearchOptions, LibrarySource};
pub(crate) use repackage_android::AndroidRepackageRequest;
pub(crate) use repackage_windows::WindowsRepackageRequest;
pub(crate) use source_registry::{CategoryDraft, CompositeDraft, SourceDraft, SourceUpdateDraft};

use model::{
    LibraryCollectResult, LibraryDescription, LibraryDownloadResult, LibraryFolder,
    LibraryProbeResult, LibraryResolved, LibrarySearchResult,
};
use rate_limit::RateLimiter;
use session::LibraryTransport;
use url::SecurityPolicy;

pub(crate) struct LibraryService {
    policy: SecurityPolicy,
    limiter: Arc<RateLimiter>,
    exchange_delays: resolve::DirectExchangeDelays,
}

impl LibraryService {
    pub(crate) fn new() -> Self {
        Self {
            policy: SecurityPolicy::Production,
            limiter: Arc::new(RateLimiter::production()),
            exchange_delays: resolve::DirectExchangeDelays::production(),
        }
    }

    fn probe(&self, source: LibrarySource) -> CoreResult<LibraryProbeResult> {
        browse::probe(source, self.policy.clone(), self.limiter.clone())
    }

    fn browse(&self, request: BrowseRequest) -> CoreResult<LibraryFolder> {
        let _ = request.refresh;
        browse::browse(
            LibrarySource {
                source_id: request.source_id,
                title: String::new(),
                share_url: request.share_url,
                password: request.password,
            },
            request.page,
            self.policy.clone(),
            self.limiter.clone(),
        )
    }

    fn search(
        &self,
        query: String,
        sources: Vec<LibrarySource>,
        options: LibrarySearchOptions,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<LibrarySearchResult> {
        search::search(
            query,
            sources,
            options,
            self.policy.clone(),
            self.limiter.clone(),
            operation.cloned(),
        )
    }

    fn collect(
        &self,
        items: Vec<LibraryItem>,
        sources: Vec<LibrarySource>,
    ) -> CoreResult<LibraryCollectResult> {
        browse::collect(items, sources, self.policy.clone(), self.limiter.clone())
    }

    fn resolve(
        &self,
        source_id: String,
        share_url: String,
        password: String,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<LibraryResolved> {
        resolve::resolve(
            &source_id,
            &share_url,
            &password,
            self.policy.clone(),
            self.exchange_delays,
            operation,
        )
    }

    fn download(
        &self,
        source_id: String,
        share_url: String,
        password: String,
        destination_directory: String,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<LibraryDownloadResult> {
        download::download(
            &source_id,
            &share_url,
            &password,
            &destination_directory,
            self.policy.clone(),
            self.exchange_delays,
            operation,
        )
    }

    fn describe(
        &self,
        source_id: String,
        share_url: String,
        password: String,
    ) -> CoreResult<LibraryDescription> {
        let source = LibrarySource {
            source_id,
            title: String::new(),
            share_url: share_url.clone(),
            password: password.clone(),
        };
        browse::validate_source(&source)?;
        let result = (|| {
            let transport = LibraryTransport::build(self.policy.clone())?;
            let page = transport.get_guarded(&share_url, "")?;
            let description = html::parse_file_description(&page.html).replace('\r', "");
            if description.chars().count() > 8_192 || description.contains('\0') {
                return Err(CoreError::remote("文件简介内容过大或格式无效", false));
            }
            Ok(LibraryDescription { description })
        })();
        result.map_err(|error| security::sanitize_access_code_error(error, !password.is_empty()))
    }

    fn catalog_target(
        &self,
        storage_root: &str,
        node_id: String,
        item_ref: Option<CatalogItemRef>,
    ) -> CoreResult<catalog::CatalogTarget> {
        let has_node = !node_id.trim().is_empty();
        if has_node == item_ref.is_some() {
            return Err(CoreError::invalid(
                "catalog 请求必须且只能提供 nodeId 或 itemRef",
            ));
        }
        source_registry::with_registry(storage_root, |registry| {
            registry.merged_catalog_target(node_id.trim(), item_ref.as_ref())
        })
    }

    fn register_remote_item(&self, item: &mut LibraryItem, password: &str) -> CoreResult<()> {
        let navigation_url = if item.share_url.is_empty() {
            item.url.clone()
        } else {
            item.share_url.clone()
        };
        if navigation_url.is_empty() {
            return Err(CoreError::parse("公共软件库项目缺少服务端分享地址"));
        }
        let handle = handle_registry::register(handle_registry::HandleTarget {
            source_id: item.source_id.clone(),
            title: item.title.clone(),
            url: if item.url.is_empty() {
                navigation_url.clone()
            } else {
                item.url.clone()
            },
            share_url: navigation_url,
            is_folder: item.is_folder,
            single_software: false,
            password: password.to_owned(),
        })?;
        item.source_id = handle;
        Ok(())
    }

    fn register_catalog_item(&self, item: &mut LibraryItem) -> CoreResult<()> {
        let target = catalog::builtin_catalog()?.target(&item.source_id)?;
        let handle = handle_registry::register(target)?;
        item.source_id = handle;
        Ok(())
    }

    fn catalog_browse(
        &self,
        storage_root: &str,
        node_id: String,
        item_ref: Option<CatalogItemRef>,
        page: u32,
        refresh: bool,
    ) -> CoreResult<LibraryFolder> {
        if item_ref.is_none() && !node_id.trim().is_empty() {
            let local = source_registry::with_registry(storage_root, |registry| {
                registry.merged_local_source_folder(node_id.trim(), page)
            })?;
            if let Some(mut folder) = local {
                for item in &mut folder.items {
                    if handle_registry::resolve(&item.source_id).is_err() {
                        self.register_catalog_item(item)?;
                    }
                }
                return Ok(folder);
            }
        }
        let target = self.catalog_target(storage_root, node_id, item_ref)?;
        if !target.is_folder {
            return Err(CoreError::invalid("catalog browse 目标不是文件夹"));
        }
        let _ = refresh;
        let password = target.password.clone();
        let mut folder = browse::browse(
            LibrarySource {
                source_id: target.source_id,
                title: target.title,
                share_url: target.url,
                password: target.password,
            },
            page,
            self.policy.clone(),
            self.limiter.clone(),
        )?;
        for item in &mut folder.items {
            self.register_remote_item(item, &password)?;
        }
        Ok(folder)
    }

    fn route_text_link(
        &self,
        text: &str,
        token_index: usize,
        preference: link_router::LinkPreference,
    ) -> CoreResult<link_router::LinkRoute> {
        let tokens = link_router::tokenize_links(text)?;
        let token = tokens
            .get(token_index)
            .ok_or_else(|| CoreError::invalid("链接 tokenIndex 超出范围"))?;
        let mut route = link_router::route_link(token, preference);
        if token.kind == link_router::LinkKind::LanzouShare
            && matches!(
                route.action,
                link_router::LinkAction::Ask | link_router::LinkAction::Parse
            )
        {
            let canonical = token
                .canonical_url
                .clone()
                .ok_or_else(|| CoreError::invalid("可信蓝奏链接缺少规范地址"))?;
            route.route_handle = Some(handle_registry::register(handle_registry::HandleTarget {
                source_id: "routed-link".to_owned(),
                title: "蓝奏链接".to_owned(),
                url: canonical.clone(),
                share_url: canonical,
                is_folder: true,
                single_software: false,
                password: String::new(),
            })?);
            route.target_url = None;
        }
        Ok(route)
    }

    fn catalog_browse_link(
        &self,
        storage_root: &str,
        route_handle: String,
        page: u32,
        refresh: bool,
    ) -> CoreResult<LibraryFolder> {
        self.catalog_browse(
            storage_root,
            String::new(),
            Some(CatalogItemRef {
                source_id: route_handle,
                title: String::new(),
                url: String::new(),
                share_url: String::new(),
                folder_id: String::new(),
                is_folder: true,
            }),
            page,
            refresh,
        )
    }

    fn catalog_search_start(
        &self,
        storage_root: &str,
        operation_id: String,
        query: String,
        scope_ids: Vec<String>,
        options: LibrarySearchOptions,
    ) -> CoreResult<search::IncrementalSearchStart> {
        let plan = source_registry::with_registry(storage_root, |registry| {
            registry.merged_search_plan(&query, &scope_ids)
        })?;
        let source_passwords = Arc::new(
            plan.sources
                .iter()
                .map(|source| (source.source_id.clone(), source.password.clone()))
                .collect::<HashMap<_, _>>(),
        );
        let mapper_passwords = source_passwords.clone();
        let mapper: search::IncrementalItemMapper = Arc::new(move |mut item| {
            if handle_registry::resolve(&item.source_id).is_ok() {
                return Ok(item);
            }
            if let Some(target) = catalog::builtin_catalog()
                .and_then(|catalog| catalog.target(&item.source_id))
                .ok()
                .filter(|target| {
                    !target.is_folder
                        && (target.share_url == item.share_url || target.share_url == item.url)
                })
            {
                item.source_id = handle_registry::register(target)?;
                return Ok(item);
            }
            let navigation_url = if item.share_url.is_empty() {
                item.url.clone()
            } else {
                item.share_url.clone()
            };
            if navigation_url.is_empty() {
                return Err(CoreError::parse("增量搜索项目缺少分享地址"));
            }
            let password = mapper_passwords
                .get(&item.source_id)
                .cloned()
                .unwrap_or_default();
            item.source_id = handle_registry::register(handle_registry::HandleTarget {
                source_id: item.source_id.clone(),
                title: item.title.clone(),
                url: if item.url.is_empty() {
                    navigation_url.clone()
                } else {
                    item.url.clone()
                },
                share_url: navigation_url,
                is_folder: item.is_folder,
                single_software: false,
                password,
            })?;
            Ok(item)
        });
        search::start_incremental_search(
            &operation_id,
            query,
            plan.sources,
            options,
            self.policy.clone(),
            self.limiter.clone(),
            plan.local_items,
            Some(mapper),
        )
    }

    fn hydrate_single_software_target(
        &self,
        mut target: catalog::CatalogTarget,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<catalog::CatalogTarget> {
        if !target.single_software {
            return Ok(target);
        }
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        let folder = browse::browse(
            LibrarySource {
                source_id: target.source_id.clone(),
                title: target.title.clone(),
                share_url: target.share_url.clone(),
                password: target.password.clone(),
            },
            1,
            self.policy.clone(),
            self.limiter.clone(),
        )?;
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        let item = folder
            .items
            .into_iter()
            .find(|item| !item.is_folder)
            .ok_or_else(|| CoreError::parse("单软件源未返回可解析的软件"))?;
        target.title = item.title;
        target.url = item.url;
        target.share_url = if item.share_url.is_empty() {
            target.url.clone()
        } else {
            item.share_url
        };
        target.is_folder = false;
        target.single_software = false;
        Ok(target)
    }

    fn catalog_search(
        &self,
        storage_root: &str,
        query: String,
        scope_ids: Vec<String>,
        options: LibrarySearchOptions,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<LibrarySearchResult> {
        let plan = source_registry::with_registry(storage_root, |registry| {
            registry.merged_search_plan(&query, &scope_ids)
        })?;
        let source_passwords = plan
            .sources
            .iter()
            .map(|source| (source.source_id.clone(), source.password.clone()))
            .collect::<HashMap<_, _>>();
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        let mut result = if plan.sources.is_empty() {
            LibrarySearchResult::default()
        } else {
            self.search(query, plan.sources, options, operation)?
        };
        let mut keys = HashSet::with_capacity(plan.local_items.len() + result.items.len());
        let mut merged = Vec::with_capacity(plan.local_items.len() + result.items.len());
        for mut item in plan.local_items.into_iter().chain(result.items) {
            let navigation_url = if item.share_url.is_empty() {
                &item.url
            } else {
                &item.share_url
            };
            let key = format!(
                "{}\0{}\0{}\0{}",
                item.source_id, navigation_url, item.folder_id, item.title
            );
            if keys.insert(key) {
                if handle_registry::resolve(&item.source_id).is_ok() {
                    merged.push(item);
                    continue;
                }
                let packaged_target = catalog::builtin_catalog()
                    .and_then(|catalog| catalog.target(&item.source_id))
                    .ok()
                    .filter(|target| {
                        !target.is_folder
                            && (target.share_url == item.share_url || target.share_url == item.url)
                    });
                if let Some(target) = packaged_target {
                    item.source_id = handle_registry::register(target)?;
                } else {
                    let password = source_passwords
                        .get(&item.source_id)
                        .map(String::as_str)
                        .unwrap_or_default();
                    self.register_remote_item(&mut item, password)?;
                }
                merged.push(item);
            }
        }
        result.items = merged;
        Ok(result)
    }

    fn catalog_describe(
        &self,
        storage_root: &str,
        node_id: String,
        item_ref: Option<CatalogItemRef>,
    ) -> CoreResult<LibraryDescription> {
        let target = self.catalog_target(storage_root, node_id, item_ref)?;
        let target = self.hydrate_single_software_target(target, None)?;
        if target.is_folder {
            return Err(CoreError::invalid("catalog describe 目标不是软件"));
        }
        self.describe(target.source_id, target.share_url, target.password)
    }

    fn catalog_resolve(
        &self,
        storage_root: &str,
        node_id: String,
        item_ref: Option<CatalogItemRef>,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<LibraryResolved> {
        let target = self.catalog_target(storage_root, node_id, item_ref)?;
        let target = self.hydrate_single_software_target(target, operation)?;
        if target.is_folder {
            return Err(CoreError::invalid("catalog resolve 目标不是软件"));
        }
        self.resolve(
            target.source_id,
            target.share_url,
            target.password,
            operation,
        )
    }

    fn catalog_download(
        &self,
        storage_root: &str,
        node_id: String,
        item_ref: Option<CatalogItemRef>,
        destination_directory: String,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<LibraryDownloadResult> {
        let target = self.catalog_target(storage_root, node_id, item_ref)?;
        let target = self.hydrate_single_software_target(target, operation)?;
        if target.is_folder {
            return Err(CoreError::invalid("catalog download 目标不是软件"));
        }
        self.download(
            target.source_id,
            target.share_url,
            target.password,
            destination_directory,
            operation,
        )
    }

    fn registry_retest(
        &self,
        storage_root: &str,
        expected_generation: u64,
        source_ids: &[String],
    ) -> CoreResult<Value> {
        let plan = source_registry::with_registry(storage_root, |registry| {
            registry.retest_plan(expected_generation, source_ids)
        })?;
        let mut owner_order = Vec::new();
        let mut aggregated = HashMap::<String, (bool, Option<String>)>::new();
        for unit in plan.units {
            if !aggregated.contains_key(&unit.owner_id) {
                owner_order.push(unit.owner_id.clone());
                aggregated.insert(unit.owner_id.clone(), (true, None));
            }
            if let Err(error) = self.probe(unit.source) {
                let aggregate = aggregated
                    .get_mut(&unit.owner_id)
                    .expect("owner inserted above");
                aggregate.0 = false;
                aggregate.1.get_or_insert_with(|| error.code.to_owned());
            }
        }
        let results = owner_order
            .into_iter()
            .map(|source_id| {
                let (passed, error_code) = aggregated
                    .remove(&source_id)
                    .expect("ordered owner has aggregate");
                source_registry::RetestResult {
                    source_id,
                    passed,
                    error_code,
                }
            })
            .collect::<Vec<_>>();
        let response = source_registry::with_registry(storage_root, |registry| {
            registry.commit_retests(plan.generation, results)
        })?;
        to_value(response)
            .map_err(|_| CoreError::new("internal_error", "来源重测响应序列化失败", false))
    }

    pub(crate) fn execute(
        &self,
        command: Command,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<Value> {
        let value = match command {
            Command::SourceRegistrySnapshot { storage_root } => {
                to_value(source_registry::with_registry(&storage_root, |registry| {
                    Ok(registry.snapshot())
                })?)
            }
            Command::SourceRegistryPage {
                storage_root,
                cursor,
                limit,
                query,
                category_id,
                kind,
                searchable,
                child_directory,
                built_in,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.page(source_registry::RegistryPageRequest {
                    cursor,
                    limit,
                    query,
                    category_id,
                    kind,
                    searchable,
                    child_directory,
                    built_in,
                })
            })?),
            Command::SourceRegistryImportPreview {
                storage_root,
                expected_generation,
                raw_text,
                category_id,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.preview_import_text(expected_generation, &raw_text, &category_id)
            })?),
            Command::SourceRegistryCommitImportPreview {
                storage_root,
                expected_generation,
                preview_id,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.commit_import_preview(expected_generation, &preview_id)
            })?),
            Command::SourceRegistryBatchImportText {
                storage_root,
                expected_generation,
                raw_text,
                category_id,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.batch_import_text(expected_generation, &raw_text, &category_id)
            })?),
            Command::SourceRegistryBatchImport {
                storage_root,
                expected_generation,
                sources,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.batch_import(expected_generation, sources)
            })?),
            Command::SourceRegistryRetest {
                storage_root,
                expected_generation,
                source_ids,
            } => return self.registry_retest(&storage_root, expected_generation, &source_ids),
            Command::SourceRegistryUpdateSource {
                storage_root,
                expected_generation,
                update,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.update_source(expected_generation, update)
            })?),
            Command::SourceRegistryDeleteSources {
                storage_root,
                expected_generation,
                source_ids,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.delete_sources(expected_generation, source_ids)
            })?),
            Command::SourceRegistryCategoryUpsert {
                storage_root,
                expected_generation,
                category,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.upsert_category(expected_generation, category)
            })?),
            Command::SourceRegistryCategoryDelete {
                storage_root,
                expected_generation,
                category_id,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.delete_category(expected_generation, &category_id)
            })?),
            Command::SourceRegistryCategorySetMembers {
                storage_root,
                expected_generation,
                category_id,
                source_ids,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.set_category_members(expected_generation, &category_id, source_ids)
            })?),
            Command::SourceRegistryCompositeUpsert {
                storage_root,
                expected_generation,
                composite,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.upsert_composite(expected_generation, composite)
            })?),
            Command::SourceRegistryCompositeDelete {
                storage_root,
                expected_generation,
                source_id,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.delete_composite(expected_generation, &source_id)
            })?),
            Command::SourceRegistryRulesImport {
                storage_root,
                expected_generation,
                source_path,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.import_rules(expected_generation, &source_path)
            })?),
            Command::SourceRegistryRulesFetchImport {
                storage_root,
                expected_generation,
                rules_url,
            } => {
                // Do not keep the per-profile registry lock during DNS/TLS and
                // response streaming. A second CAS check during import makes
                // concurrent edits safe while snapshots and pages stay fast.
                source_registry::with_registry(&storage_root, |registry| {
                    registry.ensure_generation(expected_generation)
                })?;
                let bytes = source_registry::fetch_rules_bytes(&rules_url)?;
                to_value(source_registry::with_registry(&storage_root, |registry| {
                    registry.import_rules_bytes(expected_generation, &bytes)
                })?)
            }
            Command::SourceRegistryRulesExport {
                storage_root,
                expected_generation,
                destination_path,
                source_ids,
                include_credentials,
                credential_confirmation,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.export_rules(
                    expected_generation,
                    &destination_path,
                    &source_ids,
                    include_credentials,
                    &credential_confirmation,
                )
            })?),
            Command::SourceRegistryRestoreBackup {
                storage_root,
                expected_generation,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.restore_backup(expected_generation)
            })?),
            Command::SourceRegistryRestoreOfficial {
                storage_root,
                expected_generation,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.restore_official(expected_generation)
            })?),
            Command::SourceRegistryReset {
                storage_root,
                expected_generation,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.reset_all(expected_generation)
            })?),
            Command::LinkTokenize { text } => {
                Ok(json!({ "tokens": link_router::tokenize_links(&text)? }))
            }
            Command::LinkRoute {
                text,
                token_index,
                preference,
            } => to_value(self.route_text_link(&text, token_index, preference)?),
            Command::CatalogSummary { storage_root } => {
                to_value(source_registry::with_registry(&storage_root, |registry| {
                    registry.merged_catalog_summary()
                })?)
            }
            Command::CatalogPage {
                storage_root,
                parent_id,
                category_id,
                query,
                cursor,
                limit,
            } => to_value(source_registry::with_registry(&storage_root, |registry| {
                registry.merged_catalog_page(CatalogPageRequest {
                    parent_id,
                    category_id,
                    query,
                    cursor,
                    limit,
                })
            })?),
            Command::CatalogBrowse {
                storage_root,
                node_id,
                item_ref,
                page,
                refresh,
            } => to_value(self.catalog_browse(&storage_root, node_id, item_ref, page, refresh)?),
            Command::CatalogSearch {
                storage_root,
                query,
                scope_ids,
                options,
                operation_id: _,
            } => to_value(self.catalog_search(
                &storage_root,
                query,
                scope_ids,
                options,
                operation,
            )?),
            Command::CatalogSearchStart {
                storage_root,
                operation_id,
                query,
                scope_ids,
                options,
            } => to_value(self.catalog_search_start(
                &storage_root,
                operation_id,
                query,
                scope_ids,
                options,
            )?),
            Command::CatalogSearchRead {
                operation_id,
                after_cursor,
                ack_cursor,
                limit,
            } => to_value(search::read_incremental_search(
                &operation_id,
                after_cursor.as_deref(),
                ack_cursor.as_deref(),
                limit,
            )?),
            Command::CatalogSearchPause { operation_id } => {
                to_value(search::pause_incremental_search(&operation_id)?)
            }
            Command::CatalogSearchResume { operation_id } => {
                to_value(search::resume_incremental_search(&operation_id)?)
            }
            Command::CatalogSearchCancel { operation_id } => {
                to_value(search::cancel_incremental_search(&operation_id)?)
            }
            Command::CatalogSearchForget { operation_id } => {
                to_value(search::forget_incremental_search(&operation_id)?)
            }
            Command::CatalogBrowseLink {
                storage_root,
                route_handle,
                page,
                refresh,
            } => to_value(self.catalog_browse_link(&storage_root, route_handle, page, refresh)?),
            Command::CatalogDescribe {
                storage_root,
                node_id,
                item_ref,
            } => to_value(self.catalog_describe(&storage_root, node_id, item_ref)?),
            Command::CatalogResolve {
                storage_root,
                node_id,
                item_ref,
            } => to_value(self.catalog_resolve(&storage_root, node_id, item_ref, operation)?),
            Command::CatalogDownload {
                storage_root,
                node_id,
                item_ref,
                destination_directory,
                operation_id: _,
            } => to_value(self.catalog_download(
                &storage_root,
                node_id,
                item_ref,
                destination_directory,
                operation,
            )?),
            Command::LibraryProbe { source } => to_value(self.probe(source)?),
            Command::LibraryBrowse {
                source_id,
                share_url,
                password,
                page,
                refresh,
            } => to_value(self.browse(BrowseRequest {
                source_id,
                share_url,
                password,
                page,
                refresh,
            })?),
            Command::LibrarySearch {
                query,
                sources,
                options,
                operation_id: _,
            } => to_value(self.search(query, sources, options, operation)?),
            Command::LibraryCollect { items, sources } => to_value(self.collect(items, sources)?),
            Command::LibraryResolve {
                source_id,
                share_url,
                password,
            } => to_value(self.resolve(source_id, share_url, password, operation)?),
            Command::LibraryDownload {
                source_id,
                share_url,
                password,
                destination_directory,
                operation_id: _,
            } => to_value(self.download(
                source_id,
                share_url,
                password,
                destination_directory,
                operation,
            )?),
            Command::LibraryDescribe {
                source_id,
                share_url,
                password,
            } => to_value(self.describe(source_id, share_url, password)?),
            Command::LibraryFetchAsset { url } => to_value(asset::fetch_asset(&url)?),
            Command::LibraryRepackageAndroid { request } => {
                to_value(repackage_android::repackage_android(request)?)
            }
            Command::LibraryRepackageWindows { request } => {
                to_value(repackage_windows::repackage_windows(request)?)
            }
            _ => return Err(CoreError::invalid("不是公共软件库命令")),
        };
        value.map_err(|_| CoreError::new("internal_error", "软件库响应序列化失败", false))
    }
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::Arc,
        thread,
        time::{Duration, Instant},
    };

    use super::{rate_limit::RateLimiter, resolve::DirectExchangeDelays, url, LibraryService};

    #[test]
    fn test_library_url_rejects_non_https_and_untrusted_hosts() {
        let policy = url::SecurityPolicy::Production;
        assert!(url::validate_page_url("http://www.lanzouw.com/b123", &policy).is_err());
        assert!(url::validate_page_url("https://example.com/b123", &policy).is_err());
        assert!(url::validate_page_url("https://www.lanzouw.com/b123", &policy).is_ok());
    }

    #[test]
    fn test_library_describe_reads_file_introduction_without_credentials_in_output() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 1_024];
            let _ = stream.read(&mut request);
            let body = r#"<div class="appdes">官网最新版链接：https://example.com/</div>"#;
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let service = LibraryService {
            policy: url::SecurityPolicy::Test {
                origin: origin.clone(),
            },
            limiter: Arc::new(RateLimiter::new(Duration::ZERO)),
            exchange_delays: DirectExchangeDelays::ZERO,
        };
        let result = service
            .describe(
                "source-one".to_owned(),
                format!("{origin}/file"),
                "not-returned".to_owned(),
            )
            .unwrap();
        assert_eq!(result.description, "官网最新版链接：https://example.com/");
        let json = serde_json::to_string(&result).unwrap();
        assert!(!json.contains("not-returned"));
        assert!(!json.to_ascii_lowercase().contains("password"));
        server.join().unwrap();
    }

    #[test]
    fn test_library_download_resolves_and_atomically_writes_real_file() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server_origin = origin.clone();
        let server = thread::spawn(move || {
            for index in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut request = [0_u8; 4096];
                let count = stream.read(&mut request).unwrap();
                let request = String::from_utf8_lossy(&request[..count]);
                let body = match index {
                    0 => r#"<title>工具.apk - 蓝奏云</title><script>var ajaxdata='sig';</script>"#
                        .to_owned(),
                    1 => {
                        assert!(request.contains("p=secret"));
                        format!(r#"{{"zt":1,"url":"{server_origin}/file/tool.apk"}}"#)
                    }
                    _ => "payload".to_owned(),
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let service = LibraryService {
            policy: url::SecurityPolicy::Test {
                origin: origin.clone(),
            },
            limiter: Arc::new(RateLimiter::new(Duration::ZERO)),
            exchange_delays: DirectExchangeDelays::ZERO,
        };
        let directory = tempfile::tempdir().unwrap();
        let operation = crate::operation::begin(
            Some("library-download-integration-test"),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();

        let result = service
            .download(
                "source-one".to_owned(),
                format!("{origin}/share"),
                "secret".to_owned(),
                directory.path().to_string_lossy().into_owned(),
                Some(&operation),
            )
            .unwrap();

        assert_eq!(result.file_name, "工具.apk");
        assert_eq!(result.bytes_written, 7);
        assert_eq!(std::fs::read(&result.path).unwrap(), b"payload");
        assert!(!serde_json::to_string(&result).unwrap().contains("secret"));
        assert_eq!(
            directory.path().read_dir().unwrap().count(),
            1,
            "successful publication must not leave a .part file"
        );
        operation.finish_success();
        crate::operation::forget("library-download-integration-test").unwrap();
        server.join().unwrap();
    }

    #[test]
    fn test_library_download_cancellation_removes_partial_file() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server_origin = origin.clone();
        let server = thread::spawn(move || {
            for index in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 4096];
                let _ = stream.read(&mut request);
                if index == 2 {
                    let total = 512 * 1024;
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n"
                    )
                    .unwrap();
                    stream.write_all(&vec![b'a'; 64 * 1024]).unwrap();
                    thread::sleep(Duration::from_millis(500));
                    let _ = stream.write_all(&vec![b'b'; total - 64 * 1024]);
                    continue;
                }
                let body = if index == 0 {
                    r#"<title>cancel.apk - 蓝奏云</title><script>var ajaxdata='sig';</script>"#
                        .to_owned()
                } else {
                    format!(r#"{{"zt":1,"url":"{server_origin}/file/cancel.apk"}}"#)
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let service = LibraryService {
            policy: url::SecurityPolicy::Test {
                origin: origin.clone(),
            },
            limiter: Arc::new(RateLimiter::new(Duration::ZERO)),
            exchange_delays: DirectExchangeDelays::ZERO,
        };
        let directory = tempfile::tempdir().unwrap();
        let destination = directory.path().to_string_lossy().into_owned();
        let operation = crate::operation::begin(
            Some("library-download-cancel-test"),
            crate::operation::OperationKind::Download,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let worker = thread::spawn(move || {
            let result = service.download(
                "source-one".to_owned(),
                format!("{origin}/share"),
                String::new(),
                destination,
                Some(&worker_operation),
            );
            worker_operation.finish_result(&result);
            result
        });
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            let status = crate::operation::status("library-download-cancel-test").unwrap();
            if status["bytesTransferred"].as_u64().unwrap_or(0) > 0 {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }

        crate::operation::cancel("library-download-cancel-test").unwrap();
        let error = worker.join().unwrap().unwrap_err();

        assert_eq!(error.code, "cancelled");
        assert_eq!(directory.path().read_dir().unwrap().count(), 0);
        let status = crate::operation::status("library-download-cancel-test").unwrap();
        assert_eq!(status["state"], "cancelled");
        crate::operation::forget("library-download-cancel-test").unwrap();
        server.join().unwrap();
    }
}
