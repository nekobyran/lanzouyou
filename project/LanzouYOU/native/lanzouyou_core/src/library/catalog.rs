use std::collections::{HashMap, HashSet, VecDeque};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{CoreError, CoreResult};

use super::{
    handle_registry,
    model::{LibraryFolder, LibraryItem, LibrarySource, LibrarySourceKind},
    url::{normalize_public_share_url, safe_asset_url, SecurityPolicy},
};

const CANONICAL_ORIGIN: &str = "https://www.lanzouw.com";
const DEFAULT_PAGE_LIMIT: usize = 100;
const MAX_PAGE_LIMIT: usize = 200;
const CURSOR_VERSION: u8 = 1;
const BUILTIN_SOURCES: &[u8] =
    include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/catalog/s"));
const BUILTIN_HINTS: &[u8] =
    include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/catalog/h"));
const BUILTIN_COMPOSITES: &[u8] =
    include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/catalog/c"));

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub(crate) enum CatalogNodeKind {
    RemoteSource,
    Composite,
    Folder,
    SingleSoftware,
    File,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CatalogNode {
    pub(crate) id: String,
    pub(crate) parent_id: String,
    pub(crate) source_id: String,
    pub(crate) kind: CatalogNodeKind,
    pub(crate) title: String,
    pub(crate) publisher: String,
    pub(crate) description: String,
    pub(crate) icon_url: String,
    pub(crate) size: String,
    pub(crate) time: String,
    pub(crate) searchable: bool,
    pub(crate) child_directory: bool,
    pub(crate) origin_path: String,
    pub(crate) origin_url: String,
    pub(crate) has_children: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) error_code: Option<String>,
    pub(crate) share_url: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub(crate) struct CatalogPageRequest {
    pub(crate) parent_id: String,
    pub(crate) category_id: String,
    pub(crate) query: String,
    pub(crate) cursor: String,
    pub(crate) limit: usize,
}

impl Default for CatalogPageRequest {
    fn default() -> Self {
        Self {
            parent_id: String::new(),
            category_id: "all".to_owned(),
            query: String::new(),
            cursor: String::new(),
            limit: 0,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CatalogPage {
    pub(crate) revision: String,
    pub(crate) total: usize,
    pub(crate) next_cursor: String,
    pub(crate) has_more: bool,
    pub(crate) nodes: Vec<CatalogNode>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CatalogSummary {
    pub(crate) revision: String,
    pub(crate) official_count: usize,
    pub(crate) composite_count: usize,
    pub(crate) node_count: usize,
    pub(crate) searchable_count: usize,
}

struct CatalogStats {
    top_level_sources: usize,
    child_sources: usize,
    credentialed_sources: usize,
    source_toggles: usize,
    file_nodes: usize,
    single_software_nodes: usize,
    source_asset_bytes: usize,
    hint_asset_bytes: usize,
    composite_asset_bytes: usize,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CatalogItemRef {
    pub(crate) source_id: String,
    pub(crate) title: String,
    pub(crate) url: String,
    pub(crate) share_url: String,
    pub(crate) folder_id: String,
    pub(crate) is_folder: bool,
}

pub(crate) type CatalogTarget = handle_registry::HandleTarget;

pub(crate) struct CatalogSearchPlan {
    pub(crate) sources: Vec<LibrarySource>,
    pub(crate) local_items: Vec<LibraryItem>,
}

struct CatalogEntry {
    node: CatalogNode,
    password: String,
    #[cfg(test)]
    hint: u8,
    top_level: bool,
    folded: String,
}

pub(crate) struct Catalog {
    entries: Vec<CatalogEntry>,
    by_id: HashMap<String, usize>,
    by_source_id: HashMap<String, usize>,
    children: HashMap<String, Vec<usize>>,
    summary: CatalogSummary,
    #[cfg(test)]
    stats: CatalogStats,
}

#[derive(Default)]
struct SourceStats {
    lines: usize,
    toggles: usize,
    searchable: usize,
    child: usize,
    credentialed: usize,
}

struct CompositeContext {
    node_id: String,
    publisher: String,
}

static CATALOG: Lazy<CoreResult<Catalog>> =
    Lazy::new(|| Catalog::parse(BUILTIN_SOURCES, BUILTIN_HINTS, BUILTIN_COMPOSITES));

pub(crate) fn builtin_catalog() -> CoreResult<&'static Catalog> {
    match &*CATALOG {
        Ok(catalog) => Ok(catalog),
        Err(error) => Err(error.clone()),
    }
}

impl Catalog {
    fn parse(sources: &[u8], hints: &[u8], composites: &[u8]) -> CoreResult<Self> {
        let source_text = std::str::from_utf8(sources)
            .map_err(|_| CoreError::parse("内置软件源 s 不是 UTF-8"))?;
        let composite_text = std::str::from_utf8(composites)
            .map_err(|_| CoreError::parse("内置软件源 c 不是 UTF-8"))?;
        let mut entries = Vec::with_capacity(4_096);
        let mut node_ids = HashSet::with_capacity(4_096);
        let mut stats = SourceStats::default();
        let mut searchable = false;

        for raw_line in source_text.lines() {
            let line = raw_line.trim_end_matches('\r');
            if matches!(line, "0" | "1") {
                searchable = line == "1";
                stats.toggles += 1;
                continue;
            }
            let cells = line.split('\t').collect::<Vec<_>>();
            if cells.len() < 2 {
                continue;
            }
            #[cfg(test)]
            let hint_index = stats.lines;
            stats.lines += 1;
            let title = clean_cell(cells[0]);
            let Some(share_url) = normalize_catalog_share_url(cells[1]) else {
                return Err(CoreError::parse(format!(
                    "内置软件源 s 第 {} 条分享地址无效",
                    stats.lines
                )));
            };
            let password = validate_password(cells.get(2).copied().unwrap_or_default())?;
            let child = cells.get(3).is_some_and(|value| *value == "child");
            let origin_path = clean_cell(cells.get(4).copied().unwrap_or_default());
            let origin_url = cells
                .get(5)
                .and_then(|value| normalize_catalog_share_url(value))
                .unwrap_or_default();
            if searchable {
                stats.searchable += 1;
            }
            if child {
                stats.child += 1;
            }
            if !password.is_empty() {
                stats.credentialed += 1;
            }
            let node_id = format!("remote:{}", digest_prefix(share_url.as_bytes(), 16));
            if !node_ids.insert(node_id.clone()) {
                continue;
            }
            let node = CatalogNode {
                source_id: operation_source_id(&node_id),
                id: node_id,
                parent_id: String::new(),
                kind: CatalogNodeKind::RemoteSource,
                title,
                publisher: String::new(),
                description: String::new(),
                icon_url: String::new(),
                size: String::new(),
                time: String::new(),
                searchable,
                child_directory: child,
                origin_path,
                origin_url,
                has_children: false,
                error_code: None,
                share_url,
            };
            entries.push(CatalogEntry {
                node,
                password,
                #[cfg(test)]
                hint: hints.get(hint_index).copied().unwrap_or_default(),
                top_level: true,
                folded: String::new(),
            });
        }
        if hints.len() != stats.lines {
            return Err(CoreError::parse(format!(
                "内置软件源提示 h 数量漂移：source={} hint={}",
                stats.lines,
                hints.len()
            )));
        }

        let mut current: Option<CompositeContext> = None;
        let mut member_ids = HashSet::new();
        for raw_line in composite_text.lines() {
            let line = raw_line.trim_end_matches('\r');
            let cells = line.split('\t').collect::<Vec<_>>();
            let kind = cells.first().copied().unwrap_or_default();
            if kind == "C" {
                current = None;
                member_ids.clear();
                if cells.len() < 4 {
                    continue;
                }
                let node_id = clean_cell(cells[1]);
                let title = clean_cell(cells[2]);
                if !node_id.starts_with("local:")
                    || title.is_empty()
                    || !node_ids.insert(node_id.clone())
                {
                    continue;
                }
                let publisher = clean_cell(cells[3]);
                let raw_icon = cells.get(4).copied().unwrap_or_default().trim();
                let icon_url = safe_asset_url(raw_icon).unwrap_or_default();
                let description = clean_cell(cells.get(5).copied().unwrap_or_default());
                entries.push(CatalogEntry {
                    node: CatalogNode {
                        id: node_id.clone(),
                        parent_id: String::new(),
                        source_id: operation_source_id(&node_id),
                        kind: CatalogNodeKind::Composite,
                        title,
                        publisher: publisher.clone(),
                        description,
                        icon_url,
                        size: String::new(),
                        time: String::new(),
                        searchable: false,
                        child_directory: false,
                        origin_path: String::new(),
                        origin_url: String::new(),
                        has_children: false,
                        error_code: None,
                        share_url: String::new(),
                    },
                    password: String::new(),
                    #[cfg(test)]
                    hint: 0,
                    top_level: true,
                    folded: String::new(),
                });
                current = Some(CompositeContext { node_id, publisher });
                continue;
            }

            let Some(owner) = &current else {
                continue;
            };
            if cells.len() < 5 {
                continue;
            }
            let member_id = clean_cell(cells[1]);
            if member_id.is_empty() || !member_ids.insert(member_id.clone()) {
                continue;
            }
            let node_kind = match kind {
                "D" => CatalogNodeKind::Folder,
                "R" => CatalogNodeKind::RemoteSource,
                "L" => CatalogNodeKind::SingleSoftware,
                _ => CatalogNodeKind::File,
            };
            let raw_parent = clean_cell(cells[2]);
            let parent_id = if raw_parent.is_empty() {
                owner.node_id.clone()
            } else {
                format!("{}#{raw_parent}", owner.node_id)
            };
            let node_id = format!("{}#{member_id}", owner.node_id);
            if !node_ids.insert(node_id.clone()) {
                continue;
            }
            let share_url = if node_kind == CatalogNodeKind::Folder {
                String::new()
            } else {
                let Some(url) = normalize_catalog_share_url(cells[4]) else {
                    continue;
                };
                url
            };
            let password = validate_password(cells.get(5).copied().unwrap_or_default())?;
            let error_code = cells
                .get(6)
                .filter(|value| !value.trim().is_empty())
                .map(|_| "source_error".to_owned());
            let is_searchable = cells.get(7).is_some_and(|value| *value == "1");
            let raw_icon = cells.get(8).copied().unwrap_or_default().trim();
            let icon_url = safe_asset_url(raw_icon).unwrap_or_default();
            entries.push(CatalogEntry {
                node: CatalogNode {
                    id: node_id.clone(),
                    parent_id,
                    source_id: operation_source_id(&node_id),
                    kind: node_kind,
                    title: clean_cell(cells[3]),
                    publisher: owner.publisher.clone(),
                    description: String::new(),
                    icon_url,
                    size: clean_cell(cells.get(9).copied().unwrap_or_default()),
                    time: clean_cell(cells.get(10).copied().unwrap_or_default()),
                    searchable: is_searchable,
                    child_directory: false,
                    origin_path: String::new(),
                    origin_url: String::new(),
                    has_children: false,
                    error_code,
                    share_url,
                },
                password,
                #[cfg(test)]
                hint: 0,
                top_level: false,
                folded: String::new(),
            });
        }

        Self::index(
            entries,
            CatalogSummary {
                revision: catalog_revision(sources, hints, composites),
                official_count: 0,
                composite_count: 0,
                node_count: 0,
                searchable_count: stats.searchable,
            },
            CatalogStats {
                top_level_sources: 0,
                child_sources: stats.child,
                credentialed_sources: stats.credentialed,
                source_toggles: stats.toggles,
                file_nodes: 0,
                single_software_nodes: 0,
                source_asset_bytes: sources.len(),
                hint_asset_bytes: hints.len(),
                composite_asset_bytes: composites.len(),
            },
        )
    }

    fn index(
        mut entries: Vec<CatalogEntry>,
        mut summary: CatalogSummary,
        mut stats: CatalogStats,
    ) -> CoreResult<Self> {
        let mut by_id = HashMap::with_capacity(entries.len());
        let mut by_source_id = HashMap::with_capacity(entries.len());
        let mut children = HashMap::<String, Vec<usize>>::new();
        for (index, entry) in entries.iter().enumerate() {
            if by_id.insert(entry.node.id.clone(), index).is_some() {
                return Err(CoreError::parse("内置软件源节点 id 重复"));
            }
            if by_source_id
                .insert(entry.node.source_id.clone(), index)
                .is_some()
            {
                return Err(CoreError::parse("内置软件源 operation sourceId 冲突"));
            }
            children
                .entry(entry.node.parent_id.clone())
                .or_default()
                .push(index);
        }
        let nodes_with_children = children
            .keys()
            .filter(|parent| !parent.is_empty())
            .cloned()
            .collect::<HashSet<_>>();
        for entry in &mut entries {
            entry.node.has_children = nodes_with_children.contains(&entry.node.id);
            entry.folded = fold_search(&entry.node);
        }
        summary.official_count = entries
            .iter()
            .filter(|entry| entry.top_level && entry.node.kind == CatalogNodeKind::RemoteSource)
            .count();
        summary.composite_count = entries
            .iter()
            .filter(|entry| entry.top_level && entry.node.kind == CatalogNodeKind::Composite)
            .count();
        stats.top_level_sources = children.get("").map_or(0, Vec::len);
        summary.node_count = entries.len();
        stats.file_nodes = entries
            .iter()
            .filter(|entry| entry.node.kind == CatalogNodeKind::File)
            .count();
        stats.single_software_nodes = entries
            .iter()
            .filter(|entry| entry.node.kind == CatalogNodeKind::SingleSoftware)
            .count();
        if stats.top_level_sources != summary.official_count + summary.composite_count
            || stats.child_sources > summary.official_count
            || stats.credentialed_sources > summary.node_count
            || stats.source_toggles > summary.official_count
            || stats.file_nodes + stats.single_software_nodes > summary.node_count
            || stats.source_asset_bytes == 0
            || stats.hint_asset_bytes == 0
            || stats.composite_asset_bytes == 0
        {
            return Err(CoreError::parse("内置软件源资产统计不一致"));
        }
        Ok(Self {
            entries,
            by_id,
            by_source_id,
            children,
            summary,
            #[cfg(test)]
            stats,
        })
    }

    pub(crate) fn summary(&self) -> CatalogSummary {
        self.summary.clone()
    }

    pub(crate) fn registry_baseline_nodes(&self) -> Vec<CatalogNode> {
        self.children
            .get("")
            .into_iter()
            .flatten()
            .map(|index| self.entries[*index].node.clone())
            .collect()
    }

    pub(crate) fn registry_source(&self, node_or_source_id: &str) -> CoreResult<LibrarySource> {
        let entry = self.entry(node_or_source_id)?;
        if entry.node.kind != CatalogNodeKind::RemoteSource || entry.node.share_url.is_empty() {
            return Err(CoreError::invalid("SourceRegistry 目标不是可测试远程源"));
        }
        Ok(LibrarySource {
            source_id: entry.node.source_id.clone(),
            title: entry.node.title.clone(),
            share_url: entry.node.share_url.clone(),
            password: entry.password.clone(),
        })
    }

    pub(crate) fn page(&self, request: CatalogPageRequest) -> CoreResult<CatalogPage> {
        let limit = if request.limit == 0 {
            DEFAULT_PAGE_LIMIT
        } else if request.limit > MAX_PAGE_LIMIT {
            return Err(CoreError::invalid("catalog page limit 不能超过 200"));
        } else {
            request.limit
        };
        let parent_id = request.parent_id.trim().to_owned();
        if parent_id.chars().any(char::is_control) || parent_id.chars().count() > 256 {
            return Err(CoreError::invalid("catalog parentId 格式无效"));
        }
        if !parent_id.is_empty() && !self.by_id.contains_key(&parent_id) {
            return Err(CoreError::invalid("catalog parentId 不存在"));
        }
        let query = request.query.trim().to_lowercase();
        if query.chars().count() > 256 || query.chars().any(char::is_control) {
            return Err(CoreError::invalid("catalog query 格式无效"));
        }
        let category = parse_category(&request.category_id)?;
        let scope = cursor_scope(&parent_id, category, &query);
        let offset = if request.cursor.is_empty() {
            0
        } else {
            decode_cursor(&request.cursor, &scope)?
        };
        let candidates = self.candidate_indices(&parent_id, !query.is_empty());
        let matches = candidates
            .into_iter()
            .filter(|index| {
                let entry = &self.entries[*index];
                category.is_none_or(|kind| entry.node.kind == kind)
                    && (query.is_empty() || entry.folded.contains(&query))
            })
            .collect::<Vec<_>>();
        if offset > matches.len() {
            return Err(CoreError::invalid("catalog cursor 已失效"));
        }
        let end = offset.saturating_add(limit).min(matches.len());
        let nodes = matches[offset..end]
            .iter()
            .map(|index| self.entries[*index].node.clone())
            .collect();
        Ok(CatalogPage {
            revision: self.summary.revision.clone(),
            total: matches.len(),
            next_cursor: if end < matches.len() {
                encode_cursor(end, &scope)
            } else {
                String::new()
            },
            has_more: end < matches.len(),
            nodes,
        })
    }

    fn candidate_indices(&self, parent_id: &str, recursive: bool) -> Vec<usize> {
        if !recursive {
            return self.children.get(parent_id).cloned().unwrap_or_default();
        }
        if parent_id.is_empty() {
            return (0..self.entries.len()).collect();
        }
        let mut output = Vec::new();
        let mut queue = VecDeque::from([parent_id.to_owned()]);
        while let Some(parent) = queue.pop_front() {
            for index in self.children.get(&parent).into_iter().flatten().copied() {
                output.push(index);
                if self.entries[index].node.has_children {
                    queue.push_back(self.entries[index].node.id.clone());
                }
            }
        }
        output
    }

    fn entry_index(&self, node_or_source_id: &str) -> CoreResult<usize> {
        self.by_id
            .get(node_or_source_id)
            .or_else(|| self.by_source_id.get(node_or_source_id))
            .copied()
            .ok_or_else(|| CoreError::invalid("catalog nodeId/sourceId 不存在"))
    }

    fn entry(&self, node_or_source_id: &str) -> CoreResult<&CatalogEntry> {
        self.entry_index(node_or_source_id)
            .map(|index| &self.entries[index])
    }

    pub(crate) fn library_item(&self, node_id: &str) -> CoreResult<LibraryItem> {
        let entry = self.entry(node_id)?;
        if entry.node.share_url.is_empty() {
            return Err(CoreError::invalid("catalog 节点不是远程项目"));
        }
        Ok(LibraryItem {
            source_id: entry.node.source_id.clone(),
            title: entry.node.title.clone(),
            url: entry.node.share_url.clone(),
            share_url: entry.node.share_url.clone(),
            size: entry.node.size.clone(),
            time: entry.node.time.clone(),
            icon_url: entry.node.icon_url.clone(),
            source: entry.node.publisher.clone(),
            description: entry.node.description.clone(),
            is_folder: matches!(
                entry.node.kind,
                CatalogNodeKind::RemoteSource | CatalogNodeKind::Folder
            ),
            ..LibraryItem::default()
        })
    }

    /// Materialize a bounded local composite view when a search result's
    /// stable sourceId belongs to a packaged file/single-software node.
    /// Remote source IDs deliberately return `None` and continue through the
    /// network browser.
    pub(crate) fn local_source_folder(
        &self,
        node_or_source_id: &str,
        page: u32,
    ) -> CoreResult<Option<LibraryFolder>> {
        let index = self.entry_index(node_or_source_id)?;
        if self.entries[index].node.kind == CatalogNodeKind::RemoteSource {
            return Ok(None);
        }
        if page == 0 || page > 1_000 {
            return Err(CoreError::invalid("catalog browse page 必须为 1-1000"));
        }

        let mut root = index;
        let mut visited = HashSet::new();
        while !self.entries[root].node.parent_id.is_empty() {
            if !visited.insert(root) {
                return Err(CoreError::parse("内置软件源父级形成循环"));
            }
            root = *self
                .by_id
                .get(&self.entries[root].node.parent_id)
                .ok_or_else(|| CoreError::parse("内置软件源父级不存在"))?;
        }
        let root_entry = &self.entries[root];
        let indices = self
            .candidate_indices(&root_entry.node.id, true)
            .into_iter()
            .filter(|candidate| {
                matches!(
                    self.entries[*candidate].node.kind,
                    CatalogNodeKind::RemoteSource
                        | CatalogNodeKind::SingleSoftware
                        | CatalogNodeKind::File
                )
            })
            .collect::<Vec<_>>();
        let start = usize::try_from(page - 1)
            .unwrap_or(usize::MAX)
            .saturating_mul(50);
        let end = start.saturating_add(50).min(indices.len());
        let items = if start >= indices.len() {
            Vec::new()
        } else {
            indices[start..end]
                .iter()
                .map(|candidate| self.library_item(&self.entries[*candidate].node.id))
                .collect::<CoreResult<Vec<_>>>()?
        };
        Ok(Some(LibraryFolder {
            source_id: root_entry.node.source_id.clone(),
            kind: LibrarySourceKind::Directory,
            title: root_entry.node.title.clone(),
            publisher: root_entry.node.publisher.clone(),
            avatar_url: root_entry.node.icon_url.clone(),
            description: root_entry.node.description.clone(),
            save_url: String::new(),
            url: root_entry.node.share_url.clone(),
            folder_id: root_entry.node.id.clone(),
            page,
            has_more: end < indices.len(),
            next_page_ready_at_ms: 0,
            remote_search: false,
            items,
            api_folder_count: 0,
        }))
    }

    pub(crate) fn search_plan(
        &self,
        query: &str,
        scope_ids: &[String],
    ) -> CoreResult<CatalogSearchPlan> {
        let folded_query = query.trim().to_lowercase();
        if folded_query.is_empty()
            || folded_query.chars().count() > 100
            || folded_query.chars().any(char::is_control)
        {
            return Err(CoreError::invalid("catalog search query 格式无效"));
        }
        if scope_ids.len() > 4_096 {
            return Err(CoreError::invalid(
                "catalog search scopeIds 不能超过 4096 个",
            ));
        }

        let mut indices = Vec::with_capacity(self.entries.len());
        let mut seen = HashSet::with_capacity(self.entries.len());
        if scope_ids.is_empty() {
            for (index, entry) in self.entries.iter().enumerate() {
                if matches!(
                    entry.node.kind,
                    CatalogNodeKind::RemoteSource
                        | CatalogNodeKind::File
                        | CatalogNodeKind::SingleSoftware
                ) && seen.insert(index)
                {
                    indices.push(index);
                }
            }
        } else {
            for scope_id in scope_ids {
                let scope_id = scope_id.trim();
                let root = self.entry_index(scope_id)?;
                if seen.insert(root) {
                    indices.push(root);
                }
                if self.entries[root].node.has_children {
                    for index in self.candidate_indices(&self.entries[root].node.id, true) {
                        if seen.insert(index) {
                            indices.push(index);
                        }
                    }
                }
            }
        }

        let name_only = folded_query.chars().count() == 1;
        let mut sources = Vec::new();
        let mut local_items = Vec::new();
        let mut source_urls = HashSet::new();
        for index in indices {
            let entry = &self.entries[index];
            match entry.node.kind {
                CatalogNodeKind::RemoteSource => {
                    if source_urls.insert(entry.node.share_url.clone()) {
                        sources.push(LibrarySource {
                            source_id: entry.node.source_id.clone(),
                            title: entry.node.title.clone(),
                            share_url: entry.node.share_url.clone(),
                            password: entry.password.clone(),
                        });
                    }
                }
                CatalogNodeKind::File | CatalogNodeKind::SingleSoftware => {
                    let matches = if name_only {
                        entry.node.title.to_lowercase().contains(&folded_query)
                    } else {
                        entry.folded.contains(&folded_query)
                    };
                    if matches {
                        local_items.push(self.library_item(&entry.node.id)?);
                    }
                }
                CatalogNodeKind::Composite | CatalogNodeKind::Folder => {}
            }
        }
        Ok(CatalogSearchPlan {
            sources,
            local_items,
        })
    }

    pub(crate) fn target_for_ref(&self, item_ref: &CatalogItemRef) -> CoreResult<CatalogTarget> {
        validate_ref_text(&item_ref.title, 512, "title")?;
        validate_ref_text(&item_ref.folder_id, 512, "folderId")?;
        validate_ref_text(&item_ref.url, 2_048, "url")?;
        validate_ref_text(&item_ref.share_url, 2_048, "shareUrl")?;
        // The remaining itemRef fields are presentation-only. The randomized,
        // short-lived server handle is the sole authority for URLs, kind and
        // access code, so a caller cannot borrow a source code for any URL.
        let target = handle_registry::resolve(item_ref.source_id.trim())?;
        if item_ref.is_folder != target.is_folder {
            return Err(CoreError::invalid("catalog itemRef 项目类型已失效"));
        }
        Ok(target)
    }

    pub(crate) fn target(&self, node_id: &str) -> CoreResult<CatalogTarget> {
        let entry = self.entry(node_id)?;
        if entry.node.share_url.is_empty() {
            return Err(CoreError::invalid("catalog 节点没有远程目标"));
        }
        Ok(CatalogTarget {
            source_id: entry.node.source_id.clone(),
            title: entry.node.title.clone(),
            url: entry.node.share_url.clone(),
            share_url: entry.node.share_url.clone(),
            is_folder: entry.node.kind == CatalogNodeKind::RemoteSource,
            single_software: entry.node.kind == CatalogNodeKind::SingleSoftware,
            password: entry.password.clone(),
        })
    }
}

fn validate_password(value: &str) -> CoreResult<String> {
    if value.chars().count() > 64 || value.chars().any(char::is_control) {
        Err(CoreError::parse("内置软件源访问码格式无效"))
    } else {
        Ok(value.to_owned())
    }
}

fn validate_ref_text(value: &str, max: usize, field: &str) -> CoreResult<()> {
    if value.chars().count() > max || value.chars().any(char::is_control) {
        Err(CoreError::invalid(format!(
            "catalog itemRef {field} 格式无效"
        )))
    } else {
        Ok(())
    }
}

fn normalize_catalog_share_url(value: &str) -> Option<String> {
    let value = value.trim();
    let absolute = if value.starts_with('/') {
        format!("{CANONICAL_ORIGIN}{value}")
    } else {
        value.to_owned()
    };
    normalize_public_share_url(&absolute, &SecurityPolicy::Production).ok()
}

fn clean_cell(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character == '\t' || character == '\r' || character == '\n' {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .trim()
        .to_owned()
}

fn digest_prefix(bytes: &[u8], digest_bytes: usize) -> String {
    let digest = Sha256::digest(bytes);
    digest
        .iter()
        .take(digest_bytes.max(1).min(digest.len()))
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
fn operation_source_id(node_id: &str) -> String {
    format!("catalog_{}", URL_SAFE_NO_PAD.encode(node_id.as_bytes()))
}

fn fold_search(node: &CatalogNode) -> String {
    format!(
        "{}\n{}\n{}\n{}\n{}",
        node.title, node.publisher, node.description, node.origin_path, node.origin_url
    )
    .to_lowercase()
}

fn parse_category(value: &str) -> CoreResult<Option<CatalogNodeKind>> {
    match value.trim() {
        "" | "all" => Ok(None),
        "remoteSource" => Ok(Some(CatalogNodeKind::RemoteSource)),
        "composite" => Ok(Some(CatalogNodeKind::Composite)),
        "folder" => Ok(Some(CatalogNodeKind::Folder)),
        "singleSoftware" => Ok(Some(CatalogNodeKind::SingleSoftware)),
        "file" => Ok(Some(CatalogNodeKind::File)),
        _ => Err(CoreError::invalid("catalog categoryId 不受支持")),
    }
}

fn catalog_revision(sources: &[u8], hints: &[u8], composites: &[u8]) -> String {
    format!(
        "catalog-v1-{}-{}-{}",
        sources.len(),
        hints.len(),
        composites.len()
    )
}

fn cursor_scope(parent_id: &str, category: Option<CatalogNodeKind>, query: &str) -> String {
    let kind = match category {
        None => 0,
        Some(CatalogNodeKind::RemoteSource) => 1,
        Some(CatalogNodeKind::Composite) => 2,
        Some(CatalogNodeKind::Folder) => 3,
        Some(CatalogNodeKind::SingleSoftware) => 4,
        Some(CatalogNodeKind::File) => 5,
    };
    format!("{parent_id}\0{kind}\0{query}")
}

fn encode_cursor(offset: usize, scope: &str) -> String {
    let mut payload = Vec::with_capacity(9 + scope.len());
    payload.push(CURSOR_VERSION);
    payload.extend_from_slice(&(offset as u64).to_be_bytes());
    payload.extend_from_slice(scope.as_bytes());
    URL_SAFE_NO_PAD.encode(payload)
}

fn decode_cursor(value: &str, scope: &str) -> CoreResult<usize> {
    let payload = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| CoreError::invalid("catalog cursor 格式无效"))?;
    if payload.len() < 9 || payload[0] != CURSOR_VERSION || payload[9..] != *scope.as_bytes() {
        return Err(CoreError::invalid("catalog cursor 与当前筛选不匹配"));
    }
    let mut offset = [0_u8; 8];
    offset.copy_from_slice(&payload[1..9]);
    usize::try_from(u64::from_be_bytes(offset))
        .map_err(|_| CoreError::invalid("catalog cursor 超出范围"))
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    const SOURCES: &[u8] = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/catalog/s"));
    const HINTS: &[u8] = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/catalog/h"));
    const COMPOSITES: &[u8] =
        include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/catalog/c"));

    #[test]
    fn test_packaged_catalog_assets_match_pinned_counts_and_kinds() {
        let catalog = Catalog::parse(SOURCES, HINTS, COMPOSITES).unwrap();
        let summary = catalog.summary();

        assert_eq!(SOURCES.len(), 22_990);
        assert_eq!(HINTS.len(), 597);
        assert_eq!(COMPOSITES.len(), 143_917);
        assert_eq!(catalog.stats.source_asset_bytes, SOURCES.len());
        assert_eq!(catalog.stats.hint_asset_bytes, HINTS.len());
        assert_eq!(catalog.stats.composite_asset_bytes, COMPOSITES.len());
        assert_eq!(summary.official_count, 597);
        assert_eq!(summary.composite_count, 9);
        assert_eq!(catalog.stats.top_level_sources, 606);
        assert_eq!(summary.node_count, 3_370);
        assert_eq!(summary.searchable_count, 274);
        assert_eq!(catalog.stats.child_sources, 67);
        assert_eq!(catalog.stats.credentialed_sources, 21);
        assert_eq!(catalog.stats.source_toggles, 11);
        assert_eq!(catalog.stats.file_nodes, 2_730);
        assert_eq!(catalog.stats.single_software_nodes, 34);

        let counts = catalog.entries.iter().fold(
            std::collections::HashMap::<CatalogNodeKind, usize>::new(),
            |mut counts, entry| {
                *counts.entry(entry.node.kind).or_default() += 1;
                counts
            },
        );
        assert_eq!(counts[&CatalogNodeKind::RemoteSource], 597);
        assert_eq!(counts[&CatalogNodeKind::Composite], 9);
        assert_eq!(counts[&CatalogNodeKind::File], 2_730);
        assert_eq!(counts[&CatalogNodeKind::SingleSoftware], 34);
        assert_eq!(counts.get(&CatalogNodeKind::Folder), None);

        let official = catalog
            .entries
            .iter()
            .filter(|entry| entry.top_level && entry.node.kind == CatalogNodeKind::RemoteSource)
            .collect::<Vec<_>>();
        assert_eq!(official.len(), HINTS.len());
        assert!(official
            .iter()
            .zip(HINTS)
            .all(|(entry, hint)| entry.hint == *hint));
        assert_eq!(
            official
                .iter()
                .map(|entry| entry.node.share_url.as_str())
                .collect::<HashSet<_>>()
                .len(),
            597
        );
    }

    #[test]
    fn test_catalog_page_is_opaque_stable_bounded_and_filter_bound() {
        let catalog = Catalog::parse(SOURCES, HINTS, COMPOSITES).unwrap();
        let first = catalog
            .page(CatalogPageRequest {
                limit: 100,
                ..CatalogPageRequest::default()
            })
            .unwrap();
        assert_eq!(first.total, 606);
        assert_eq!(first.nodes.len(), 100);
        let cursor = first.next_cursor.clone();
        assert!(first.has_more);
        assert!(!cursor.is_empty());
        assert!(!cursor.contains("100"));

        let second = catalog
            .page(CatalogPageRequest {
                cursor: cursor.clone(),
                limit: 100,
                ..CatalogPageRequest::default()
            })
            .unwrap();
        let first_ids = first
            .nodes
            .iter()
            .map(|node| &node.id)
            .collect::<HashSet<_>>();
        assert!(second
            .nodes
            .iter()
            .all(|node| !first_ids.contains(&node.id)));
        assert!(catalog
            .page(CatalogPageRequest {
                query: "different".to_owned(),
                cursor,
                limit: 100,
                ..CatalogPageRequest::default()
            })
            .is_err());
        assert!(catalog
            .page(CatalogPageRequest {
                limit: 201,
                ..CatalogPageRequest::default()
            })
            .is_err());

        let default_page = catalog.page(CatalogPageRequest::default()).unwrap();
        assert_eq!(default_page.nodes.len(), 100);
        let files = catalog
            .page(CatalogPageRequest {
                category_id: "file".to_owned(),
                query: "apk".to_owned(),
                limit: 200,
                ..CatalogPageRequest::default()
            })
            .unwrap();
        assert!(files
            .nodes
            .iter()
            .all(|node| node.kind == CatalogNodeKind::File));
    }

    #[test]
    fn test_catalog_reproduces_c_f_l_d_r_tree_and_keeps_credentials_private() {
        let sources = "1\n远程源\t/s/root\troot-secret\tchild\t分类 / 远程源\thttps://www.lanzouw.com/s/parent\n";
        let composites = concat!(
            "C\tlocal:test\t本地合集\t发布者\t\t合集简介\n",
            "D\tfolder\t\t分类\t\t\t\t0\t\t\t\n",
            "F\tfile\tfolder\t文件.apk\t/i-file\tmember-secret\t\t0\t\t1 M\t2026-07-15\n",
            "L\tsingle\t\t单软件目录\t/s/single\tsingle-secret\t\t0\t\t\t\n",
            "R\tremote\t\t远程目录\t/b-remote\tremote-secret\t\t1\t\t\t\n",
            "F\tfile\tfolder\t重复必须忽略.apk\t/i-other\twrong-secret\t\t0\t\t\t\n"
        );
        let catalog = Catalog::parse(sources.as_bytes(), &[0x55], composites.as_bytes()).unwrap();
        let root = catalog
            .page(CatalogPageRequest {
                limit: 10,
                ..CatalogPageRequest::default()
            })
            .unwrap();
        assert_eq!(root.total, 2);
        assert_eq!(root.nodes[0].kind, CatalogNodeKind::RemoteSource);
        assert_eq!(root.nodes[1].kind, CatalogNodeKind::Composite);
        assert!(root.nodes[1].has_children);

        let children = catalog
            .page(CatalogPageRequest {
                parent_id: root.nodes[1].id.clone(),
                limit: 10,
                ..CatalogPageRequest::default()
            })
            .unwrap();
        assert_eq!(children.total, 3);
        assert_eq!(children.nodes[0].kind, CatalogNodeKind::Folder);
        assert_eq!(children.nodes[1].kind, CatalogNodeKind::SingleSoftware);
        assert_eq!(children.nodes[2].kind, CatalogNodeKind::RemoteSource);
        assert!(children.nodes[0].has_children);

        let nested = catalog
            .page(CatalogPageRequest {
                parent_id: children.nodes[0].id.clone(),
                limit: 10,
                ..CatalogPageRequest::default()
            })
            .unwrap();
        assert_eq!(nested.total, 1, "duplicate member ids keep the first entry");
        assert_eq!(nested.nodes[0].kind, CatalogNodeKind::File);
        let file = &nested.nodes[0];
        let item = catalog.library_item(&file.id).unwrap();
        assert!(!item.is_folder);
        let single = catalog.library_item(&children.nodes[1].id).unwrap();
        assert!(
            !single.is_folder,
            "L is a single-software directory, not a folder row"
        );
        assert!(
            catalog
                .target(&children.nodes[1].id)
                .unwrap()
                .single_software
        );
        let remote = catalog.library_item(&children.nodes[2].id).unwrap();
        assert!(remote.is_folder);

        let source = catalog.target(&file.id).unwrap();
        assert_eq!(source.source_id, file.source_id);
        assert_eq!(source.password, "member-secret");
        let target_by_source_id = catalog.target(&file.source_id).unwrap();
        assert_eq!(
            target_by_source_id.share_url,
            "https://www.lanzouw.com/i-file"
        );
        assert_eq!(target_by_source_id.password, "member-secret");
        let global_plan = catalog.search_plan("文件", &[]).unwrap();
        assert_eq!(global_plan.sources.len(), 2);
        assert_eq!(global_plan.local_items.len(), 1);
        assert_eq!(global_plan.local_items[0].title, "文件.apk");
        let composite_plan = catalog
            .search_plan("单软件", &[root.nodes[1].id.clone()])
            .unwrap();
        assert_eq!(composite_plan.sources.len(), 1);
        assert_eq!(composite_plan.local_items.len(), 1);
        assert_eq!(composite_plan.local_items[0].title, "单软件目录");
        let handle = handle_registry::register(catalog.target(&file.id).unwrap()).unwrap();
        let item_ref: CatalogItemRef = serde_json::from_value(serde_json::json!({
            "sourceId": handle,
            "title": file.title,
            "url": "https://evil.example/client-controlled",
            "shareUrl": "https://evil.example/client-controlled",
            "folderId": "",
            "isFolder": false
        }))
        .unwrap();
        let target = catalog.target_for_ref(&item_ref).unwrap();
        assert_eq!(target.password, "member-secret");
        assert_eq!(target.share_url, "https://www.lanzouw.com/i-file");
        assert!(serde_json::from_value::<CatalogItemRef>(serde_json::json!({
            "sourceId": "item:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "title": file.title,
            "url": file.share_url,
            "shareUrl": file.share_url,
            "folderId": "",
            "isFolder": false,
            "password": "must-never-cross-flutter"
        }))
        .is_err());

        let json = serde_json::to_string(&root).unwrap()
            + &serde_json::to_string(&children).unwrap()
            + &serde_json::to_string(&nested).unwrap();
        for secret in [
            "root-secret",
            "member-secret",
            "single-secret",
            "remote-secret",
        ] {
            assert!(!json.contains(secret));
        }

        let scoped = catalog
            .search_plan("文件", std::slice::from_ref(&file.source_id))
            .unwrap();
        assert!(scoped.sources.is_empty());
        assert_eq!(scoped.local_items.len(), 1);
        assert_eq!(scoped.local_items[0].title, "文件.apk");

        let source_folder = catalog
            .local_source_folder(&file.source_id, 1)
            .unwrap()
            .expect("local search provenance opens its packaged source");
        assert_eq!(source_folder.title, "本地合集");
        assert_eq!(source_folder.items.len(), 3);
        assert!(!serde_json::to_string(&source_folder)
            .unwrap()
            .contains("member-secret"));
    }

    #[test]
    fn test_catalog_rejects_hint_drift_and_invalid_item_refs() {
        assert!(Catalog::parse(b"1\nsource\t/s/one\n", &[], b"").is_err());
        let catalog = Catalog::parse(
            b"1\nsource\t/s/one\n",
            &[0],
            b"C\tlocal:test\tcollection\tpublisher\n",
        )
        .unwrap();
        let source = catalog.page(CatalogPageRequest::default()).unwrap().nodes[0].clone();

        for value in [
            serde_json::json!({
                "sourceId": "unknown",
                "title": "source",
                "url": source.share_url,
                "shareUrl": source.share_url,
                "folderId": "",
                "isFolder": true
            }),
            serde_json::json!({
                "sourceId": source.source_id,
                "title": "source",
                "url": "https://evil.example/file",
                "shareUrl": "https://evil.example/file",
                "folderId": "",
                "isFolder": true
            }),
        ] {
            let item_ref: CatalogItemRef = serde_json::from_value(value).unwrap();
            assert!(catalog.target_for_ref(&item_ref).is_err());
        }
    }
}
