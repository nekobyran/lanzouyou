use lanzouyou_core::dispatch_json;
use serde_json::Value;

#[test]
fn test_dispatch_rejects_unknown_operation_with_stable_envelope() {
    let response: Value = serde_json::from_str(&dispatch_json(r#"{"op":"unknown"}"#)).unwrap();
    assert_eq!(response["ok"], false);
    assert!(response["data"].is_null());
    assert_eq!(response["error"]["code"], "invalid_request");
    assert_eq!(response["error"]["retriable"], false);
}

#[test]
fn test_dispatch_validates_login_without_network() {
    let response: Value = serde_json::from_str(&dispatch_json(
        r#"{"op":"login","account":"","password":"x"}"#,
    ))
    .unwrap();
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "invalid_argument");
}

#[test]
fn test_library_fetch_asset_is_dispatched_and_blocks_invalid_url_before_network() {
    let response: Value = serde_json::from_str(&dispatch_json(
        r#"{"op":"library_fetch_asset","url":"http://127.0.0.1/icon.png"}"#,
    ))
    .unwrap();
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "invalid_argument");
    assert_ne!(response["error"]["code"], "invalid_request");
}

#[test]
fn test_operation_controls_have_stable_safe_contract() {
    let started: Value = serde_json::from_str(&dispatch_json(
        r#"{"op":"upload","folderId":"-1","path":"C:/private/not-returned.bin","operationId":"contract-upload-failure"}"#,
    ))
    .unwrap();
    assert_eq!(started["ok"], false);
    assert_eq!(started["error"]["code"], "unauthenticated");

    let status: Value = serde_json::from_str(&dispatch_json(
        r#"{"op":"operation_status","operationId":"contract-upload-failure"}"#,
    ))
    .unwrap();
    assert_eq!(status["ok"], true);
    assert_eq!(status["data"]["operationId"], "contract-upload-failure");
    assert_eq!(status["data"]["kind"], "upload");
    assert_eq!(status["data"]["state"], "failed");
    for field in [
        "completedUnits",
        "totalUnits",
        "bytesTransferred",
        "totalBytes",
        "itemsFound",
    ] {
        assert!(status["data"][field].is_u64(), "missing integer {field}");
    }
    let serialized = status.to_string();
    assert!(!serialized.contains("private"));
    assert!(!serialized.contains("not-returned"));

    let forgotten: Value = serde_json::from_str(&dispatch_json(
        r#"{"op":"operation_forget","operationId":"contract-upload-failure"}"#,
    ))
    .unwrap();
    assert_eq!(forgotten["ok"], true);
    assert_eq!(forgotten["data"]["forgotten"], true);
}

#[test]
fn test_operation_control_rejects_non_ascii_or_path_like_ids() {
    for operation_id in ["../secret", "包含中文"] {
        let request = serde_json::json!({
            "op": "operation_status",
            "operationId": operation_id,
        });
        let response: Value = serde_json::from_str(&dispatch_json(&request.to_string())).unwrap();
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "invalid_argument");
        assert!(!response.to_string().contains(operation_id));
    }
}

#[test]
fn test_library_download_has_stable_safe_operation_contract() {
    let response: Value = serde_json::from_str(&dispatch_json(
        r#"{"op":"library_download","sourceId":"source-one","shareUrl":"https://www.lanzouw.com/file","password":"never-echo-this","destinationDirectory":"relative","operationId":"contract-library-download-failure"}"#,
    ))
    .unwrap();
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "invalid_argument");
    assert!(!response.to_string().contains("never-echo-this"));

    let status: Value = serde_json::from_str(&dispatch_json(
        r#"{"op":"operation_status","operationId":"contract-library-download-failure"}"#,
    ))
    .unwrap();
    assert_eq!(status["data"]["kind"], "download");
    assert_eq!(status["data"]["state"], "failed");
    assert_eq!(status["data"]["bytesTransferred"], 0);
    assert_eq!(status["data"]["totalBytes"], 0);

    let forgotten: Value = serde_json::from_str(&dispatch_json(
        r#"{"op":"operation_forget","operationId":"contract-library-download-failure"}"#,
    ))
    .unwrap();
    assert_eq!(forgotten["data"]["forgotten"], true);
}
