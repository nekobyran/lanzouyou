use std::{collections::VecDeque, process::ExitCode, time::Instant};

use lanzouyou_core::dispatch_json;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const PAGE_LIMIT: usize = 200;
const MAX_DIRECTORY_ATTEMPTS: usize = 8;
const MAX_SINGLE_ATTEMPTS: usize = 64;

struct SmokeFailure {
    stage: &'static str,
    code: String,
}

fn main() -> ExitCode {
    match run() {
        Ok(report) => {
            println!("{}", serde_json::to_string(&report).unwrap_or_default());
            ExitCode::SUCCESS
        }
        Err(error) => {
            println!(
                "{}",
                json!({
                    "result": "failure",
                    "stage": error.stage,
                    "code": safe_code(&error.code),
                })
            );
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<Value, SmokeFailure> {
    let total_started = Instant::now();
    let summary = call("summary", json!({"op": "catalog_summary"}))?;
    let official_count = unsigned(&summary, "officialCount", "summary")?;
    let composite_count = unsigned(&summary, "compositeCount", "summary")?;
    let node_count = unsigned(&summary, "nodeCount", "summary")?;
    let searchable_count = unsigned(&summary, "searchableCount", "summary")?;
    let revision = summary
        .get("revision")
        .and_then(Value::as_str)
        .ok_or_else(|| failure("summary", "invalid_response"))?;
    let revision_sha256 = format!("{:X}", Sha256::digest(revision.as_bytes()));

    let root_nodes = catalog_pages("", "root_catalog")?;
    let remote_ids = root_nodes
        .iter()
        .filter(|node| node.get("kind").and_then(Value::as_str) == Some("remoteSource"))
        .filter_map(|node| node.get("sourceId").and_then(Value::as_str))
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    let composite_ids = root_nodes
        .iter()
        .filter(|node| node.get("kind").and_then(Value::as_str) == Some("composite"))
        .filter_map(|node| node.get("id").and_then(Value::as_str))
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();

    let directory_started = Instant::now();
    let mut directory_attempts = 0usize;
    let mut directory_items = None;
    for source_id in remote_ids.iter().take(MAX_DIRECTORY_ATTEMPTS) {
        directory_attempts += 1;
        let result = call(
            "directory_browse",
            json!({
                "op": "catalog_browse",
                "nodeId": source_id,
                "page": 1,
                "refresh": true,
            }),
        );
        let Ok(folder) = result else { continue };
        let Some(items) = folder.get("items").and_then(Value::as_array) else {
            continue;
        };
        directory_items = Some(items.len());
        break;
    }
    let directory_items =
        directory_items.ok_or_else(|| failure("directory_browse", "no_readable_directory"))?;

    let single_ids = collect_single_software_ids(&composite_ids)?;
    let single_started = Instant::now();
    let mut single_attempts = 0usize;
    let mut single_result = None;
    let mut last_single_code = "operation_failed".to_owned();
    for node_id in single_ids.iter().take(MAX_SINGLE_ATTEMPTS) {
        single_attempts += 1;
        let description = call(
            "single_describe",
            json!({"op": "catalog_describe", "nodeId": node_id}),
        );
        let description = match description {
            Ok(description) => description,
            Err(error) => {
                last_single_code = format!("describe_{}", error.code);
                continue;
            }
        };
        let Some(description) = description.get("description").and_then(Value::as_str) else {
            continue;
        };
        let resolved = call(
            "single_resolve",
            json!({"op": "catalog_resolve", "nodeId": node_id}),
        );
        let resolved = match resolved {
            Ok(resolved) => resolved,
            Err(error) => {
                last_single_code = format!("resolve_{}", error.code);
                continue;
            }
        };
        let resolved_ok = resolved
            .get("url")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
            && resolved
                .get("fileName")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.is_empty());
        if resolved_ok {
            single_result = Some(description.chars().count());
            break;
        }
    }
    let description_chars = single_result.ok_or_else(|| {
        failure(
            "single_resolve",
            &format!("no_resolvable_single_{last_single_code}"),
        )
    })?;

    Ok(json!({
        "result": "success",
        "catalog": {
            "officialCount": official_count,
            "compositeCount": composite_count,
            "nodeCount": node_count,
            "searchableCount": searchable_count,
            "revisionSha256": revision_sha256,
        },
        "directory": {
            "attempts": directory_attempts,
            "itemCount": directory_items,
            "elapsedMs": directory_started.elapsed().as_millis(),
        },
        "singleSoftware": {
            "attempts": single_attempts,
            "descriptionChars": description_chars,
            "resolved": true,
            "elapsedMs": single_started.elapsed().as_millis(),
        },
        "elapsedMs": total_started.elapsed().as_millis(),
    }))
}

fn collect_single_software_ids(composite_ids: &[String]) -> Result<Vec<String>, SmokeFailure> {
    let mut queue = VecDeque::from(composite_ids.to_vec());
    let mut singles = Vec::new();
    let mut visited = 0usize;
    while let Some(parent_id) = queue.pop_front() {
        visited += 1;
        if visited > 512 {
            return Err(failure("single_catalog", "catalog_tree_too_large"));
        }
        for node in catalog_pages(&parent_id, "single_catalog")? {
            match node.get("kind").and_then(Value::as_str) {
                Some("singleSoftware") => {
                    if let Some(id) = node.get("id").and_then(Value::as_str) {
                        singles.push(id.to_owned());
                    }
                }
                Some("folder")
                    if node.get("hasChildren").and_then(Value::as_bool) == Some(true) =>
                {
                    if let Some(id) = node.get("id").and_then(Value::as_str) {
                        queue.push_back(id.to_owned());
                    }
                }
                _ => {}
            }
        }
    }
    if singles.is_empty() {
        Err(failure("single_catalog", "single_software_missing"))
    } else {
        Ok(singles)
    }
}

fn catalog_pages(parent_id: &str, stage: &'static str) -> Result<Vec<Value>, SmokeFailure> {
    let mut cursor = String::new();
    let mut nodes = Vec::new();
    for _ in 0..32 {
        let page = call(
            stage,
            json!({
                "op": "catalog_page",
                "parentId": parent_id,
                "cursor": cursor,
                "limit": PAGE_LIMIT,
            }),
        )?;
        let page_nodes = page
            .get("nodes")
            .and_then(Value::as_array)
            .ok_or_else(|| failure(stage, "invalid_response"))?;
        nodes.extend(page_nodes.iter().cloned());
        if page.get("hasMore").and_then(Value::as_bool) != Some(true) {
            return Ok(nodes);
        }
        cursor = page
            .get("nextCursor")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| failure(stage, "invalid_cursor"))?
            .to_owned();
    }
    Err(failure(stage, "too_many_pages"))
}

fn call(stage: &'static str, request: Value) -> Result<Value, SmokeFailure> {
    let request = serde_json::to_string(&request)
        .map_err(|_| failure(stage, "request_serialization_failed"))?;
    let response = dispatch_json(&request);
    let envelope: Value =
        serde_json::from_str(&response).map_err(|_| failure(stage, "invalid_envelope"))?;
    if envelope.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = envelope
            .pointer("/error/code")
            .and_then(Value::as_str)
            .unwrap_or("operation_failed");
        return Err(failure(stage, code));
    }
    envelope
        .get("data")
        .cloned()
        .ok_or_else(|| failure(stage, "missing_data"))
}

fn unsigned(value: &Value, key: &str, stage: &'static str) -> Result<u64, SmokeFailure> {
    value
        .get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| failure(stage, "invalid_count"))
}

fn failure(stage: &'static str, code: &str) -> SmokeFailure {
    SmokeFailure {
        stage,
        code: safe_code(code),
    }
}

fn safe_code(value: &str) -> String {
    let code = value
        .bytes()
        .filter(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
        .take(64)
        .map(char::from)
        .collect::<String>();
    if code.is_empty() {
        "operation_failed".to_owned()
    } else {
        code
    }
}
