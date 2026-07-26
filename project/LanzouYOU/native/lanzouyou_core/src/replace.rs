use std::{collections::HashSet, path::Path};

use serde_json::{json, Value};

use crate::{
    error::{CoreError, CoreResult},
    model::{CloudItem, ManagedMetadata, UploadKind},
    operation::OperationHandle,
    session::SessionClient,
    validation,
};

impl SessionClient {
    pub(crate) fn replace_file(
        &self,
        old_file_id: &str,
        folder_id: &str,
        path: &str,
        compat_wrap: bool,
        icon_path: Option<&str>,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<Value> {
        self.require_session()?;
        validation::id(old_file_id, "oldFileId")?;
        validation::id(folder_id, "folderId")?;
        validate_replace_apk(path)?;
        let old = self.managed_metadata(old_file_id, false)?;
        validate_old_metadata(&old)?;
        let before = self.list_all(folder_id)?;
        if !before
            .iter()
            .any(|item| !item.is_folder && item.id == old_file_id)
        {
            return Err(CoreError::new(
                "not_found",
                "待换包文件不在指定目录中",
                false,
            ));
        }
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }

        let upload =
            self.upload_with_operation(folder_id, path, compat_wrap, UploadKind::File, operation)?;
        let uploaded_name = required_result_string(&upload, "uploadedName")?;
        let new_file_id = match optional_result_string(&upload, "id")? {
            Some(id) => id,
            None => {
                let after = self.list_all(folder_id).map_err(|error| {
                    CoreError::new(
                        "ambiguous_uploaded_file",
                        format!("上传成功但无法读取目录以确定新文件: {}", error.message),
                        error.retriable,
                    )
                })?;
                resolve_uploaded_file_id(&before, &after, &uploaded_name)?
            }
        };
        validation::id(&new_file_id, "newFileId")?;
        if new_file_id == old_file_id {
            return Err(CoreError::ambiguous(
                "上传响应错误地返回了旧文件 ID，已阻止换包写入",
            ));
        }

        if let Some(operation) = operation {
            operation.set_total_units(if icon_path.is_some() { 4 } else { 3 });
            if let Err(error) = operation.check_cancelled() {
                return Err(uploaded_failure(
                    "cancelled",
                    error,
                    old_file_id,
                    &new_file_id,
                    &uploaded_name,
                ));
            }
        }

        apply_metadata(self, &new_file_id, &old).map_err(|error| {
            uploaded_failure("metadata", error, old_file_id, &new_file_id, &uploaded_name)
        })?;
        if let Some(operation) = operation {
            operation.complete_unit(0);
            if let Err(error) = operation.check_cancelled() {
                return Err(uploaded_failure(
                    "cancelled",
                    error,
                    old_file_id,
                    &new_file_id,
                    &uploaded_name,
                ));
            }
        }

        let icon_applied = if let Some(icon_path) = icon_path {
            self.set_icon(&new_file_id, icon_path).map_err(|error| {
                uploaded_failure("icon", error, old_file_id, &new_file_id, &uploaded_name)
            })?;
            if let Some(operation) = operation {
                operation.complete_unit(0);
                if let Err(error) = operation.check_cancelled() {
                    return Err(uploaded_failure(
                        "cancelled",
                        error,
                        old_file_id,
                        &new_file_id,
                        &uploaded_name,
                    ));
                }
            }
            true
        } else {
            false
        };

        let delete_was_confirmed_by_error_readback = match self.delete(old_file_id, false) {
            Ok(_) => false,
            Err(delete_error) => match self.old_file_still_present(folder_id, old_file_id) {
                Ok(false) => true,
                Ok(true) => {
                    return Err(uploaded_failure(
                        "delete_old",
                        delete_error,
                        old_file_id,
                        &new_file_id,
                        &uploaded_name,
                    ))
                }
                Err(readback_error) => {
                    return Err(delete_unknown_failure(
                        delete_error,
                        readback_error,
                        old_file_id,
                        &new_file_id,
                        &uploaded_name,
                    ))
                }
            },
        };
        if !delete_was_confirmed_by_error_readback {
            match self.old_file_still_present(folder_id, old_file_id) {
                Ok(false) => {}
                Ok(true) => {
                    return Err(uploaded_failure(
                        "delete_old",
                        CoreError::remote("蓝奏云未确认旧文件已移入回收站", false),
                        old_file_id,
                        &new_file_id,
                        &uploaded_name,
                    ))
                }
                Err(readback_error) => {
                    return Err(delete_unknown_failure(
                        CoreError::ambiguous("旧文件删除结果需要回读确认"),
                        readback_error,
                        old_file_id,
                        &new_file_id,
                        &uploaded_name,
                    ))
                }
            }
        }
        if let Some(operation) = operation {
            operation.complete_unit(0);
        }
        Ok(replace_success(
            old_file_id,
            &new_file_id,
            folder_id,
            &old.name,
            &uploaded_name,
            icon_applied,
        ))
    }

    fn old_file_still_present(&self, folder_id: &str, old_file_id: &str) -> CoreResult<bool> {
        Ok(self
            .list_all(folder_id)?
            .iter()
            .any(|item| !item.is_folder && item.id == old_file_id))
    }
}

fn validate_replace_apk(path: &str) -> CoreResult<()> {
    if path.trim().is_empty() || path.contains(['\0', '\r', '\n']) {
        return Err(CoreError::invalid("换包路径无效"));
    }
    let path = Path::new(path);
    if !path.is_file()
        || !path
            .extension()
            .and_then(|value| value.to_str())
            .is_some_and(|value| value.eq_ignore_ascii_case("apk"))
    {
        return Err(CoreError::invalid("换包文件必须是本地 APK"));
    }
    Ok(())
}

fn validate_old_metadata(metadata: &ManagedMetadata) -> CoreResult<()> {
    validation::required(&metadata.name, "name", 255)?;
    if metadata.description.chars().count() > 4000 || metadata.description.contains('\0') {
        return Err(CoreError::invalid("远端 description 过长或包含非法字符"));
    }
    Ok(())
}

fn apply_metadata(
    session: &SessionClient,
    file_id: &str,
    expected: &ManagedMetadata,
) -> CoreResult<()> {
    if let Err(error) = session.rename(file_id, false, &expected.name) {
        if error.code != "ambiguous_result"
            || session.managed_metadata(file_id, false)?.name != expected.name
        {
            return Err(error);
        }
    }
    if let Err(error) = session.set_description(file_id, false, &expected.description) {
        if error.code != "ambiguous_result"
            || session.managed_metadata(file_id, false)?.description != expected.description
        {
            return Err(error);
        }
    }
    let actual = session.managed_metadata(file_id, false)?;
    if actual != *expected {
        return Err(CoreError::remote("新文件标题或简介回读不一致", false));
    }
    Ok(())
}

pub(crate) fn resolve_uploaded_file_id(
    before: &[CloudItem],
    after: &[CloudItem],
    uploaded_name: &str,
) -> CoreResult<String> {
    let known: HashSet<&str> = before.iter().map(|item| item.id.as_str()).collect();
    let candidates: Vec<&CloudItem> = after
        .iter()
        .filter(|item| {
            !item.is_folder && !known.contains(item.id.as_str()) && item.name == uploaded_name
        })
        .collect();
    match candidates.as_slice() {
        [item] => Ok(item.id.clone()),
        [] => Err(CoreError::new(
            "ambiguous_uploaded_file",
            "上传成功但目录快照中没有唯一新增文件",
            false,
        )),
        _ => Err(CoreError::new(
            "ambiguous_uploaded_file",
            "上传期间出现多个同名新增文件，已阻止错误换包",
            false,
        )),
    }
}

fn required_result_string(value: &Value, key: &str) -> CoreResult<String> {
    optional_result_string(value, key)?
        .ok_or_else(|| CoreError::parse(format!("上传结果缺少 {key}")))
}

fn optional_result_string(value: &Value, key: &str) -> CoreResult<Option<String>> {
    match value.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.is_empty() => Ok(Some(value.clone())),
        Some(Value::Number(value)) => Ok(Some(value.to_string())),
        _ => Err(CoreError::parse(format!("上传结果 {key} 无效"))),
    }
}

fn uploaded_failure(
    stage: &'static str,
    error: CoreError,
    old_file_id: &str,
    new_file_id: &str,
    uploaded_name: &str,
) -> CoreError {
    CoreError::new(
        error.code,
        format!("换包在 {stage} 阶段失败: {}", error.message),
        error.retriable,
    )
    .with_details(json!({
        "stage": stage,
        "oldFileId": old_file_id,
        "newFileId": new_file_id,
        "uploadedName": uploaded_name,
        "oldRetained": true,
        "cleanupRequired": true,
    }))
}

fn delete_unknown_failure(
    delete_error: CoreError,
    readback_error: CoreError,
    old_file_id: &str,
    new_file_id: &str,
    uploaded_name: &str,
) -> CoreError {
    CoreError::new(
        "ambiguous_result",
        format!(
            "旧文件删除结果未知且回读失败: {}; {}",
            delete_error.message, readback_error.message
        ),
        readback_error.retriable,
    )
    .with_details(json!({
        "stage": "delete_old_readback",
        "oldFileId": old_file_id,
        "newFileId": new_file_id,
        "uploadedName": uploaded_name,
        "oldRetained": Value::Null,
        "cleanupRequired": Value::Null,
    }))
}

fn replace_success(
    old_file_id: &str,
    new_file_id: &str,
    folder_id: &str,
    final_name: &str,
    uploaded_name: &str,
    icon_applied: bool,
) -> Value {
    json!({
        "replaced": true,
        "oldFileId": old_file_id,
        "newFileId": new_file_id,
        "folderId": folder_id,
        "finalName": final_name,
        "uploadedName": uploaded_name,
        "descriptionPreserved": true,
        "iconApplied": icon_applied,
        "oldDeleted": true,
        "cleanupRequired": false,
    })
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        sync::{Arc, Mutex},
        thread,
    };

    use tempfile::tempdir;

    use super::*;

    fn file(id: &str, name: &str) -> CloudItem {
        CloudItem::file(id, name)
    }

    fn read_request(stream: &mut TcpStream) -> String {
        let mut data = Vec::new();
        let mut buffer = [0_u8; 4096];
        let mut expected = None;
        loop {
            let read = stream.read(&mut buffer).unwrap();
            if read == 0 {
                break;
            }
            data.extend_from_slice(&buffer[..read]);
            if expected.is_none() {
                if let Some(header_end) = data.windows(4).position(|part| part == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&data[..header_end]);
                    let content_length = headers
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .and_then(|value| value.trim().parse::<usize>().ok())
                        })
                        .unwrap_or(0);
                    expected = Some(header_end + 4 + content_length);
                }
            }
            if expected.map(|length| data.len() >= length).unwrap_or(false) {
                break;
            }
        }
        String::from_utf8_lossy(&data).to_string()
    }

    fn mock_server(
        responses: Vec<&'static str>,
    ) -> (String, Arc<Mutex<Vec<String>>>, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let received = requests.clone();
        let handle = thread::spawn(move || {
            for body in responses {
                let (mut stream, _) = listener.accept().unwrap();
                received.lock().unwrap().push(read_request(&mut stream));
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        (format!("http://{address}"), requests, handle)
    }

    fn authenticated_test_session(base: String) -> SessionClient {
        let mut session = SessionClient::for_test(base).unwrap();
        session.cookie = "sid=test-only".to_owned();
        session.uid = "101".to_owned();
        session.vei = "202".to_owned();
        session
    }

    fn is_task(request: &str, task: &str) -> bool {
        request.contains(&format!("task={task}"))
            || request.contains(&format!("\r\n\r\n{task}\r\n"))
    }

    #[test]
    fn test_resolve_uploaded_file_id_uses_snapshot_delta_with_same_name_old_file() {
        let before = vec![file("old", "App.apk"), file("other", "Other.apk")];
        let after = vec![
            file("old", "App.apk"),
            file("new", "App.apk"),
            file("other", "Other.apk"),
        ];
        assert_eq!(
            resolve_uploaded_file_id(&before, &after, "App.apk").unwrap(),
            "new"
        );
    }

    #[test]
    fn test_resolve_uploaded_file_id_rejects_concurrent_same_name_additions() {
        let before = vec![file("old", "App.apk")];
        let after = vec![
            file("old", "App.apk"),
            file("new-1", "App.apk"),
            file("new-2", "App.apk"),
        ];
        assert_eq!(
            resolve_uploaded_file_id(&before, &after, "App.apk")
                .unwrap_err()
                .code,
            "ambiguous_uploaded_file"
        );
    }

    #[test]
    fn test_uploaded_failure_exposes_cleanup_id_without_private_values() {
        let error = uploaded_failure(
            "icon",
            CoreError::remote("图标绑定失败", false),
            "old-1",
            "new-2",
            "App.apk",
        );
        let body = serde_json::to_value(error.body()).unwrap();
        assert_eq!(body["details"]["oldRetained"], true);
        assert_eq!(body["details"]["newFileId"], "new-2");
        let serialized = body.to_string();
        assert!(!serialized.contains("cookie"));
        assert!(!serialized.contains("description"));
        assert!(!serialized.contains("password"));
    }

    #[test]
    fn test_validate_replace_apk_rejects_non_apk_before_upload() {
        let directory = tempdir().unwrap();
        let apk = directory.path().join("App.APK");
        let text = directory.path().join("App.txt");
        std::fs::write(&apk, b"apk").unwrap();
        std::fs::write(&text, b"text").unwrap();

        assert!(validate_replace_apk(apk.to_str().unwrap()).is_ok());
        assert_eq!(
            validate_replace_apk(text.to_str().unwrap())
                .unwrap_err()
                .code,
            "invalid_argument"
        );
    }

    #[test]
    fn test_get_description_uses_task12_without_public_link_resolution() {
        let (base, requests, server) =
            mock_server(vec![r#"{"zt":1,"text":"应用.apk","info":"已有简介"}"#]);
        let session = authenticated_test_session(base);

        let result = session.get_description("8", false).unwrap();
        server.join().unwrap();

        assert_eq!(result["description"], "已有简介");
        let requests = requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert!(is_task(&requests[0], "12"));
        assert!(!requests[0].contains("task=22"));
        assert!(!requests[0].contains("ajax"));
    }

    #[test]
    fn test_replace_http_mock_preserves_metadata_before_deleting_old_file() {
        let (base, requests, server) = mock_server(vec![
            r#"{"zt":1,"text":"App.apk","info":"官网链接：https://example.test/"}"#,
            r#"{"zt":1,"text":[]}"#,
            r#"{"zt":1,"info":0,"text":[{"id":"100","name_all":"App.apk"}]}"#,
            r#"{"zt":1,"text":[{}]}"#,
            r#"{"zt":1,"text":[]}"#,
            r#"{"zt":1,"info":0,"text":[{"id":"100","name_all":"App.apk"},{"id":"200","name_all":"New.apk"}]}"#,
            r#"{"zt":1,"text":[]}"#,
            r#"{"zt":1,"text":[]}"#,
            r#"{"zt":1,"text":"App.apk","info":"官网链接：https://example.test/"}"#,
            r#"{"zt":1,"text":[]}"#,
            r#"{"zt":1,"text":[]}"#,
            r#"{"zt":1,"info":0,"text":[{"id":"200","name_all":"App.apk"}]}"#,
        ]);
        let session = authenticated_test_session(base);
        let directory = tempdir().unwrap();
        let path = directory.path().join("New.apk");
        std::fs::write(&path, b"test-apk").unwrap();

        let result = session
            .replace_file("100", "-1", path.to_str().unwrap(), false, None, None)
            .unwrap();
        server.join().unwrap();

        assert_eq!(result["newFileId"], "200");
        assert_eq!(result["descriptionPreserved"], true);
        assert_eq!(result["oldDeleted"], true);
        let requests = requests.lock().unwrap();
        assert_eq!(requests.len(), 12);
        let rename = requests
            .iter()
            .position(|item| is_task(item, "46"))
            .unwrap();
        let description = requests
            .iter()
            .position(|item| is_task(item, "11"))
            .unwrap();
        let metadata_readback = requests
            .iter()
            .enumerate()
            .filter(|(_, item)| is_task(item, "12"))
            .map(|(index, _)| index)
            .next_back()
            .unwrap();
        let delete = requests.iter().position(|item| is_task(item, "6")).unwrap();
        assert!(rename < description);
        assert!(description < metadata_readback);
        assert!(metadata_readback < delete);
    }

    #[test]
    fn test_replace_http_mock_keeps_old_when_description_write_fails() {
        let (base, requests, server) = mock_server(vec![
            r#"{"zt":1,"text":"App.apk","info":"已有简介"}"#,
            r#"{"zt":1,"text":[]}"#,
            r#"{"zt":1,"info":0,"text":[{"id":"100","name_all":"App.apk"}]}"#,
            r#"{"zt":1,"text":[{"id":"200"}]}"#,
            r#"{"zt":1,"text":[]}"#,
            r#"{"zt":0,"inf":"写入被拒绝"}"#,
        ]);
        let session = authenticated_test_session(base);
        let directory = tempdir().unwrap();
        let path = directory.path().join("New.apk");
        std::fs::write(&path, b"test-apk").unwrap();

        let error = session
            .replace_file("100", "-1", path.to_str().unwrap(), false, None, None)
            .unwrap_err();
        server.join().unwrap();

        let details = error.details.unwrap();
        assert_eq!(details["newFileId"], "200");
        assert_eq!(details["oldRetained"], true);
        assert_eq!(details["cleanupRequired"], true);
        let requests = requests.lock().unwrap();
        assert!(!requests.iter().any(|item| is_task(item, "6")));
    }
}
