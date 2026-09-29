use std::time::Duration;

use reqwest::{blocking::Client, redirect::Policy, Url};
use serde::Serialize;
use serde_json::Value;

use crate::error::{CoreError, CoreResult};

const GITHUB_LATEST: &str =
    "https://api.github.com/repos/nekobyran/lanzouyou-download/releases/latest";
const GITHUB_REPOSITORY: &str = "nekobyran/lanzouyou-download";
const ANDROID_ASSET: &str = "LanzouYOU.apk";
const RELEASE_JSON_LIMIT: u64 = 256 * 1024;
const MIRROR_PREFIXES: &[&str] = &[
    "https://gh.llkk.cc/",
    "https://gh-proxy.com/",
    "https://ghfast.top/",
];

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AppUpdateInfo {
    pub version: String,
    pub body: String,
    pub asset_name: String,
    pub size: u64,
    pub github_url: String,
    pub download_urls: Vec<String>,
}

pub(crate) fn check_android(
    current_version: &str,
    prefer_mirror: bool,
) -> CoreResult<Option<AppUpdateInfo>> {
    let current = parse_version(current_version)?;
    let client = Client::builder()
        .use_rustls_tls()
        .redirect(Policy::none())
        .connect_timeout(Duration::from_secs(7))
        .timeout(Duration::from_secs(10))
        .user_agent("LanzouYOU-Update")
        .build()
        .map_err(CoreError::from_reqwest)?;
    let response = client
        .get(GITHUB_LATEST)
        .header("Accept", "application/vnd.github+json, application/json")
        .header("Accept-Encoding", "identity")
        .send()
        .map_err(CoreError::from_reqwest)?;
    if !response.status().is_success() {
        return Err(CoreError::remote(
            format!("更新请求失败 HTTP {}", response.status().as_u16()),
            response.status().is_server_error(),
        ));
    }
    if response
        .content_length()
        .is_some_and(|length| length > RELEASE_JSON_LIMIT)
    {
        return Err(CoreError::parse("更新信息过大"));
    }
    let bytes = response.bytes().map_err(CoreError::from_reqwest)?;
    if bytes.len() as u64 > RELEASE_JSON_LIMIT {
        return Err(CoreError::parse("更新信息过大"));
    }
    let release: Value =
        serde_json::from_slice(&bytes).map_err(|_| CoreError::parse("更新信息格式无效"))?;
    parse_release(&release, current, prefer_mirror)
}

fn parse_release(
    release: &Value,
    current: [u64; 3],
    prefer_mirror: bool,
) -> CoreResult<Option<AppUpdateInfo>> {
    if release
        .get("draft")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || release
            .get("prerelease")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(CoreError::parse("更新信息不是正式版本"));
    }
    let raw_tag = release
        .get("tag_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    let latest = parse_version(raw_tag)?;
    if latest <= current {
        return Ok(None);
    }

    let assets = release
        .get("assets")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::parse("更新信息缺少安装包"))?;
    let mut selected = None;
    for asset in assets {
        if asset.get("name").and_then(Value::as_str) != Some(ANDROID_ASSET)
            || asset
                .get("state")
                .and_then(Value::as_str)
                .is_some_and(|state| state != "uploaded")
        {
            continue;
        }
        if selected.is_some() {
            return Err(CoreError::parse("更新安装包不唯一"));
        }
        selected = Some(asset);
    }
    let asset = selected.ok_or_else(|| CoreError::parse("更新信息缺少指定安装包"))?;
    let size = asset
        .get("size")
        .and_then(Value::as_u64)
        .filter(|size| *size > 0)
        .ok_or_else(|| CoreError::parse("更新安装包大小无效"))?;
    let github_url = asset
        .get("browser_download_url")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    validate_github_asset(github_url, raw_tag, ANDROID_ASSET)?;

    let mut mirrors = MIRROR_PREFIXES
        .iter()
        .map(|prefix| format!("{prefix}{github_url}"))
        .collect::<Vec<_>>();
    let mut download_urls = Vec::with_capacity(mirrors.len().saturating_add(1));
    if prefer_mirror {
        download_urls.append(&mut mirrors);
        download_urls.push(github_url.to_owned());
    } else {
        download_urls.push(github_url.to_owned());
        download_urls.append(&mut mirrors);
    }

    Ok(Some(AppUpdateInfo {
        version: normalize_version(raw_tag).to_owned(),
        body: release
            .get("body")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_owned(),
        asset_name: ANDROID_ASSET.to_owned(),
        size,
        github_url: github_url.to_owned(),
        download_urls,
    }))
}

fn parse_version(value: &str) -> CoreResult<[u64; 3]> {
    let normalized = normalize_version(value);
    let mut parts = normalized.split('.');
    let major = parse_version_part(parts.next())?;
    let minor = parse_version_part(parts.next())?;
    let patch = parse_version_part(parts.next())?;
    if parts.next().is_some() {
        return Err(CoreError::invalid("版本号格式无效"));
    }
    Ok([major, minor, patch])
}

fn parse_version_part(value: Option<&str>) -> CoreResult<u64> {
    let value = value.ok_or_else(|| CoreError::invalid("版本号格式无效"))?;
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(CoreError::invalid("版本号格式无效"));
    }
    value
        .parse::<u64>()
        .map_err(|_| CoreError::invalid("版本号超出范围"))
}

fn normalize_version(value: &str) -> &str {
    value.trim().strip_prefix('v').unwrap_or(value.trim())
}

fn validate_github_asset(value: &str, tag: &str, asset_name: &str) -> CoreResult<()> {
    let url = Url::parse(value).map_err(|_| CoreError::parse("GitHub 安装包地址无效"))?;
    let expected = format!("/{GITHUB_REPOSITORY}/releases/download/{tag}/{asset_name}");
    if url.scheme() != "https"
        || url.host_str() != Some("github.com")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.path() != expected
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(CoreError::parse("GitHub 安装包地址不受信任"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(tag: &str, asset_name: &str) -> Value {
        serde_json::json!({
            "tag_name": tag,
            "draft": false,
            "prerelease": false,
            "body": "notes",
            "assets": [{
                "name": asset_name,
                "state": "uploaded",
                "size": 123456,
                "browser_download_url": format!(
                    "https://github.com/{GITHUB_REPOSITORY}/releases/download/{tag}/{asset_name}"
                )
            }]
        })
    }

    #[test]
    fn numeric_version_comparison_does_not_use_lexical_order() {
        let info = parse_release(
            &release("v1.10.0", ANDROID_ASSET),
            parse_version("1.9.9").unwrap(),
            false,
        )
        .unwrap()
        .unwrap();
        assert_eq!(info.version, "1.10.0");
    }

    #[test]
    fn stable_release_requires_exact_android_asset() {
        let error = parse_release(
            &release("v1.0.2", "other.apk"),
            parse_version("1.0.1").unwrap(),
            false,
        )
        .unwrap_err();
        assert_eq!(error.message, "更新信息缺少指定安装包");
    }

    #[test]
    fn mirror_preference_only_changes_order_and_keeps_github_fallback() {
        let info = parse_release(
            &release("v1.0.2", ANDROID_ASSET),
            parse_version("1.0.1").unwrap(),
            true,
        )
        .unwrap()
        .unwrap();
        assert!(info
            .download_urls
            .first()
            .unwrap()
            .starts_with("https://gh."));
        assert_eq!(info.download_urls.last().unwrap(), &info.github_url);
        assert_eq!(info.download_urls.len(), MIRROR_PREFIXES.len() + 1);
    }

    #[test]
    fn draft_and_prerelease_are_not_accepted_as_formal_updates() {
        for field in ["draft", "prerelease"] {
            let mut value = release("v1.0.2", ANDROID_ASSET);
            value[field] = Value::Bool(true);
            assert!(parse_release(&value, [1, 0, 1], false).is_err());
        }
    }

    #[test]
    fn current_or_older_release_is_not_an_update() {
        assert!(parse_release(
            &release("v1.0.1", ANDROID_ASSET),
            parse_version("1.0.1").unwrap(),
            false,
        )
        .unwrap()
        .is_none());
    }
}
