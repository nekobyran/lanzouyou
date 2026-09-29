use std::{
    collections::HashSet,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
};

#[cfg(test)]
use std::net::ToSocketAddrs;

use reqwest::Url;

use crate::error::{CoreError, CoreResult};

const FOLDER_MARKER: &str = "lanzou-folder=";

const CANONICAL_PUBLIC_ORIGIN: &str = "https://www.lanzouw.com";

#[derive(Clone, Debug)]
pub(crate) enum SecurityPolicy {
    Production,
    #[cfg(test)]
    Test {
        origin: String,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct FolderTarget {
    pub root_url: String,
    pub folder_id: String,
    pub title: String,
    pub description: String,
}

#[derive(Clone, Debug)]
pub(crate) struct ValidatedDirectTarget {
    pub url: Url,
    /// Exact DNS answers approved by the SSRF policy. `None` is reserved for
    /// the evidence-based Lanzou/dmpdmp allowlist (including proxy fake-IP)
    /// and the isolated local test policy.
    pub pinned_addresses: Option<Vec<SocketAddr>>,
}

/// Canonicalize user/catalog share URLs before any public operation applies
/// the strict request-host policy.
///
/// Historical Lanzou domains and HTTP links are accepted as input only. The
/// returned URL is always HTTPS on the single canonical public origin, drops
/// tracking query/ordinary fragments, and preserves only our bounded virtual
/// folder fragment. Credentials, explicit ports, IDNs and lookalike hosts are
/// rejected before a request can be made.
pub(crate) fn normalize_public_share_url(
    value: &str,
    _policy: &SecurityPolicy,
) -> CoreResult<String> {
    #[cfg(test)]
    if matches!(_policy, SecurityPolicy::Test { .. }) {
        return validate_page_url(value, _policy).map(|url| url.to_string());
    }

    let normalized = value.trim().replace(['。', '．'], ".");
    reject_explicit_port(&normalized)
        .map_err(|_| CoreError::invalid("请输入有效的蓝奏分享链接"))?;
    let parsed =
        Url::parse(&normalized).map_err(|_| CoreError::invalid("请输入有效的蓝奏分享链接"))?;
    let host = parsed.host_str().unwrap_or_default();
    if !matches!(parsed.scheme(), "http" | "https")
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.port().is_some()
        || !is_legacy_public_host(host)
        || parsed.path().is_empty()
        || parsed.path() == "/"
    {
        return Err(CoreError::invalid("请输入有效的蓝奏分享链接"));
    }

    let mut canonical = format!("{CANONICAL_PUBLIC_ORIGIN}{}", parsed.path());
    if let Some(fragment) = parsed
        .fragment()
        .filter(|fragment| fragment.starts_with(FOLDER_MARKER))
    {
        canonical.push('#');
        canonical.push_str(fragment);
    }
    Ok(canonical)
}

pub(crate) fn validate_page_url(value: &str, policy: &SecurityPolicy) -> CoreResult<Url> {
    let parsed = Url::parse(value.trim()).map_err(|_| CoreError::invalid("蓝奏分享地址无效"))?;
    match policy {
        SecurityPolicy::Production => {
            reject_explicit_port(value)?;
            if !url_authority(value)?.is_ascii() {
                return Err(CoreError::invalid("仅允许 ASCII 蓝奏分享主机名"));
            }
            if parsed.scheme() != "https"
                || parsed.username() != ""
                || parsed.password().is_some()
                || parsed.port().is_some()
                || !parsed.host_str().is_some_and(is_lanzou_host)
            {
                return Err(CoreError::invalid("仅允许可信的蓝奏 HTTPS 分享地址"));
            }
        }
        #[cfg(test)]
        SecurityPolicy::Test { origin } => {
            let expected =
                Url::parse(origin).map_err(|_| CoreError::invalid("测试服务地址无效"))?;
            if parsed.scheme() != expected.scheme()
                || parsed.host_str() != expected.host_str()
                || parsed.port_or_known_default() != expected.port_or_known_default()
            {
                return Err(CoreError::invalid("测试请求离开了受信任源"));
            }
        }
    }
    Ok(parsed)
}

pub(crate) fn validate_verification_url(value: &str, _policy: &SecurityPolicy) -> CoreResult<Url> {
    #[cfg(test)]
    if matches!(_policy, SecurityPolicy::Test { .. }) {
        return validate_page_url(value, _policy);
    }
    reject_explicit_port(value).map_err(|_| CoreError::parse("蓝奏验证地址不受信任"))?;
    let parsed = Url::parse(value.trim()).map_err(|_| CoreError::parse("蓝奏验证地址无效"))?;
    let is_lanzou = parsed.host_str().is_some_and(is_lanzou_host);
    let is_verification = parsed.host_str().is_some_and(is_verification_host);
    let trusted_host = is_lanzou || is_verification;
    if parsed.scheme() != "https"
        || parsed.username() != ""
        || parsed.password().is_some()
        || parsed.port().is_some()
        || parsed.fragment().is_some()
        || !trusted_host
        || is_verification && !is_verification_page_path(parsed.path())
    {
        return Err(CoreError::parse("蓝奏验证地址不受信任"));
    }
    Ok(parsed)
}

pub(crate) fn validate_verification_hop(
    initial: &Url,
    value: &str,
    policy: &SecurityPolicy,
) -> CoreResult<Url> {
    let candidate = validate_verification_url(value, policy)?;
    if initial.scheme() != candidate.scheme()
        || initial.host_str() != candidate.host_str()
        || initial.port_or_known_default() != candidate.port_or_known_default()
    {
        return Err(CoreError::parse("蓝奏验证跳转离开了初始源"));
    }
    Ok(candidate)
}

#[cfg(test)]
pub(crate) fn validate_direct_url(value: &str, policy: &SecurityPolicy) -> CoreResult<Url> {
    validate_direct_target_with_resolver(value, policy, |host| {
        (host, 443)
            .to_socket_addrs()
            .map_err(|_| CoreError::remote("无法验证蓝奏直链主机", true))
            .map(|addresses| addresses.map(|address| address.ip()).collect())
    })
    .map(|target| target.url)
}

pub(crate) fn validate_direct_target_with_resolver<F>(
    value: &str,
    _policy: &SecurityPolicy,
    resolver: F,
) -> CoreResult<ValidatedDirectTarget>
where
    F: FnOnce(&str) -> CoreResult<Vec<IpAddr>>,
{
    let parsed = Url::parse(value.trim()).map_err(|_| CoreError::parse("蓝奏返回了无效直链"))?;
    #[cfg(test)]
    if matches!(_policy, SecurityPolicy::Test { .. }) {
        return validate_page_url(value, _policy).map(|url| ValidatedDirectTarget {
            url,
            pinned_addresses: None,
        });
    }
    reject_explicit_port(value).map_err(|_| CoreError::parse("蓝奏返回了不安全的直链"))?;
    if parsed.scheme() != "https"
        || parsed.username() != ""
        || parsed.password().is_some()
        || parsed.port().is_some()
        || parsed.fragment().is_some()
    {
        return Err(CoreError::parse("蓝奏返回了不安全的直链"));
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| CoreError::parse("蓝奏直链缺少主机名"))?;
    if host.eq_ignore_ascii_case("localhost") || host.ends_with(".local") {
        return Err(CoreError::parse("蓝奏直链指向了本地网络"));
    }
    if is_lanzou_host(host) || is_verification_host(host) {
        return Ok(ValidatedDirectTarget {
            url: parsed,
            pinned_addresses: None,
        });
    }
    // `Url::host_str` keeps the brackets around an IPv6 literal. Normalize
    // only that serialization wrapper so literals are classified locally
    // instead of accidentally being sent through DNS as a hostname.
    let literal_host = host
        .strip_prefix('[')
        .and_then(|value| value.strip_suffix(']'))
        .unwrap_or(host);
    let literal_ip = literal_host.parse::<IpAddr>().ok();
    let resolved = if let Some(ip) = literal_ip {
        vec![ip]
    } else {
        resolver(host)?
    };
    if !direct_host_addresses_are_safe(host, &resolved) {
        return Err(if literal_ip.is_some() {
            CoreError::parse("蓝奏直链指向了本地网络")
        } else {
            CoreError::parse("蓝奏直链主机解析到了非公网地址")
        });
    }
    let mut seen = HashSet::new();
    let pinned_addresses = resolved
        .into_iter()
        .filter(|address| seen.insert(*address))
        .map(|address| SocketAddr::new(address, 443))
        .collect::<Vec<_>>();
    if pinned_addresses.is_empty() {
        return Err(CoreError::remote("无法验证蓝奏直链主机", true));
    }
    Ok(ValidatedDirectTarget {
        url: parsed,
        pinned_addresses: Some(pinned_addresses),
    })
}

#[cfg(test)]
fn validate_direct_target_with_resolved(
    value: &str,
    policy: &SecurityPolicy,
    resolved: Option<&[IpAddr]>,
) -> CoreResult<ValidatedDirectTarget> {
    validate_direct_target_with_resolver(value, policy, |host| {
        if let Some(resolved) = resolved {
            Ok(resolved.to_vec())
        } else {
            (host, 443)
                .to_socket_addrs()
                .map_err(|_| CoreError::remote("无法验证蓝奏直链主机", true))
                .map(|addresses| addresses.map(|address| address.ip()).collect())
        }
    })
}

fn direct_host_addresses_are_safe(host: &str, resolved: &[IpAddr]) -> bool {
    // Lanzou's current file and verification CDN uses dmpdmp.com. Local proxy
    // clients commonly expose trusted remote hosts through RFC 2544 fake-IP
    // addresses (198.18.0.0/15); treating that local resolver view as SSRF
    // breaks otherwise valid downloads. The exact evidence-based Lanzou and
    // dmpdmp host allowlists remain safe without DNS classification, while all
    // other hostnames and literal IPs must still resolve exclusively public.
    is_lanzou_host(host)
        || is_verification_host(host)
        || (!resolved.is_empty() && resolved.iter().all(|ip| is_public_ip(*ip)))
}

pub(crate) fn safe_asset_url(value: &str) -> Option<String> {
    reject_explicit_port(value).ok()?;
    let parsed = Url::parse(value.trim()).ok()?;
    if parsed.scheme() != "https"
        || parsed.username() != ""
        || parsed.password().is_some()
        || parsed.port().is_some()
        || parsed.fragment().is_some()
    {
        return None;
    }
    let host = parsed.host_str()?.to_ascii_lowercase();
    let trusted = host == "image.dmpdmp.com"
        || (host == "images.bakstotre.com" && parsed.path().starts_with("/assets/images/type/"));
    trusted.then(|| parsed.to_string())
}

pub(crate) fn join_page_url(base: &str, value: &str, policy: &SecurityPolicy) -> CoreResult<Url> {
    let base = validate_page_url(base, policy)?;
    if matches!(policy, SecurityPolicy::Production) {
        reject_explicit_port_reference(value)?;
    }
    let joined = base
        .join(value)
        .map_err(|_| CoreError::parse("蓝奏页面返回了无效跳转"))?;
    validate_page_url(joined.as_str(), policy)
}

pub(crate) fn join_verification_url(
    base: &str,
    value: &str,
    policy: &SecurityPolicy,
) -> CoreResult<Url> {
    let base = validate_page_url(base, policy)?;
    if matches!(policy, SecurityPolicy::Production) {
        reject_explicit_port_reference(value)
            .map_err(|_| CoreError::parse("蓝奏验证跳转地址不受信任"))?;
    }
    let joined = base
        .join(value)
        .map_err(|_| CoreError::parse("蓝奏验证跳转地址无效"))?;
    let verified = validate_verification_url(joined.as_str(), policy)?;
    if matches!(policy, SecurityPolicy::Production)
        && verified.host_str().is_some_and(is_verification_host)
        && !is_verification_page_path(verified.path())
    {
        return Err(CoreError::parse("蓝奏验证跳转路径不受信任"));
    }
    Ok(verified)
}

pub(crate) fn same_origin_endpoint(
    page_url: &str,
    raw: &str,
    expected_suffix: &str,
    policy: &SecurityPolicy,
) -> CoreResult<Url> {
    let page = validate_page_url(page_url, policy)?;
    if matches!(policy, SecurityPolicy::Production) {
        reject_explicit_port_reference(raw)?;
    }
    let endpoint = page
        .join(raw)
        .map_err(|_| CoreError::parse("蓝奏接口地址无效"))?;
    validate_page_url(endpoint.as_str(), policy)?;
    if page.scheme() != endpoint.scheme()
        || page.host_str() != endpoint.host_str()
        || page.port_or_known_default() != endpoint.port_or_known_default()
        || !endpoint.path().ends_with(expected_suffix)
    {
        return Err(CoreError::parse("蓝奏页面返回了非同源接口"));
    }
    Ok(endpoint)
}

pub(crate) fn same_origin_verification_endpoint(
    page_url: &str,
    raw: &str,
    expected_suffix: &str,
    policy: &SecurityPolicy,
) -> CoreResult<Url> {
    let page = validate_verification_url(page_url, policy)?;
    if matches!(policy, SecurityPolicy::Production) {
        reject_explicit_port_reference(raw)
            .map_err(|_| CoreError::parse("蓝奏验证接口地址不受信任"))?;
    }
    let endpoint = page
        .join(raw)
        .map_err(|_| CoreError::parse("蓝奏验证接口地址无效"))?;
    validate_verification_url(endpoint.as_str(), policy)?;
    if page.scheme() != endpoint.scheme()
        || page.host_str() != endpoint.host_str()
        || page.port_or_known_default() != endpoint.port_or_known_default()
        || !endpoint.path().starts_with("/file/")
        || !endpoint.path().ends_with(expected_suffix)
        || endpoint
            .path_segments()
            .and_then(Iterator::last)
            .is_none_or(|segment| segment != expected_suffix.trim_start_matches('/'))
    {
        return Err(CoreError::parse("蓝奏验证页面返回了非同源接口"));
    }
    Ok(endpoint)
}

pub(crate) fn origin(value: &str, policy: &SecurityPolicy) -> CoreResult<String> {
    let parsed = validate_page_url(value, policy)?;
    let host = parsed
        .host_str()
        .ok_or_else(|| CoreError::parse("蓝奏地址缺少主机名"))?;
    let mut output = format!("{}://{}", parsed.scheme(), host);
    if let Some(port) = parsed.port() {
        output.push(':');
        output.push_str(&port.to_string());
    }
    Ok(output)
}

pub(crate) fn parse_folder_target(value: &str) -> FolderTarget {
    let trimmed = value.trim();
    let Ok(mut parsed) = Url::parse(trimmed) else {
        return FolderTarget {
            root_url: trimmed.to_owned(),
            ..FolderTarget::default()
        };
    };
    let Some(fragment) = parsed.fragment().map(ToOwned::to_owned) else {
        return FolderTarget {
            root_url: trimmed.to_owned(),
            ..FolderTarget::default()
        };
    };
    let Some(values) = fragment.strip_prefix(FOLDER_MARKER) else {
        parsed.set_fragment(None);
        return FolderTarget {
            root_url: parsed.to_string(),
            ..FolderTarget::default()
        };
    };
    let query = format!("folderId={values}");
    let parsed_values: Vec<(String, String)> = Url::parse(&format!("https://local/?{query}"))
        .ok()
        .map(|url| url.query_pairs().into_owned().collect())
        .unwrap_or_default();
    parsed.set_fragment(None);
    let mut target = FolderTarget {
        root_url: parsed.to_string(),
        ..FolderTarget::default()
    };
    for (key, value) in parsed_values {
        match key.as_str() {
            "folderId" => target.folder_id = value,
            "title" => target.title = value,
            "description" => target.description = value,
            _ => {}
        }
    }
    target
}

pub(crate) fn virtual_folder_url(
    root: &str,
    id: &str,
    title: &str,
    description: &str,
) -> CoreResult<String> {
    let mut root = Url::parse(root).map_err(|_| CoreError::parse("蓝奏目录地址无效"))?;
    root.set_fragment(None);
    let mut query = Url::parse("https://local/").expect("static URL is valid");
    query
        .query_pairs_mut()
        .append_pair("folderId", id)
        .append_pair("title", title)
        .append_pair("description", description);
    let fragment = query.query().unwrap_or_default();
    root.set_fragment(Some(&fragment.replacen("folderId=", FOLDER_MARKER, 1)));
    Ok(root.to_string())
}

pub(crate) fn reject_explicit_port(value: &str) -> CoreResult<()> {
    let authority = url_authority(value)?.rsplit('@').next().unwrap_or_default();
    let has_port = if authority.starts_with('[') {
        authority.find(']').is_some_and(|end| {
            authority
                .get(end + 1..)
                .is_some_and(|tail| tail.starts_with(':'))
        })
    } else {
        authority.contains(':')
    };
    if has_port {
        Err(CoreError::invalid("URL 不允许显式端口"))
    } else {
        Ok(())
    }
}

fn url_authority(value: &str) -> CoreResult<&str> {
    value
        .trim()
        .split_once("://")
        .map(|(_, rest)| rest)
        .ok_or_else(|| CoreError::invalid("URL 缺少协议"))?
        .split(['/', '?', '#'])
        .next()
        .ok_or_else(|| CoreError::invalid("URL 缺少主机名"))
}

pub(crate) fn reject_explicit_port_reference(value: &str) -> CoreResult<()> {
    let trimmed = value.trim();
    if trimmed.contains('\\') || trimmed.starts_with("///") {
        Err(CoreError::invalid("URL 引用格式不受信任"))
    } else if trimmed.starts_with("//") {
        reject_explicit_port(&format!("https:{trimmed}"))
    } else if trimmed.contains("://") {
        reject_explicit_port(trimmed)
    } else {
        Ok(())
    }
}

fn is_lanzou_host(host: &str) -> bool {
    is_legacy_public_host(host)
}

fn is_legacy_public_host(host: &str) -> bool {
    if !host.is_ascii() || host.ends_with('.') {
        return false;
    }
    let host = host.to_ascii_lowercase();
    let labels = host.split('.').collect::<Vec<_>>();
    if labels.len() < 2
        || labels.last().copied() != Some("com")
        || labels[..labels.len() - 2]
            .iter()
            .any(|label| !is_plain_ascii_dns_label(label))
    {
        return false;
    }
    matches!(
        labels[labels.len() - 2],
        "lanzouw"
            | "lanzoui"
            | "lanzoub"
            | "lanzouq"
            | "lanzoux"
            | "lanzouy"
            | "lanzoup"
            | "lanzout"
            | "lanzous"
            | "lanzouj"
            | "lanzov"
            | "laozouw"
    )
}

fn is_verification_host(host: &str) -> bool {
    is_ascii_host_or_subdomain(host, "dmpdmp.com")
}

fn is_ascii_host_or_subdomain(host: &str, root: &str) -> bool {
    if !host.is_ascii() || host.ends_with('.') {
        return false;
    }
    let host = host.to_ascii_lowercase();
    if host == root {
        return true;
    }
    let Some(prefix) = host.strip_suffix(&format!(".{root}")) else {
        return false;
    };
    !prefix.is_empty() && prefix.split('.').all(is_plain_ascii_dns_label)
}

fn is_plain_ascii_dns_label(label: &str) -> bool {
    !label.is_empty()
        && label.len() <= 63
        && !label.starts_with("xn--")
        && label
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        && label
            .as_bytes()
            .last()
            .is_some_and(u8::is_ascii_alphanumeric)
        && label
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn is_verification_page_path(path: &str) -> bool {
    path == "/file" || path.starts_with("/file/")
}

pub(crate) fn is_public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(value) => is_public_ipv4(value),
        IpAddr::V6(value) => is_public_ipv6(value),
    }
}

fn is_public_ipv4(value: Ipv4Addr) -> bool {
    let [a, b, c, d] = value.octets();
    !(a == 0
        || a == 10
        || a == 127
        || (a == 100 && (64..=127).contains(&b))
        || (a == 169 && b == 254)
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && b == 168)
        || (a == 192 && b == 0 && c == 0 && d != 9 && d != 10)
        || (a == 192 && b == 0 && c == 2)
        || (a == 192 && b == 88 && c == 99)
        || (a == 198 && (b == 18 || b == 19))
        || (a == 198 && b == 51 && c == 100)
        || (a == 203 && b == 0 && c == 113)
        || a >= 224
        || (a == 255 && b == 255 && c == 255 && d == 255))
}

fn is_public_ipv6(value: Ipv6Addr) -> bool {
    let segments = value.segments();
    let octets = value.octets();
    let mapped_ipv4 = matches!(segments, [0, 0, 0, 0, 0, 0xffff, _, _]);
    let deprecated_ipv4_compatible = matches!(segments, [0, 0, 0, 0, 0, 0, _, _]);
    let nat64_well_known_private = matches!(segments, [0x0064, 0xff9b, 0, 0, 0, 0, _, _])
        && !is_public_ipv4(Ipv4Addr::new(
            octets[12], octets[13], octets[14], octets[15],
        ));
    let ietf_assignment = segments[0] == 0x2001 && segments[1] < 0x0200;
    let ietf_global_exception = u128::from_be_bytes(octets)
        == 0x2001_0001_0000_0000_0000_0000_0000_0001
        || u128::from_be_bytes(octets) == 0x2001_0001_0000_0000_0000_0000_0000_0002
        || (segments[0] == 0x2001 && segments[1] == 0x0003)
        || (segments[0] == 0x2001 && segments[1] == 0x0004 && segments[2] == 0x0112)
        || (segments[0] == 0x2001 && (0x0020..=0x003f).contains(&segments[1]));
    !(value.is_loopback()
        || value.is_unspecified()
        || value.is_multicast()
        || mapped_ipv4
        || deprecated_ipv4_compatible
        || nat64_well_known_private
        || value.is_unique_local()
        || value.is_unicast_link_local()
        || (segments[0] == 0x0064 && segments[1] == 0xff9b && segments[2] == 0x0001)
        || (segments[0] == 0x0100 && segments[1] == 0 && segments[2] == 0 && segments[3] == 0)
        || (ietf_assignment && !ietf_global_exception)
        || (segments[0] == 0x2001 && segments[1] == 0x0db8)
        || segments[0] == 0x2002
        || (segments[0] == 0x3fff && segments[1] <= 0x0fff)
        || segments[0] == 0x5f00
        || (segments[0] & 0xffc0) == 0xfec0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_same_origin_endpoint_rejects_host_switch() {
        assert!(same_origin_endpoint(
            "https://www.lanzouw.com/b1",
            "https://evil.example/filemoreajax.php?file=1",
            "/filemoreajax.php",
            &SecurityPolicy::Production,
        )
        .is_err());
    }

    #[test]
    fn test_virtual_folder_roundtrip_preserves_unicode_metadata() {
        let value = virtual_folder_url(
            "https://www.lanzouw.com/b1",
            "42",
            "工具 合集",
            "第一行/第二行",
        )
        .unwrap();
        let target = parse_folder_target(&value);
        assert_eq!(target.folder_id, "42");
        assert_eq!(target.title, "工具 合集");
        assert_eq!(target.description, "第一行/第二行");
    }

    #[test]
    fn test_direct_url_rejects_private_ip() {
        assert!(
            validate_direct_url("https://127.0.0.1/file/a", &SecurityPolicy::Production).is_err()
        );
    }

    #[test]
    fn test_trusted_lanzou_cdn_accepts_local_proxy_fake_ip_without_weakening_other_hosts() {
        let fake_ip = "198.18.0.42".parse().unwrap();

        assert!(direct_host_addresses_are_safe(
            "c1031.dmpdmp.com",
            &[fake_ip]
        ));
        assert!(!direct_host_addresses_are_safe(
            "download.evil.example",
            &[fake_ip]
        ));
        assert!(!direct_host_addresses_are_safe(
            "dmpdmp.com.evil.example",
            &[fake_ip]
        ));
        assert!(!direct_host_addresses_are_safe(
            "evil-dmpdmp.com",
            &[fake_ip]
        ));
    }

    #[test]
    fn test_ipv4_embedded_ipv6_reuses_private_ipv4_policy() {
        assert!(!is_public_ipv6("::ffff:127.0.0.1".parse().unwrap()));
        assert!(!is_public_ipv6("::ffff:192.168.1.1".parse().unwrap()));
        assert!(!is_public_ipv6("::127.0.0.1".parse().unwrap()));
        assert!(!is_public_ipv6("::192.168.1.1".parse().unwrap()));
        assert!(!is_public_ipv6("::ffff:8.8.8.8".parse().unwrap()));
        assert!(!is_public_ipv6("::8.8.8.8".parse().unwrap()));
        assert!(!is_public_ipv6("64:ff9b::127.0.0.1".parse().unwrap()));
        assert!(!is_public_ipv6("64:ff9b::100.64.0.1".parse().unwrap()));
        assert!(!is_public_ipv6("64:ff9b::169.254.1.1".parse().unwrap()));
        assert!(!is_public_ipv6("64:ff9b::192.168.1.1".parse().unwrap()));
        assert!(!is_public_ipv6("64:ff9b::224.0.0.1".parse().unwrap()));
        assert!(is_public_ipv6("64:ff9b::8.8.8.8".parse().unwrap()));
    }

    #[test]
    fn test_direct_literal_ipv6_is_classified_without_dns_fallback() {
        let policy = SecurityPolicy::Production;
        let public: IpAddr = "2001:4860:4860::8888".parse().unwrap();
        let target = validate_direct_target_with_resolver(
            "https://[2001:4860:4860::8888]/file/app.apk",
            &policy,
            |_| panic!("an IPv6 literal must not be sent to DNS"),
        )
        .unwrap();
        assert_eq!(
            target.pinned_addresses,
            Some(vec![SocketAddr::new(public, 443)])
        );

        for value in [
            "https://[::1]/file/app.apk",
            "https://[::ffff:127.0.0.1]/file/app.apk",
            "https://[::192.168.1.1]/file/app.apk",
            "https://[64:ff9b::192.168.1.1]/file/app.apk",
            "https://[64:ff9b:1::1]/file/app.apk",
            "https://[2001:db8::1]/file/app.apk",
            "https://[fc00::1]/file/app.apk",
        ] {
            let error = validate_direct_target_with_resolver(value, &policy, |_| {
                panic!("a private IPv6 literal must not be sent to DNS")
            })
            .unwrap_err();
            assert_eq!(error.code, "parse_error", "{value}");
            assert!(error.message.contains("本地网络"), "{value}: {error:?}");
        }
    }

    #[test]
    fn test_public_ip_policy_rejects_complete_ipv4_special_use_boundaries() {
        for value in [
            "0.0.0.0",
            "0.255.255.255",
            "10.0.0.1",
            "100.64.0.1",
            "100.127.255.254",
            "127.255.255.255",
            "169.254.1.1",
            "172.16.0.1",
            "172.31.255.254",
            "192.0.0.1",
            "192.0.2.1",
            "192.88.99.1",
            "192.168.1.1",
            "198.18.0.1",
            "198.19.255.254",
            "198.51.100.1",
            "203.0.113.1",
            "224.0.0.1",
            "239.255.255.255",
            "240.0.0.1",
            "255.255.255.255",
        ] {
            assert!(!is_public_ip(value.parse().unwrap()), "{value}");
        }
        for value in [
            "8.8.8.8",
            "100.128.0.1",
            "172.32.0.1",
            "192.0.0.9",
            "192.0.0.10",
            "203.0.114.1",
        ] {
            assert!(is_public_ip(value.parse().unwrap()), "{value}");
        }
    }

    #[test]
    fn test_public_ip_policy_rejects_complete_ipv6_non_public_boundaries() {
        for value in [
            "::",
            "::1",
            "64:ff9b:1::1",
            "100::1",
            "2001::1",
            "2001:db8::1",
            "2002::1",
            "3fff::1",
            "5f00::1",
            "fc00::1",
            "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            "fe80::1",
            "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            "fec0::1",
            "ff00::1",
        ] {
            assert!(!is_public_ip(value.parse().unwrap()), "{value}");
        }
        for value in [
            "64:ff9b::808:808",
            "2001:1::1",
            "2001:1::2",
            "2001:3::1",
            "2001:4:112::1",
            "2001:20::1",
            "2001:30::1",
            "2001:4860:4860::8888",
            "2606:4700:4700::1111",
            "3ffe::1",
            "3fff:1000::1",
        ] {
            assert!(is_public_ip(value.parse().unwrap()), "{value}");
        }
    }

    #[test]
    fn test_direct_connection_plan_pins_only_untrusted_public_dns_answers() {
        let public: IpAddr = "8.8.8.8".parse().unwrap();
        let fake_ip: IpAddr = "198.18.0.42".parse().unwrap();
        let policy = SecurityPolicy::Production;

        let target = validate_direct_target_with_resolved(
            "https://download.example/file/app.apk",
            &policy,
            Some(&[public]),
        )
        .unwrap();
        assert_eq!(
            target.pinned_addresses,
            Some(vec![SocketAddr::new(public, 443)])
        );

        let trusted = validate_direct_target_with_resolved(
            "https://c1031.dmpdmp.com/file/app.apk",
            &policy,
            Some(&[fake_ip]),
        )
        .unwrap();
        assert!(trusted.pinned_addresses.is_none());

        for host in ["dmpdmp.com.evil.example", "evil-dmpdmp.com"] {
            assert!(validate_direct_target_with_resolved(
                &format!("https://{host}/file/app.apk"),
                &policy,
                Some(&[fake_ip]),
            )
            .is_err());
        }
    }

    #[test]
    fn test_asset_url_only_allows_known_https_hosts() {
        assert!(safe_asset_url("https://image.dmpdmp.com/image/a.png").is_some());
        assert!(safe_asset_url("https://images.bakstotre.com/assets/images/type/a.gif").is_some());
        assert!(safe_asset_url("https://127.0.0.1/icon.png").is_none());
        assert!(safe_asset_url("https://evil.example/icon.png").is_none());
        assert!(safe_asset_url("http://images.bakstotre.com/icon.png").is_none());
        assert!(safe_asset_url("https://other.dmpdmp.com/image/a.png").is_none());
        assert!(safe_asset_url("https://other.bakstotre.com/assets/images/type/a.gif").is_none());
        assert!(safe_asset_url("https://www.lanzouw.com/icon.png").is_none());
    }

    #[test]
    fn test_public_share_host_uses_exact_evidence_based_allowlist() {
        let policy = SecurityPolicy::Production;
        for value in [
            "https://lanzouw.com/b1",
            "https://www.lanzouw.com/b1",
            "https://a-b.lanzoui.com/b1",
        ] {
            assert!(validate_page_url(value, &policy).is_ok(), "{value}");
        }
        for value in [
            "https://lanzou0.com/b1",
            "https://lanzou1.com/b1",
            "https://lanzoua.com/b1",
            "https://evil-lanzouw.com/b1",
            "https://lanzouw.com.evil.example/b1",
            "https://lanzouw.com./b1",
            "https://-bad.lanzouw.com/b1",
            "https://bad-.lanzouw.com/b1",
            "https://woozooo.com/b1",
            "https://蓝奏.lanzouw.com/b1",
        ] {
            assert!(validate_page_url(value, &policy).is_err(), "{value}");
        }
    }

    #[test]
    fn test_common_public_operations_canonicalize_legacy_hosts_before_strict_validation() {
        let policy = SecurityPolicy::Production;
        let cases = [
            (
                "probe",
                "http://share.LanZouB.com/path/to/source?ignored=yes#ordinary",
                "https://www.lanzouw.com/path/to/source",
            ),
            (
                "browse",
                "https://cdn.laozouw.com/legacy#lanzou-folder=42&title=%E5%B7%A5%E5%85%B7",
                "https://www.lanzouw.com/legacy#lanzou-folder=42&title=%E5%B7%A5%E5%85%B7",
            ),
            (
                "resolve",
                "https://www。lanzouq．com/fullwidth",
                "https://www.lanzouw.com/fullwidth",
            ),
            (
                "describe",
                "https://mirror.lanzoui.com/i-description?tracking=discarded",
                "https://www.lanzouw.com/i-description",
            ),
            (
                "download",
                "https://pan.lanzoux.com/i-download#discarded",
                "https://www.lanzouw.com/i-download",
            ),
        ];

        for (operation, input, expected) in cases {
            let normalized = normalize_public_share_url(input, &policy).unwrap();
            assert_eq!(normalized, expected, "{operation}");
            validate_page_url(&normalized, &policy).unwrap_or_else(|error| {
                panic!("{operation} escaped strict request roots: {error:?}")
            });
        }
    }

    #[test]
    fn test_common_public_operation_normalization_rejects_host_lookalikes_and_url_authority() {
        let policy = SecurityPolicy::Production;
        for value in [
            "https://evil-lanzouw.com/source",
            "https://www.lanzouxx.com/source",
            "https://user@www.lanzouw.com/source",
            "https://www.lanzouw.com:443/source",
            "https://xn--evil-9za.lanzouq.com/source",
            "https://www.lanzouw.com/",
            "ftp://www.lanzouw.com/source",
        ] {
            assert!(
                normalize_public_share_url(value, &policy).is_err(),
                "{value}"
            );
        }
    }

    #[test]
    fn test_url_scopes_reject_every_explicit_port_including_443() {
        let policy = SecurityPolicy::Production;
        for value in [
            "https://www.lanzouw.com:443/b1",
            "https://www.lanzouw.com:444/b1",
        ] {
            assert!(validate_page_url(value, &policy).is_err(), "{value}");
        }
        for value in [
            "https://verify.dmpdmp.com:443/file/token",
            "https://verify.dmpdmp.com:444/file/token",
        ] {
            assert!(
                validate_verification_url(value, &policy).is_err(),
                "{value}"
            );
        }
        for value in [
            "https://image.dmpdmp.com:443/image/a.png",
            "https://images.bakstotre.com:444/assets/images/type/a.gif",
        ] {
            assert!(safe_asset_url(value).is_none(), "{value}");
        }
        for value in [
            "//verify.dmpdmp.com:443/file/token",
            "///verify.dmpdmp.com:443/file/token",
            r"\\verify.dmpdmp.com:443/file/token",
            r"https:\\verify.dmpdmp.com:443\file\token",
        ] {
            assert!(reject_explicit_port_reference(value).is_err(), "{value}");
        }
    }

    #[test]
    fn test_verification_scope_allows_dmpdmp_without_expanding_share_scope() {
        let value = "https://slsstm.dmpdmp.com/file/token";
        assert!(validate_page_url(value, &SecurityPolicy::Production).is_err());
        assert!(validate_verification_url(value, &SecurityPolicy::Production).is_ok());
        assert!(join_verification_url(
            "https://www.lanzouw.com/tp/file",
            value,
            &SecurityPolicy::Production,
        )
        .is_ok());
        assert!(join_verification_url(
            "https://www.lanzouw.com/tp/file",
            "https://slsstm.dmpdmp.com/not-file/token",
            &SecurityPolicy::Production,
        )
        .is_err());
        assert!(validate_verification_url(
            "https://evil.example/file/token",
            &SecurityPolicy::Production,
        )
        .is_err());
    }

    #[test]
    fn test_verification_scope_restricts_path_origin_and_ajax_location() {
        let policy = SecurityPolicy::Production;
        for value in [
            "https://verify.dmpdmp.com/file",
            "https://verify.dmpdmp.com/file/",
            "https://verify.dmpdmp.com/file/token",
        ] {
            assert!(validate_verification_url(value, &policy).is_ok(), "{value}");
            assert!(
                join_verification_url("https://www.lanzouw.com/tp/file", value, &policy,).is_ok(),
                "{value}"
            );
        }
        for value in [
            "https://verify.dmpdmp.com/",
            "https://verify.dmpdmp.com/not-file/token",
            "https://verify.dmpdmp.com/fileish/token",
        ] {
            assert!(
                validate_verification_url(value, &policy).is_err(),
                "{value}"
            );
        }
        assert!(same_origin_verification_endpoint(
            "https://verify.dmpdmp.com/file/token",
            "/file/ajax.php",
            "/ajax.php",
            &policy,
        )
        .is_ok());
        for endpoint in [
            "https://other.dmpdmp.com/file/ajax.php",
            "/ajax.php",
            "/not-file/ajax.php",
            "/file/ajax.php/extra",
        ] {
            assert!(
                same_origin_verification_endpoint(
                    "https://verify.dmpdmp.com/file/token",
                    endpoint,
                    "/ajax.php",
                    &policy,
                )
                .is_err(),
                "{endpoint}"
            );
        }
    }

    #[test]
    fn test_dmpdmp_verification_hops_stay_on_initial_origin() {
        let policy = SecurityPolicy::Production;
        let initial =
            validate_verification_url("https://verify.dmpdmp.com/file/token", &policy).unwrap();
        assert!(validate_verification_hop(
            &initial,
            "https://verify.dmpdmp.com/file/next",
            &policy,
        )
        .is_ok());
        for value in [
            "https://other.dmpdmp.com/file/next",
            "https://verify.dmpdmp.com:443/file/next",
            "http://verify.dmpdmp.com/file/next",
            "https://user@verify.dmpdmp.com/file/next",
            "https://verify.dmpdmp.com/not-file/next",
        ] {
            assert!(
                validate_verification_hop(&initial, value, &policy).is_err(),
                "{value}"
            );
        }
    }
}
