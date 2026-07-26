use std::collections::BTreeMap;

use regex::Regex;
use serde_json::Value;

use crate::{
    error::{CoreError, CoreResult},
    model::{CloudItem, ManagedMetadata, ShareRecord},
};

pub fn api_json(body: &str) -> CoreResult<Value> {
    let value: Value =
        serde_json::from_str(body).map_err(|_| CoreError::parse("蓝奏云返回了无法识别的数据"))?;
    let status = value.get("zt").and_then(value_as_i64).unwrap_or_default();
    match status {
        1 | 2 | 4 => Ok(value),
        9 => Err(CoreError::session_expired()),
        _ => {
            let message = value
                .get("inf")
                .or_else(|| value.get("info"))
                .and_then(Value::as_str)
                .map(sanitize_message)
                .filter(|text| !text.is_empty())
                .unwrap_or_else(|| "蓝奏云操作失败".to_owned());
            Err(CoreError::remote(message, status == 4))
        }
    }
}

pub fn value_as_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
}

pub fn list_items(value: &Value, is_folder: bool) -> CoreResult<Vec<CloudItem>> {
    let array = value
        .get("text")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::parse("文件列表字段缺失"))?;
    array
        .iter()
        .map(|item| {
            let id_key = if is_folder { "fol_id" } else { "id" };
            let name_key = if is_folder { "name" } else { "name_all" };
            let id = string_field(item, id_key)?;
            let name = string_field(item, name_key)?.replace("&amp;", "&");
            let mut cloud = if is_folder {
                CloudItem::folder(id, name)
            } else {
                CloudItem::file(id, name)
            };
            cloud.size = optional_string(item, "size");
            cloud.modified_at = optional_string(item, "time");
            cloud.description = optional_string(item, "folder_des")
                .map(|text| text.trim_matches(&['[', ']'][..]).to_owned());
            cloud.has_password = item
                .get("onof")
                .and_then(value_as_i64)
                .map(|status| status == 1);
            cloud.downloads = item
                .get("downs")
                .and_then(value_as_i64)
                .and_then(|count| u64::try_from(count).ok());
            if !is_folder {
                cloud.has_custom_icon = item
                    .get("is_ico")
                    .or_else(|| item.get("p_ico"))
                    .and_then(value_as_i64)
                    .map(|status| status == 1);
                if cloud.has_custom_icon == Some(true) {
                    cloud.icon_url =
                        optional_string(item, "ico").and_then(|value| trusted_icon_url(&value));
                }
            }
            Ok(cloud)
        })
        .collect()
}

pub fn move_targets(value: &Value) -> CoreResult<Vec<CloudItem>> {
    let mut result = vec![CloudItem {
        path: Some("/".to_owned()),
        ..CloudItem::folder("-1", "LanzouYOU")
    }];
    let Some(array) = value.get("info").and_then(Value::as_array) else {
        return Ok(result);
    };
    for entry in array {
        let id = string_field(entry, "folder_id")?;
        let name = string_field(entry, "folder_name")?;
        result.push(CloudItem::folder(id, name));
    }
    Ok(result)
}

pub fn share_record(value: &Value, is_folder: bool) -> CoreResult<ShareRecord> {
    let info = value
        .get("info")
        .ok_or_else(|| CoreError::parse("分享信息字段缺失"))?;
    let enabled = optional_string(info, "onof").as_deref() == Some("1");
    let password = if enabled {
        optional_string(info, "pwd").unwrap_or_default()
    } else {
        String::new()
    };
    if is_folder {
        let name = optional_string(info, "name").unwrap_or_default();
        let url = string_field(info, "new_url")?;
        Ok(ShareRecord {
            name,
            url: absolute_share_url(&url),
            password,
            description: optional_string(info, "des").unwrap_or_default(),
        })
    } else {
        let share_id = string_field(info, "f_id")?;
        if share_id == "i" {
            return Err(CoreError::new("not_found", "文件不存在", false));
        }
        let base = optional_string(info, "is_newd")
            .filter(|text| !text.is_empty())
            .unwrap_or_else(|| "https://wws.lanzoui.com".to_owned());
        Ok(ShareRecord {
            name: String::new(),
            url: format!("{}/{}", base.trim_end_matches('/'), share_id),
            password,
            description: String::new(),
        })
    }
}

pub(crate) fn managed_file_metadata(value: &Value) -> CoreResult<ManagedMetadata> {
    Ok(ManagedMetadata {
        name: present_string(value, "text", "文件信息缺少 text")?,
        description: present_string(value, "info", "文件信息缺少 info")?,
    })
}

pub(crate) fn managed_folder_metadata(value: &Value) -> CoreResult<ManagedMetadata> {
    let info = value
        .get("info")
        .and_then(Value::as_object)
        .ok_or_else(|| CoreError::parse("目录信息缺少 info"))?;
    Ok(ManagedMetadata {
        name: present_string_in_object(info, "name", "目录信息缺少 name")?,
        description: present_string_in_object(info, "des", "目录信息缺少 des")?,
    })
}

pub(crate) fn upload_file_id(value: &Value) -> CoreResult<Option<String>> {
    let Some(text) = value.get("text") else {
        return Err(CoreError::parse("上传响应缺少 text"));
    };
    let candidate = match text {
        Value::Array(items) => items.first().and_then(|item| item.get("id")),
        Value::Object(item) => item.get("id"),
        value => Some(value),
    };
    match candidate {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value_to_id(value)
            .map(Some)
            .ok_or_else(|| CoreError::parse("上传响应 id 无效")),
    }
}

pub fn bootstrap_values(html: &str) -> CoreResult<(String, String)> {
    ensure_session_html(html)?;
    let uid = capture(html, r#"uid=([^'\"&;\s]+)"#).ok_or_else(CoreError::session_expired)?;
    let fields = js_data_fields(html)?;
    let vei = fields
        .get("vei")
        .cloned()
        .ok_or_else(|| CoreError::parse("登录页面缺少 vei"))?;
    Ok((uid, vei))
}

pub fn ensure_session_html(html: &str) -> CoreResult<()> {
    if html.contains("网盘用户登录")
        || html.contains("<title>用户登录")
        || html.contains("<title>登录蓝奏云")
    {
        Err(CoreError::session_expired())
    } else {
        Ok(())
    }
}

pub fn js_data_fields(html: &str) -> CoreResult<BTreeMap<String, String>> {
    js_data_fields_with_context(html, html)
}

pub fn js_data_fields_with_context(
    html: &str,
    context: &str,
) -> CoreResult<BTreeMap<String, String>> {
    let data_regex = Regex::new(r#"(?s)data\s*[:=]\s*\{([^}]+)\}"#)
        .map_err(|_| CoreError::parse("页面解析规则初始化失败"))?;
    let candidates: Vec<_> = data_regex.captures_iter(html).collect();
    let content = candidates
        .iter()
        .max_by_key(|capture| capture.get(1).map(|item| item.as_str().len()).unwrap_or(0))
        .and_then(|capture| capture.get(1))
        .map(|item| item.as_str())
        .ok_or_else(|| CoreError::parse("页面缺少下载参数"))?;
    let pair_regex = Regex::new(r#"['\"]?([A-Za-z0-9_]+)['\"]?\s*:\s*([^,}]+)"#)
        .map_err(|_| CoreError::parse("页面解析规则初始化失败"))?;
    let mut result = BTreeMap::new();
    for capture in pair_regex.captures_iter(content) {
        let key = capture[1].to_owned();
        let raw = capture[2].trim().trim_matches(&['\'', '"'][..]);
        let value = if raw.chars().all(|ch| ch.is_ascii_digit())
            || capture[2].trim().starts_with(['\'', '"'])
        {
            raw.to_owned()
        } else {
            capture_variable(context, raw).unwrap_or_default()
        };
        result.insert(key, value);
    }
    if result.is_empty() {
        Err(CoreError::parse("页面下载参数为空"))
    } else {
        Ok(result)
    }
}

pub fn formhash(html: &str) -> CoreResult<String> {
    capture(html, r#"name=['\"]formhash['\"]\s+value=['\"]([^'\"]+)"#)
        .ok_or_else(|| CoreError::parse("回收站页面缺少 formhash"))
}

pub fn iframe_path(html: &str) -> Option<String> {
    capture(
        html,
        r#"(?is)<iframe[^>]+src=['\"]([^'\"]*/fn(?:\?|/)[^'\"]*)"#,
    )
    .or_else(|| capture(html, r#"(?is)(?:href|src)=['\"]([^'\"]*/tp/[^'\"]+)"#))
}

pub fn ajax_file_id(html: &str) -> Option<String> {
    capture(html, r#"ajaxm\.php\?file=(\d+)"#)
}

pub fn ajax_endpoint(html: &str) -> Option<String> {
    capture(
        html,
        r#"(?is)url\s*:\s*['\"]([^'\"]*ajaxm\.php(?:\?file=\d+)?)"#,
    )
    .or_else(|| capture(html, r#"(?is)['\"]([^'\"]*ajaxm\.php(?:\?file=\d+)?)['\"]"#))
}

pub fn function_block(html: &str, name: &str) -> Option<String> {
    let pattern = format!(
        r#"(?is)function\s+{}\s*\([^)]*\)\s*\{{"#,
        regex::escape(name)
    );
    let found = Regex::new(&pattern).ok()?.find(html)?;
    let mut depth = 1_usize;
    let rest = &html[found.end()..];
    let bytes = rest.as_bytes();
    let mut offset = 0_usize;
    let mut quote = None;
    let mut line_comment = false;
    let mut block_comment = false;
    while offset < bytes.len() {
        let current = bytes[offset];
        let next = bytes.get(offset + 1).copied();
        if line_comment {
            if matches!(current, b'\n' | b'\r') {
                line_comment = false;
            }
            offset += 1;
            continue;
        }
        if block_comment {
            if current == b'*' && next == Some(b'/') {
                block_comment = false;
                offset += 2;
            } else {
                offset += 1;
            }
            continue;
        }
        if let Some(delimiter) = quote {
            if current == b'\\' {
                offset = (offset + 2).min(bytes.len());
                continue;
            }
            if current == delimiter {
                quote = None;
            }
            offset += 1;
            continue;
        }
        match (current, next) {
            (b'/', Some(b'/')) => {
                line_comment = true;
                offset += 2;
            }
            (b'/', Some(b'*')) => {
                block_comment = true;
                offset += 2;
            }
            (b'\'' | b'"' | b'`', _) => {
                quote = Some(current);
                offset += 1;
            }
            (b'{', _) => {
                depth += 1;
                offset += 1;
            }
            (b'}', _) => {
                depth -= 1;
                if depth == 0 {
                    return Some(html[found.start()..found.end() + offset + 1].to_owned());
                }
                offset += 1;
            }
            _ => offset += 1,
        }
    }
    None
}

pub fn recycle_items(html: &str) -> CoreResult<Vec<CloudItem>> {
    let folder_regex = Regex::new(
        r#"(?is)folder_id=(\d+)[^>]*>[^<]*(?:&nbsp;)?\s*([^<]+?)\.{0,3}</a>.*?<td[^>]*>([^<]*)</td>.*?<td[^>]*>([^<]*)</td>"#,
    )
    .map_err(|_| CoreError::parse("回收站解析规则初始化失败"))?;
    let file_regex = Regex::new(
        r#"(?is)fl_sel_ids[^>]+value=['\"](\d+)['\"].*?filetype/([A-Za-z0-9]+)\.gif.*?/?>\s*([^<]+?)(?:\.{3})?</a>.*?<td[^>]*>([\d\-]+)</td>"#,
    )
    .map_err(|_| CoreError::parse("回收站解析规则初始化失败"))?;
    let mut items = Vec::new();
    for capture in folder_regex.captures_iter(html) {
        let mut item = CloudItem::folder(capture[1].to_owned(), clean_html_text(&capture[2]));
        item.size = Some(clean_html_text(&capture[3]));
        item.modified_at = Some(clean_html_text(&capture[4]));
        item.is_recycle = true;
        items.push(item);
    }
    for capture in file_regex.captures_iter(html) {
        let extension = &capture[2];
        let mut name = clean_html_text(&capture[3]);
        if !name
            .to_ascii_lowercase()
            .ends_with(&format!(".{extension}").to_ascii_lowercase())
        {
            name.push('.');
            name.push_str(extension);
        }
        let mut item = CloudItem::file(capture[1].to_owned(), name);
        item.modified_at = Some(capture[4].to_owned());
        item.is_recycle = true;
        items.push(item);
    }
    Ok(items)
}

fn capture(text: &str, pattern: &str) -> Option<String> {
    Regex::new(pattern)
        .ok()?
        .captures(text)?
        .get(1)
        .map(|value| value.as_str().trim().to_owned())
}

fn capture_variable(html: &str, name: &str) -> Option<String> {
    let pattern = format!(r#"var\s+{}\s*=\s*['\"]?([^;'\"]+)"#, regex::escape(name));
    capture(html, &pattern)
}

fn string_field(value: &Value, key: &str) -> CoreResult<String> {
    optional_string(value, key).ok_or_else(|| CoreError::parse(format!("字段 {key} 缺失")))
}

fn present_string(value: &Value, key: &str, message: &str) -> CoreResult<String> {
    let object = value.as_object().ok_or_else(|| CoreError::parse(message))?;
    present_string_in_object(object, key, message)
}

fn present_string_in_object(
    value: &serde_json::Map<String, Value>,
    key: &str,
    message: &str,
) -> CoreResult<String> {
    value
        .get(key)
        .and_then(value_to_id)
        .ok_or_else(|| CoreError::parse(message))
}

fn value_to_id(value: &Value) -> Option<String> {
    value
        .as_str()
        .map(ToOwned::to_owned)
        .or_else(|| value.as_i64().map(|number| number.to_string()))
}

fn optional_string(value: &Value, key: &str) -> Option<String> {
    let field = value.get(key)?;
    field
        .as_str()
        .map(ToOwned::to_owned)
        .or_else(|| field.as_i64().map(|number| number.to_string()))
}

fn sanitize_message(value: &str) -> String {
    value
        .chars()
        .filter(|character| !character.is_control())
        .take(160)
        .collect()
}

fn absolute_share_url(value: &str) -> String {
    if value.starts_with("http://") || value.starts_with("https://") {
        value.to_owned()
    } else {
        format!("https://pan.lanzoui.com/{}", value.trim_start_matches('/'))
    }
}

fn trusted_icon_url(value: &str) -> Option<String> {
    if value.is_empty() || value.len() > 16 * 1024 || value.contains(['\0', '\r', '\n']) {
        return None;
    }
    let candidate = if value.starts_with("https://") {
        value.to_owned()
    } else if value.contains("://") {
        return None;
    } else {
        format!("https://{}", value.trim_start_matches('/'))
    };
    let parsed = reqwest::Url::parse(&candidate).ok()?;
    if parsed.scheme() != "https"
        || parsed.host_str() != Some("image.dmpdmp.com")
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || !matches!(parsed.port(), None | Some(443))
    {
        return None;
    }
    Some(candidate)
}

fn clean_html_text(value: &str) -> String {
    value
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_api_json_maps_expired_cookie() {
        let error = api_json(r#"{"zt":9,"info":"ignored"}"#).unwrap_err();
        assert_eq!(error.code, "session_expired");
    }

    #[test]
    fn test_ensure_session_html_maps_login_page_to_expired() {
        let error = ensure_session_html("<title>用户登录</title>网盘用户登录").unwrap_err();
        assert_eq!(error.code, "session_expired");
    }

    #[test]
    fn test_list_items_parses_folder_and_file_shapes() {
        let folder: Value =
            serde_json::from_str(r#"{"zt":1,"text":[{"fol_id":"7","name":"docs","onof":"1"}]}"#)
                .unwrap();
        let item = &list_items(&folder, true).unwrap()[0];
        assert!(item.is_folder);
        assert_eq!(item.id, "7");
        assert_eq!(item.has_password, Some(true));

        let file: Value = serde_json::from_str(
            r#"{"zt":1,"text":[{"id":"8","name_all":"app.apk","is_ico":"1","ico":"image.dmpdmp.com/icon.png?e=1&s=secret"}]}"#,
        )
        .unwrap();
        let item = &list_items(&file, false).unwrap()[0];
        assert_eq!(item.has_custom_icon, Some(true));
        assert_eq!(
            item.icon_url.as_deref(),
            Some("https://image.dmpdmp.com/icon.png?e=1&s=secret")
        );
    }

    #[test]
    fn test_list_items_parses_p_ico_custom_icon_state() {
        let file: Value = serde_json::from_str(
            r#"{"zt":1,"text":[{"id":"8","name_all":"app.apk","p_ico":1,"ico":"image.dmpdmp.com/icon.png?e=1&s=secret"}]}"#,
        )
        .unwrap();

        let item = &list_items(&file, false).unwrap()[0];

        assert_eq!(item.has_custom_icon, Some(true));
        assert_eq!(
            item.icon_url.as_deref(),
            Some("https://image.dmpdmp.com/icon.png?e=1&s=secret")
        );
    }

    #[test]
    fn test_list_items_rejects_untrusted_custom_icon_host() {
        let file: Value = serde_json::from_str(
            r#"{"zt":1,"text":[{"id":"8","name_all":"app.apk","is_ico":"1","ico":"evil.example/icon.png?signature=x"}]}"#,
        )
        .unwrap();
        let item = &list_items(&file, false).unwrap()[0];
        assert_eq!(item.has_custom_icon, Some(true));
        assert_eq!(item.icon_url, None);
    }

    #[test]
    fn test_managed_file_metadata_distinguishes_empty_from_missing_description() {
        let empty = api_json(r#"{"zt":1,"text":"软件.apk","info":""}"#).unwrap();
        assert_eq!(
            managed_file_metadata(&empty).unwrap(),
            ManagedMetadata {
                name: "软件.apk".to_owned(),
                description: String::new(),
            }
        );

        let missing = api_json(r#"{"zt":1,"text":"软件.apk"}"#).unwrap();
        assert_eq!(
            managed_file_metadata(&missing).unwrap_err().code,
            "parse_error"
        );
    }

    #[test]
    fn test_managed_folder_metadata_requires_real_description_field() {
        let value = api_json(
            r#"{"zt":1,"info":{"name":"软件库","des":"真实简介","new_url":"https://example.invalid"}}"#,
        )
        .unwrap();
        assert_eq!(
            managed_folder_metadata(&value).unwrap(),
            ManagedMetadata {
                name: "软件库".to_owned(),
                description: "真实简介".to_owned(),
            }
        );
        let missing = api_json(r#"{"zt":1,"info":{"name":"软件库"}}"#).unwrap();
        assert!(managed_folder_metadata(&missing).is_err());
    }

    #[test]
    fn test_upload_file_id_accepts_openlist_shape_and_rejects_invalid_id() {
        assert_eq!(
            upload_file_id(&serde_json::json!({"text": [{"id": "901"}]})).unwrap(),
            Some("901".to_owned())
        );
        assert_eq!(
            upload_file_id(&serde_json::json!({"text": [{"id": 902}]})).unwrap(),
            Some("902".to_owned())
        );
        assert_eq!(
            upload_file_id(&serde_json::json!({"text": [{}]})).unwrap(),
            None
        );
        assert!(upload_file_id(&serde_json::json!({"text": [{"id": []}]})).is_err());
    }

    #[test]
    fn test_js_data_fields_resolves_variables() {
        let html = r#"var sg='token'; data: {'action':'downprocess','sign':sg,'ves':1}"#;
        let fields = js_data_fields(html).unwrap();
        assert_eq!(fields["sign"], "token");
        assert_eq!(fields["ves"], "1");
    }

    #[test]
    fn test_function_block_ignores_other_page_data() {
        let html = r#"function other(){data:{'bad':'x'}} function down_p(){if(true){data:{'action':'downprocess','sign':'ok'}}}"#;
        let block = function_block(html, "down_p").unwrap();
        assert!(!block.contains("'bad'"));
        assert_eq!(js_data_fields(&block).unwrap()["sign"], "ok");
    }

    #[test]
    fn test_function_block_ignores_braces_inside_javascript_strings() {
        let html = r#"function down_p(){var template='}'; var quoted="{ignored}"; /* } */ data:{'action':'downprocess','sign':'ok'} // }
        } function after(){data:{'bad':'x'}}"#;
        let block = function_block(html, "down_p").unwrap();
        assert!(block.contains("'sign':'ok'"));
        assert!(!block.contains("function after"));
    }

    #[test]
    fn test_iframe_path_uses_only_download_jump_routes() {
        let html = r#"<iframe src='/ad/banner'></iframe><iframe src='/fn?token=one'></iframe>"#;
        assert_eq!(iframe_path(html).as_deref(), Some("/fn?token=one"));
        assert_eq!(iframe_path("<iframe src='/ad/banner'></iframe>"), None);
        assert_eq!(
            iframe_path(r#"<a href='/tp/share-token'>download</a>"#).as_deref(),
            Some("/tp/share-token")
        );
    }

    #[test]
    fn test_recycle_items_normalizes_folder_and_file() {
        let html = r#"
          <a href="?folder_id=42">&nbsp;docs...</a><td>1 MB</td><td>2026-07-01</td>
          <input name="fl_sel_ids[]" value="7"><img src="filetype/txt.gif" /> report</a><td>2026-07-02</td>
        "#;
        let items = recycle_items(html).unwrap();
        assert_eq!(items.len(), 2);
        assert!(items.iter().all(|item| item.is_recycle));
        assert_eq!(items[0].id, "42");
        assert_eq!(items[1].name, "report.txt");
    }
}
