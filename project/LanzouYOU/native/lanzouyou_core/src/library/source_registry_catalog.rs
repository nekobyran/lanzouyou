use std::collections::{HashSet, VecDeque};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};

use crate::error::{CoreError, CoreResult};

use super::super::{
    catalog::{
        CatalogItemRef, CatalogNode, CatalogNodeKind, CatalogPage, CatalogPageRequest,
        CatalogSearchPlan, CatalogSummary, CatalogTarget,
    },
    handle_registry,
    model::{LibraryFolder, LibraryItem, LibrarySource, LibrarySourceKind},
};
use super::{SourceRegistry, StoredMember, StoredSource};

const DEFAULT_PAGE_LIMIT: usize = 100;
const MAX_PAGE_LIMIT: usize = 200;

impl SourceRegistry {
    pub(crate) fn merged_catalog_summary(&self) -> CoreResult<CatalogSummary> {
        let baseline = self.visible_baseline_tree()?;
        let overlay = self.overlay_nodes_recursive();
        let nodes = baseline.iter().chain(&overlay).collect::<Vec<_>>();
        Ok(CatalogSummary {
            revision: self.catalog_revision(),
            official_count: nodes
                .iter()
                .filter(|node| {
                    node.parent_id.is_empty() && node.kind == CatalogNodeKind::RemoteSource
                })
                .count(),
            composite_count: nodes
                .iter()
                .filter(|node| node.parent_id.is_empty() && node.kind == CatalogNodeKind::Composite)
                .count(),
            node_count: nodes.len(),
            searchable_count: nodes.iter().filter(|node| node.searchable).count(),
        })
    }

    pub(crate) fn merged_catalog_page(
        &self,
        request: CatalogPageRequest,
    ) -> CoreResult<CatalogPage> {
        let limit = match request.limit {
            0 => DEFAULT_PAGE_LIMIT,
            value if value <= MAX_PAGE_LIMIT => value,
            _ => return Err(CoreError::invalid("catalog page limit 不能超过 200")),
        };
        let parent_id = request.parent_id.trim();
        if parent_id.chars().count() > 256 || parent_id.chars().any(char::is_control) {
            return Err(CoreError::invalid("catalog parentId 格式无效"));
        }
        let query = request.query.trim().to_lowercase();
        if query.chars().count() > 256 || query.chars().any(char::is_control) {
            return Err(CoreError::invalid("catalog query 格式无效"));
        }

        let custom_category = self
            .overlay
            .categories
            .iter()
            .find(|category| category.id == request.category_id);
        let builtin_category = if custom_category.is_some() {
            "all"
        } else {
            request.category_id.as_str()
        };
        let mut nodes = self.collect_baseline_page(parent_id, builtin_category, &query)?;
        let overlay = self.overlay_nodes_recursive();
        if query.is_empty() {
            nodes.extend(
                overlay
                    .into_iter()
                    .filter(|node| node.parent_id == parent_id),
            );
        } else if parent_id.is_empty() {
            nodes.extend(overlay);
        } else {
            nodes.extend(overlay.into_iter().filter(|node| {
                node.parent_id == parent_id || node.id.starts_with(&format!("{parent_id}::"))
            }));
        }
        if let Some(category) = custom_category {
            let allowed = category.source_ids.iter().collect::<HashSet<_>>();
            nodes.retain(|node| allowed.contains(&node.source_id) || allowed.contains(&node.id));
        }
        if !query.is_empty() {
            nodes.retain(|node| fold_node(node).contains(&query));
        }
        nodes.sort_by(|left, right| {
            left.title
                .cmp(&right.title)
                .then_with(|| left.id.cmp(&right.id))
        });
        nodes.dedup_by(|left, right| left.id == right.id);

        if !parent_id.is_empty() && nodes.is_empty() && !self.node_exists(parent_id)? {
            return Err(CoreError::invalid("catalog parentId 不存在"));
        }
        let scope = catalog_cursor_scope(
            self.overlay.generation,
            parent_id,
            &request.category_id,
            &query,
        );
        let offset = if request.cursor.is_empty() {
            0
        } else {
            decode_catalog_cursor(&request.cursor, &scope)?
        };
        if offset > nodes.len() {
            return Err(CoreError::invalid("catalog cursor 已失效"));
        }
        let end = offset.saturating_add(limit).min(nodes.len());
        Ok(CatalogPage {
            revision: self.catalog_revision(),
            total: nodes.len(),
            next_cursor: if end < nodes.len() {
                encode_catalog_cursor(end, &scope)
            } else {
                String::new()
            },
            has_more: end < nodes.len(),
            nodes: nodes[offset..end].to_vec(),
        })
    }

    pub(crate) fn merged_search_plan(
        &self,
        query: &str,
        scope_ids: &[String],
    ) -> CoreResult<CatalogSearchPlan> {
        if scope_ids.len() > 4_096 {
            return Err(CoreError::invalid(
                "catalog search scopeIds 不能超过 4096 个",
            ));
        }
        let overlay_ids = self
            .overlay
            .sources
            .iter()
            .map(|source| source.id.as_str())
            .collect::<HashSet<_>>();
        let visible_roots = self.visible_baseline_roots();
        let baseline_ids = visible_roots
            .iter()
            .flat_map(|node| [node.id.as_str(), node.source_id.as_str()])
            .collect::<HashSet<_>>();
        let baseline_scopes = if scope_ids.is_empty() {
            visible_roots
                .iter()
                .map(|node| node.id.clone())
                .collect::<Vec<_>>()
        } else {
            scope_ids
                .iter()
                .filter(|id| baseline_ids.contains(id.as_str()))
                .cloned()
                .collect::<Vec<_>>()
        };
        let mut plan = if baseline_scopes.is_empty() {
            CatalogSearchPlan {
                sources: Vec::new(),
                local_items: Vec::new(),
            }
        } else {
            self.baseline.search_plan(query, &baseline_scopes)?
        };
        let selected_overlay = |source: &StoredSource| {
            scope_ids.is_empty()
                || scope_ids
                    .iter()
                    .any(|id| id == &source.id || id.starts_with(&format!("{}::", source.id)))
        };
        let folded_query = query.trim().to_lowercase();
        for source in self
            .overlay
            .sources
            .iter()
            .filter(|source| selected_overlay(source))
        {
            self.append_overlay_search(source, &folded_query, &mut plan)?;
        }
        if !scope_ids.is_empty()
            && baseline_scopes.is_empty()
            && !scope_ids.iter().any(|id| overlay_ids.contains(id.as_str()))
        {
            return Err(CoreError::invalid("catalog search scopeId 不存在"));
        }
        Ok(plan)
    }

    pub(crate) fn merged_catalog_target(
        &self,
        node_id: &str,
        item_ref: Option<&CatalogItemRef>,
    ) -> CoreResult<CatalogTarget> {
        if let Some(item_ref) = item_ref {
            return self.baseline.target_for_ref(item_ref);
        }
        if self.is_hidden_baseline(node_id) {
            return Err(CoreError::invalid("catalog nodeId 已隐藏"));
        }
        for source in &self.overlay.sources {
            if source.id == node_id {
                if source.kind == 1 {
                    return Err(CoreError::invalid("catalog 合集根节点不是远程目标"));
                }
                return Ok(CatalogTarget {
                    source_id: source.id.clone(),
                    title: source.title.clone(),
                    url: source.url.clone(),
                    share_url: source.url.clone(),
                    is_folder: source.kind == 0,
                    single_software: source.kind == 2,
                    password: source.password.clone(),
                });
            }
            if let Some(member) = source
                .members
                .iter()
                .find(|member| overlay_member_id(source, member) == node_id)
            {
                if member.kind == 3 {
                    return Err(CoreError::invalid("catalog 本地文件夹不是远程目标"));
                }
                return Ok(member_target(source, member));
            }
        }
        self.baseline.target(node_id)
    }

    pub(crate) fn merged_local_source_folder(
        &self,
        node_id: &str,
        page: u32,
    ) -> CoreResult<Option<LibraryFolder>> {
        if let Some(source) = self
            .overlay
            .sources
            .iter()
            .find(|source| source.id == node_id)
        {
            if source.kind != 1 {
                return Ok(None);
            }
            if page == 0 || page > 1_000 {
                return Err(CoreError::invalid("catalog browse page 必须为 1-1000"));
            }
            let files = source
                .members
                .iter()
                .filter(|member| member.kind != 3)
                .collect::<Vec<_>>();
            let start = (page as usize - 1).saturating_mul(50);
            let end = start.saturating_add(50).min(files.len());
            let mut items = Vec::new();
            if start < files.len() {
                for member in &files[start..end] {
                    let target = member_target(source, member);
                    let handle = handle_registry::register(target)?;
                    items.push(member_item(source, member, handle));
                }
            }
            return Ok(Some(LibraryFolder {
                source_id: source.id.clone(),
                kind: LibrarySourceKind::Directory,
                title: source.title.clone(),
                publisher: source.publisher.clone(),
                avatar_url: source.avatar.clone(),
                description: source.description.clone(),
                save_url: String::new(),
                url: String::new(),
                folder_id: source.id.clone(),
                page,
                has_more: end < files.len(),
                next_page_ready_at_ms: 0,
                remote_search: false,
                items,
                api_folder_count: 0,
            }));
        }
        if self.is_hidden_baseline(node_id) {
            return Err(CoreError::invalid("catalog nodeId 已隐藏"));
        }
        self.baseline.local_source_folder(node_id, page)
    }

    fn append_overlay_search(
        &self,
        source: &StoredSource,
        query: &str,
        plan: &mut CatalogSearchPlan,
    ) -> CoreResult<()> {
        if source.kind == 0 && source.searchable {
            plan.sources.push(LibrarySource {
                source_id: source.id.clone(),
                title: source.title.clone(),
                share_url: source.url.clone(),
                password: source.password.clone(),
            });
            return Ok(());
        }
        if source.kind == 2 && fold_source(source).contains(query) {
            let handle = handle_registry::register(CatalogTarget {
                source_id: source.id.clone(),
                title: source.title.clone(),
                url: source.url.clone(),
                share_url: source.url.clone(),
                is_folder: false,
                single_software: true,
                password: source.password.clone(),
            })?;
            plan.local_items.push(source_item(source, handle));
        }
        if source.kind == 1 {
            for member in &source.members {
                if member.kind == 3 {
                    continue;
                }
                if matches!(member.kind, 2 | 4) && member.searchable {
                    plan.sources.push(LibrarySource {
                        source_id: overlay_member_id(source, member),
                        title: member.title.clone(),
                        share_url: member.url.clone(),
                        password: member.password.clone(),
                    });
                } else if fold_member(member).contains(query) {
                    let handle = handle_registry::register(member_target(source, member))?;
                    plan.local_items.push(member_item(source, member, handle));
                }
            }
        }
        Ok(())
    }

    fn collect_baseline_page(
        &self,
        parent_id: &str,
        category_id: &str,
        query: &str,
    ) -> CoreResult<Vec<CatalogNode>> {
        let mut output = Vec::new();
        let mut cursor = String::new();
        loop {
            let page = self.baseline.page(CatalogPageRequest {
                parent_id: parent_id.to_owned(),
                category_id: category_id.to_owned(),
                query: query.to_owned(),
                cursor,
                limit: MAX_PAGE_LIMIT,
            })?;
            output.extend(
                page.nodes
                    .into_iter()
                    .filter(|node| !self.is_hidden_baseline_node(node)),
            );
            if !page.has_more {
                break;
            }
            cursor = page.next_cursor;
        }
        Ok(output)
    }

    fn visible_baseline_tree(&self) -> CoreResult<Vec<CatalogNode>> {
        let mut output = Vec::new();
        let mut parents = VecDeque::from([String::new()]);
        while let Some(parent) = parents.pop_front() {
            let nodes = self.collect_baseline_page(&parent, "all", "")?;
            for node in nodes {
                if node.has_children {
                    parents.push_back(node.id.clone());
                }
                output.push(node);
            }
        }
        Ok(output)
    }

    fn visible_baseline_roots(&self) -> Vec<CatalogNode> {
        self.baseline
            .registry_baseline_nodes()
            .into_iter()
            .filter(|node| !self.is_hidden_baseline_node(node))
            .collect()
    }

    fn overlay_nodes_recursive(&self) -> Vec<CatalogNode> {
        let mut nodes = Vec::new();
        for source in &self.overlay.sources {
            nodes.push(source_node(source));
            for member in &source.members {
                nodes.push(member_node(source, member));
            }
        }
        nodes
    }

    fn node_exists(&self, node_id: &str) -> CoreResult<bool> {
        if self
            .overlay_nodes_recursive()
            .iter()
            .any(|node| node.id == node_id)
        {
            return Ok(true);
        }
        Ok(self
            .visible_baseline_tree()?
            .iter()
            .any(|node| node.id == node_id))
    }

    fn is_hidden_baseline(&self, id: &str) -> bool {
        self.overlay
            .hidden_baseline_ids
            .iter()
            .any(|hidden| hidden == id)
    }

    fn is_hidden_baseline_node(&self, node: &CatalogNode) -> bool {
        self.overlay.hidden_baseline_ids.iter().any(|hidden| {
            hidden == &node.id || hidden == &node.source_id || hidden == &node.share_url
        })
    }

    fn catalog_revision(&self) -> String {
        format!(
            "registry:{}:{}",
            self.baseline.summary().revision,
            self.overlay.generation
        )
    }
}

fn source_node(source: &StoredSource) -> CatalogNode {
    CatalogNode {
        id: source.id.clone(),
        parent_id: String::new(),
        source_id: source.id.clone(),
        kind: match source.kind {
            1 => CatalogNodeKind::Composite,
            2 => CatalogNodeKind::SingleSoftware,
            _ => CatalogNodeKind::RemoteSource,
        },
        title: source.title.clone(),
        publisher: source.publisher.clone(),
        description: source.description.clone(),
        icon_url: source.avatar.clone(),
        size: String::new(),
        time: String::new(),
        searchable: source.searchable,
        child_directory: source.child_directory,
        origin_path: source.origin_path.clone(),
        origin_url: source.origin_url.clone(),
        has_children: source.kind == 1 && !source.members.is_empty(),
        error_code: source_error(source),
        share_url: source.url.clone(),
    }
}

fn member_node(source: &StoredSource, member: &StoredMember) -> CatalogNode {
    CatalogNode {
        id: overlay_member_id(source, member),
        parent_id: if member.parent_id.is_empty() {
            source.id.clone()
        } else {
            format!("{}::{}", source.id, member.parent_id)
        },
        source_id: source.id.clone(),
        kind: match member.kind {
            3 => CatalogNodeKind::Folder,
            2 | 4 => CatalogNodeKind::RemoteSource,
            _ => CatalogNodeKind::File,
        },
        title: member.title.clone(),
        publisher: source.publisher.clone(),
        description: member.description.clone(),
        icon_url: member.icon_url.clone(),
        size: member.size.clone(),
        time: member.time.clone(),
        searchable: member.searchable,
        child_directory: false,
        origin_path: String::new(),
        origin_url: String::new(),
        has_children: member.kind == 3,
        error_code: (!member.error.is_empty()).then(|| "source_unavailable".to_owned()),
        share_url: member.url.clone(),
    }
}

fn source_error(source: &StoredSource) -> Option<String> {
    (!source.error.is_empty()).then(|| "source_unavailable".to_owned())
}

fn overlay_member_id(source: &StoredSource, member: &StoredMember) -> String {
    format!("{}::{}", source.id, member.id)
}

fn member_target(source: &StoredSource, member: &StoredMember) -> CatalogTarget {
    CatalogTarget {
        source_id: overlay_member_id(source, member),
        title: member.title.clone(),
        url: member.url.clone(),
        share_url: member.url.clone(),
        is_folder: matches!(member.kind, 2 | 4),
        single_software: false,
        password: member.password.clone(),
    }
}

fn member_item(source: &StoredSource, member: &StoredMember, handle: String) -> LibraryItem {
    LibraryItem {
        source_id: handle,
        title: member.title.clone(),
        url: member.url.clone(),
        share_url: member.url.clone(),
        size: member.size.clone(),
        time: member.time.clone(),
        icon_url: member.icon_url.clone(),
        source: source.title.clone(),
        description: member.description.clone(),
        folder_id: member.parent_id.clone(),
        is_folder: matches!(member.kind, 2 | 4),
    }
}

fn source_item(source: &StoredSource, handle: String) -> LibraryItem {
    LibraryItem {
        source_id: handle,
        title: source.title.clone(),
        url: source.url.clone(),
        share_url: source.url.clone(),
        source: source.publisher.clone(),
        description: source.description.clone(),
        is_folder: false,
        ..LibraryItem::default()
    }
}

fn fold_node(node: &CatalogNode) -> String {
    format!(
        "{}\n{}\n{}\n{}",
        node.title, node.publisher, node.description, node.origin_path
    )
    .to_lowercase()
}
fn fold_source(source: &StoredSource) -> String {
    format!(
        "{}\n{}\n{}",
        source.title, source.publisher, source.description
    )
    .to_lowercase()
}
fn fold_member(member: &StoredMember) -> String {
    format!("{}\n{}", member.title, member.description).to_lowercase()
}

fn catalog_cursor_scope(generation: u64, parent: &str, category: &str, query: &str) -> String {
    format!("{generation}\0{parent}\0{category}\0{query}")
}
fn encode_catalog_cursor(offset: usize, scope: &str) -> String {
    let mut bytes = Vec::with_capacity(8 + scope.len());
    bytes.extend_from_slice(&(offset as u64).to_be_bytes());
    bytes.extend_from_slice(scope.as_bytes());
    URL_SAFE_NO_PAD.encode(bytes)
}
fn decode_catalog_cursor(value: &str, scope: &str) -> CoreResult<usize> {
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| CoreError::invalid("catalog cursor 无效"))?;
    if bytes.len() < 8 || bytes[8..] != *scope.as_bytes() {
        return Err(CoreError::invalid("catalog cursor 已失效"));
    }
    usize::try_from(u64::from_be_bytes(bytes[..8].try_into().expect("cursor")))
        .map_err(|_| CoreError::invalid("catalog cursor 超出范围"))
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;
    use crate::library::source_registry::SourceDraft;

    #[test]
    fn imported_source_is_visible_in_merged_catalog_and_delete_removes_it() {
        let root = tempdir().unwrap();
        let mut registry = SourceRegistry::open(root.path()).unwrap();
        registry
            .batch_import(
                0,
                vec![SourceDraft {
                    title: "OverlayUniqueCustom2026".to_owned(),
                    url: "https://www.lanzouw.com/custom-visible".to_owned(),
                    password: "code".to_owned(),
                    searchable: true,
                    category_id: String::new(),
                }],
            )
            .unwrap();
        let page = registry
            .merged_catalog_page(CatalogPageRequest {
                query: "OverlayUniqueCustom2026".to_owned(),
                ..CatalogPageRequest::default()
            })
            .unwrap();
        assert_eq!(page.nodes.len(), 1);
        assert_eq!(page.nodes[0].title, "OverlayUniqueCustom2026");
        let plan = registry.merged_search_plan("Custom", &[]).unwrap();
        assert!(plan
            .sources
            .iter()
            .any(|source| source.title == "OverlayUniqueCustom2026"));
        let id = registry.snapshot().user_sources[0].id.clone();
        registry.delete_sources(1, vec![id]).unwrap();
        let page = registry
            .merged_catalog_page(CatalogPageRequest {
                query: "OverlayUniqueCustom2026".to_owned(),
                ..CatalogPageRequest::default()
            })
            .unwrap();
        assert!(page.nodes.is_empty());
    }
}
