use std::collections::HashSet;

use once_cell::sync::Lazy;
use regex::Regex;
use reqwest::Url;
use serde_json::Value;

use crate::error::{CoreError, CoreResult};

use super::{
    model::LibraryItem,
    url::{normalize_public_share_url, safe_asset_url, virtual_folder_url, SecurityPolicy},
};

static ICON_DATE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:^|/)(\d{4})/(\d{2})/(\d{2})(?:/|$)").expect("the icon date regex is valid")
});

#[derive(Debug)]
pub(crate) enum PageState {
    Items {
        items: Vec<LibraryItem>,
        raw_count: usize,
        total: Option<usize>,
    },
    End,
    Busy,
}

pub(crate) struct ItemContext {
    pub source_id: String,
    pub source_title: String,
    pub base_origin: String,
}

pub(crate) fn parse_file_page(raw: &str, context: &ItemContext) -> CoreResult<PageState> {
    parse_page(raw, context, &["text", "item"], false, "目录接口返回异常")
}

pub(crate) fn parse_search_page(raw: &str, context: &ItemContext) -> CoreResult<PageState> {
    parse_page(raw, context, &["item", "text"], false, "源内搜索失败")
}

pub(crate) fn parse_folder_page(
    raw: &str,
    context: &ItemContext,
    root_url: &str,
) -> CoreResult<PageState> {
    let data: Value = serde_json::from_str(raw.trim_start_matches('\u{feff}').trim())
        .map_err(|_| CoreError::parse("目录子文件夹接口返回了无效 JSON"))?;
    match state(&data) {
        4 => return Ok(PageState::Busy),
        2 => return Ok(PageState::End),
        1 => {}
        _ => return Err(remote_message(&data, "目录子文件夹接口返回异常")),
    }
    let values = data
        .get("text")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut items = Vec::new();
    for value in &values {
        let id = first_string(value, &["fol_id", "folder_id", "id"]);
        let title = strip_text(&first_string(value, &["name", "folder_name", "name_all"]));
        if id.is_empty() || id == "null" || title.is_empty() {
            continue;
        }
        let description = strip_text(&first_string(
            value,
            &["folder_des", "description", "introduce", "info", "size"],
        ));
        let public_url = folder_public_url(value, root_url).unwrap_or(virtual_folder_url(
            root_url,
            &id,
            &title,
            &description,
        )?);
        items.push(LibraryItem {
            source_id: context.source_id.clone(),
            title: title.clone(),
            url: public_url.clone(),
            share_url: public_url,
            size: description.clone(),
            icon_url: "https://images.bakstotre.com/assets/images/type/folder.gif".to_owned(),
            source: context.source_title.clone(),
            description,
            folder_id: id,
            is_folder: true,
            ..LibraryItem::default()
        });
    }
    Ok(PageState::Items {
        items,
        raw_count: values.len(),
        total: optional_usize(data.get("total")),
    })
}

fn folder_public_url(value: &Value, root_url: &str) -> Option<String> {
    let base = Url::parse(root_url).ok()?;
    for key in ["share_url", "folder_url", "url", "href"] {
        let raw = string(value.get(key));
        if raw.is_empty() {
            continue;
        }
        let Ok(candidate) = base.join(&raw) else {
            continue;
        };
        if candidate.scheme() != "https" {
            continue;
        }
        if let Ok(canonical) =
            normalize_public_share_url(candidate.as_str(), &SecurityPolicy::Production)
        {
            return Some(canonical);
        }
    }
    None
}

fn parse_page(
    raw: &str,
    context: &ItemContext,
    array_keys: &[&str],
    folders_only: bool,
    fallback: &str,
) -> CoreResult<PageState> {
    let data: Value = serde_json::from_str(raw.trim_start_matches('\u{feff}').trim())
        .map_err(|_| CoreError::parse("蓝奏接口返回了无效 JSON"))?;
    match state(&data) {
        4 => return Ok(PageState::Busy),
        2 => return Ok(PageState::End),
        1 => {}
        _ => return Err(remote_message(&data, fallback)),
    }
    let values = array_keys
        .iter()
        .find_map(|key| data.get(*key).and_then(Value::as_array))
        .cloned()
        .unwrap_or_default();
    if values.is_empty() {
        return Ok(PageState::End);
    }
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    for value in &values {
        if let Some(item) = item_from_value(value, context) {
            if (!folders_only || item.is_folder) && seen.insert(item.url.clone()) {
                items.push(item);
            }
        }
    }
    Ok(PageState::Items {
        items,
        raw_count: values.len(),
        total: optional_usize(data.get("total")),
    })
}

fn item_from_value(value: &Value, context: &ItemContext) -> Option<LibraryItem> {
    let title = strip_text(&first_string(value, &["name_all", "name"]));
    let raw_url = first_string(value, &["id", "url"]);
    if title.is_empty() || raw_url.is_empty() || raw_url == "-1" {
        return None;
    }
    let base = Url::parse(&context.base_origin).ok()?;
    let url = base.join(&raw_url).ok()?;
    if !is_trusted_item_url(&base, &url, &raw_url) {
        return None;
    }
    let custom = string(value.get("ico"));
    let kind = string(value.get("icon"));
    let has_custom = integer(value.get("p_ico")) == Some(1);
    let icon_url = if has_custom && !custom.is_empty() {
        if custom.starts_with("https://") {
            safe_asset_url(&custom).unwrap_or_default()
        } else {
            format!("https://image.dmpdmp.com/image/ico/{custom}?x-oss-process=image/auto-orient,1/resize,m_fill,w_100,h_100/format,png")
        }
    } else if !kind.is_empty() {
        if kind.starts_with("https://") {
            safe_asset_url(&kind).unwrap_or_default()
        } else {
            format!("https://images.bakstotre.com/assets/images/type/{kind}.gif")
        }
    } else {
        String::new()
    };
    let is_folder = value.get("folder").is_some_and(|entry| {
        entry.as_bool() == Some(true)
            || integer(Some(entry)) == Some(1)
            || entry.as_str().is_some_and(|kind| kind == "1")
    }) || value
        .get("type")
        .and_then(Value::as_str)
        .is_some_and(|kind| kind.eq_ignore_ascii_case("folder"));
    let time = first_non_empty(&[
        string(value.get("time")),
        string(value.get("time_all")),
        string(value.get("date")),
        date_from_icon(&custom),
    ]);
    Some(LibraryItem {
        source_id: context.source_id.clone(),
        title,
        url: url.to_string(),
        share_url: url.to_string(),
        size: string(value.get("size")),
        time,
        icon_url,
        source: context.source_title.clone(),
        description: strip_text(&first_non_empty(&[
            string(value.get("description")),
            string(value.get("introduce")),
            string(value.get("info")),
        ])),
        folder_id: String::new(),
        is_folder,
    })
}

fn is_trusted_item_url(base: &Url, candidate: &Url, raw: &str) -> bool {
    if !candidate.username().is_empty()
        || candidate.password().is_some()
        || has_explicit_authority_port(raw)
        || raw_url_authority(raw).is_some_and(|authority| !authority.is_ascii())
    {
        return false;
    }
    let same_origin = candidate.scheme() == base.scheme()
        && candidate.host_str() == base.host_str()
        && candidate.port_or_known_default() == base.port_or_known_default();
    if same_origin {
        return true;
    }

    // Search results occasionally use an absolute URL from another official
    // Lanzou public host. Only that exact HTTPS host family may cross the page
    // origin; relative references and every non-Lanzou destination stay scoped
    // to the page origin.
    Url::parse(raw).is_ok()
        && base.scheme() == "https"
        && candidate.scheme() == "https"
        && candidate.port().is_none()
        && base.host_str().is_some_and(is_trusted_lanzou_host)
        && candidate.host_str().is_some_and(is_trusted_lanzou_host)
}

fn has_explicit_authority_port(value: &str) -> bool {
    raw_url_authority(value).is_some_and(|authority| {
        authority
            .rsplit('@')
            .next()
            .unwrap_or_default()
            .contains(':')
    })
}

fn raw_url_authority(value: &str) -> Option<&str> {
    let rest = value
        .split_once("://")
        .map(|(_, rest)| rest)
        .or_else(|| value.strip_prefix("//"));
    rest.and_then(|rest| rest.split(['/', '?', '#']).next())
}

fn is_trusted_lanzou_host(host: &str) -> bool {
    ["lanzouw.com", "lanzoui.com"]
        .into_iter()
        .any(|root| is_host_or_subdomain(host, root))
}

fn is_host_or_subdomain(host: &str, root: &str) -> bool {
    if !host.is_ascii() || host.ends_with('.') {
        return false;
    }
    let host = host.to_ascii_lowercase();
    if host == root {
        return true;
    }
    host.strip_suffix(&format!(".{root}"))
        .is_some_and(|prefix| {
            !prefix.is_empty()
                && prefix.split('.').all(|label| {
                    !label.is_empty()
                        && label.len() <= 63
                        && !label.to_ascii_lowercase().starts_with("xn--")
                        && !label.starts_with('-')
                        && !label.ends_with('-')
                        && label
                            .bytes()
                            .all(|value| value.is_ascii_alphanumeric() || value == b'-')
                })
        })
}

fn state(data: &Value) -> i64 {
    integer(data.get("zt")).unwrap_or(-1)
}

fn integer(value: Option<&Value>) -> Option<i64> {
    value.and_then(|entry| {
        entry
            .as_i64()
            .or_else(|| entry.as_str().and_then(|text| text.parse().ok()))
    })
}

fn optional_usize(value: Option<&Value>) -> Option<usize> {
    integer(value).and_then(|value| usize::try_from(value).ok())
}

fn string(value: Option<&Value>) -> String {
    value
        .and_then(|entry| {
            entry
                .as_str()
                .map(ToOwned::to_owned)
                .or_else(|| entry.as_i64().map(|value| value.to_string()))
        })
        .unwrap_or_default()
        .trim()
        .to_owned()
}

fn first_string(value: &Value, keys: &[&str]) -> String {
    keys.iter()
        .map(|key| string(value.get(*key)))
        .find(|entry| !entry.is_empty())
        .unwrap_or_default()
}

fn first_non_empty(values: &[String]) -> String {
    values
        .iter()
        .find(|value| !value.trim().is_empty())
        .cloned()
        .unwrap_or_default()
}

fn strip_text(value: &str) -> String {
    let without_tags = Regex::new(r"(?is)<[^>]+>")
        .map(|regex| regex.replace_all(value, "").into_owned())
        .unwrap_or_else(|_| value.to_owned());
    without_tags
        .replace("&amp;", "&")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .trim()
        .to_owned()
}

fn date_from_icon(value: &str) -> String {
    ICON_DATE
        .captures(value)
        .map(|captures| format!("{}-{}-{}", &captures[1], &captures[2], &captures[3]))
        .unwrap_or_default()
}

fn remote_message(data: &Value, fallback: &str) -> CoreError {
    let message = ["info", "msg", "inf"]
        .iter()
        .map(|key| string(data.get(*key)))
        .find(|value| !value.is_empty())
        .unwrap_or_else(|| fallback.to_owned());
    if is_password_required_message(&message) {
        CoreError::new("password_required", "分享需要正确的访问码", false)
    } else {
        CoreError::remote(message, true)
    }
}

fn is_password_required_message(message: &str) -> bool {
    let normalized = message
        .to_lowercase()
        .replace([' ', '\t', '\r', '\n', '，', ',', '：', ':'], "");
    let mentions_code = ["密码", "访问码", "提取码", "password", "passcode"]
        .into_iter()
        .any(|marker| normalized.contains(marker));
    let rejected = [
        "不正确",
        "错误",
        "请输入",
        "需要",
        "required",
        "incorrect",
        "invalid",
        "wrong",
    ]
    .into_iter()
    .any(|marker| normalized.contains(marker));
    mentions_code && rejected
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> ItemContext {
        ItemContext {
            source_id: "source-one".to_owned(),
            source_title: "软件库".to_owned(),
            base_origin: "https://www.lanzouw.com".to_owned(),
        }
    }

    #[test]
    fn test_file_page_maps_custom_icon_and_never_adds_password() {
        let raw = r#"{"zt":1,"text":[{"id":"abc","name_all":"工具.apk","size":"1 M","p_ico":1,"ico":"2026/07/14/icon.jpg"}]}"#;
        let PageState::Items {
            items, raw_count, ..
        } = parse_file_page(raw, &context()).unwrap()
        else {
            panic!("expected items");
        };
        assert_eq!(raw_count, 1);
        assert_eq!(items[0].source_id, "source-one");
        assert!(items[0].icon_url.contains("2026/07/14"));
        assert_eq!(items[0].time, "2026-07-14");
        let json = serde_json::to_string(&items).unwrap();
        assert!(!json.to_ascii_lowercase().contains("password"));
    }

    #[test]
    fn test_page_states_accept_numeric_strings_and_busy_end() {
        assert!(matches!(
            parse_file_page(r#"{"zt":"4"}"#, &context()).unwrap(),
            PageState::Busy
        ));
        assert!(matches!(
            parse_file_page(r#"{"zt":"2"}"#, &context()).unwrap(),
            PageState::End
        ));
    }

    #[test]
    fn test_file_page_preserves_password_required_error_code() {
        let error = parse_file_page(r#"{"zt":3,"inf":"访问密码不正确"}"#, &context()).unwrap_err();
        assert_eq!(error.code, "password_required");
        assert_eq!(error.message, "分享需要正确的访问码");
        assert!(!error.retriable);
    }

    #[test]
    fn test_file_page_discards_cross_origin_advertisement() {
        let raw = r#"{"zt":1,"text":[{"id":"https://evil.example/app","name_all":"广告"}]}"#;
        let PageState::Items { items, .. } = parse_file_page(raw, &context()).unwrap() else {
            panic!("expected items state");
        };
        assert!(items.is_empty());
    }

    #[test]
    fn test_search_page_accepts_absolute_url_on_another_trusted_lanzou_family() {
        let raw = r#"{"zt":1,"item":[{"id":"https://mirror.lanzoui.com/app","name_all":"可信工具.apk"}]}"#;
        let PageState::Items { items, .. } = parse_search_page(raw, &context()).unwrap() else {
            panic!("expected items state");
        };

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].url, "https://mirror.lanzoui.com/app");
    }

    #[test]
    fn test_search_page_rejects_lookalike_lanzou_host() {
        let raw = r#"{"zt":1,"item":[{"id":"https://www.lanzouw.com.evil.example/app","name_all":"伪装广告"}]}"#;
        let PageState::Items { items, .. } = parse_search_page(raw, &context()).unwrap() else {
            panic!("expected items state");
        };

        assert!(items.is_empty());
    }

    #[test]
    fn test_search_page_rejects_absolute_lanzou_url_with_credentials_or_explicit_port() {
        let raw = r#"{"zt":1,"item":[{"id":"https://user@www.lanzouw.com/app","name_all":"凭据"},{"id":"https://www.lanzouw.com:443/app","name_all":"端口"},{"id":"https://蓝奏.lanzouw.com/app","name_all":"非 ASCII 主机"}]}"#;
        let PageState::Items { items, .. } = parse_search_page(raw, &context()).unwrap() else {
            panic!("expected items state");
        };

        assert!(items.is_empty());
    }

    #[test]
    fn test_search_page_rejects_punycode_lanzou_subdomain() {
        let raw = r#"{"zt":1,"item":[{"id":"https://xn--evil-9za.lanzouw.com/app","name_all":"伪装主机"}]}"#;
        let PageState::Items { items, .. } = parse_search_page(raw, &context()).unwrap() else {
            panic!("expected items state");
        };

        assert!(items.is_empty());
    }

    #[test]
    fn test_folder_page_preserves_real_public_share_url_and_falls_back_for_hostile_url() {
        let raw = r#"{"zt":1,"text":[
          {"fol_id":"one","name":"公开子目录","share_url":"https://mirror.lanzoui.com/b-child?pwd=must-not-emit#discarded"},
          {"fol_id":"two","name":"不可信子目录","folder_url":"https://evil.example/b-ad"},
          {"fol_id":"three","name":"跳过恶意候选","share_url":"https://evil.example/b-first","folder_url":"/b-secondary"},
          {"fol_id":"four","name":"旧域名真实目录","url":"https://folder.lanzouq.com/b-url#discarded"},
          {"fol_id":"five","name":"相对真实目录","href":"/b-href"}
        ]}"#;
        let PageState::Items { items, .. } =
            parse_folder_page(raw, &context(), "https://www.lanzouw.com/b-root").unwrap()
        else {
            panic!("expected folder items");
        };

        assert_eq!(items[0].url, "https://www.lanzouw.com/b-child");
        assert_eq!(items[0].share_url, items[0].url);
        assert!(items[1]
            .url
            .starts_with("https://www.lanzouw.com/b-root#lanzou-folder="));
        assert_eq!(items[1].share_url, items[1].url);
        assert_eq!(items[2].url, "https://www.lanzouw.com/b-secondary");
        assert_eq!(items[2].share_url, items[2].url);
        assert_eq!(items[3].url, "https://www.lanzouw.com/b-url");
        assert_eq!(items[3].share_url, items[3].url);
        assert_eq!(items[4].url, "https://www.lanzouw.com/b-href");
        assert_eq!(items[4].share_url, items[4].url);
        let json = serde_json::to_string(&items).unwrap();
        assert!(!json.contains("evil.example"));
        assert!(!json.contains("must-not-emit"));
    }
}
