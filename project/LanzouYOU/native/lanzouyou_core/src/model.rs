use serde::{Deserialize, Serialize};

use crate::library::{
    AndroidRepackageRequest, CatalogItemRef, CategoryDraft, CompositeDraft, LibraryItem,
    LibrarySearchOptions, LibrarySource, LinkPreference, SourceDraft, SourceUpdateDraft,
    WindowsRepackageRequest,
};

fn root_id() -> String {
    "-1".to_owned()
}

fn first_page() -> u32 {
    1
}

fn default_page_size() -> u32 {
    50
}

fn all_category() -> String {
    "all".to_owned()
}

fn default_event_batch_limit() -> usize {
    8
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Command {
    Login {
        account: String,
        password: String,
    },
    RestoreSession {
        cookie: String,
    },
    Logout,
    SessionInfo,
    List {
        #[serde(default = "root_id")]
        folder_id: String,
        #[serde(default = "first_page")]
        page: u32,
        #[serde(default = "default_page_size")]
        page_size: u32,
    },
    MoveTargets,
    Mkdir {
        #[serde(default = "root_id")]
        parent_id: String,
        name: String,
        #[serde(default)]
        description: String,
    },
    Rename {
        id: String,
        is_folder: bool,
        name: String,
    },
    Move {
        id: String,
        is_folder: bool,
        #[serde(default = "root_id")]
        target_id: String,
    },
    Delete {
        id: String,
        is_folder: bool,
    },
    ShareInfo {
        id: String,
        is_folder: bool,
    },
    GetDescription {
        id: String,
        is_folder: bool,
    },
    AccountCapabilities,
    SetPassword {
        id: String,
        is_folder: bool,
        #[serde(default)]
        password: String,
    },
    SetDescription {
        id: String,
        is_folder: bool,
        #[serde(default)]
        description: String,
    },
    Upload {
        #[serde(default = "root_id")]
        folder_id: String,
        path: String,
        #[serde(default)]
        compat_wrap: bool,
        #[serde(default)]
        kind: UploadKind,
        #[serde(default)]
        operation_id: Option<String>,
    },
    UploadDirectory {
        #[serde(default = "root_id")]
        folder_id: String,
        path: String,
        #[serde(default)]
        compat_wrap: bool,
        #[serde(default)]
        kind: UploadKind,
        #[serde(default)]
        auto_apk_icons: bool,
        #[serde(default)]
        operation_id: Option<String>,
    },
    PrepareIcon {
        source_path: String,
        #[serde(default)]
        output_path: Option<String>,
    },
    SetIcon {
        file_id: String,
        path: String,
    },
    ReplaceFile {
        old_file_id: String,
        #[serde(default = "root_id")]
        folder_id: String,
        path: String,
        #[serde(default)]
        compat_wrap: bool,
        #[serde(default)]
        icon_path: Option<String>,
        #[serde(default)]
        operation_id: Option<String>,
    },
    Download {
        id: String,
        #[serde(default)]
        name: Option<String>,
        destination: String,
        #[serde(default)]
        operation_id: Option<String>,
    },
    Copy {
        id: String,
        is_folder: bool,
        name: String,
        #[serde(default = "root_id")]
        target_id: String,
        temp_dir: String,
    },
    RecycleList,
    RecycleRestore {
        id: String,
        is_folder: bool,
    },
    RecyclePurge {
        id: String,
        is_folder: bool,
    },
    RecycleEmpty,
    AppUpdateCheck {
        current_version: String,
        #[serde(default)]
        prefer_mirror: bool,
    },
    RuntimeCapabilities,
    LibraryImportVerificationCookie {
        url: String,
        cookie: String,
    },
    OperationStatus {
        operation_id: String,
    },
    OperationPause {
        operation_id: String,
    },
    OperationResume {
        operation_id: String,
    },
    OperationCancel {
        operation_id: String,
    },
    OperationForget {
        operation_id: String,
    },
    SourceRegistrySnapshot {
        storage_root: String,
    },
    SourceRegistryPage {
        storage_root: String,
        #[serde(default)]
        cursor: String,
        #[serde(default)]
        limit: usize,
        #[serde(default)]
        query: String,
        #[serde(default = "all_category")]
        category_id: String,
        #[serde(default = "all_category")]
        kind: String,
        #[serde(default)]
        searchable: Option<bool>,
        #[serde(default)]
        child_directory: Option<bool>,
        #[serde(default)]
        built_in: Option<bool>,
    },
    SourceRegistryImportPreview {
        storage_root: String,
        expected_generation: u64,
        raw_text: String,
        #[serde(default)]
        category_id: String,
    },
    SourceRegistryCommitImportPreview {
        storage_root: String,
        expected_generation: u64,
        preview_id: String,
    },
    SourceRegistryBatchImportText {
        storage_root: String,
        expected_generation: u64,
        raw_text: String,
        #[serde(default)]
        category_id: String,
    },
    SourceRegistryBatchImport {
        storage_root: String,
        expected_generation: u64,
        sources: Vec<SourceDraft>,
    },
    SourceRegistryRetest {
        storage_root: String,
        expected_generation: u64,
        source_ids: Vec<String>,
    },
    SourceRegistryUpdateSource {
        storage_root: String,
        expected_generation: u64,
        update: SourceUpdateDraft,
    },
    SourceRegistryDeleteSources {
        storage_root: String,
        expected_generation: u64,
        source_ids: Vec<String>,
    },
    SourceRegistryCategoryUpsert {
        storage_root: String,
        expected_generation: u64,
        category: CategoryDraft,
    },
    SourceRegistryCategoryDelete {
        storage_root: String,
        expected_generation: u64,
        category_id: String,
    },
    SourceRegistryCategorySetMembers {
        storage_root: String,
        expected_generation: u64,
        category_id: String,
        source_ids: Vec<String>,
    },
    SourceRegistryCompositeUpsert {
        storage_root: String,
        expected_generation: u64,
        composite: CompositeDraft,
    },
    SourceRegistryCompositeDelete {
        storage_root: String,
        expected_generation: u64,
        source_id: String,
    },
    SourceRegistryRulesImport {
        storage_root: String,
        expected_generation: u64,
        source_path: String,
    },
    SourceRegistryRulesFetchImport {
        storage_root: String,
        expected_generation: u64,
        rules_url: String,
    },
    SourceRegistryRulesExport {
        storage_root: String,
        expected_generation: u64,
        destination_path: String,
        #[serde(default)]
        source_ids: Vec<String>,
        #[serde(default)]
        include_credentials: bool,
        #[serde(default)]
        credential_confirmation: String,
    },
    SourceRegistryRestoreBackup {
        storage_root: String,
        expected_generation: u64,
    },
    SourceRegistryRestoreOfficial {
        storage_root: String,
        expected_generation: u64,
    },
    SourceRegistryReset {
        storage_root: String,
        expected_generation: u64,
    },
    LinkTokenize {
        text: String,
    },
    LinkRoute {
        text: String,
        token_index: usize,
        preference: LinkPreference,
    },
    CatalogSummary {
        storage_root: String,
    },
    CatalogPage {
        storage_root: String,
        #[serde(default)]
        parent_id: String,
        #[serde(default = "all_category")]
        category_id: String,
        #[serde(default)]
        query: String,
        #[serde(default)]
        cursor: String,
        #[serde(default)]
        limit: usize,
    },
    CatalogBrowse {
        storage_root: String,
        #[serde(default)]
        node_id: String,
        #[serde(default)]
        item_ref: Option<CatalogItemRef>,
        #[serde(default = "first_page")]
        page: u32,
        #[serde(default)]
        refresh: bool,
    },
    CatalogSearch {
        storage_root: String,
        query: String,
        #[serde(default)]
        scope_ids: Vec<String>,
        #[serde(default)]
        options: LibrarySearchOptions,
        #[serde(default)]
        operation_id: Option<String>,
    },
    CatalogSearchStart {
        storage_root: String,
        operation_id: String,
        query: String,
        #[serde(default)]
        scope_ids: Vec<String>,
        #[serde(default)]
        options: LibrarySearchOptions,
    },
    CatalogSearchRead {
        operation_id: String,
        #[serde(default)]
        after_cursor: Option<String>,
        #[serde(default)]
        ack_cursor: Option<String>,
        #[serde(default = "default_event_batch_limit")]
        limit: usize,
    },
    CatalogSearchPause {
        operation_id: String,
    },
    CatalogSearchResume {
        operation_id: String,
    },
    CatalogSearchCancel {
        operation_id: String,
    },
    CatalogSearchForget {
        operation_id: String,
    },
    CatalogBrowseLink {
        storage_root: String,
        route_handle: String,
        #[serde(default = "first_page")]
        page: u32,
        #[serde(default)]
        refresh: bool,
    },
    CatalogDescribe {
        storage_root: String,
        #[serde(default)]
        node_id: String,
        #[serde(default)]
        item_ref: Option<CatalogItemRef>,
    },
    CatalogResolve {
        storage_root: String,
        #[serde(default)]
        node_id: String,
        #[serde(default)]
        item_ref: Option<CatalogItemRef>,
    },
    CatalogDownload {
        storage_root: String,
        #[serde(default)]
        node_id: String,
        #[serde(default)]
        item_ref: Option<CatalogItemRef>,
        destination_directory: String,
        #[serde(default)]
        operation_id: Option<String>,
    },
    LibraryProbe {
        source: LibrarySource,
    },
    LibraryBrowse {
        source_id: String,
        share_url: String,
        #[serde(default)]
        password: String,
        #[serde(default = "first_page")]
        page: u32,
        #[serde(default)]
        refresh: bool,
    },
    LibrarySearch {
        query: String,
        sources: Vec<LibrarySource>,
        #[serde(default)]
        options: LibrarySearchOptions,
        #[serde(default)]
        operation_id: Option<String>,
    },
    LibraryCollect {
        items: Vec<LibraryItem>,
        sources: Vec<LibrarySource>,
    },
    LibraryResolve {
        source_id: String,
        share_url: String,
        #[serde(default)]
        password: String,
    },
    LibraryDownload {
        source_id: String,
        share_url: String,
        #[serde(default)]
        password: String,
        destination_directory: String,
        #[serde(default)]
        operation_id: Option<String>,
    },
    LibraryDescribe {
        source_id: String,
        share_url: String,
        #[serde(default)]
        password: String,
    },
    LibraryReadDocument {
        share_url: String,
    },
    LibraryFetchAsset {
        url: String,
    },
    LibraryRepackageAndroid {
        #[serde(flatten)]
        request: AndroidRepackageRequest,
    },
    LibraryRepackageWindows {
        #[serde(flatten)]
        request: WindowsRepackageRequest,
    },
}

impl Command {
    pub(crate) fn is_library(&self) -> bool {
        matches!(
            self,
            Self::SourceRegistrySnapshot { .. }
                | Self::SourceRegistryPage { .. }
                | Self::SourceRegistryImportPreview { .. }
                | Self::SourceRegistryCommitImportPreview { .. }
                | Self::SourceRegistryBatchImportText { .. }
                | Self::SourceRegistryBatchImport { .. }
                | Self::SourceRegistryRetest { .. }
                | Self::SourceRegistryUpdateSource { .. }
                | Self::SourceRegistryDeleteSources { .. }
                | Self::SourceRegistryCategoryUpsert { .. }
                | Self::SourceRegistryCategoryDelete { .. }
                | Self::SourceRegistryCategorySetMembers { .. }
                | Self::SourceRegistryCompositeUpsert { .. }
                | Self::SourceRegistryCompositeDelete { .. }
                | Self::SourceRegistryRulesImport { .. }
                | Self::SourceRegistryRulesFetchImport { .. }
                | Self::SourceRegistryRulesExport { .. }
                | Self::SourceRegistryRestoreBackup { .. }
                | Self::SourceRegistryRestoreOfficial { .. }
                | Self::SourceRegistryReset { .. }
                | Self::LinkTokenize { .. }
                | Self::LinkRoute { .. }
                | Self::CatalogSummary { .. }
                | Self::CatalogPage { .. }
                | Self::CatalogBrowse { .. }
                | Self::CatalogSearch { .. }
                | Self::CatalogSearchStart { .. }
                | Self::CatalogSearchRead { .. }
                | Self::CatalogSearchPause { .. }
                | Self::CatalogSearchResume { .. }
                | Self::CatalogSearchCancel { .. }
                | Self::CatalogSearchForget { .. }
                | Self::CatalogBrowseLink { .. }
                | Self::CatalogDescribe { .. }
                | Self::CatalogResolve { .. }
                | Self::CatalogDownload { .. }
                | Self::LibraryProbe { .. }
                | Self::LibraryBrowse { .. }
                | Self::LibrarySearch { .. }
                | Self::LibraryCollect { .. }
                | Self::LibraryResolve { .. }
                | Self::LibraryDownload { .. }
                | Self::LibraryDescribe { .. }
                | Self::LibraryReadDocument { .. }
                | Self::LibraryFetchAsset { .. }
                | Self::LibraryRepackageAndroid { .. }
                | Self::LibraryRepackageWindows { .. }
        )
    }
}

#[derive(Debug, Default, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UploadKind {
    #[default]
    Auto,
    File,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudItem {
    pub id: String,
    pub name: String,
    pub is_folder: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub has_password: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub downloads: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub has_custom_icon: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_url: Option<String>,
    pub is_recycle: bool,
}

impl CloudItem {
    pub fn folder(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            is_folder: true,
            size: None,
            modified_at: None,
            description: None,
            has_password: None,
            downloads: None,
            path: None,
            has_custom_icon: None,
            icon_url: None,
            is_recycle: false,
        }
    }

    pub fn file(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            is_folder: false,
            ..Self::folder(id, name)
        }
    }
}

#[derive(Debug, Clone)]
pub struct ShareRecord {
    pub name: String,
    pub url: String,
    pub password: String,
    pub description: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ManagedMetadata {
    pub name: String,
    pub description: String,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CopySummary {
    pub files: u64,
    pub folders: u64,
    pub bytes: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_command_schema_accepts_every_operation() {
        let commands = [
            r#"{"op":"login","account":"a","password":"p"}"#,
            r#"{"op":"restore_session","cookie":"a=b"}"#,
            r#"{"op":"logout"}"#,
            r#"{"op":"session_info"}"#,
            r#"{"op":"list","folderId":"-1","page":1,"pageSize":50}"#,
            r#"{"op":"move_targets"}"#,
            r#"{"op":"mkdir","parentId":"-1","name":"n","description":"d"}"#,
            r#"{"op":"rename","id":"1","isFolder":false,"name":"n"}"#,
            r#"{"op":"move","id":"1","isFolder":false,"targetId":"-1"}"#,
            r#"{"op":"delete","id":"1","isFolder":false}"#,
            r#"{"op":"share_info","id":"1","isFolder":false}"#,
            r#"{"op":"get_description","id":"1","isFolder":false}"#,
            r#"{"op":"account_capabilities"}"#,
            r#"{"op":"set_password","id":"1","isFolder":false,"password":"12"}"#,
            r#"{"op":"set_description","id":"1","isFolder":false,"description":"d"}"#,
            r#"{"op":"upload","folderId":"-1","path":"x","compatWrap":true,"kind":"file","operationId":"upload-1"}"#,
            r#"{"op":"prepare_icon","sourcePath":"x.apk","outputPath":"x.png"}"#,
            r#"{"op":"set_icon","fileId":"1","path":"x.png"}"#,
            r#"{"op":"replace_file","oldFileId":"1","folderId":"-1","path":"new.apk","compatWrap":false,"iconPath":"new.png","operationId":"replace-1"}"#,
            r#"{"op":"download","id":"1","name":"n","destination":"x","operationId":"download-1"}"#,
            r#"{"op":"copy","id":"1","isFolder":false,"name":"n","targetId":"-1","tempDir":"x"}"#,
            r#"{"op":"recycle_list"}"#,
            r#"{"op":"recycle_restore","id":"1","isFolder":false}"#,
            r#"{"op":"recycle_purge","id":"1","isFolder":false}"#,
            r#"{"op":"recycle_empty"}"#,
            r#"{"op":"operation_status","operationId":"upload-1"}"#,
            r#"{"op":"operation_cancel","operationId":"upload-1"}"#,
            r#"{"op":"operation_forget","operationId":"upload-1"}"#,
            r#"{"op":"source_registry_snapshot","storageRoot":"D:\\data"}"#,
            r#"{"op":"source_registry_page","storageRoot":"D:\\data","cursor":"","limit":100,"query":"tool","categoryId":"all","kind":"official","searchable":true,"childDirectory":false,"builtIn":false}"#,
            r#"{"op":"source_registry_import_preview","storageRoot":"D:\\data","expectedGeneration":0,"rawText":"https://www.lanzouw.com/b1 code","categoryId":""}"#,
            r#"{"op":"source_registry_commit_import_preview","storageRoot":"D:\\data","expectedGeneration":0,"previewId":"preview:one"}"#,
            r#"{"op":"source_registry_batch_import_text","storageRoot":"D:\\data","expectedGeneration":0,"rawText":"https://www.lanzouw.com/b1 code","categoryId":""}"#,
            r#"{"op":"source_registry_batch_import","storageRoot":"D:\\data","expectedGeneration":0,"sources":[{"title":"Tools","url":"https://www.lanzouw.com/b1","password":"code","searchable":true,"categoryId":""}]}"#,
            r#"{"op":"source_registry_retest","storageRoot":"D:\\data","expectedGeneration":1,"sourceIds":["https://www.lanzouw.com/b1"]}"#,
            r#"{"op":"source_registry_update_source","storageRoot":"D:\\data","expectedGeneration":1,"update":{"sourceId":"https://www.lanzouw.com/b1","title":"Tools","searchable":true,"accessCode":"new"}}"#,
            r#"{"op":"source_registry_delete_sources","storageRoot":"D:\\data","expectedGeneration":1,"sourceIds":["https://www.lanzouw.com/b1"]}"#,
            r#"{"op":"source_registry_category_upsert","storageRoot":"D:\\data","expectedGeneration":1,"category":{"id":"tools","title":"Tools","sourceIds":[]}}"#,
            r#"{"op":"source_registry_category_delete","storageRoot":"D:\\data","expectedGeneration":2,"categoryId":"tools"}"#,
            r#"{"op":"source_registry_category_set_members","storageRoot":"D:\\data","expectedGeneration":2,"categoryId":"tools","sourceIds":[]}"#,
            r#"{"op":"source_registry_composite_upsert","storageRoot":"D:\\data","expectedGeneration":2,"composite":{"id":"","title":"Bundle","publisher":"Publisher","avatarUrl":"","description":"","members":[{"kind":"file","url":"https://www.lanzouw.com/f1"},{"kind":"file","url":"https://www.lanzouw.com/f2"}]}}"#,
            r#"{"op":"source_registry_composite_delete","storageRoot":"D:\\data","expectedGeneration":3,"sourceId":"local:bundle"}"#,
            r#"{"op":"source_registry_rules_import","storageRoot":"D:\\data","expectedGeneration":3,"sourcePath":"D:\\rules.json"}"#,
            r#"{"op":"source_registry_rules_fetch_import","storageRoot":"D:\\data","expectedGeneration":3,"rulesUrl":"https://rules.example/sources.json"}"#,
            r#"{"op":"source_registry_rules_export","storageRoot":"D:\\data","expectedGeneration":3,"destinationPath":"D:\\rules.json","sourceIds":[],"includeCredentials":true,"credentialConfirmation":"export-source-access-codes"}"#,
            r#"{"op":"source_registry_restore_backup","storageRoot":"D:\\data","expectedGeneration":4}"#,
            r#"{"op":"source_registry_restore_official","storageRoot":"D:\\data","expectedGeneration":4}"#,
            r#"{"op":"source_registry_reset","storageRoot":"D:\\data","expectedGeneration":4}"#,
            r#"{"op":"catalog_summary","storageRoot":"D:\\data"}"#,
            r#"{"op":"catalog_page","storageRoot":"D:\\data","parentId":"","categoryId":"all","query":"工具","cursor":"","limit":100}"#,
            r#"{"op":"catalog_browse","storageRoot":"D:\\data","nodeId":"remote:one","page":1,"refresh":true}"#,
            r#"{"op":"catalog_search","storageRoot":"D:\\data","query":"工具","scopeIds":["local:one"],"options":{},"operationId":"catalog-search-1"}"#,
            r#"{"op":"catalog_describe","storageRoot":"D:\\data","itemRef":{"sourceId":"opaque","title":"工具.apk","url":"https://www.lanzouw.com/a","shareUrl":"https://www.lanzouw.com/a","folderId":"","isFolder":false}}"#,
            r#"{"op":"catalog_resolve","storageRoot":"D:\\data","nodeId":"file:one"}"#,
            r#"{"op":"catalog_download","storageRoot":"D:\\data","nodeId":"file:one","destinationDirectory":"downloads","operationId":"catalog-download-1"}"#,
            r#"{"op":"library_probe","source":{"sourceId":"s1","title":"库","shareUrl":"https://www.lanzouw.com/b1","password":"p"}}"#,
            r#"{"op":"library_browse","sourceId":"s1","shareUrl":"https://www.lanzouw.com/b1","password":"p","page":1,"refresh":true}"#,
            r#"{"op":"library_search","query":"工具","sources":[{"sourceId":"s1","title":"库","shareUrl":"https://www.lanzouw.com/b1","password":"p"}],"options":{"untilLastPage":true,"maxPages":3},"operationId":"search-1"}"#,
            r#"{"op":"library_collect","items":[{"sourceId":"s1","title":"工具.apk","url":"https://www.lanzouw.com/a","isFolder":false}],"sources":[{"sourceId":"s1","title":"库","shareUrl":"https://www.lanzouw.com/b1","password":"p"}]}"#,
            r#"{"op":"library_resolve","sourceId":"s1","shareUrl":"https://www.lanzouw.com/a","password":"p"}"#,
            r#"{"op":"library_download","sourceId":"s1","shareUrl":"https://www.lanzouw.com/a","password":"p","destinationDirectory":"downloads","operationId":"library-download-1"}"#,
            r#"{"op":"library_describe","sourceId":"s1","shareUrl":"https://www.lanzouw.com/a","password":"p"}"#,
            r#"{"op":"library_read_document","shareUrl":"https://docs.example/readme.txt"}"#,
            r#"{"op":"library_fetch_asset","url":"https://image.dmpdmp.com/image/icon.png"}"#,
            r#"{"op":"library_repackage_android","templatePath":"shell.apk","outputPath":"out.apk","runtimeConfig":{"schemaVersion":1,"identity":{"displayName":"库","applicationId":"cc.nkbr.library","versionName":"1.0.0","versionCode":1,"windowsExeName":"my-library"}},"iconPath":"icon.png","signingIdentityPath":"private/identity.bin"}"#,
            r#"{"op":"library_repackage_windows","templatePath":"shell.zip","outputPath":"out.zip","runtimeConfig":{"schemaVersion":1,"identity":{"displayName":"库","applicationId":"cc.nkbr.library","versionName":"1.0.0","versionCode":1,"windowsExeName":"my-library"}},"iconPath":"icon.png"}"#,
        ];
        for command in commands {
            assert!(
                serde_json::from_str::<Command>(command).is_ok(),
                "schema rejected: {command}"
            );
        }
    }

    #[test]
    fn test_source_registry_nested_requests_deny_unknown_fields() {
        let source = r#"{"op":"source_registry_batch_import","storageRoot":"D:\\data","expectedGeneration":0,"sources":[{"title":"Tools","url":"https://www.lanzouw.com/b1","password":"","searchable":true,"categoryId":"","legacy":true}]}"#;
        let category = r#"{"op":"source_registry_category_upsert","storageRoot":"D:\\data","expectedGeneration":0,"category":{"id":"tools","title":"Tools","sourceIds":[],"legacy":true}}"#;
        let composite = r#"{"op":"source_registry_composite_upsert","storageRoot":"D:\\data","expectedGeneration":0,"composite":{"id":"","title":"Bundle","publisher":"","avatarUrl":"","description":"","members":[{"kind":"file","url":"https://www.lanzouw.com/f1","legacy":true}]}}"#;

        for request in [source, category, composite] {
            assert!(
                serde_json::from_str::<Command>(request).is_err(),
                "{request}"
            );
        }
    }

    #[test]
    fn test_controllable_operations_keep_operation_id_optional() {
        let upload =
            serde_json::from_str::<Command>(r#"{"op":"upload","folderId":"-1","path":"x"}"#)
                .unwrap();
        let download =
            serde_json::from_str::<Command>(r#"{"op":"download","id":"1","destination":"x"}"#)
                .unwrap();
        let replace = serde_json::from_str::<Command>(
            r#"{"op":"replace_file","oldFileId":"1","folderId":"-1","path":"new.apk"}"#,
        )
        .unwrap();
        let search =
            serde_json::from_str::<Command>(r#"{"op":"library_search","query":"x","sources":[]}"#)
                .unwrap();
        let library_download = serde_json::from_str::<Command>(
            r#"{"op":"library_download","sourceId":"s1","shareUrl":"https://www.lanzouw.com/a","destinationDirectory":"downloads"}"#,
        )
        .unwrap();
        let catalog_search = serde_json::from_str::<Command>(
            r#"{"op":"catalog_search","storageRoot":"D:\\data","query":"x"}"#,
        )
        .unwrap();
        let catalog_download = serde_json::from_str::<Command>(
            r#"{"op":"catalog_download","storageRoot":"D:\\data","nodeId":"file:one","destinationDirectory":"downloads"}"#,
        )
        .unwrap();
        assert!(matches!(
            upload,
            Command::Upload {
                operation_id: None,
                ..
            }
        ));
        assert!(matches!(
            download,
            Command::Download {
                operation_id: None,
                ..
            }
        ));
        assert!(matches!(
            replace,
            Command::ReplaceFile {
                operation_id: None,
                ..
            }
        ));
        assert!(matches!(
            search,
            Command::LibrarySearch {
                operation_id: None,
                ..
            }
        ));
        assert!(matches!(
            library_download,
            Command::LibraryDownload {
                operation_id: None,
                ..
            }
        ));
        assert!(matches!(
            catalog_search,
            Command::CatalogSearch {
                operation_id: None,
                ..
            }
        ));
        assert!(matches!(
            catalog_download,
            Command::CatalogDownload {
                operation_id: None,
                ..
            }
        ));
    }
}
