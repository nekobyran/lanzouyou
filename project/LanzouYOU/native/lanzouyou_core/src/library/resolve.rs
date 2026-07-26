use std::{collections::BTreeMap, time::Duration};

use serde_json::Value;

use crate::error::{CoreError, CoreResult};
use crate::operation::OperationHandle;

use super::{
    html::{capture, parse_page, strip},
    model::LibraryResolved,
    security::sanitize_access_code_error,
    session::{wait_cooperatively, LibraryTransport, ANDROID_USER_AGENT},
    url::{
        join_page_url, join_verification_url, same_origin_endpoint,
        same_origin_verification_endpoint, validate_page_url, SecurityPolicy,
    },
};

#[derive(Clone, Copy, Debug)]
pub(crate) struct DirectExchangeDelays {
    pub initial: Duration,
    pub retry: Duration,
}

impl DirectExchangeDelays {
    #[cfg(test)]
    pub(crate) const ZERO: Self = Self {
        initial: Duration::ZERO,
        retry: Duration::ZERO,
    };

    pub(crate) const fn production() -> Self {
        Self {
            initial: Duration::from_millis(1_900),
            retry: Duration::from_millis(250),
        }
    }
}

pub(crate) fn resolve(
    source_id: &str,
    share_url: &str,
    password: &str,
    policy: SecurityPolicy,
    exchange_delays: DirectExchangeDelays,
    operation: Option<&OperationHandle>,
) -> CoreResult<LibraryResolved> {
    resolve_with_transport(
        source_id,
        share_url,
        password,
        policy,
        exchange_delays,
        operation,
    )
    .map(|(_, resolved)| resolved)
}

pub(crate) fn resolve_with_transport(
    source_id: &str,
    share_url: &str,
    password: &str,
    policy: SecurityPolicy,
    exchange_delays: DirectExchangeDelays,
    operation: Option<&OperationHandle>,
) -> CoreResult<(LibraryTransport, LibraryResolved)> {
    if source_id.trim().is_empty() {
        return Err(CoreError::invalid("sourceId 不能为空"));
    }
    if password.chars().count() > 64 || password.chars().any(char::is_control) {
        return Err(CoreError::invalid("分享密码格式无效"));
    }
    validate_page_url(share_url, &policy)?;
    let mut last = None;
    for _ in 0..2 {
        if let Some(operation) = operation {
            operation.check_cancelled()?;
        }
        let transport = LibraryTransport::build(policy.clone())?;
        match resolve_once(&transport, share_url, password, exchange_delays, operation) {
            Ok(value) => return Ok((transport, value)),
            Err(error)
                if matches!(
                    error.code,
                    "cancelled" | "share_cancelled" | "password_required"
                ) =>
            {
                return Err(error)
            }
            Err(error) => {
                last = Some(sanitize_access_code_error(error, !password.is_empty()));
            }
        }
    }
    Err(last.unwrap_or_else(|| CoreError::remote("蓝奏直链解析失败", true)))
}

fn resolve_once(
    transport: &LibraryTransport,
    share_url: &str,
    password: &str,
    exchange_delays: DirectExchangeDelays,
    operation: Option<&OperationHandle>,
) -> CoreResult<LibraryResolved> {
    let share = transport.get_guarded_constrained(share_url, "", operation, None)?;
    require_active_share(&share.html)?;
    let title = clean_file_name(&strip(&capture(
        &share.html,
        r"(?is)<title[^>]*>(.*?)</title>",
    )));
    let transfer = first_non_empty(&[
        capture(
            &share.html,
            r#"(?is)id=['\"]downurl['\"][^>]*href=['\"]([^'\"]+)"#,
        ),
        capture(&share.html, r#"(?is)<a[^>]+href=['\"]([^'\"]*/tp/[^'\"]+)"#),
    ]);
    let page = if transfer.is_empty() {
        share.clone()
    } else {
        let target = join_page_url(&share.url, &transfer, &transport.policy)?;
        let page =
            transport.get_guarded_constrained(target.as_str(), &share.url, operation, None)?;
        require_active_share(&page.html)?;
        page
    };

    let base = capture(&page.html, r#"vkjxld\s*=\s*['\"]([^'\"]+)['\"]"#);
    let token = capture(&page.html, r#"hyggid\s*=\s*['\"]([^'\"]+)['\"]"#);
    if !base.is_empty() && !token.is_empty() {
        for suffix in ["&lanosso2", ""] {
            let bootstrap_raw = format!("{base}{token}{suffix}");
            let bootstrap = join_verification_url(&page.url, &bootstrap_raw, &transport.policy)?;
            let verify = transport.get_guarded_verification_constrained(
                bootstrap.as_str(),
                &page.url,
                operation,
                None,
            )?;
            require_active_share(&verify.html)?;
            let file = capture(&verify.html, r#"['\"]file['\"]\s*:\s*['\"]([^'\"]+)['\"]"#);
            let sign = capture(&verify.html, r#"['\"]sign['\"]\s*:\s*['\"]([^'\"]+)['\"]"#);
            if file.is_empty() || sign.is_empty() {
                continue;
            }
            let ajax_raw = first_non_empty(&[
                capture(
                    &verify.html,
                    r#"url\s*:\s*['\"]([^'\"]*ajax\.php[^'\"]*)['\"]"#,
                ),
                "ajax.php".to_owned(),
            ]);
            let ajax = same_origin_verification_endpoint(
                &verify.url,
                &ajax_raw,
                "/ajax.php",
                &transport.policy,
            )?;
            let mut form = BTreeMap::new();
            form.insert("file".to_owned(), file);
            form.insert("el".to_owned(), "2".to_owned());
            form.insert("sign".to_owned(), sign);
            for delay in [exchange_delays.initial, exchange_delays.retry] {
                wait_cooperatively(delay, operation, None)?;
                let raw = transport.post_form_verification_constrained(
                    ajax.as_str(),
                    &form,
                    &verify.url,
                    ANDROID_USER_AGENT,
                    operation,
                    None,
                )?;
                let data = parse_json(&raw)?;
                if integer(data.get("zt")) == Some(1) {
                    let direct = string(data.get("url"));
                    if direct.starts_with("http://") || direct.starts_with("https://") {
                        return Ok(LibraryResolved {
                            url: transport
                                .validate_direct_url_constrained(&direct, operation, None)?
                                .to_string(),
                            file_name: title,
                        });
                    }
                }
                if !direct_exchange_pending(&data) {
                    return Err(direct_exchange_error(&data));
                }
            }
            return Err(CoreError::remote("蓝奏验证未返回真实直链", true));
        }
        return Err(CoreError::remote("蓝奏验证未返回真实直链", true));
    }

    let sign = first_non_empty(&[
        capture(&page.html, r#"ajaxdata\s*=\s*['\"]([^'\"]+)['\"]"#),
        capture(&page.html, r#"sign\s*[:=]\s*['\"]([^'\"]+)['\"]"#),
    ]);
    if sign.is_empty() {
        return Err(missing_signature_error(&page.html));
    }
    let ajax = same_origin_endpoint(&page.url, "/ajaxm.php", "/ajaxm.php", &transport.policy)?;
    let mut form = BTreeMap::new();
    form.insert("action".to_owned(), "downprocess".to_owned());
    form.insert("sign".to_owned(), sign);
    form.insert("p".to_owned(), password.to_owned());
    let raw = transport.post_form_constrained(
        ajax.as_str(),
        &form,
        &page.url,
        ANDROID_USER_AGENT,
        operation,
        None,
    )?;
    let data = parse_json(&raw)?;
    if integer(data.get("zt")) != Some(1) {
        return Err(direct_exchange_error(&data));
    }
    let path = string(data.get("url"));
    let direct = if path.starts_with("https://") || path.starts_with("http://") {
        path
    } else {
        let domain = string(data.get("dom")).trim_end_matches('/').to_owned();
        format!("{domain}/file/{}", path.trim_start_matches(['/', '?']))
    };
    Ok(LibraryResolved {
        url: transport
            .validate_direct_url_constrained(&direct, operation, None)?
            .to_string(),
        file_name: title,
    })
}

fn require_active_share(html: &str) -> CoreResult<()> {
    if parse_page(html).cancelled {
        Err(share_cancelled_error())
    } else {
        Ok(())
    }
}

fn share_cancelled_error() -> CoreError {
    CoreError::new("share_cancelled", "分享已取消", false)
}

fn password_required_error() -> CoreError {
    CoreError::new("password_required", "分享需要正确的访问码", false)
}

fn missing_signature_error(html: &str) -> CoreError {
    let lowercase = html.to_ascii_lowercase();
    let compact = strip(html).split_whitespace().collect::<String>();
    let password_form = [
        "name=\"pwd\"",
        "name='pwd'",
        "id=\"pwd\"",
        "id='pwd'",
        "type=\"password\"",
        "type='password'",
    ]
    .iter()
    .any(|marker| lowercase.contains(marker));
    if password_form
        || ["请输入密码", "输入密码", "访问密码", "提取码"]
            .iter()
            .any(|marker| compact.contains(marker))
    {
        password_required_error()
    } else {
        CoreError::parse("未找到下载签名")
    }
}

fn direct_exchange_pending(data: &Value) -> bool {
    let info = first_non_empty(&[string(data.get("inf")), string(data.get("info"))]);
    if direct_exchange_terminal_info(&info) {
        return false;
    }
    if integer(data.get("zt")) == Some(1) {
        let direct = string(data.get("url"));
        return !(direct.starts_with("http://") || direct.starts_with("https://"));
    }
    info.is_empty()
        || info == "0"
        || ["稍后", "验证", "处理中", "等待"]
            .iter()
            .any(|marker| info.contains(marker))
}

fn direct_exchange_terminal_info(info: &str) -> bool {
    [
        "取消",
        "来晚",
        "删除",
        "不存在",
        "失效",
        "密码",
        "禁止",
        "违规",
        "封禁",
        "关闭",
        "拒绝",
        "错误",
        "失败",
    ]
    .iter()
    .any(|marker| info.contains(marker))
}

fn direct_exchange_error(data: &Value) -> CoreError {
    let info = first_non_empty(&[
        string(data.get("inf")),
        string(data.get("info")),
        "蓝奏解析失败".to_owned(),
    ]);
    if info.contains("取消") || info.contains("不存在") || info.contains("删除") {
        share_cancelled_error()
    } else if info.contains("密码") || info.contains("访问码") || info.contains("提取码") {
        password_required_error()
    } else {
        CoreError::remote(info, false)
    }
}

fn parse_json(raw: &str) -> CoreResult<Value> {
    serde_json::from_str(raw.trim_start_matches('\u{feff}').trim())
        .map_err(|_| CoreError::parse("蓝奏直链接口返回了无效 JSON"))
}

fn integer(value: Option<&Value>) -> Option<i64> {
    value.and_then(|entry| {
        entry
            .as_i64()
            .or_else(|| entry.as_str().and_then(|text| text.parse().ok()))
    })
}

fn string(value: Option<&Value>) -> String {
    value
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_owned()
}

fn first_non_empty(values: &[String]) -> String {
    values
        .iter()
        .find(|value| !value.trim().is_empty())
        .cloned()
        .unwrap_or_default()
}

fn clean_file_name(value: &str) -> String {
    let trimmed = value
        .trim()
        .trim_end_matches(" - 蓝奏云")
        .trim_end_matches("_蓝奏云")
        .trim();
    let mut cleaned = trimmed
        .chars()
        .map(|character| {
            if character.is_control() || r#"\\/:*?"<>|"#.contains(character) {
                '_'
            } else {
                character
            }
        })
        .collect::<String>()
        .trim_matches(['.', ' '])
        .to_owned();
    if cleaned.is_empty() {
        return "download.bin".to_owned();
    }
    if crate::validation::safe_filename(&cleaned).is_err() {
        cleaned.insert(0, '_');
    }
    cleaned = truncate_file_name(&cleaned, 200);
    if crate::validation::safe_filename(&cleaned).is_ok() {
        cleaned
    } else {
        "download.bin".to_owned()
    }
}

fn truncate_file_name(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_owned();
    }
    let (stem, extension) = value
        .rsplit_once('.')
        .filter(|(stem, extension)| {
            !stem.is_empty() && !extension.is_empty() && extension.len() <= 32
        })
        .map_or((value, ""), |(stem, extension)| (stem, extension));
    let suffix_bytes = if extension.is_empty() {
        0
    } else {
        extension.len() + 1
    };
    let stem_budget = max_bytes.saturating_sub(suffix_bytes);
    let mut truncated = String::new();
    for character in stem.chars() {
        if truncated.len() + character.len_utf8() > stem_budget {
            break;
        }
        truncated.push(character);
    }
    if truncated.is_empty() {
        return "download.bin".to_owned();
    }
    if !extension.is_empty() {
        truncated.push('.');
        truncated.push_str(extension);
    }
    truncated
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
        time::Instant,
    };

    use super::*;

    fn read_request(stream: &mut std::net::TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut bytes = Vec::new();
        let mut buffer = [0u8; 2048];
        loop {
            let count = stream.read(&mut buffer).unwrap_or(0);
            if count == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..count]);
            if let Some(split) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&bytes[..split + 4]);
                let length = headers
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length: ")
                            .and_then(|value| value.trim().parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                if bytes.len() >= split + 4 + length {
                    break;
                }
            }
        }
        String::from_utf8_lossy(&bytes).into_owned()
    }

    #[test]
    fn test_resolve_standard_flow_sends_password_and_returns_validated_url() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let direct = format!("{origin}/file/app.apk");
        let server_direct = direct.clone();
        let server = thread::spawn(move || {
            for index in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_request(&mut stream);
                let body = if index == 0 {
                    r#"<title>工具.apk - 蓝奏云</title><script>var ajaxdata='sig';</script>"#
                        .to_owned()
                } else {
                    assert!(request.contains("p=secret"));
                    format!(r#"{{"zt":1,"url":"{server_direct}"}}"#)
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                stream.write_all(response.as_bytes()).unwrap();
            }
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();
        let result = resolve_once(
            &transport,
            &format!("{origin}/share"),
            "secret",
            DirectExchangeDelays::ZERO,
            None,
        )
        .unwrap();
        assert_eq!(result.url, direct);
        assert_eq!(result.file_name, "工具.apk");
        assert!(!serde_json::to_string(&result).unwrap().contains("secret"));
        server.join().unwrap();
    }

    #[test]
    fn test_direct_exchange_delays_match_latest_lanzoumax_contract() {
        let delays = DirectExchangeDelays::production();
        assert_eq!(delays.initial, Duration::from_millis(1_900));
        assert_eq!(delays.retry, Duration::from_millis(250));
    }

    #[test]
    fn test_pending_direct_exchange_retries_same_session_endpoint_form_and_referer() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server_origin = origin.clone();
        let server = thread::spawn(move || {
            let mut first_post = String::new();
            for index in 0..4 {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_request(&mut stream);
                let (body, extra_headers) = match index {
                    0 => (
                        format!(
                            r#"<title>工具.apk - 蓝奏云</title><script>var vkjxld='{server_origin}/file/bootstrap?';var hyggid='token';</script>"#
                        ),
                        "",
                    ),
                    1 => (
                        r#"<script>var data={'file':'file-id','sign':'sign-id','url':'ajax.php'};</script>"#
                            .to_owned(),
                        "Set-Cookie: verify=kept; Path=/\r\n",
                    ),
                    2 => {
                        assert!(
                            request.starts_with("POST /file/ajax.php "),
                            "unexpected request: {request}"
                        );
                        assert!(request.to_ascii_lowercase().contains("referer: "));
                        assert!(request.contains("el=2"));
                        assert!(request.contains("file=file-id"));
                        assert!(request.contains("sign=sign-id"));
                        assert!(request.to_ascii_lowercase().contains("verify=kept"));
                        first_post = request;
                        (
                            r#"{"zt":0,"inf":"处理中"}"#.to_owned(),
                            "Set-Cookie: exchange=kept; Path=/\r\n",
                        )
                    }
                    _ => {
                        let request_body = request
                            .split_once("\r\n\r\n")
                            .map(|(_, body)| body)
                            .unwrap_or_default();
                        let first_body = first_post
                            .split_once("\r\n\r\n")
                            .map(|(_, body)| body)
                            .unwrap_or_default();
                        assert_eq!(request_body, first_body);
                        let lower = request.to_ascii_lowercase();
                        assert!(lower.contains("verify=kept"));
                        assert!(lower.contains("exchange=kept"));
                        assert_eq!(
                            request
                                .lines()
                                .find(|line| line.to_ascii_lowercase().starts_with("referer:")),
                            first_post.lines().find(|line| {
                                line.to_ascii_lowercase().starts_with("referer:")
                            })
                        );
                        (
                            format!(r#"{{"zt":1,"url":"{server_origin}/file/app.apk"}}"#),
                            "",
                        )
                    }
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\n{extra_headers}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();

        let result = resolve_once(
            &transport,
            &format!("{origin}/share"),
            "",
            DirectExchangeDelays::ZERO,
            None,
        )
        .unwrap();

        assert_eq!(result.url, format!("{origin}/file/app.apk"));
        server.join().unwrap();
    }

    #[test]
    fn test_terminal_direct_exchange_does_not_use_short_retry() {
        let terminal: Value = serde_json::from_str(r#"{"zt":0,"inf":"密码错误"}"#).unwrap();
        let pending: Value = serde_json::from_str(r#"{"zt":0,"inf":"处理中"}"#).unwrap();
        assert!(!direct_exchange_pending(&terminal));
        assert!(direct_exchange_pending(&pending));

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server_origin = origin.clone();
        let server = thread::spawn(move || {
            for index in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_request(&mut stream);
                let body = match index {
                    0 => format!(
                        r#"<script>var vkjxld='{server_origin}/file/bootstrap?';var hyggid='token';</script>"#
                    ),
                    1 => r#"<script>var data={'file':'file-id','sign':'sign-id','url':'ajax.php'};</script>"#
                        .to_owned(),
                    _ => {
                        assert!(request.starts_with("POST /file/ajax.php "));
                        r#"{"zt":0,"inf":"密码错误"}"#.to_owned()
                    }
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
            listener.set_nonblocking(true).unwrap();
            let deadline = Instant::now() + Duration::from_millis(150);
            while Instant::now() < deadline {
                match listener.accept() {
                    Ok(_) => panic!("terminal exchange unexpectedly used the short retry"),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("unexpected listener error: {error}"),
                }
            }
        });
        let transport = LibraryTransport::for_test(origin.clone()).unwrap();

        let error = resolve_once(
            &transport,
            &format!("{origin}/share"),
            "",
            DirectExchangeDelays::ZERO,
            None,
        )
        .unwrap_err();

        assert_eq!(error.code, "password_required");
        assert_eq!(error.message, "分享需要正确的访问码");
        assert!(!error.retriable);
        server.join().unwrap();
    }

    #[test]
    fn test_password_page_and_json_use_stable_password_required_error() {
        let data: Value = serde_json::from_str(r#"{"zt":0,"inf":"密码不正确"}"#).unwrap();
        let error = direct_exchange_error(&data);
        assert_eq!(error.code, "password_required");
        assert_eq!(error.message, "分享需要正确的访问码");
        assert!(!error.retriable);

        let error = missing_signature_error(
            r#"<form><input type="password" name="pwd"><p>请输入访问密码</p></form>"#,
        );
        assert_eq!(error.code, "password_required");
        assert_eq!(error.message, "分享需要正确的访问码");
    }

    #[test]
    fn test_cancelled_share_is_terminal_and_not_hidden_by_access_code_sanitizer() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let _ = read_request(&mut stream);
            let body = "<html><main>文件 已取消分享，无法访问</main></html>";
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });

        let result = resolve_with_transport(
            "source-one",
            &format!("{origin}/share"),
            "secret",
            SecurityPolicy::Test {
                origin: origin.clone(),
            },
            DirectExchangeDelays::ZERO,
            None,
        );
        let error = match result {
            Ok(_) => panic!("cancelled share unexpectedly resolved"),
            Err(error) => error,
        };

        assert_eq!(error.code, "share_cancelled");
        assert_eq!(error.message, "分享已取消");
        assert!(!error.retriable);
        server.join().unwrap();
    }

    #[test]
    fn test_clean_file_name_removes_lanzou_title_suffix() {
        assert_eq!(clean_file_name("工具.apk - 蓝奏云"), "工具.apk");
    }

    #[test]
    fn test_clean_file_name_never_emits_traversal_or_windows_device_names() {
        assert_eq!(clean_file_name(".. - 蓝奏云"), "download.bin");
        assert_eq!(clean_file_name("CON - 蓝奏云"), "_CON");
        assert_eq!(
            clean_file_name("bad\u{1}name?.apk - 蓝奏云"),
            "bad_name_.apk"
        );

        let long = clean_file_name(&format!("{}.apk - 蓝奏云", "测".repeat(100)));
        assert!(long.len() <= 200);
        assert!(long.ends_with(".apk"));
        crate::validation::safe_filename(&long).unwrap();
    }
}
