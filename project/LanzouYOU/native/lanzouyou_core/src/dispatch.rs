use std::sync::Mutex;

use once_cell::sync::OnceCell;
use serde_json::{json, Value};

use crate::{
    error::{CoreError, CoreResult, Envelope},
    icon,
    library::LibraryService,
    model::Command,
    operation::{self, OperationHandle, OperationKind},
    session::SessionClient,
};

static SESSION: OnceCell<Mutex<SessionClient>> = OnceCell::new();
static LIBRARY: OnceCell<LibraryService> = OnceCell::new();

pub fn dispatch_json(request: &str) -> String {
    let envelope = match serde_json::from_str::<Command>(request) {
        Ok(command) => execute_global(command),
        Err(_) => Envelope::failure(CoreError::new(
            "invalid_request",
            "请求 JSON 或 op 无效",
            false,
        )),
    };
    serde_json::to_string(&envelope).unwrap_or_else(|_| {
        r#"{"ok":false,"data":null,"error":{"code":"internal_error","message":"响应序列化失败","retriable":false}}"#.to_owned()
    })
}

fn execute_global(command: Command) -> Envelope {
    let control = match &command {
        Command::OperationStatus { operation_id } => Some(operation::status(operation_id)),
        Command::OperationCancel { operation_id } => Some(operation::cancel(operation_id)),
        Command::OperationForget { operation_id } => Some(operation::forget(operation_id)),
        _ => None,
    };
    if let Some(result) = control {
        return envelope(result);
    }

    let operation = match operation_for_command(&command) {
        Ok(operation) => operation,
        Err(error) => return Envelope::failure(error),
    };
    let result = execute_global_operation(command, operation.as_ref());
    if let Some(operation) = &operation {
        operation.finish_result(&result);
    }
    envelope(result)
}

fn execute_global_operation(
    command: Command,
    operation: Option<&OperationHandle>,
) -> CoreResult<Value> {
    if command.is_library() {
        return LIBRARY
            .get_or_init(LibraryService::new)
            .execute(command, operation);
    }
    let session = SESSION.get_or_try_init(|| SessionClient::new().map(Mutex::new))?;
    let mut session = session
        .lock()
        .map_err(|_| CoreError::new("internal_error", "会话状态锁已损坏", false))?;
    let result = execute(&mut session, command, operation);
    if let Err(error) = &result {
        if error.code == "session_expired" {
            session.clear();
        }
    }
    result
}

fn operation_for_command(command: &Command) -> CoreResult<Option<OperationHandle>> {
    match command {
        Command::Upload { operation_id, .. } => {
            operation::begin(operation_id.as_deref(), OperationKind::Upload)
        }
        Command::UploadDirectory { operation_id, .. } => {
            operation::begin(operation_id.as_deref(), OperationKind::DirectoryUpload)
        }
        Command::ReplaceFile { operation_id, .. } => {
            operation::begin(operation_id.as_deref(), OperationKind::ReplaceFile)
        }
        Command::Download { operation_id, .. } | Command::LibraryDownload { operation_id, .. } => {
            operation::begin(operation_id.as_deref(), OperationKind::Download)
        }
        Command::LibrarySearch { operation_id, .. } => {
            operation::begin(operation_id.as_deref(), OperationKind::LibrarySearch)
        }
        Command::CatalogSearch { operation_id, .. } => {
            operation::begin(operation_id.as_deref(), OperationKind::LibrarySearch)
        }
        Command::CatalogDownload { operation_id, .. } => {
            operation::begin(operation_id.as_deref(), OperationKind::Download)
        }
        _ => Ok(None),
    }
}

fn envelope(result: CoreResult<Value>) -> Envelope {
    match result {
        Ok(data) => Envelope::success(data),
        Err(error) => Envelope::failure(error),
    }
}

pub(crate) fn execute(
    session: &mut SessionClient,
    command: Command,
    operation: Option<&OperationHandle>,
) -> CoreResult<Value> {
    match command {
        Command::Login { account, password } => session.login(&account, &password),
        Command::RestoreSession { cookie } => session.restore(&cookie),
        Command::Logout => session.logout(),
        Command::SessionInfo => Ok(session.session_info()),
        Command::List {
            folder_id,
            page,
            page_size,
        } => session.list(&folder_id, page, page_size),
        Command::MoveTargets => session.move_targets(),
        Command::Mkdir {
            parent_id,
            name,
            description,
        } => session.mkdir(&parent_id, &name, &description),
        Command::Rename {
            id,
            is_folder,
            name,
        } => session.rename(&id, is_folder, &name),
        Command::Move {
            id,
            is_folder,
            target_id,
        } => session.move_item(&id, is_folder, &target_id),
        Command::Delete { id, is_folder } => session.delete(&id, is_folder),
        Command::ShareInfo { id, is_folder } => session.share_info(&id, is_folder),
        Command::GetDescription { id, is_folder } => session.get_description(&id, is_folder),
        Command::AccountCapabilities => session.account_capabilities(),
        Command::SetPassword {
            id,
            is_folder,
            password,
        } => session.set_password(&id, is_folder, &password),
        Command::SetDescription {
            id,
            is_folder,
            description,
        } => session.set_description(&id, is_folder, &description),
        Command::Upload {
            folder_id,
            path,
            compat_wrap,
            kind,
            operation_id: _,
        } => session.upload_with_operation(&folder_id, &path, compat_wrap, kind, operation),
        Command::UploadDirectory {
            folder_id,
            path,
            compat_wrap,
            kind,
            auto_apk_icons,
            operation_id: _,
        } => session.upload_directory(
            &folder_id,
            &path,
            compat_wrap,
            kind,
            auto_apk_icons,
            operation,
        ),
        Command::PrepareIcon {
            source_path,
            output_path,
        } => icon::prepare_icon(&source_path, output_path.as_deref()),
        Command::SetIcon { file_id, path } => session.set_icon(&file_id, &path),
        Command::ReplaceFile {
            old_file_id,
            folder_id,
            path,
            compat_wrap,
            icon_path,
            operation_id: _,
        } => session.replace_file(
            &old_file_id,
            &folder_id,
            &path,
            compat_wrap,
            icon_path.as_deref(),
            operation,
        ),
        Command::Download {
            id,
            name,
            destination,
            operation_id: _,
        } => match operation {
            Some(operation) => {
                session.download_with_operation(&id, name.as_deref(), &destination, Some(operation))
            }
            None => session.download(&id, name.as_deref(), &destination),
        },
        Command::Copy {
            id,
            is_folder,
            name,
            target_id,
            temp_dir,
        } => session.copy_item(&id, is_folder, &name, &target_id, &temp_dir),
        Command::RecycleList => session.recycle_list(),
        Command::RecycleRestore { id, is_folder } => session.recycle_action(&id, is_folder, false),
        Command::RecyclePurge { id, is_folder } => session.recycle_action(&id, is_folder, true),
        Command::RecycleEmpty => session.recycle_empty(),
        Command::SourceRegistrySnapshot { .. }
        | Command::SourceRegistryPage { .. }
        | Command::SourceRegistryImportPreview { .. }
        | Command::SourceRegistryCommitImportPreview { .. }
        | Command::SourceRegistryBatchImportText { .. }
        | Command::SourceRegistryBatchImport { .. }
        | Command::SourceRegistryRetest { .. }
        | Command::SourceRegistryUpdateSource { .. }
        | Command::SourceRegistryDeleteSources { .. }
        | Command::SourceRegistryCategoryUpsert { .. }
        | Command::SourceRegistryCategoryDelete { .. }
        | Command::SourceRegistryCategorySetMembers { .. }
        | Command::SourceRegistryCompositeUpsert { .. }
        | Command::SourceRegistryCompositeDelete { .. }
        | Command::SourceRegistryRulesImport { .. }
        | Command::SourceRegistryRulesFetchImport { .. }
        | Command::SourceRegistryRulesExport { .. }
        | Command::SourceRegistryRestoreBackup { .. }
        | Command::SourceRegistryRestoreOfficial { .. }
        | Command::SourceRegistryReset { .. }
        | Command::LinkTokenize { .. }
        | Command::LinkRoute { .. }
        | Command::CatalogSummary { .. }
        | Command::CatalogPage { .. }
        | Command::CatalogBrowse { .. }
        | Command::CatalogSearch { .. }
        | Command::CatalogSearchStart { .. }
        | Command::CatalogSearchRead { .. }
        | Command::CatalogSearchPause { .. }
        | Command::CatalogSearchResume { .. }
        | Command::CatalogSearchCancel { .. }
        | Command::CatalogSearchForget { .. }
        | Command::CatalogBrowseLink { .. }
        | Command::CatalogDescribe { .. }
        | Command::CatalogResolve { .. }
        | Command::CatalogDownload { .. }
        | Command::LibraryProbe { .. }
        | Command::LibraryBrowse { .. }
        | Command::LibrarySearch { .. }
        | Command::LibraryCollect { .. }
        | Command::LibraryResolve { .. }
        | Command::LibraryDownload { .. }
        | Command::LibraryDescribe { .. }
        | Command::LibraryFetchAsset { .. }
        | Command::LibraryRepackageAndroid { .. }
        | Command::LibraryRepackageWindows { .. } => {
            return Err(CoreError::invalid("公共软件库命令必须由独立会话执行"))
        }
        Command::OperationStatus { .. }
        | Command::OperationCancel { .. }
        | Command::OperationForget { .. } => {
            return Err(CoreError::invalid("操作控制命令必须在会话锁外执行"))
        }
    }
    .map(|value| if value.is_null() { json!({}) } else { value })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_execute_session_info_has_no_cookie() {
        let mut session = SessionClient::for_test("http://127.0.0.1:9".to_owned()).unwrap();
        session.cookie = "secret=value".to_owned();
        session.uid = "123".to_owned();
        let value = execute(&mut session, Command::SessionInfo, None).unwrap();
        assert_eq!(value["authenticated"], true);
        assert!(value.get("cookie").is_none());
    }

    #[test]
    fn test_operation_controls_are_available_without_session_lock() {
        let operation = operation::begin(Some("dispatch-control-test"), OperationKind::Download)
            .unwrap()
            .unwrap();
        let session = SESSION
            .get_or_try_init(|| SessionClient::new().map(Mutex::new))
            .unwrap();
        let session_guard = session.lock().unwrap();
        let (sender, receiver) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let status =
                dispatch_json(r#"{"op":"operation_status","operationId":"dispatch-control-test"}"#);
            let cancelled =
                dispatch_json(r#"{"op":"operation_cancel","operationId":"dispatch-control-test"}"#);
            sender.send((status, cancelled)).unwrap();
        });

        let (status, cancelled) = receiver
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("control operations must not wait for the session mutex");
        let status: Value = serde_json::from_str(&status).unwrap();
        assert_eq!(status["ok"], true);
        assert_eq!(status["data"]["state"], "running");

        let cancelled: Value = serde_json::from_str(&cancelled).unwrap();
        assert_eq!(cancelled["data"]["state"], "cancelling");
        assert_eq!(operation.check_cancelled().unwrap_err().code, "cancelled");
        operation.finish_cancelled();
        drop(session_guard);
        worker.join().unwrap();

        let forgotten: Value = serde_json::from_str(&dispatch_json(
            r#"{"op":"operation_forget","operationId":"dispatch-control-test"}"#,
        ))
        .unwrap();
        assert_eq!(forgotten["data"]["forgotten"], true);
    }

    #[test]
    fn test_library_download_uses_real_download_operation_kind() {
        let command = serde_json::from_str::<Command>(
            r#"{"op":"library_download","sourceId":"source-one","shareUrl":"https://www.lanzouw.com/file","destinationDirectory":"downloads","operationId":"library-download-routing-test"}"#,
        )
        .unwrap();

        let operation = operation_for_command(&command).unwrap().unwrap();
        let status = operation::status("library-download-routing-test").unwrap();

        assert_eq!(status["kind"], "download");
        operation.finish_success();
        operation::forget("library-download-routing-test").unwrap();
    }

    #[test]
    fn test_library_download_dispatch_finishes_failed_operation_without_echoing_secrets() {
        let response = dispatch_json(
            r#"{"op":"library_download","sourceId":"source-one","shareUrl":"https://www.lanzouw.com/file","password":"never-echo-this","destinationDirectory":"relative","operationId":"library-download-failure-test"}"#,
        );
        let value: Value = serde_json::from_str(&response).unwrap();

        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "invalid_argument");
        assert!(!response.contains("never-echo-this"));
        assert!(!response.contains("https://www.lanzouw.com/file"));
        let status = operation::status("library-download-failure-test").unwrap();
        assert_eq!(status["kind"], "download");
        assert_eq!(status["state"], "failed");
        operation::forget("library-download-failure-test").unwrap();
    }

    #[test]
    fn test_catalog_summary_and_page_dispatch_are_bounded_and_password_free() {
        let summary_raw = dispatch_json(r#"{"op":"catalog_summary"}"#);
        let summary: Value = serde_json::from_str(&summary_raw).unwrap();
        assert_eq!(summary["ok"], true);
        assert_eq!(summary["data"]["officialCount"], 597);
        assert_eq!(summary["data"]["compositeCount"], 9);
        assert_eq!(summary["data"]["nodeCount"], 3_370);

        let page_raw = dispatch_json(r#"{"op":"catalog_page","limit":200}"#);
        let page: Value = serde_json::from_str(&page_raw).unwrap();
        assert_eq!(page["ok"], true);
        assert_eq!(page["data"]["total"], 606);
        assert_eq!(page["data"]["nodes"].as_array().unwrap().len(), 200);
        assert_eq!(page["data"]["hasMore"], true);

        let combined = format!("{summary_raw}{page_raw}").to_ascii_lowercase();
        for forbidden in ["password", "accesscode", "cookie", "secret"] {
            assert!(!combined.contains(forbidden), "leaked key: {forbidden}");
        }
    }

    #[test]
    fn test_source_registry_dispatch_preview_commit_and_filtered_page_are_password_free() {
        let root = tempfile::tempdir_in(std::env::temp_dir()).unwrap();
        let storage_root = root.path().display().to_string();
        let snapshot_raw = dispatch_json(
            &serde_json::json!({
                "op": "source_registry_snapshot",
                "storageRoot": storage_root,
            })
            .to_string(),
        );
        let snapshot: Value = serde_json::from_str(&snapshot_raw).unwrap();
        assert_eq!(snapshot["ok"], true);
        assert_eq!(snapshot["data"]["baselineCount"], 606);

        let preview_raw = dispatch_json(
            &serde_json::json!({
                "op": "source_registry_import_preview",
                "storageRoot": storage_root,
                "expectedGeneration": 0,
                "rawText": "https://www.lanzouw.com/dispatch-source private-code",
                "categoryId": "",
            })
            .to_string(),
        );
        let preview: Value = serde_json::from_str(&preview_raw).unwrap();
        assert_eq!(preview["ok"], true);
        assert_eq!(preview["data"]["valid"].as_array().unwrap().len(), 1);
        assert!(!preview_raw.contains("private-code"));
        let preview_id = preview["data"]["previewId"].as_str().unwrap();

        let commit_raw = dispatch_json(
            &serde_json::json!({
                "op": "source_registry_commit_import_preview",
                "storageRoot": storage_root,
                "expectedGeneration": 0,
                "previewId": preview_id,
            })
            .to_string(),
        );
        let commit: Value = serde_json::from_str(&commit_raw).unwrap();
        assert_eq!(commit["ok"], true);
        assert_eq!(commit["data"]["generation"], 1);

        let page_raw = dispatch_json(
            &serde_json::json!({
                "op": "source_registry_page",
                "storageRoot": storage_root,
                "query": "dispatch-source",
                "categoryId": "all",
                "kind": "official",
                "searchable": true,
                "builtIn": false,
                "limit": 100,
            })
            .to_string(),
        );
        let page: Value = serde_json::from_str(&page_raw).unwrap();
        assert_eq!(page["ok"], true);
        assert_eq!(page["data"]["total"], 1);
        let combined =
            format!("{snapshot_raw}{preview_raw}{commit_raw}{page_raw}").to_ascii_lowercase();
        for forbidden in ["password", "accesscode", "cookie", "private-code"] {
            assert!(
                !combined.contains(forbidden),
                "leaked key/value: {forbidden}"
            );
        }
    }

    #[test]
    fn test_catalog_operations_use_shared_search_download_registry_kinds() {
        let search = serde_json::from_str::<Command>(
            r#"{"op":"catalog_search","query":"tool","operationId":"catalog-search-kind"}"#,
        )
        .unwrap();
        let search_operation = operation_for_command(&search).unwrap().unwrap();
        assert_eq!(
            operation::status("catalog-search-kind").unwrap()["kind"],
            "library_search"
        );
        search_operation.finish_success();
        operation::forget("catalog-search-kind").unwrap();

        let download = serde_json::from_str::<Command>(
            r#"{"op":"catalog_download","nodeId":"opaque","destinationDirectory":"downloads","operationId":"catalog-download-kind"}"#,
        )
        .unwrap();
        let download_operation = operation_for_command(&download).unwrap().unwrap();
        assert_eq!(
            operation::status("catalog-download-kind").unwrap()["kind"],
            "download"
        );
        download_operation.finish_success();
        operation::forget("catalog-download-kind").unwrap();
    }

    #[test]
    fn test_catalog_item_reference_rejects_credential_fields_without_echoing_them() {
        let response = dispatch_json(
            r#"{"op":"catalog_describe","itemRef":{"sourceId":"source","title":"tool","url":"https://www.lanzouw.com/tool","shareUrl":"https://www.lanzouw.com/tool","folderId":"","isFolder":false,"password":"never-echo-this"}}"#,
        );
        let value: Value = serde_json::from_str(&response).unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "invalid_request");
        assert!(!response.contains("never-echo-this"));
    }
}
