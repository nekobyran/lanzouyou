use std::io::{self, BufRead, Write};

use serde_json::{json, Value};

fn main() {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(line) => line,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }
        let response = handle_rpc(&line);
        if writeln!(stdout, "{response}")
            .and_then(|_| stdout.flush())
            .is_err()
        {
            break;
        }
    }
}

fn handle_rpc(request: &str) -> String {
    let parsed: Value = match serde_json::from_str(request) {
        Ok(value) => value,
        Err(_) => return rpc_error(Value::Null, -32700, "Parse error"),
    };
    let id = parsed.get("id").cloned().unwrap_or(Value::Null);
    let method = parsed.get("method").and_then(Value::as_str).unwrap_or("");
    let result = match method {
        "initialize" => json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "lanzouyou", "version": lanzouyou_core::version()}
        }),
        "tools/list" => json!({"tools": [{
            "name": "lanzouyou_dispatch",
            "description": "Execute one LanzouYOU Rust Core command. The input is forwarded unchanged to the shared Rust dispatch layer.",
            "inputSchema": {
                "type": "object",
                "properties": {"command": {"type": "object"}},
                "required": ["command"],
                "additionalProperties": false
            }
        }]}),
        "tools/call" => {
            let params = parsed.get("params").cloned().unwrap_or(Value::Null);
            if params.get("name").and_then(Value::as_str) != Some("lanzouyou_dispatch") {
                return rpc_error(id, -32602, "Unknown tool");
            }
            let Some(command) = params.get("arguments").and_then(|v| v.get("command")) else {
                return rpc_error(id, -32602, "Missing command");
            };
            let core = lanzouyou_core::dispatch_json(&command.to_string());
            let core_json: Value = serde_json::from_str(&core).unwrap_or_else(|_| json!({"ok": false, "error": {"code": "internal_error", "message": "invalid core response", "retriable": false}}));
            json!({"content": [{"type": "text", "text": core}], "structuredContent": core_json, "isError": !core_json.get("ok").and_then(Value::as_bool).unwrap_or(false)})
        }
        "notifications/initialized" => return String::new(),
        _ => return rpc_error(id, -32601, "Method not found"),
    };
    json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string()
}

fn rpc_error(id: Value, code: i64, message: &str) -> String {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}).to_string()
}
