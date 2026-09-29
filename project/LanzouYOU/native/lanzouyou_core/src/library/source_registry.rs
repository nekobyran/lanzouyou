use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    net::{IpAddr, SocketAddr, ToSocketAddrs},
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use once_cell::sync::Lazy;
use rand::{rngs::OsRng, RngCore};
use reqwest::{
    blocking::Client,
    header::{ACCEPT, ACCEPT_ENCODING, CONTENT_LENGTH, CONTENT_TYPE, LOCATION, USER_AGENT},
    redirect::Policy,
    Url,
};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::error::{CoreError, CoreResult};

use super::{
    catalog::{builtin_catalog, Catalog, CatalogNodeKind},
    link_router::{tokenize_links, LinkKind},
    model::LibrarySource,
    url::{
        is_public_ip, normalize_public_share_url, reject_explicit_port_reference, SecurityPolicy,
    },
};

#[path = "source_registry_catalog.rs"]
mod catalog_overlay;

const SCHEMA_VERSION: u32 = 1;
const RULE_VERSION: u32 = 2;
const OVERLAY_FILE: &str = "source-registry-v1.json";
const OVERLAY_BACKUP_FILE: &str = "source-registry-v1.json.bak";
const MAX_OVERLAY_BYTES: u64 = 2 * 1024 * 1024;
const MAX_RULE_BYTES: u64 = 512 * 1024;
const MAX_USER_SOURCES: usize = 4_096;
const MAX_CATEGORIES: usize = 256;
const MAX_PAGE_LIMIT: usize = 200;
const MAX_IMPORT_TEXT_BYTES: usize = 256 * 1024;
const MAX_IMPORT_PREVIEWS: usize = 32;
const IMPORT_PREVIEW_TTL: Duration = Duration::from_secs(10 * 60);

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct OverlayDocument {
    pub(crate) schema_version: u32,
    pub(crate) generation: u64,
    pub(crate) sources: Vec<StoredSource>,
    pub(crate) categories: Vec<StoredCategory>,
    pub(crate) hidden_baseline_ids: Vec<String>,
    pub(crate) retests: Vec<StoredRetest>,
}

impl OverlayDocument {
    fn empty(generation: u64) -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            generation,
            sources: Vec::new(),
            categories: Vec::new(),
            hidden_baseline_ids: Vec::new(),
            retests: Vec::new(),
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct StoredSource {
    pub(crate) v: u32,
    pub(crate) id: String,
    pub(crate) kind: u8,
    pub(crate) title: String,
    pub(crate) url: String,
    pub(crate) password: String,
    pub(crate) searchable: bool,
    pub(crate) error: String,
    pub(crate) publisher: String,
    pub(crate) avatar: String,
    pub(crate) description: String,
    #[serde(rename = "childDirectory")]
    pub(crate) child_directory: bool,
    #[serde(rename = "originPath")]
    pub(crate) origin_path: String,
    #[serde(rename = "originUrl")]
    pub(crate) origin_url: String,
    pub(crate) overlay: bool,
    #[serde(rename = "metadataOverride")]
    pub(crate) metadata_override: bool,
    pub(crate) members: Vec<StoredMember>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct StoredMember {
    pub(crate) kind: u8,
    pub(crate) id: String,
    #[serde(rename = "parent")]
    pub(crate) parent_id: String,
    pub(crate) url: String,
    pub(crate) password: String,
    #[serde(rename = "icon")]
    pub(crate) icon_url: String,
    pub(crate) error: String,
    pub(crate) searchable: bool,
    pub(crate) lightweight: bool,
    #[serde(default)]
    pub(crate) title: String,
    #[serde(default)]
    pub(crate) size: String,
    #[serde(default)]
    pub(crate) time: String,
    #[serde(default)]
    pub(crate) description: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StoredCategory {
    pub(crate) id: String,
    pub(crate) title: String,
    pub(crate) source_ids: Vec<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StoredRetest {
    pub(crate) source_id: String,
    pub(crate) status: RetestStatus,
    pub(crate) error_code: String,
    pub(crate) tested_at_ms: u64,
}

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum RetestStatus {
    Pending,
    Passed,
    Failed,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct RuleDocument {
    version: u32,
    sources: Vec<StoredSource>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceDraft {
    pub title: String,
    pub url: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub searchable: bool,
    #[serde(default)]
    pub category_id: String,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceUpdateDraft {
    pub source_id: String,
    pub title: String,
    pub searchable: bool,
    #[serde(default)]
    pub access_code: Option<String>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CategoryDraft {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub source_ids: Vec<String>,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompositeMemberKind {
    File,
    Directory,
    Folder,
    RemoteFolder,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CompositeMemberDraft {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub parent_id: String,
    pub kind: CompositeMemberKind,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub searchable: bool,
    #[serde(default)]
    pub icon_url: String,
    #[serde(default)]
    pub size: String,
    #[serde(default)]
    pub time: String,
    #[serde(default)]
    pub description: String,
}

impl CompositeMemberDraft {
    #[cfg(test)]
    fn file(url: &str) -> Self {
        Self {
            id: String::new(),
            parent_id: String::new(),
            kind: CompositeMemberKind::File,
            title: String::new(),
            url: url.to_owned(),
            password: String::new(),
            searchable: false,
            icon_url: String::new(),
            size: String::new(),
            time: String::new(),
            description: String::new(),
        }
    }
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CompositeDraft {
    #[serde(default)]
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub publisher: String,
    #[serde(default)]
    pub avatar_url: String,
    #[serde(default)]
    pub description: String,
    pub members: Vec<CompositeMemberDraft>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RegistryPageRequest {
    #[serde(default)]
    pub(crate) cursor: String,
    #[serde(default)]
    pub(crate) limit: usize,
    #[serde(default)]
    pub(crate) query: String,
    #[serde(default = "all_category")]
    pub(crate) category_id: String,
    #[serde(default = "all_category")]
    pub(crate) kind: String,
    #[serde(default)]
    pub(crate) searchable: Option<bool>,
    #[serde(default)]
    pub(crate) child_directory: Option<bool>,
    #[serde(default)]
    pub(crate) built_in: Option<bool>,
}

fn all_category() -> String {
    "all".to_owned()
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RegistrySourceView {
    pub(crate) id: String,
    pub(crate) kind: RegistrySourceKind,
    pub(crate) title: String,
    pub(crate) publisher: String,
    pub(crate) description: String,
    pub(crate) avatar_url: String,
    pub(crate) share_url: String,
    pub(crate) searchable: bool,
    pub(crate) child_directory: bool,
    pub(crate) origin_path: String,
    pub(crate) origin_url: String,
    pub(crate) member_count: usize,
    pub(crate) built_in: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) error_code: Option<String>,
}

#[derive(Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum RegistrySourceKind {
    Official,
    Composite,
    SingleSoftware,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RegistryCategoryView {
    pub(crate) id: String,
    pub(crate) title: String,
    pub(crate) source_ids: Vec<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RegistrySnapshot {
    pub(crate) generation: u64,
    pub(crate) baseline_revision: String,
    pub(crate) baseline_count: usize,
    pub(crate) user_count: usize,
    pub(crate) merged_count: usize,
    pub(crate) categories: Vec<RegistryCategoryView>,
    pub(crate) user_sources: Vec<RegistrySourceView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RegistryPage {
    pub(crate) generation: u64,
    pub(crate) total: usize,
    pub(crate) next_cursor: String,
    pub(crate) has_more: bool,
    pub(crate) sources: Vec<RegistrySourceView>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MutationResult {
    pub(crate) generation: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportResult {
    pub(crate) generation: u64,
    pub(crate) added: usize,
    pub(crate) duplicates: usize,
    pub(crate) invalid: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TextImportResult {
    pub(crate) generation: u64,
    pub(crate) added: usize,
    pub(crate) duplicates: usize,
    pub(crate) invalid: usize,
    pub(crate) lines: Vec<TextImportLineResult>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TextImportLineResult {
    pub(crate) line: usize,
    pub(crate) source_id: String,
    pub(crate) state: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) error_code: Option<&'static str>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DeleteSourcesResult {
    pub(crate) generation: u64,
    pub(crate) removed: usize,
    pub(crate) hidden: usize,
    pub(crate) missing: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportPreviewValid {
    pub(crate) line: usize,
    pub(crate) title: String,
    pub(crate) share_url: String,
    pub(crate) requires_code: bool,
    pub(crate) category_id: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportPreviewDuplicate {
    pub(crate) line: usize,
    pub(crate) share_url: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportPreviewInvalid {
    pub(crate) line: usize,
    pub(crate) code: String,
    pub(crate) message: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ImportPreview {
    pub(crate) generation: u64,
    pub(crate) preview_id: String,
    pub(crate) valid: Vec<ImportPreviewValid>,
    pub(crate) duplicates: Vec<ImportPreviewDuplicate>,
    pub(crate) invalid: Vec<ImportPreviewInvalid>,
}

struct PendingImportPreview {
    generation: u64,
    created_at: Instant,
    drafts: Vec<SourceDraft>,
    duplicate_count: usize,
    invalid_count: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CompositeMutationResult {
    pub(crate) generation: u64,
    pub(crate) source_id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ExportResult {
    pub(crate) generation: u64,
    pub(crate) count: usize,
    pub(crate) bytes_written: usize,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RetestResult {
    pub(crate) source_id: String,
    pub(crate) passed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) error_code: Option<String>,
}

pub(crate) struct RetestPlan {
    pub(crate) generation: u64,
    pub(crate) units: Vec<RetestUnit>,
}

pub(crate) struct RetestUnit {
    pub(crate) owner_id: String,
    pub(crate) source: LibrarySource,
}

pub(crate) struct SourceRegistry {
    pub(crate) root: PathBuf,
    pub(crate) overlay: OverlayDocument,
    pub(crate) baseline: &'static Catalog,
    pending_imports: HashMap<String, PendingImportPreview>,
    pending_import_order: VecDeque<String>,
}

impl std::fmt::Debug for SourceRegistry {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SourceRegistry")
            .field("root", &self.root)
            .field("generation", &self.overlay.generation)
            .field("source_count", &self.overlay.sources.len())
            .finish()
    }
}

impl SourceRegistry {
    pub(crate) fn open(root: impl AsRef<Path>) -> CoreResult<Self> {
        let requested = validate_absolute_path(root.as_ref(), "storageRoot")?;
        fs::create_dir_all(&requested).map_err(CoreError::io)?;
        let root = fs::canonicalize(&requested).map_err(CoreError::io)?;
        let path = root.join(OVERLAY_FILE);
        let overlay = if path.exists() {
            read_overlay(&path)?
        } else {
            OverlayDocument::empty(0)
        };
        validate_overlay(&overlay)?;
        Ok(Self {
            root,
            overlay,
            baseline: builtin_catalog()?,
            pending_imports: HashMap::new(),
            pending_import_order: VecDeque::new(),
        })
    }

    pub(crate) fn snapshot(&self) -> RegistrySnapshot {
        let baseline_nodes = self.visible_baseline_nodes();
        let user_sources = self
            .overlay
            .sources
            .iter()
            .map(|source| self.source_view(source))
            .collect::<Vec<_>>();
        RegistrySnapshot {
            generation: self.overlay.generation,
            baseline_revision: self.baseline.summary().revision,
            baseline_count: self.baseline.registry_baseline_nodes().len(),
            user_count: user_sources.len(),
            merged_count: baseline_nodes.len() + user_sources.len(),
            categories: self
                .overlay
                .categories
                .iter()
                .map(|category| RegistryCategoryView {
                    id: category.id.clone(),
                    title: category.title.clone(),
                    source_ids: category.source_ids.clone(),
                })
                .collect(),
            user_sources,
        }
    }

    pub(crate) fn page(&self, request: RegistryPageRequest) -> CoreResult<RegistryPage> {
        let limit = match request.limit {
            0 => 100,
            value if value <= MAX_PAGE_LIMIT => value,
            _ => return Err(CoreError::invalid("SourceRegistry page limit 不能超过 200")),
        };
        let query = clean_query(&request.query)?;
        let allowed = self.category_source_ids(&request.category_id)?;
        let kind = parse_registry_kind(&request.kind)?;
        let mut sources = self
            .visible_baseline_nodes()
            .into_iter()
            .map(|node| self.baseline_source_view(&node))
            .chain(
                self.overlay
                    .sources
                    .iter()
                    .map(|source| self.source_view(source)),
            )
            .filter(|source| {
                allowed.as_ref().is_none_or(|ids| ids.contains(&source.id))
                    && kind.is_none_or(|kind| source.kind == kind)
                    && request
                        .searchable
                        .is_none_or(|searchable| source.searchable == searchable)
                    && request
                        .child_directory
                        .is_none_or(|child| source.child_directory == child)
                    && request
                        .built_in
                        .is_none_or(|built_in| source.built_in == built_in)
                    && (query.is_empty() || fold_view(source).contains(&query))
            })
            .collect::<Vec<_>>();
        sources.sort_by(|left, right| {
            left.built_in
                .cmp(&right.built_in)
                .reverse()
                .then_with(|| left.title.cmp(&right.title))
                .then_with(|| left.id.cmp(&right.id))
        });
        let scope = page_scope(
            self.overlay.generation,
            &request.category_id,
            &query,
            &request.kind,
            request.searchable,
            request.child_directory,
            request.built_in,
        );
        let offset = if request.cursor.is_empty() {
            0
        } else {
            decode_cursor(&request.cursor, &scope)?
        };
        if offset > sources.len() {
            return Err(CoreError::invalid("SourceRegistry cursor 已失效"));
        }
        let end = offset.saturating_add(limit).min(sources.len());
        Ok(RegistryPage {
            generation: self.overlay.generation,
            total: sources.len(),
            next_cursor: if end < sources.len() {
                encode_cursor(end, &scope)
            } else {
                String::new()
            },
            has_more: end < sources.len(),
            sources: sources.drain(offset..end).collect(),
        })
    }

    pub(crate) fn preview_import_text(
        &mut self,
        expected_generation: u64,
        raw_text: &str,
        category_id: &str,
    ) -> CoreResult<ImportPreview> {
        self.ensure_generation(expected_generation)?;
        self.prune_pending_imports();
        if raw_text.len() > MAX_IMPORT_TEXT_BYTES {
            return Err(CoreError::invalid("来源导入文本不能超过 256 KiB"));
        }
        let category_id = category_id.trim().to_owned();
        if !category_id.is_empty()
            && !self
                .overlay
                .categories
                .iter()
                .any(|category| category.id == category_id)
        {
            return Err(CoreError::invalid("SourceRegistry 分类不存在"));
        }

        let non_empty_lines = raw_text
            .lines()
            .filter(|line| !line.trim().is_empty())
            .count();
        if non_empty_lines > MAX_USER_SOURCES {
            return Err(CoreError::invalid("SourceRegistry 批量来源超过 4096 条"));
        }
        let mut known = self.known_content_keys();
        let mut drafts = Vec::with_capacity(non_empty_lines);
        let mut valid = Vec::with_capacity(non_empty_lines);
        let mut duplicates = Vec::new();
        let mut invalid = Vec::new();

        for (index, line) in raw_text.lines().enumerate() {
            let line_number = index + 1;
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let parsed = parse_plain_source_line(line, &category_id);
            let draft = match parsed {
                Ok(draft) => draft,
                Err(error) => {
                    invalid.push(ImportPreviewInvalid {
                        line: line_number,
                        code: error.code.to_owned(),
                        message: error.message,
                    });
                    continue;
                }
            };
            let (stored, _) = stored_source_from_draft(draft.clone())?;
            let key = source_content_key(&stored);
            if !known.insert(key) {
                duplicates.push(ImportPreviewDuplicate {
                    line: line_number,
                    share_url: stored.url,
                });
                continue;
            }
            valid.push(ImportPreviewValid {
                line: line_number,
                title: stored.title.clone(),
                share_url: stored.url,
                requires_code: !stored.password.is_empty(),
                category_id: category_id.clone(),
            });
            drafts.push(draft);
        }

        let preview_id = random_preview_id();
        while self.pending_import_order.len() >= MAX_IMPORT_PREVIEWS {
            if let Some(expired) = self.pending_import_order.pop_front() {
                self.pending_imports.remove(&expired);
            }
        }
        self.pending_import_order.push_back(preview_id.clone());
        self.pending_imports.insert(
            preview_id.clone(),
            PendingImportPreview {
                generation: self.overlay.generation,
                created_at: Instant::now(),
                drafts,
                duplicate_count: duplicates.len(),
                invalid_count: invalid.len(),
            },
        );
        Ok(ImportPreview {
            generation: self.overlay.generation,
            preview_id,
            valid,
            duplicates,
            invalid,
        })
    }

    pub(crate) fn commit_import_preview(
        &mut self,
        expected_generation: u64,
        preview_id: &str,
    ) -> CoreResult<ImportResult> {
        self.ensure_generation(expected_generation)?;
        self.prune_pending_imports();
        let pending = self
            .pending_imports
            .get(preview_id)
            .ok_or_else(|| CoreError::new("preview_not_found", "来源导入预览已失效", false))?;
        if pending.generation != expected_generation {
            return Err(CoreError::new(
                "generation_conflict",
                "来源列表已被其他操作更新，请重新预览",
                true,
            ));
        }
        let drafts = pending.drafts.clone();
        let preview_duplicates = pending.duplicate_count;
        let preview_invalid = pending.invalid_count;
        let mut result = self.batch_import(expected_generation, drafts)?;
        result.duplicates = result.duplicates.saturating_add(preview_duplicates);
        result.invalid = result.invalid.saturating_add(preview_invalid);
        self.pending_imports.remove(preview_id);
        self.pending_import_order.retain(|id| id != preview_id);
        Ok(result)
    }

    pub(crate) fn batch_import(
        &mut self,
        expected_generation: u64,
        drafts: Vec<SourceDraft>,
    ) -> CoreResult<ImportResult> {
        self.ensure_generation(expected_generation)?;
        if drafts.len() > MAX_USER_SOURCES {
            return Err(CoreError::invalid("SourceRegistry 批量来源超过 4096 条"));
        }
        let mut next = self.overlay.clone();
        let mut known = self.known_content_keys();
        let mut added = 0;
        let mut duplicates = 0;
        let mut invalid = 0;
        for draft in drafts {
            match stored_source_from_draft(draft) {
                Ok((source, category_id)) => {
                    let key = source_content_key(&source);
                    if !known.insert(key) {
                        duplicates += 1;
                        continue;
                    }
                    if next.sources.len() >= MAX_USER_SOURCES {
                        invalid += 1;
                        continue;
                    }
                    if !category_id.is_empty()
                        && !next
                            .categories
                            .iter()
                            .any(|category| category.id == category_id)
                    {
                        known.remove(&source_content_key(&source));
                        invalid += 1;
                        continue;
                    }
                    let id = source.id.clone();
                    next.sources.push(source);
                    next.retests.retain(|status| status.source_id != id);
                    next.retests.push(pending_retest(id.clone()));
                    if !category_id.is_empty() {
                        if let Some(category) = next
                            .categories
                            .iter_mut()
                            .find(|category| category.id == category_id)
                        {
                            if !category.source_ids.contains(&id) {
                                category.source_ids.push(id);
                            }
                        }
                    }
                    added += 1;
                }
                Err(_) => invalid += 1,
            }
        }
        if added > 0 {
            next.generation = next.generation.saturating_add(1);
            self.commit(next)?;
        }
        Ok(ImportResult {
            generation: self.overlay.generation,
            added,
            duplicates,
            invalid,
        })
    }

    pub(crate) fn batch_import_text(
        &mut self,
        expected_generation: u64,
        raw_text: &str,
        category_id: &str,
    ) -> CoreResult<TextImportResult> {
        self.ensure_generation(expected_generation)?;
        if raw_text.len() > MAX_RULE_BYTES as usize || raw_text.contains('\0') {
            return Err(CoreError::invalid(
                "SourceRegistry 批量文本超过 512 KiB 或格式无效",
            ));
        }
        if !category_id.is_empty() {
            validate_identifier(category_id, "categoryId")?;
            if !self
                .overlay
                .categories
                .iter()
                .any(|category| category.id == category_id)
            {
                return Err(CoreError::invalid("SourceRegistry 分类不存在"));
            }
        }
        let non_empty_lines = raw_text
            .lines()
            .filter(|line| !line.trim().is_empty())
            .count();
        if non_empty_lines > MAX_USER_SOURCES {
            return Err(CoreError::invalid("SourceRegistry 批量文本超过 4096 行"));
        }

        let mut next = self.overlay.clone();
        let mut known = self.known_content_keys();
        let mut lines = Vec::with_capacity(non_empty_lines);
        let mut added = 0;
        let mut duplicates = 0;
        let mut invalid = 0;
        for (index, raw_line) in raw_text.lines().enumerate() {
            let line_number = index + 1;
            let trimmed = raw_line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let parsed = parse_source_text_line(trimmed, line_number);
            let source = match parsed {
                Ok(source) => source,
                Err(_) => {
                    invalid += 1;
                    lines.push(TextImportLineResult {
                        line: line_number,
                        source_id: String::new(),
                        state: "invalid",
                        error_code: Some("invalid_source_line"),
                    });
                    continue;
                }
            };
            let source_id = source.id.clone();
            let key = source_content_key(&source);
            if !known.insert(key) || next.sources.iter().any(|old| old.id == source_id) {
                duplicates += 1;
                lines.push(TextImportLineResult {
                    line: line_number,
                    source_id,
                    state: "duplicate",
                    error_code: None,
                });
                continue;
            }
            if next.sources.len() >= MAX_USER_SOURCES {
                invalid += 1;
                lines.push(TextImportLineResult {
                    line: line_number,
                    source_id,
                    state: "invalid",
                    error_code: Some("source_limit_reached"),
                });
                continue;
            }
            next.sources.push(source);
            next.retests.retain(|status| status.source_id != source_id);
            next.retests.push(pending_retest(source_id.clone()));
            if !category_id.is_empty() {
                let category = next
                    .categories
                    .iter_mut()
                    .find(|category| category.id == category_id)
                    .expect("category validated above");
                if !category.source_ids.contains(&source_id) {
                    category.source_ids.push(source_id.clone());
                }
            }
            added += 1;
            lines.push(TextImportLineResult {
                line: line_number,
                source_id,
                state: "added",
                error_code: Some("not_tested"),
            });
        }
        if added > 0 {
            next.generation = next.generation.saturating_add(1);
            self.commit(next)?;
        }
        Ok(TextImportResult {
            generation: self.overlay.generation,
            added,
            duplicates,
            invalid,
            lines,
        })
    }

    pub(crate) fn update_source(
        &mut self,
        expected_generation: u64,
        draft: SourceUpdateDraft,
    ) -> CoreResult<MutationResult> {
        self.ensure_generation(expected_generation)?;
        validate_text(&draft.source_id, 512, false, "来源身份")?;
        validate_text(&draft.title, 160, false, "来源标题")?;
        if let Some(access_code) = &draft.access_code {
            validate_text(access_code, 64, true, "来源访问码")?;
        }
        let mut next = self.overlay.clone();
        let source = next
            .sources
            .iter_mut()
            .find(|source| source.id == draft.source_id)
            .ok_or_else(|| CoreError::invalid("SourceRegistry 只能更新用户来源"))?;
        if source.kind == 1
            && draft
                .access_code
                .as_deref()
                .is_some_and(|code| !code.is_empty())
        {
            return Err(CoreError::invalid("自建合集不能设置来源访问码"));
        }
        source.title = draft.title.trim().to_owned();
        source.searchable = draft.searchable;
        if let Some(access_code) = draft.access_code {
            if source.password != access_code {
                source.password = access_code;
                next.retests
                    .retain(|status| status.source_id != draft.source_id);
                next.retests.push(pending_retest(draft.source_id));
            }
        }
        next.generation = next.generation.saturating_add(1);
        self.commit(next)?;
        Ok(self.mutation())
    }

    pub(crate) fn delete_sources(
        &mut self,
        expected_generation: u64,
        source_ids: Vec<String>,
    ) -> CoreResult<DeleteSourcesResult> {
        self.ensure_generation(expected_generation)?;
        if source_ids.is_empty() || source_ids.len() > 256 {
            return Err(CoreError::invalid(
                "SourceRegistry 删除来源数量必须为 1-256",
            ));
        }
        let mut requested = HashSet::new();
        for source_id in source_ids {
            validate_text(&source_id, 512, false, "来源身份")?;
            requested.insert(source_id);
        }
        let mut next = self.overlay.clone();
        let before = next.sources.len();
        next.sources
            .retain(|source| !requested.contains(&source.id));
        let removed = before - next.sources.len();
        let removed_ids = self
            .overlay
            .sources
            .iter()
            .filter(|source| requested.contains(&source.id))
            .map(|source| source.id.clone())
            .collect::<HashSet<_>>();
        let mut hidden = 0;
        let mut matched = removed_ids.clone();
        for node in self.baseline.registry_baseline_nodes() {
            if requested.contains(&node.id)
                || requested.contains(&node.source_id)
                || requested.contains(&node.share_url)
            {
                if !next.hidden_baseline_ids.contains(&node.id) {
                    next.hidden_baseline_ids.push(node.id.clone());
                    hidden += 1;
                }
                matched.extend([node.id, node.source_id, node.share_url]);
            }
        }
        // A built-in node can be addressed by node id, source id or share URL.
        // Remove every alias from dependent state after hiding it, otherwise a
        // category can retain an invisible member when deletion used another
        // valid alias for the same node.
        for category in &mut next.categories {
            category.source_ids.retain(|id| !matched.contains(id));
        }
        next.retests
            .retain(|status| !matched.contains(&status.source_id));
        let missing = requested
            .iter()
            .filter(|source_id| !matched.contains(*source_id))
            .count();
        if removed + hidden > 0 {
            next.generation = next.generation.saturating_add(1);
            self.commit(next)?;
        }
        Ok(DeleteSourcesResult {
            generation: self.overlay.generation,
            removed,
            hidden,
            missing,
        })
    }

    pub(crate) fn set_category_members(
        &mut self,
        expected_generation: u64,
        category_id: &str,
        source_ids: Vec<String>,
    ) -> CoreResult<MutationResult> {
        self.ensure_generation(expected_generation)?;
        validate_identifier(category_id, "categoryId")?;
        if source_ids.len() > MAX_USER_SOURCES {
            return Err(CoreError::invalid("分类来源不能超过 4096 个"));
        }
        let known = self.all_source_ids();
        let mut unique = Vec::with_capacity(source_ids.len());
        let mut seen = HashSet::new();
        for source_id in source_ids {
            validate_text(&source_id, 512, false, "分类来源身份")?;
            if !known.contains(&source_id) {
                return Err(CoreError::invalid("分类包含不存在的来源"));
            }
            if seen.insert(source_id.clone()) {
                unique.push(source_id);
            }
        }
        let mut next = self.overlay.clone();
        let category = next
            .categories
            .iter_mut()
            .find(|category| category.id == category_id)
            .ok_or_else(|| CoreError::invalid("SourceRegistry 分类不存在"))?;
        category.source_ids = unique;
        next.generation = next.generation.saturating_add(1);
        self.commit(next)?;
        Ok(self.mutation())
    }

    pub(crate) fn upsert_category(
        &mut self,
        expected_generation: u64,
        draft: CategoryDraft,
    ) -> CoreResult<MutationResult> {
        self.ensure_generation(expected_generation)?;
        let category = validate_category_draft(draft, &self.all_source_ids())?;
        let mut next = self.overlay.clone();
        if let Some(existing) = next
            .categories
            .iter_mut()
            .find(|existing| existing.id == category.id)
        {
            *existing = category;
        } else {
            if next.categories.len() >= MAX_CATEGORIES {
                return Err(CoreError::invalid("SourceRegistry 分类不能超过 256 个"));
            }
            next.categories.push(category);
        }
        next.generation = next.generation.saturating_add(1);
        self.commit(next)?;
        Ok(self.mutation())
    }

    pub(crate) fn delete_category(
        &mut self,
        expected_generation: u64,
        category_id: &str,
    ) -> CoreResult<MutationResult> {
        self.ensure_generation(expected_generation)?;
        validate_identifier(category_id, "categoryId")?;
        let mut next = self.overlay.clone();
        let before = next.categories.len();
        next.categories
            .retain(|category| category.id != category_id);
        if next.categories.len() == before {
            return Err(CoreError::invalid("SourceRegistry 分类不存在"));
        }
        next.generation = next.generation.saturating_add(1);
        self.commit(next)?;
        Ok(self.mutation())
    }

    pub(crate) fn upsert_composite(
        &mut self,
        expected_generation: u64,
        draft: CompositeDraft,
    ) -> CoreResult<CompositeMutationResult> {
        self.ensure_generation(expected_generation)?;
        let source = stored_composite_from_draft(draft)?;
        let source_id = source.id.clone();
        let mut next = self.overlay.clone();
        if let Some(existing) = next
            .sources
            .iter_mut()
            .find(|existing| existing.id == source_id)
        {
            if existing.kind != 1 {
                return Err(CoreError::invalid("SourceRegistry sourceId 不是自建合集"));
            }
            *existing = source;
        } else {
            if next.sources.len() >= MAX_USER_SOURCES {
                return Err(CoreError::invalid(
                    "SourceRegistry 用户来源不能超过 4096 个",
                ));
            }
            next.sources.push(source);
        }
        next.retests.retain(|status| status.source_id != source_id);
        next.retests.push(pending_retest(source_id.clone()));
        next.generation = next.generation.saturating_add(1);
        self.commit(next)?;
        Ok(CompositeMutationResult {
            generation: self.overlay.generation,
            source_id,
        })
    }

    pub(crate) fn delete_composite(
        &mut self,
        expected_generation: u64,
        source_id: &str,
    ) -> CoreResult<MutationResult> {
        self.ensure_generation(expected_generation)?;
        validate_local_id(source_id)?;
        let mut next = self.overlay.clone();
        let index = next
            .sources
            .iter()
            .position(|source| source.id == source_id && source.kind == 1)
            .ok_or_else(|| CoreError::invalid("SourceRegistry 自建合集不存在"))?;
        next.sources.remove(index);
        for category in &mut next.categories {
            category.source_ids.retain(|id| id != source_id);
        }
        next.retests.retain(|status| status.source_id != source_id);
        next.generation = next.generation.saturating_add(1);
        self.commit(next)?;
        Ok(self.mutation())
    }

    pub(crate) fn export_rules(
        &self,
        expected_generation: u64,
        destination: impl AsRef<Path>,
        source_ids: &[String],
        include_credentials: bool,
        credential_confirmation: &str,
    ) -> CoreResult<ExportResult> {
        self.ensure_generation(expected_generation)?;
        if include_credentials && credential_confirmation != "export-source-access-codes" {
            return Err(CoreError::new(
                "credential_export_confirmation_required",
                "导出来源访问码需要再次明确确认",
                false,
            ));
        }
        let destination = validate_absolute_path(destination.as_ref(), "destinationPath")?;
        let selected = source_ids
            .iter()
            .map(String::as_str)
            .collect::<HashSet<_>>();
        let mut sources = self
            .overlay
            .sources
            .iter()
            .filter(|source| selected.is_empty() || selected.contains(source.id.as_str()))
            .cloned()
            .collect::<Vec<_>>();
        if !selected.is_empty() && sources.len() != selected.len() {
            return Err(CoreError::invalid(
                "SourceRegistry 导出 sourceIds 包含不存在项目",
            ));
        }
        if !include_credentials {
            for source in &mut sources {
                source.password.clear();
                for member in &mut source.members {
                    member.password.clear();
                }
            }
        }
        let count = sources.len();
        let mut bytes = serde_json::to_vec_pretty(&RuleDocument {
            version: RULE_VERSION,
            sources,
        })
        .map_err(|_| CoreError::new("internal_error", "来源规则序列化失败", false))?;
        bytes.push(b'\n');
        if bytes.len() as u64 > MAX_RULE_BYTES {
            return Err(CoreError::invalid("来源规则文件不能超过 512 KiB"));
        }
        atomic_write(&destination, &bytes, false)?;
        Ok(ExportResult {
            generation: self.overlay.generation,
            count,
            bytes_written: bytes.len(),
        })
    }

    pub(crate) fn import_rules(
        &mut self,
        expected_generation: u64,
        source_path: impl AsRef<Path>,
    ) -> CoreResult<ImportResult> {
        self.ensure_generation(expected_generation)?;
        let source_path = validate_absolute_path(source_path.as_ref(), "sourcePath")?;
        let bytes = read_bounded(&source_path, MAX_RULE_BYTES)?;
        self.import_rules_bytes(expected_generation, &bytes)
    }

    pub(crate) fn import_rules_bytes(
        &mut self,
        expected_generation: u64,
        bytes: &[u8],
    ) -> CoreResult<ImportResult> {
        self.ensure_generation(expected_generation)?;
        let document: RuleDocument = serde_json::from_slice(&bytes)
            .map_err(|_| CoreError::parse("仅支持严格的 v2 来源规则"))?;
        if document.version != RULE_VERSION {
            return Err(CoreError::parse("仅支持严格的 v2 来源规则"));
        }
        if document.sources.len() > MAX_USER_SOURCES {
            return Err(CoreError::invalid("来源规则不能超过 4096 个来源"));
        }
        let mut next = self.overlay.clone();
        let mut known = self.known_content_keys();
        let mut added = 0;
        let mut duplicates = 0;
        let mut invalid = 0;
        for mut source in document.sources {
            if validate_stored_source(&mut source).is_err() {
                invalid += 1;
                continue;
            }
            let key = source_content_key(&source);
            if !known.insert(key) || next.sources.iter().any(|old| old.id == source.id) {
                duplicates += 1;
                continue;
            }
            let source_id = source.id.clone();
            next.sources.push(source);
            next.retests.retain(|status| status.source_id != source_id);
            next.retests.push(pending_retest(source_id));
            added += 1;
        }
        if added > 0 {
            next.generation = next.generation.saturating_add(1);
            self.commit(next)?;
        }
        Ok(ImportResult {
            generation: self.overlay.generation,
            added,
            duplicates,
            invalid,
        })
    }

    pub(crate) fn restore_backup(
        &mut self,
        expected_generation: u64,
    ) -> CoreResult<MutationResult> {
        self.ensure_generation(expected_generation)?;
        let mut restored = read_overlay(&self.root.join(OVERLAY_BACKUP_FILE))?;
        restored.generation = self.overlay.generation.saturating_add(1);
        validate_overlay(&restored)?;
        self.commit(restored)?;
        Ok(self.mutation())
    }

    pub(crate) fn restore_official(
        &mut self,
        expected_generation: u64,
    ) -> CoreResult<MutationResult> {
        self.ensure_generation(expected_generation)?;
        let mut next = self.overlay.clone();
        let baseline_ids = self
            .baseline
            .registry_baseline_nodes()
            .into_iter()
            .flat_map(|node| [node.id, node.source_id])
            .collect::<HashSet<_>>();
        next.hidden_baseline_ids.clear();
        next.retests
            .retain(|status| !baseline_ids.contains(&status.source_id));
        next.generation = next.generation.saturating_add(1);
        self.commit(next)?;
        Ok(self.mutation())
    }

    pub(crate) fn reset_all(&mut self, expected_generation: u64) -> CoreResult<MutationResult> {
        self.ensure_generation(expected_generation)?;
        self.commit(OverlayDocument::empty(
            self.overlay.generation.saturating_add(1),
        ))?;
        Ok(self.mutation())
    }

    pub(crate) fn retest_plan(
        &self,
        expected_generation: u64,
        source_ids: &[String],
    ) -> CoreResult<RetestPlan> {
        self.ensure_generation(expected_generation)?;
        if source_ids.is_empty() || source_ids.len() > 256 {
            return Err(CoreError::invalid(
                "SourceRegistry 重测来源数量必须为 1-256",
            ));
        }
        let mut seen = HashSet::new();
        let mut units = Vec::new();
        for source_id in source_ids {
            if !seen.insert(source_id) {
                continue;
            }
            if let Some(source) = self
                .overlay
                .sources
                .iter()
                .find(|source| source.id == *source_id)
            {
                if source.kind == 1 {
                    let mut member_count = 0;
                    for member in source.members.iter().filter(|member| member.kind != 3) {
                        member_count += 1;
                        units.push(RetestUnit {
                            owner_id: source.id.clone(),
                            source: LibrarySource {
                                source_id: source.id.clone(),
                                title: if member.title.is_empty() {
                                    source.title.clone()
                                } else {
                                    member.title.clone()
                                },
                                share_url: member.url.clone(),
                                password: member.password.clone(),
                            },
                        });
                    }
                    if member_count == 0 {
                        return Err(CoreError::invalid("SourceRegistry 自建合集没有可重测成员"));
                    }
                } else {
                    units.push(RetestUnit {
                        owner_id: source.id.clone(),
                        source: LibrarySource {
                            source_id: source.id.clone(),
                            title: source.title.clone(),
                            share_url: source.url.clone(),
                            password: source.password.clone(),
                        },
                    });
                }
            } else {
                let source = self.baseline.registry_source(source_id)?;
                units.push(RetestUnit {
                    owner_id: source.source_id.clone(),
                    source,
                });
            }
        }
        Ok(RetestPlan {
            generation: self.overlay.generation,
            units,
        })
    }

    pub(crate) fn commit_retests(
        &mut self,
        expected_generation: u64,
        results: Vec<RetestResult>,
    ) -> CoreResult<MutationResult> {
        self.ensure_generation(expected_generation)?;
        let mut next = self.overlay.clone();
        let tested_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u128::from(u64::MAX)) as u64;
        for result in results {
            next.retests.retain(|old| old.source_id != result.source_id);
            next.retests.push(StoredRetest {
                source_id: result.source_id,
                status: if result.passed {
                    RetestStatus::Passed
                } else {
                    RetestStatus::Failed
                },
                error_code: result.error_code.unwrap_or_default(),
                tested_at_ms,
            });
        }
        next.generation = next.generation.saturating_add(1);
        self.commit(next)?;
        Ok(self.mutation())
    }

    pub(crate) fn ensure_generation(&self, expected: u64) -> CoreResult<()> {
        if self.overlay.generation != expected {
            return Err(CoreError::new(
                "generation_conflict",
                "来源列表已被其他操作更新，请刷新后重试",
                true,
            )
            .with_details(json!({
                "expectedGeneration": expected,
                "currentGeneration": self.overlay.generation,
            })));
        }
        Ok(())
    }

    fn commit(&mut self, document: OverlayDocument) -> CoreResult<()> {
        validate_overlay(&document)?;
        let mut bytes = serde_json::to_vec_pretty(&document)
            .map_err(|_| CoreError::new("internal_error", "来源列表序列化失败", false))?;
        bytes.push(b'\n');
        if bytes.len() as u64 > MAX_OVERLAY_BYTES {
            return Err(CoreError::invalid("SourceRegistry 数据超过 2 MiB"));
        }
        atomic_write(&self.root.join(OVERLAY_FILE), &bytes, true)?;
        self.overlay = document;
        Ok(())
    }

    fn mutation(&self) -> MutationResult {
        MutationResult {
            generation: self.overlay.generation,
        }
    }

    fn prune_pending_imports(&mut self) {
        self.pending_imports
            .retain(|_, pending| pending.created_at.elapsed() <= IMPORT_PREVIEW_TTL);
        self.pending_import_order
            .retain(|id| self.pending_imports.contains_key(id));
    }

    fn visible_baseline_nodes(&self) -> Vec<super::catalog::CatalogNode> {
        let hidden = self
            .overlay
            .hidden_baseline_ids
            .iter()
            .map(String::as_str)
            .collect::<HashSet<_>>();
        let user_urls = self
            .overlay
            .sources
            .iter()
            .filter(|source| source.kind != 1)
            .map(|source| source.url.as_str())
            .collect::<HashSet<_>>();
        self.baseline
            .registry_baseline_nodes()
            .into_iter()
            .filter(|node| {
                !hidden.contains(node.id.as_str())
                    && !hidden.contains(node.source_id.as_str())
                    && !hidden.contains(node.share_url.as_str())
                    && !user_urls.contains(node.share_url.as_str())
            })
            .collect()
    }

    fn source_view(&self, source: &StoredSource) -> RegistrySourceView {
        let status = self
            .overlay
            .retests
            .iter()
            .find(|status| status.source_id == source.id);
        RegistrySourceView {
            id: source.id.clone(),
            kind: source_kind(source.kind),
            title: source.title.clone(),
            publisher: source.publisher.clone(),
            description: source.description.clone(),
            avatar_url: source.avatar.clone(),
            share_url: source.url.clone(),
            searchable: source.searchable,
            child_directory: source.child_directory,
            origin_path: source.origin_path.clone(),
            origin_url: source.origin_url.clone(),
            member_count: source
                .members
                .iter()
                .filter(|member| member.kind != 3)
                .count(),
            built_in: false,
            error_code: status.and_then(|status| match status.status {
                RetestStatus::Pending => Some("not_tested".to_owned()),
                RetestStatus::Passed => None,
                RetestStatus::Failed => Some(if status.error_code.is_empty() {
                    "source_unavailable".to_owned()
                } else {
                    status.error_code.clone()
                }),
            }),
        }
    }

    fn baseline_source_view(&self, node: &super::catalog::CatalogNode) -> RegistrySourceView {
        let mut view = baseline_view(node);
        if let Some(status) = self.overlay.retests.iter().find(|status| {
            status.source_id == node.id
                || status.source_id == node.source_id
                || status.source_id == node.share_url
        }) {
            view.error_code = match status.status {
                RetestStatus::Pending => Some("not_tested".to_owned()),
                RetestStatus::Passed => None,
                RetestStatus::Failed => Some(if status.error_code.is_empty() {
                    "source_unavailable".to_owned()
                } else {
                    status.error_code.clone()
                }),
            };
        }
        view
    }

    fn category_source_ids(&self, category_id: &str) -> CoreResult<Option<HashSet<String>>> {
        if category_id == "all" || category_id.trim().is_empty() {
            return Ok(None);
        }
        validate_identifier(category_id, "categoryId")?;
        self.overlay
            .categories
            .iter()
            .find(|category| category.id == category_id)
            .map(|category| category.source_ids.iter().cloned().collect())
            .map(Some)
            .ok_or_else(|| CoreError::invalid("SourceRegistry 分类不存在"))
    }

    fn known_content_keys(&self) -> HashSet<String> {
        self.baseline
            .registry_baseline_nodes()
            .into_iter()
            .filter(|node| !node.share_url.is_empty())
            .map(|node| format!("remote:{}", node.share_url))
            .chain(self.overlay.sources.iter().map(source_content_key))
            .collect()
    }

    fn all_source_ids(&self) -> HashSet<String> {
        self.baseline
            .registry_baseline_nodes()
            .into_iter()
            .flat_map(|node| [node.id, node.source_id])
            .chain(self.overlay.sources.iter().map(|source| source.id.clone()))
            .collect()
    }
}

static REGISTRIES: Lazy<Mutex<HashMap<PathBuf, Arc<Mutex<SourceRegistry>>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

pub(crate) fn with_registry<T>(
    storage_root: &str,
    action: impl FnOnce(&mut SourceRegistry) -> CoreResult<T>,
) -> CoreResult<T> {
    let requested = validate_absolute_path(Path::new(storage_root), "storageRoot")?;
    fs::create_dir_all(&requested).map_err(CoreError::io)?;
    let key = fs::canonicalize(&requested).map_err(CoreError::io)?;
    let registry = {
        let mut registries = REGISTRIES
            .lock()
            .map_err(|_| CoreError::new("internal_error", "来源注册表索引已损坏", false))?;
        if let Some(registry) = registries.get(&key) {
            registry.clone()
        } else {
            let registry = SourceRegistry::open(&key)?;
            let registry = Arc::new(Mutex::new(registry));
            registries.insert(key, registry.clone());
            registry
        }
    };
    let mut registry = registry
        .lock()
        .map_err(|_| CoreError::new("internal_error", "来源注册表状态已损坏", false))?;
    action(&mut registry)
}

fn stored_source_from_draft(draft: SourceDraft) -> CoreResult<(StoredSource, String)> {
    let url = normalize_source_url(&draft.url)?;
    let mut source = StoredSource {
        v: RULE_VERSION,
        id: url.clone(),
        kind: 0,
        title: draft.title,
        url,
        password: draft.password,
        searchable: draft.searchable,
        error: String::new(),
        publisher: String::new(),
        avatar: String::new(),
        description: String::new(),
        child_directory: false,
        origin_path: String::new(),
        origin_url: String::new(),
        overlay: false,
        metadata_override: false,
        members: Vec::new(),
    };
    validate_stored_source(&mut source)?;
    if !draft.category_id.is_empty() {
        validate_identifier(&draft.category_id, "categoryId")?;
    }
    Ok((source, draft.category_id))
}

fn stored_composite_from_draft(draft: CompositeDraft) -> CoreResult<StoredSource> {
    let id = if draft.id.trim().is_empty() {
        random_local_id()
    } else {
        draft.id.trim().to_owned()
    };
    let members = draft
        .members
        .into_iter()
        .enumerate()
        .map(|(index, member)| StoredMember {
            kind: match member.kind {
                CompositeMemberKind::File => 1,
                CompositeMemberKind::Directory => 2,
                CompositeMemberKind::Folder => 3,
                CompositeMemberKind::RemoteFolder => 4,
            },
            id: if member.id.trim().is_empty() {
                format!("m{index:x}")
            } else {
                member.id.trim().to_owned()
            },
            parent_id: member.parent_id.trim().to_owned(),
            url: member.url,
            password: member.password,
            icon_url: member.icon_url,
            error: String::new(),
            searchable: member.searchable,
            lightweight: matches!(
                member.kind,
                CompositeMemberKind::File | CompositeMemberKind::Directory
            ),
            title: member.title,
            size: member.size,
            time: member.time,
            description: member.description,
        })
        .collect();
    let mut source = StoredSource {
        v: RULE_VERSION,
        id,
        kind: 1,
        title: draft.title,
        url: String::new(),
        password: String::new(),
        searchable: false,
        error: String::new(),
        publisher: draft.publisher,
        avatar: draft.avatar_url,
        description: draft.description,
        child_directory: false,
        origin_path: String::new(),
        origin_url: String::new(),
        overlay: false,
        metadata_override: false,
        members,
    };
    validate_stored_source(&mut source)?;
    Ok(source)
}

fn validate_overlay(document: &OverlayDocument) -> CoreResult<()> {
    if document.schema_version != SCHEMA_VERSION {
        return Err(CoreError::parse("SourceRegistry schemaVersion 不受支持"));
    }
    if document.sources.len() > MAX_USER_SOURCES
        || document.categories.len() > MAX_CATEGORIES
        || document.hidden_baseline_ids.len() > MAX_USER_SOURCES
        || document.retests.len() > MAX_USER_SOURCES
    {
        return Err(CoreError::parse("SourceRegistry 项目数量超过限制"));
    }
    let mut sources = document.sources.clone();
    let mut source_ids = HashSet::new();
    for source in &mut sources {
        validate_stored_source(source)?;
        if !source_ids.insert(source.id.clone()) {
            return Err(CoreError::parse("SourceRegistry sourceId 重复"));
        }
    }
    let mut category_ids = HashSet::new();
    for category in &document.categories {
        validate_identifier(&category.id, "categoryId")?;
        validate_text(&category.title, 80, false, "分类标题")?;
        if !category_ids.insert(&category.id) || category.source_ids.len() > MAX_USER_SOURCES {
            return Err(CoreError::parse("SourceRegistry 分类无效或重复"));
        }
    }
    let mut hidden = HashSet::new();
    for id in &document.hidden_baseline_ids {
        validate_text(id, 512, false, "隐藏来源身份")?;
        if !hidden.insert(id) {
            return Err(CoreError::parse("SourceRegistry 隐藏来源重复"));
        }
    }
    let mut retests = HashSet::new();
    for status in &document.retests {
        validate_text(&status.source_id, 512, false, "重测来源身份")?;
        validate_text(&status.error_code, 64, true, "重测错误码")?;
        if !retests.insert(&status.source_id) {
            return Err(CoreError::parse("SourceRegistry 重测状态重复"));
        }
    }
    Ok(())
}

fn validate_stored_source(source: &mut StoredSource) -> CoreResult<()> {
    if source.v != RULE_VERSION || source.kind > 2 {
        return Err(CoreError::parse("来源规则版本或 kind 无效"));
    }
    validate_text(&source.title, 160, false, "来源标题")?;
    validate_text(&source.password, 64, true, "来源访问码")?;
    validate_text(&source.error, 256, true, "来源错误")?;
    validate_text(&source.publisher, 80, true, "来源发布者")?;
    validate_text(&source.avatar, 2_048, true, "来源头像")?;
    validate_text(&source.description, 4_000, true, "来源简介")?;
    validate_text(&source.origin_path, 512, true, "来源路径")?;
    validate_text(&source.origin_url, 2_048, true, "来源原始地址")?;
    if source.kind == 1 {
        validate_local_id(&source.id)?;
        if !source.url.is_empty() || !source.password.is_empty() {
            return Err(CoreError::parse("自建合集不能把身份伪装成远程地址"));
        }
    } else {
        let normalized = normalize_source_url(&source.url)?;
        if !source.id.is_empty() && source.id != normalized {
            return Err(CoreError::parse("远程来源 id 必须等于规范分享地址"));
        }
        source.id = normalized.clone();
        source.url = normalized;
    }
    if source.members.len() > MAX_USER_SOURCES {
        return Err(CoreError::parse("来源成员超过 4096 个"));
    }
    let mut ids = HashSet::new();
    let mut folders = HashSet::new();
    let mut content = HashSet::new();
    for member in &mut source.members {
        if !(1..=4).contains(&member.kind) {
            return Err(CoreError::parse("来源成员 kind 无效"));
        }
        validate_identifier(&member.id, "memberId")?;
        if !ids.insert(member.id.clone()) {
            return Err(CoreError::parse("来源成员 id 重复"));
        }
        validate_text(&member.parent_id, 64, true, "成员父级")?;
        validate_text(&member.password, 64, true, "成员访问码")?;
        validate_text(&member.title, 512, true, "成员标题")?;
        validate_text(&member.icon_url, 2_048, true, "成员图标")?;
        validate_text(&member.error, 256, true, "成员错误")?;
        validate_text(&member.size, 128, true, "成员大小")?;
        validate_text(&member.time, 128, true, "成员时间")?;
        validate_text(&member.description, 4_000, true, "成员简介")?;
        if member.kind == 3 {
            if !member.url.is_empty() || !member.password.is_empty() {
                return Err(CoreError::parse("本地文件夹成员不能带远程地址或访问码"));
            }
            folders.insert(member.id.clone());
        } else {
            member.url = normalize_source_url(&member.url)?;
            let key = format!("{}\n{}\n{}", member.parent_id, member.url, member.password);
            if !content.insert(key) {
                return Err(CoreError::parse("来源成员重复"));
            }
        }
    }
    for member in &source.members {
        if !member.parent_id.is_empty() && !folders.contains(&member.parent_id) {
            return Err(CoreError::parse("来源成员 parent 不存在或不是文件夹"));
        }
    }
    if source.kind == 1
        && source
            .members
            .iter()
            .filter(|member| member.kind != 3)
            .count()
            < 2
    {
        return Err(CoreError::invalid("自建合集至少需要 2 个真实远程成员"));
    }
    if source.kind == 0 && !source.members.is_empty() {
        return Err(CoreError::parse("普通远程来源不能包含 members"));
    }
    Ok(())
}

fn validate_category_draft(
    draft: CategoryDraft,
    known_sources: &HashSet<String>,
) -> CoreResult<StoredCategory> {
    validate_identifier(&draft.id, "categoryId")?;
    validate_text(&draft.title, 80, false, "分类标题")?;
    if draft.source_ids.len() > MAX_USER_SOURCES {
        return Err(CoreError::invalid("分类来源不能超过 4096 个"));
    }
    let mut source_ids = Vec::with_capacity(draft.source_ids.len());
    let mut unique = HashSet::new();
    for source_id in draft.source_ids {
        validate_text(&source_id, 512, false, "分类来源身份")?;
        if !known_sources.contains(&source_id) {
            return Err(CoreError::invalid("分类包含不存在的来源"));
        }
        if unique.insert(source_id.clone()) {
            source_ids.push(source_id);
        }
    }
    Ok(StoredCategory {
        id: draft.id,
        title: draft.title.trim().to_owned(),
        source_ids,
    })
}

fn validate_identifier(value: &str, field: &str) -> CoreResult<()> {
    let value = value.trim();
    if value.is_empty()
        || value.len() > 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        return Err(CoreError::invalid(format!(
            "SourceRegistry {field} 格式无效"
        )));
    }
    Ok(())
}

fn validate_local_id(value: &str) -> CoreResult<()> {
    if !value.starts_with("local:")
        || value.len() > 96
        || value.len() <= 6
        || value.chars().any(char::is_control)
    {
        return Err(CoreError::invalid("SourceRegistry 自建合集 id 无效"));
    }
    Ok(())
}

fn validate_text(value: &str, max: usize, allow_empty: bool, label: &str) -> CoreResult<()> {
    if (!allow_empty && value.trim().is_empty())
        || value.chars().count() > max
        || value.chars().any(char::is_control)
    {
        return Err(CoreError::invalid(format!("{label}格式无效")));
    }
    Ok(())
}

fn normalize_source_url(value: &str) -> CoreResult<String> {
    normalize_public_share_url(value.trim(), &SecurityPolicy::Production)
        .map_err(|_| CoreError::invalid("来源分享地址无效或不受信任"))
}

fn validate_rules_url_with_resolver<F>(value: &str, resolver: F) -> CoreResult<Url>
where
    F: FnOnce(&str) -> CoreResult<Vec<IpAddr>>,
{
    if value.len() > 2_048 || value.chars().any(char::is_control) {
        return Err(CoreError::invalid("来源规则地址格式无效"));
    }
    reject_explicit_port_reference(value)
        .map_err(|_| CoreError::invalid("来源规则地址不能使用显式端口"))?;
    let url = Url::parse(value).map_err(|_| CoreError::invalid("来源规则地址无效"))?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.fragment().is_some()
        || url.path().is_empty()
        || url.path() == "/"
    {
        return Err(CoreError::invalid("来源规则地址必须是安全 HTTPS 地址"));
    }
    let host = url
        .host_str()
        .filter(|host| !host.is_empty())
        .ok_or_else(|| CoreError::invalid("来源规则地址缺少主机名"))?;
    if !host.is_ascii() || host.eq_ignore_ascii_case("localhost") || host.ends_with(".local") {
        return Err(CoreError::invalid("来源规则主机名不受信任"));
    }
    let addresses = match host.parse::<IpAddr>() {
        Ok(address) => vec![address],
        Err(_) => resolver(host)?,
    };
    if addresses.is_empty() || addresses.iter().any(|address| !is_public_ip(*address)) {
        return Err(CoreError::invalid("来源规则地址解析到了非公网地址"));
    }
    Ok(url)
}

pub(crate) fn fetch_rules_bytes(value: &str) -> CoreResult<Vec<u8>> {
    let mut current = value.trim().to_owned();
    for redirect_count in 0..=5 {
        let parsed = Url::parse(&current).map_err(|_| CoreError::invalid("来源规则地址无效"))?;
        let host = parsed
            .host_str()
            .filter(|host| !host.is_empty())
            .ok_or_else(|| CoreError::invalid("来源规则地址缺少主机名"))?
            .to_owned();
        let ips = match host.parse::<IpAddr>() {
            Ok(address) => vec![address],
            Err(_) => (host.as_str(), 443)
                .to_socket_addrs()
                .map_err(|_| CoreError::remote("无法验证来源规则主机", true))?
                .map(|address| address.ip())
                .collect::<Vec<_>>(),
        };
        let url = validate_rules_url_with_resolver(&current, |_| Ok(ips.clone()))?;
        let addresses = ips
            .iter()
            .copied()
            .map(|ip| SocketAddr::new(ip, 443))
            .collect::<Vec<_>>();
        let client = Client::builder()
            .use_rustls_tls()
            .no_proxy()
            .redirect(Policy::none())
            .connect_timeout(Duration::from_secs(8))
            .timeout(Duration::from_secs(20))
            .resolve_to_addrs(&host, &addresses)
            .build()
            .map_err(CoreError::from_reqwest)?;
        let response = client
            .get(url.clone())
            .header(USER_AGENT, "LanzouYOU-SourceRegistry/1")
            .header(ACCEPT, "application/json,text/plain;q=0.9")
            .header(ACCEPT_ENCODING, "identity")
            .send()
            .map_err(CoreError::from_reqwest)?;
        if response.status().is_redirection() {
            if redirect_count == 5 {
                return Err(CoreError::remote("来源规则跳转次数过多", false));
            }
            let location = response
                .headers()
                .get(LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or_else(|| CoreError::parse("来源规则跳转缺少地址"))?;
            reject_explicit_port_reference(location)
                .map_err(|_| CoreError::invalid("来源规则跳转包含显式端口"))?;
            current = url
                .join(location)
                .map_err(|_| CoreError::parse("来源规则跳转地址无效"))?
                .to_string();
            continue;
        }
        if !response.status().is_success() {
            return Err(CoreError::remote(
                format!("来源规则请求 HTTP {}", response.status().as_u16()),
                response.status().is_server_error(),
            ));
        }
        if response
            .headers()
            .get(CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok())
            .is_some_and(|length| length > MAX_RULE_BYTES)
        {
            return Err(CoreError::invalid("来源规则文件不能超过 512 KiB"));
        }
        if let Some(media_type) = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .map(|value| value.split(';').next().unwrap_or_default().trim())
        {
            if !matches!(
                media_type,
                "application/json" | "text/plain" | "application/octet-stream"
            ) {
                return Err(CoreError::parse("来源规则响应类型无效"));
            }
        }
        let mut bytes = Vec::new();
        response
            .take(MAX_RULE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(CoreError::io)?;
        if bytes.len() as u64 > MAX_RULE_BYTES {
            return Err(CoreError::invalid("来源规则文件不能超过 512 KiB"));
        }
        return Ok(bytes);
    }
    Err(CoreError::remote("来源规则跳转次数过多", false))
}

fn parse_plain_source_line(value: &str, category_id: &str) -> CoreResult<SourceDraft> {
    let tokens = tokenize_links(value)?;
    if tokens.len() != 1 || tokens[0].start_utf16 != 0 || tokens[0].kind != LinkKind::LanzouShare {
        return Err(CoreError::invalid(
            "每行必须以且只能包含一个可信蓝奏分享链接",
        ));
    }
    let token = &tokens[0];
    let canonical = token
        .canonical_url
        .as_deref()
        .ok_or_else(|| CoreError::invalid("来源分享地址无效或不受信任"))?;
    let password = value
        .get(token.text.len()..)
        .ok_or_else(|| CoreError::invalid("来源导入行格式无效"))?
        .trim()
        .to_owned();
    if password.split_whitespace().count() > 1 {
        return Err(CoreError::invalid("每行仅允许链接和一个访问码"));
    }
    validate_text(&password, 64, true, "来源访问码")?;
    let share_id = canonical
        .split(['?', '#'])
        .next()
        .and_then(|url| url.rsplit('/').find(|part| !part.is_empty()))
        .unwrap_or("来源");
    let title = format!("蓝奏来源 {share_id}");
    Ok(SourceDraft {
        title,
        url: canonical.to_owned(),
        password,
        searchable: true,
        category_id: category_id.to_owned(),
    })
}

fn parse_source_text_line(value: &str, _line_number: usize) -> CoreResult<StoredSource> {
    let mut draft = parse_plain_source_line(value, "")?;
    // Text import cannot safely infer whether a remote library supports
    // recursive search. Keep it disabled until the user explicitly enables
    // it (normally after a successful retest).
    draft.searchable = false;
    stored_source_from_draft(draft).map(|(source, _)| source)
}

fn pending_retest(source_id: String) -> StoredRetest {
    StoredRetest {
        source_id,
        status: RetestStatus::Pending,
        error_code: String::new(),
        tested_at_ms: 0,
    }
}

fn parse_registry_kind(value: &str) -> CoreResult<Option<RegistrySourceKind>> {
    match value.trim() {
        "" | "all" => Ok(None),
        "official" => Ok(Some(RegistrySourceKind::Official)),
        "composite" => Ok(Some(RegistrySourceKind::Composite)),
        "singleSoftware" | "single_software" => Ok(Some(RegistrySourceKind::SingleSoftware)),
        _ => Err(CoreError::invalid("SourceRegistry kind 无效")),
    }
}

fn baseline_view(node: &super::catalog::CatalogNode) -> RegistrySourceView {
    RegistrySourceView {
        id: node.id.clone(),
        kind: match node.kind {
            CatalogNodeKind::Composite => RegistrySourceKind::Composite,
            CatalogNodeKind::SingleSoftware | CatalogNodeKind::File => {
                RegistrySourceKind::SingleSoftware
            }
            CatalogNodeKind::RemoteSource | CatalogNodeKind::Folder => RegistrySourceKind::Official,
        },
        title: node.title.clone(),
        publisher: node.publisher.clone(),
        description: node.description.clone(),
        avatar_url: node.icon_url.clone(),
        share_url: node.share_url.clone(),
        searchable: node.searchable,
        child_directory: node.child_directory,
        origin_path: node.origin_path.clone(),
        origin_url: node.origin_url.clone(),
        member_count: usize::from(node.has_children),
        built_in: true,
        error_code: node.error_code.clone(),
    }
}

fn source_kind(kind: u8) -> RegistrySourceKind {
    match kind {
        1 => RegistrySourceKind::Composite,
        2 => RegistrySourceKind::SingleSoftware,
        _ => RegistrySourceKind::Official,
    }
}

fn fold_view(source: &RegistrySourceView) -> String {
    format!(
        "{}\n{}\n{}\n{}",
        source.title, source.publisher, source.description, source.origin_path
    )
    .to_lowercase()
}

fn clean_query(value: &str) -> CoreResult<String> {
    let value = value.trim().to_lowercase();
    if value.chars().count() > 128 || value.chars().any(char::is_control) {
        return Err(CoreError::invalid("SourceRegistry query 格式无效"));
    }
    Ok(value)
}

fn source_content_key(source: &StoredSource) -> String {
    if source.kind != 1 {
        return format!("remote:{}", source.url);
    }
    let mut members = source
        .members
        .iter()
        .filter(|member| member.kind != 3)
        .map(|member| format!("{}\n{}", member.url, member.password))
        .collect::<Vec<_>>();
    members.sort();
    format!(
        "composite:{}",
        URL_SAFE_NO_PAD.encode(members.join("\n").as_bytes())
    )
}

fn random_local_id() -> String {
    let mut bytes = [0_u8; 16];
    OsRng.fill_bytes(&mut bytes);
    format!("local:{}", URL_SAFE_NO_PAD.encode(bytes))
}

fn random_preview_id() -> String {
    let mut bytes = [0_u8; 16];
    OsRng.fill_bytes(&mut bytes);
    format!("preview:{}", URL_SAFE_NO_PAD.encode(bytes))
}

fn page_scope(
    generation: u64,
    category: &str,
    query: &str,
    kind: &str,
    searchable: Option<bool>,
    child_directory: Option<bool>,
    built_in: Option<bool>,
) -> String {
    format!(
        "{generation}\0{category}\0{query}\0{kind}\0{searchable:?}\0{child_directory:?}\0{built_in:?}"
    )
}

fn encode_cursor(offset: usize, scope: &str) -> String {
    let mut bytes = Vec::with_capacity(8 + scope.len());
    bytes.extend_from_slice(&(offset as u64).to_be_bytes());
    bytes.extend_from_slice(scope.as_bytes());
    URL_SAFE_NO_PAD.encode(bytes)
}

fn decode_cursor(value: &str, scope: &str) -> CoreResult<usize> {
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| CoreError::invalid("SourceRegistry cursor 无效"))?;
    if bytes.len() < 8 || bytes[8..] != *scope.as_bytes() {
        return Err(CoreError::invalid("SourceRegistry cursor 已失效"));
    }
    usize::try_from(u64::from_be_bytes(
        bytes[..8].try_into().expect("cursor prefix is fixed"),
    ))
    .map_err(|_| CoreError::invalid("SourceRegistry cursor 超出范围"))
}

fn validate_absolute_path(path: &Path, label: &str) -> CoreResult<PathBuf> {
    if !path.is_absolute()
        || path.as_os_str().is_empty()
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::CurDir))
    {
        return Err(CoreError::invalid(format!(
            "SourceRegistry {label} 必须是无跳转的绝对路径"
        )));
    }
    Ok(path.to_path_buf())
}

fn read_overlay(path: &Path) -> CoreResult<OverlayDocument> {
    let bytes = read_bounded(path, MAX_OVERLAY_BYTES)?;
    let document = serde_json::from_slice::<OverlayDocument>(&bytes)
        .map_err(|_| CoreError::parse("SourceRegistry 数据不是严格 current schema"))?;
    validate_overlay(&document)?;
    Ok(document)
}

fn read_bounded(path: &Path, limit: u64) -> CoreResult<Vec<u8>> {
    let metadata = fs::metadata(path).map_err(CoreError::io)?;
    if !metadata.is_file() || metadata.len() > limit {
        return Err(CoreError::invalid(
            "SourceRegistry 文件不存在、不是文件或超过限制",
        ));
    }
    let file = File::open(path).map_err(CoreError::io)?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(CoreError::io)?;
    if bytes.len() as u64 > limit {
        return Err(CoreError::invalid("SourceRegistry 文件超过限制"));
    }
    Ok(bytes)
}

fn atomic_write(path: &Path, bytes: &[u8], keep_backup: bool) -> CoreResult<()> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .ok_or_else(|| CoreError::invalid("SourceRegistry 写入路径缺少父目录"))?;
    fs::create_dir_all(parent).map_err(CoreError::io)?;
    let mut nonce = [0_u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| CoreError::invalid("SourceRegistry 文件名无效"))?;
    let temp = parent.join(format!(
        ".{file_name}.{}.tmp",
        URL_SAFE_NO_PAD.encode(nonce)
    ));
    let write_result = (|| -> CoreResult<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(CoreError::io)?;
        file.write_all(bytes).map_err(CoreError::io)?;
        file.flush().map_err(CoreError::io)?;
        file.sync_all().map_err(CoreError::io)?;
        drop(file);

        if keep_backup && path.is_file() {
            let backup = path.with_file_name(format!("{file_name}.bak"));
            let backup_temp = parent.join(format!(
                ".{file_name}.bak.{}.tmp",
                URL_SAFE_NO_PAD.encode(nonce)
            ));
            fs::copy(path, &backup_temp).map_err(CoreError::io)?;
            OpenOptions::new()
                .read(true)
                .write(true)
                .open(&backup_temp)
                .and_then(|file| file.sync_all())
                .map_err(CoreError::io)?;
            replace_file(&backup_temp, &backup)?;
        }
        replace_file(&temp, path)?;
        sync_directory(parent)?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    write_result
}

#[cfg(windows)]
fn replace_file(source: &Path, destination: &Path) -> CoreResult<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, ReplaceFileW, MOVEFILE_WRITE_THROUGH, REPLACEFILE_WRITE_THROUGH,
    };

    let destination_exists = destination.is_file();
    let source = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let moved = unsafe {
        if destination_exists {
            // ReplaceFileW is the atomic replace primitive for an existing
            // destination. MoveFileExW can return ERROR_ACCESS_DENIED for this
            // case on Windows even when MOVEFILE_REPLACE_EXISTING is present.
            ReplaceFileW(
                destination.as_ptr(),
                source.as_ptr(),
                std::ptr::null(),
                REPLACEFILE_WRITE_THROUGH,
                std::ptr::null(),
                std::ptr::null(),
            )
        } else {
            MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                MOVEFILE_WRITE_THROUGH,
            )
        }
    };
    if moved == 0 {
        return Err(CoreError::io(std::io::Error::last_os_error()));
    }
    Ok(())
}

#[cfg(not(windows))]
fn replace_file(source: &Path, destination: &Path) -> CoreResult<()> {
    fs::rename(source, destination).map_err(CoreError::io)
}

#[cfg(windows)]
fn sync_directory(_path: &Path) -> CoreResult<()> {
    // Windows does not support FlushFileBuffers on directory handles and
    // returns ERROR_ACCESS_DENIED even when the handle was opened with
    // FILE_FLAG_BACKUP_SEMANTICS. `replace_file` above already asks
    // MoveFileExW for MOVEFILE_WRITE_THROUGH, which is the Windows durability
    // boundary for this atomic replacement. Do not turn a committed move into
    // a false failure by attempting a POSIX-only directory fsync afterwards.
    Ok(())
}

#[cfg(not(windows))]
fn sync_directory(path: &Path) -> CoreResult<()> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(CoreError::io)
}

#[cfg(test)]
mod tests {
    use std::{fs, net::IpAddr};

    use tempfile::tempdir_in;

    use super::{
        validate_rules_url_with_resolver, CategoryDraft, CompositeDraft, CompositeMemberDraft,
        RegistryPageRequest, SourceDraft, SourceRegistry, SourceUpdateDraft,
    };

    fn temp_root() -> tempfile::TempDir {
        tempdir_in(std::env::temp_dir()).unwrap()
    }

    fn source(url: &str, title: &str) -> SourceDraft {
        SourceDraft {
            title: title.to_owned(),
            url: url.to_owned(),
            password: "secret-code".to_owned(),
            searchable: true,
            category_id: String::new(),
        }
    }

    #[test]
    fn test_source_registry_requires_absolute_storage_root() {
        let error = SourceRegistry::open("relative/cache").unwrap_err();
        assert_eq!(error.code, "invalid_argument");
    }

    #[test]
    fn test_source_registry_batch_import_is_cas_and_snapshot_is_password_free() {
        let root = temp_root();
        let mut registry = SourceRegistry::open(root.path()).unwrap();

        let initial = registry.snapshot();
        assert_eq!(initial.generation, 0);
        assert_eq!(initial.baseline_count, 606);
        assert_eq!(initial.user_count, 0);

        let result = registry
            .batch_import(
                0,
                vec![
                    source("https://lanzoui.com/b123", "One"),
                    source("https://www.lanzouw.com/b123", "Duplicate"),
                ],
            )
            .unwrap();
        assert_eq!(result.generation, 1);
        assert_eq!(result.added, 1);
        assert_eq!(result.duplicates, 1);

        let serialized = serde_json::to_string(&registry.snapshot()).unwrap();
        assert!(!serialized.contains("secret-code"));
        assert!(!serialized.to_ascii_lowercase().contains("password"));

        let stale = registry
            .batch_import(0, vec![source("https://www.lanzouw.com/b456", "Stale")])
            .unwrap_err();
        assert_eq!(stale.code, "generation_conflict");
        assert_eq!(registry.snapshot().generation, 1);
    }

    #[test]
    fn test_source_registry_page_merges_baseline_and_overlay_without_secrets() {
        let root = temp_root();
        let mut registry = SourceRegistry::open(root.path()).unwrap();
        registry
            .batch_import(
                0,
                vec![source("https://www.lanzouw.com/custom-source", "Custom")],
            )
            .unwrap();

        let page = registry
            .page(RegistryPageRequest {
                cursor: String::new(),
                limit: 200,
                query: "Custom".to_owned(),
                category_id: "all".to_owned(),
                kind: "all".to_owned(),
                searchable: None,
                child_directory: None,
                built_in: None,
            })
            .unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.sources[0].title, "Custom");
        let serialized = serde_json::to_string(&page).unwrap();
        assert!(!serialized.contains("secret-code"));
        assert!(!serialized.to_ascii_lowercase().contains("password"));
    }

    #[test]
    fn test_source_registry_plain_import_preview_is_password_free_and_commit_is_cas() {
        let root = temp_root();
        let mut registry = SourceRegistry::open(root.path()).unwrap();
        let preview = registry
            .preview_import_text(
                0,
                "https://www.lanzouw.com/b-private secret-code\nnot-a-link\nhttps://www.lanzouw.com/b-private duplicate",
                "",
            )
            .unwrap();

        assert_eq!(preview.valid.len(), 1);
        assert_eq!(preview.duplicates.len(), 1);
        assert_eq!(preview.invalid.len(), 1);
        assert!(preview.valid[0].requires_code);
        let json = serde_json::to_string(&preview).unwrap();
        assert!(!json.contains("secret-code"));
        assert!(!json.contains(" duplicate\""));
        assert!(!json.to_ascii_lowercase().contains("\"password\":"));

        let committed = registry
            .commit_import_preview(0, &preview.preview_id)
            .unwrap();
        assert_eq!(committed.generation, 1);
        assert_eq!(committed.added, 1);
        assert_eq!(committed.duplicates, 1);
        assert_eq!(committed.invalid, 1);
        assert_eq!(
            registry
                .commit_import_preview(0, &preview.preview_id)
                .unwrap_err()
                .code,
            "generation_conflict"
        );
    }

    #[test]
    fn test_source_registry_import_preview_expires_secret_bearing_state() {
        let root = temp_root();
        let mut registry = SourceRegistry::open(root.path()).unwrap();
        let preview = registry
            .preview_import_text(0, "https://www.lanzouw.com/preview-expiry private-code", "")
            .unwrap();
        registry
            .pending_imports
            .get_mut(&preview.preview_id)
            .unwrap()
            .created_at = std::time::Instant::now()
            .checked_sub(super::IMPORT_PREVIEW_TTL + std::time::Duration::from_secs(1))
            .unwrap();

        let error = registry
            .commit_import_preview(0, &preview.preview_id)
            .unwrap_err();

        assert_eq!(error.code, "preview_not_found");
        assert!(registry.pending_imports.is_empty());
    }

    #[test]
    fn test_source_registry_batch_import_text_is_rust_owned_and_line_granular() {
        let root = temp_root();
        let mut registry = SourceRegistry::open(root.path()).unwrap();

        let result = registry
            .batch_import_text(
                0,
                "https://lanzoui.com/text-one code-one\n\ninvalid line extra\nhttps://www.lanzouw.com/text-one code-two\nhttps://www.lanzouw.com/text-two",
                "",
            )
            .unwrap();

        assert_eq!(result.generation, 1);
        assert_eq!(result.added, 2);
        assert_eq!(result.duplicates, 1);
        assert_eq!(result.invalid, 1);
        assert_eq!(result.lines.len(), 4);
        assert_eq!(result.lines[0].line, 1);
        assert_eq!(result.lines[1].state, "invalid");
        assert_eq!(result.lines[2].state, "duplicate");
        assert_eq!(result.lines[3].state, "added");
        let json = serde_json::to_string(&result).unwrap();
        assert!(!json.contains("code-one"));
        assert!(!json.to_ascii_lowercase().contains("password"));
        assert!(registry
            .snapshot()
            .user_sources
            .iter()
            .all(|source| source.error_code.as_deref() == Some("not_tested")));
    }

    #[test]
    fn test_source_registry_update_delete_and_category_membership_are_cas() {
        let root = temp_root();
        let mut registry = SourceRegistry::open(root.path()).unwrap();
        registry
            .batch_import_text(
                0,
                "https://www.lanzouw.com/manage-one old-code\nhttps://www.lanzouw.com/manage-two",
                "",
            )
            .unwrap();
        let ids = registry
            .snapshot()
            .user_sources
            .iter()
            .map(|source| source.id.clone())
            .collect::<Vec<_>>();
        registry
            .upsert_category(
                1,
                CategoryDraft {
                    id: "tools".to_owned(),
                    title: "Tools".to_owned(),
                    source_ids: Vec::new(),
                },
            )
            .unwrap();
        registry
            .set_category_members(2, "tools", ids.clone())
            .unwrap();
        registry
            .update_source(
                3,
                SourceUpdateDraft {
                    source_id: ids[0].clone(),
                    title: "Renamed".to_owned(),
                    searchable: true,
                    access_code: Some("new-code".to_owned()),
                },
            )
            .unwrap();
        let page = registry
            .page(RegistryPageRequest {
                cursor: String::new(),
                limit: 100,
                query: "Renamed".to_owned(),
                category_id: "tools".to_owned(),
                kind: "official".to_owned(),
                searchable: Some(true),
                child_directory: None,
                built_in: Some(false),
            })
            .unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.sources[0].title, "Renamed");

        let deleted = registry.delete_sources(4, vec![ids[0].clone()]).unwrap();
        assert_eq!(deleted.generation, 5);
        assert_eq!(deleted.removed, 1);
        assert_eq!(registry.snapshot().user_count, 1);
        assert_eq!(
            registry
                .update_source(
                    4,
                    SourceUpdateDraft {
                        source_id: ids[1].clone(),
                        title: "stale".to_owned(),
                        searchable: false,
                        access_code: None,
                    },
                )
                .unwrap_err()
                .code,
            "generation_conflict"
        );
    }

    #[test]
    fn test_source_registry_hiding_builtin_cleans_category_aliases() {
        let root = temp_root();
        let mut registry = SourceRegistry::open(root.path()).unwrap();
        let node = registry
            .baseline
            .registry_baseline_nodes()
            .into_iter()
            .find(|node| node.id != node.source_id)
            .expect("baseline contains separately addressed nodes");
        registry
            .upsert_category(
                0,
                CategoryDraft {
                    id: "builtin-tools".to_owned(),
                    title: "Built-in tools".to_owned(),
                    source_ids: vec![node.id.clone()],
                },
            )
            .unwrap();

        let deleted = registry
            .delete_sources(1, vec![node.source_id.clone()])
            .unwrap();

        assert!(deleted.hidden > 0);
        assert!(registry.snapshot().categories[0].source_ids.is_empty());
    }

    #[test]
    fn test_source_registry_rule_export_is_sanitized_by_default_and_gated_for_credentials() {
        let root = temp_root();
        let export_root = temp_root();
        let safe_path = export_root.path().join("safe.json");
        let secret_path = export_root.path().join("secret.json");
        let mut registry = SourceRegistry::open(root.path()).unwrap();
        registry
            .batch_import_text(0, "https://www.lanzouw.com/export-gated private-code", "")
            .unwrap();

        registry
            .export_rules(1, &safe_path, &[], false, "")
            .unwrap();
        assert!(!fs::read_to_string(&safe_path)
            .unwrap()
            .contains("private-code"));
        assert_eq!(
            registry
                .export_rules(1, &secret_path, &[], true, "wrong")
                .unwrap_err()
                .code,
            "credential_export_confirmation_required"
        );
        registry
            .export_rules(1, &secret_path, &[], true, "export-source-access-codes")
            .unwrap();
        assert!(fs::read_to_string(&secret_path)
            .unwrap()
            .contains("private-code"));
    }

    #[test]
    fn test_source_registry_rules_url_requires_https_public_addresses() {
        let public = validate_rules_url_with_resolver("https://rules.example/sources.json", |_| {
            Ok(vec!["93.184.216.34".parse::<IpAddr>().unwrap()])
        })
        .unwrap();
        assert_eq!(public.as_str(), "https://rules.example/sources.json");
        for value in [
            "http://rules.example/sources.json",
            "https://127.0.0.1/sources.json",
            "https://rules.example:8443/sources.json",
        ] {
            assert!(validate_rules_url_with_resolver(value, |_| {
                Ok(vec!["127.0.0.1".parse::<IpAddr>().unwrap()])
            })
            .is_err());
        }
    }

    #[test]
    fn test_source_registry_category_and_composite_crud_are_atomic() {
        let root = temp_root();
        let mut registry = SourceRegistry::open(root.path()).unwrap();
        let imported = registry
            .batch_import(
                0,
                vec![source(
                    "https://www.lanzouw.com/category-source",
                    "Categorized",
                )],
            )
            .unwrap();
        let source_id = registry.snapshot().user_sources[0].id.clone();

        let category = registry
            .upsert_category(
                imported.generation,
                CategoryDraft {
                    id: "tools".to_owned(),
                    title: "Tools".to_owned(),
                    source_ids: vec![source_id],
                },
            )
            .unwrap();
        assert_eq!(category.generation, 2);

        let composite = registry
            .upsert_composite(
                category.generation,
                CompositeDraft {
                    id: String::new(),
                    title: "Bundle".to_owned(),
                    publisher: "Publisher".to_owned(),
                    avatar_url: String::new(),
                    description: "Description".to_owned(),
                    members: vec![
                        CompositeMemberDraft::file("https://www.lanzouw.com/f1"),
                        CompositeMemberDraft::file("https://www.lanzouw.com/f2"),
                    ],
                },
            )
            .unwrap();
        assert_eq!(composite.generation, 3);
        assert!(composite.source_id.starts_with("local:"));
        let snapshot = registry.snapshot();
        assert_eq!(snapshot.user_count, 2);
        assert_eq!(
            snapshot
                .user_sources
                .iter()
                .find(|source| source.id == composite.source_id)
                .and_then(|source| source.error_code.as_deref()),
            Some("not_tested")
        );

        let deleted = registry
            .delete_composite(composite.generation, &composite.source_id)
            .unwrap();
        assert_eq!(deleted.generation, 4);
        assert_eq!(registry.snapshot().user_count, 1);
    }

    #[test]
    fn test_source_registry_composite_retest_plan_keeps_one_logical_owner() {
        let root = temp_root();
        let mut registry = SourceRegistry::open(root.path()).unwrap();
        let composite = registry
            .upsert_composite(
                0,
                CompositeDraft {
                    id: String::new(),
                    title: "Retest Bundle".to_owned(),
                    publisher: String::new(),
                    avatar_url: String::new(),
                    description: String::new(),
                    members: vec![
                        CompositeMemberDraft::file("https://www.lanzouw.com/retest-a"),
                        CompositeMemberDraft::file("https://www.lanzouw.com/retest-b"),
                    ],
                },
            )
            .unwrap();

        let plan = registry
            .retest_plan(1, std::slice::from_ref(&composite.source_id))
            .unwrap();
        assert_eq!(plan.units.len(), 2);
        assert!(plan
            .units
            .iter()
            .all(|unit| unit.owner_id == composite.source_id));
    }

    #[test]
    fn test_source_registry_rules_roundtrip_restore_backup_and_reset() {
        let root = temp_root();
        let export_root = temp_root();
        let export_path = export_root.path().join("rules-v2.json");
        let mut registry = SourceRegistry::open(root.path()).unwrap();
        registry
            .batch_import(
                0,
                vec![source("https://www.lanzouw.com/export-source", "Export")],
            )
            .unwrap();

        let exported = registry
            .export_rules(1, &export_path, &[], true, "export-source-access-codes")
            .unwrap();
        assert_eq!(exported.count, 1);
        assert_eq!(exported.generation, 1);

        let rules = fs::read_to_string(&export_path).unwrap();
        assert!(rules.contains("\"version\": 2"));
        assert!(rules.contains("secret-code"));

        let reset = registry.reset_all(1).unwrap();
        assert_eq!(reset.generation, 2);
        assert_eq!(registry.snapshot().user_count, 0);
        assert!(root.path().join("source-registry-v1.json.bak").is_file());

        let restored = registry.restore_backup(2).unwrap();
        assert_eq!(restored.generation, 3);
        assert_eq!(registry.snapshot().user_count, 1);

        let import_root = temp_root();
        let mut imported = SourceRegistry::open(import_root.path()).unwrap();
        let result = imported.import_rules(0, &export_path).unwrap();
        assert_eq!(result.added, 1);
        assert_eq!(imported.snapshot().user_count, 1);
    }

    #[test]
    fn test_source_registry_rejects_unknown_overlay_fields_without_fallback() {
        let root = temp_root();
        fs::create_dir_all(root.path()).unwrap();
        fs::write(
            root.path().join("source-registry-v1.json"),
            r#"{"schemaVersion":1,"generation":0,"sources":[],"categories":[],"hiddenBaselineIds":[],"retests":[],"legacy":true}"#,
        )
        .unwrap();

        let error = SourceRegistry::open(root.path()).unwrap_err();
        assert_eq!(error.code, "parse_error");
    }
}
