use serde::{Deserialize, Serialize};

const MAX_LOGICAL_SEARCH_SOURCES: usize = 4_096;

fn first_page() -> u32 {
    1
}

fn default_concurrency() -> usize {
    16
}

fn default_source_switch_delay_ms() -> u64 {
    0
}

fn default_until_last_page() -> bool {
    true
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibrarySource {
    pub source_id: String,
    #[serde(default)]
    pub title: String,
    pub share_url: String,
    #[serde(default)]
    pub password: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicLibrarySource {
    pub source_id: String,
    pub title: String,
    pub share_url: String,
    pub searchable: bool,
    pub kind: LibrarySourceKind,
}

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum LibrarySourceKind {
    #[default]
    Directory,
    SingleSoftware,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LibraryItem {
    pub source_id: String,
    pub title: String,
    pub url: String,
    #[serde(default)]
    pub share_url: String,
    #[serde(default)]
    pub size: String,
    #[serde(default)]
    pub time: String,
    #[serde(default)]
    pub icon_url: String,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub folder_id: String,
    #[serde(default)]
    pub is_folder: bool,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryFolder {
    pub source_id: String,
    pub kind: LibrarySourceKind,
    pub title: String,
    pub publisher: String,
    pub avatar_url: String,
    pub description: String,
    pub save_url: String,
    pub url: String,
    pub folder_id: String,
    pub page: u32,
    pub has_more: bool,
    pub next_page_ready_at_ms: u64,
    pub remote_search: bool,
    pub items: Vec<LibraryItem>,
    #[serde(skip)]
    pub(crate) api_folder_count: usize,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LibrarySearchOptions {
    pub concurrency: usize,
    pub source_switch_delay_ms: u64,
    pub until_last_page: bool,
    pub max_pages: u32,
}

impl Default for LibrarySearchOptions {
    fn default() -> Self {
        Self {
            concurrency: default_concurrency(),
            source_switch_delay_ms: default_source_switch_delay_ms(),
            until_last_page: default_until_last_page(),
            max_pages: 0,
        }
    }
}

impl LibrarySearchOptions {
    pub(crate) fn normalized(mut self) -> Self {
        self.concurrency = self.concurrency.clamp(1, MAX_LOGICAL_SEARCH_SOURCES);
        if self.source_switch_delay_ms != 0 {
            self.source_switch_delay_ms = self.source_switch_delay_ms.clamp(1_000, 60_000);
        }
        self.max_pages = self.max_pages.min(1_000);
        self
    }

    pub(crate) fn page_limit(&self) -> u32 {
        if !self.until_last_page {
            1
        } else if self.max_pages == 0 {
            1_000
        } else {
            self.max_pages
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibrarySourceStatus {
    pub source_id: String,
    pub title: String,
    pub found: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibrarySearchResult {
    pub items: Vec<LibraryItem>,
    pub sources: Vec<LibrarySourceStatus>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryProbeResult {
    pub source: PublicLibrarySource,
    pub folder: LibraryFolder,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryCollectResult {
    pub files: Vec<LibraryItem>,
    pub folders_scanned: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryResolved {
    pub url: String,
    pub file_name: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryDownloadResult {
    pub path: String,
    pub file_name: String,
    pub bytes_written: u64,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryDescription {
    pub description: String,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowseRequest {
    pub source_id: String,
    pub share_url: String,
    #[serde(default)]
    pub password: String,
    #[serde(default = "first_page")]
    pub page: u32,
    #[serde(default)]
    pub refresh: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_output_models_never_serialize_source_password() {
        let source: LibrarySource = serde_json::from_str(
            r#"{"sourceId":"one","title":"库","shareUrl":"https://www.lanzouw.com/b1","password":"never-print-me"}"#,
        )
        .unwrap();
        let output = PublicLibrarySource {
            source_id: source.source_id,
            title: source.title,
            share_url: source.share_url,
            searchable: true,
            kind: LibrarySourceKind::Directory,
        };
        let json = serde_json::to_string(&output).unwrap();
        assert!(!json.contains("never-print-me"));
        assert!(!json.to_ascii_lowercase().contains("password"));
    }

    #[test]
    fn test_search_options_keep_zero_as_rotation_disabled() {
        let options = LibrarySearchOptions {
            concurrency: 100,
            source_switch_delay_ms: 0,
            until_last_page: true,
            max_pages: 2_000,
        }
        .normalized();
        assert_eq!(options.concurrency, 100);
        assert_eq!(options.source_switch_delay_ms, 0);
        assert_eq!(options.max_pages, 1_000);
    }

    #[test]
    fn test_search_options_cap_logical_sources_without_shrinking_to_http_pool() {
        let options = LibrarySearchOptions {
            concurrency: usize::MAX,
            ..LibrarySearchOptions::default()
        }
        .normalized();
        assert_eq!(options.concurrency, 4_096);
        assert_eq!(options.source_switch_delay_ms, 0);
    }
}
