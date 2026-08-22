use std::{
    io::Read,
    net::{IpAddr, SocketAddr, ToSocketAddrs},
    time::Duration,
};

use reqwest::{
    blocking::{Client, Response},
    header::{ACCEPT, CONTENT_LENGTH, CONTENT_TYPE, LOCATION, USER_AGENT},
    redirect::Policy,
    Url,
};
use serde::Serialize;

use crate::error::{CoreError, CoreResult};

use super::{
    session::ANDROID_USER_AGENT,
    url::{is_public_ip, reject_explicit_port_reference},
};

pub(crate) const MAX_DOCUMENT_BYTES: usize = 256 * 1024;
const MAX_DOCUMENT_REDIRECTS: usize = 3;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LibraryDocument {
    pub text: String,
    pub source_kind: &'static str,
}

#[derive(Clone, Debug)]
enum DocumentPolicy {
    Production,
    #[cfg(test)]
    Test {
        origin: String,
    },
}

pub(crate) fn fetch_text(value: &str) -> CoreResult<LibraryDocument> {
    fetch_text_with_policy(value, DocumentPolicy::Production)
}

fn fetch_text_with_policy(value: &str, policy: DocumentPolicy) -> CoreResult<LibraryDocument> {
    let initial = validate_document_syntax(value, &policy)?;
    let client = build_client(&initial, &policy)?;
    let mut current = initial.clone();
    let mut redirects = 0usize;
    loop {
        let response = client
            .get(current.clone())
            .header(USER_AGENT, ANDROID_USER_AGENT)
            .header(
                ACCEPT,
                "text/plain,text/markdown,application/json,application/octet-stream;q=0.8",
            )
            .send()
            .map_err(CoreError::from_reqwest)?;
        if response.status().is_redirection() {
            if redirects >= MAX_DOCUMENT_REDIRECTS {
                return Err(CoreError::remote("远程文档跳转次数过多", false));
            }
            let location = response
                .headers()
                .get(LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or_else(|| CoreError::parse("远程文档跳转缺少地址"))?;
            if matches!(policy, DocumentPolicy::Production) {
                reject_explicit_port_reference(location)
                    .map_err(|_| CoreError::parse("远程文档跳转包含显式端口"))?;
            }
            let next = current
                .join(location)
                .map_err(|_| CoreError::parse("远程文档跳转地址无效"))?;
            let next = validate_document_syntax(next.as_str(), &policy)?;
            ensure_same_origin(&initial, &next)?;
            redirects += 1;
            current = next;
            continue;
        }
        if !response.status().is_success() {
            return Err(CoreError::remote(
                format!("远程文档请求 HTTP {}", response.status().as_u16()),
                response.status().is_server_error(),
            ));
        }
        let final_url = validate_document_syntax(response.url().as_str(), &policy)?;
        ensure_same_origin(&initial, &final_url)?;
        validate_media_type(&response)?;
        let bytes = read_limited(response)?;
        let text = String::from_utf8(bytes)
            .map_err(|_| CoreError::parse("远程文档不是有效 UTF-8 文本"))?;
        let text = text
            .strip_prefix('\u{feff}')
            .unwrap_or(&text)
            .replace('\r', "");
        if text.contains('\0') {
            return Err(CoreError::parse("远程文档包含无效字符"));
        }
        return Ok(LibraryDocument {
            text,
            source_kind: "remote_text",
        });
    }
}

fn validate_document_syntax(value: &str, policy: &DocumentPolicy) -> CoreResult<Url> {
    if value.len() > 2_048 || value.chars().any(char::is_control) {
        return Err(CoreError::invalid("远程文档地址格式无效"));
    }
    let parsed = match policy {
        DocumentPolicy::Production => {
            reject_explicit_port_reference(value)
                .map_err(|_| CoreError::invalid("远程文档地址包含显式端口"))?;
            let parsed =
                Url::parse(value.trim()).map_err(|_| CoreError::invalid("远程文档地址格式无效"))?;
            if parsed.scheme() != "https" || parsed.host_str().is_none() {
                return Err(CoreError::invalid("远程文档必须使用 HTTPS 公网地址"));
            }
            parsed
        }
        #[cfg(test)]
        DocumentPolicy::Test { origin } => {
            let expected =
                Url::parse(origin).map_err(|_| CoreError::invalid("测试文档服务地址无效"))?;
            let parsed =
                Url::parse(value).map_err(|_| CoreError::invalid("远程文档地址格式无效"))?;
            if parsed.scheme() != expected.scheme()
                || parsed.host_str() != expected.host_str()
                || parsed.port_or_known_default() != expected.port_or_known_default()
            {
                return Err(CoreError::invalid("远程文档请求离开了测试源"));
            }
            parsed
        }
    };
    if !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.fragment().is_some()
        || parsed.path() == "/"
        || !parsed.path().starts_with('/')
        || parsed.path().contains('\\')
    {
        return Err(CoreError::invalid("远程文档地址路径不受信任"));
    }
    let path = parsed.path().to_ascii_lowercase();
    if ["%00", "%2f", "%5c"]
        .iter()
        .any(|encoded| path.contains(encoded))
    {
        return Err(CoreError::invalid("远程文档地址路径不受信任"));
    }
    Ok(parsed)
}

fn build_client(initial: &Url, policy: &DocumentPolicy) -> CoreResult<Client> {
    let mut builder = Client::builder()
        .use_rustls_tls()
        .no_proxy()
        .redirect(Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(25));
    if matches!(policy, DocumentPolicy::Production) {
        let host = initial
            .host_str()
            .ok_or_else(|| CoreError::invalid("远程文档地址缺少主机名"))?;
        let addresses = resolve_public_addresses(host)?;
        builder = builder.resolve_to_addrs(host, &addresses);
    }
    builder.build().map_err(CoreError::from_reqwest)
}

fn resolve_public_addresses(host: &str) -> CoreResult<Vec<SocketAddr>> {
    let addresses = (host, 443)
        .to_socket_addrs()
        .map_err(|_| CoreError::remote("无法验证远程文档主机", true))?
        .collect::<Vec<_>>();
    ensure_public_addresses(&addresses.iter().map(|value| value.ip()).collect::<Vec<_>>())?;
    Ok(addresses)
}

fn ensure_public_addresses(addresses: &[IpAddr]) -> CoreResult<()> {
    if addresses.is_empty() || addresses.iter().any(|address| !is_public_ip(*address)) {
        return Err(CoreError::invalid("远程文档主机解析到了非公网地址"));
    }
    Ok(())
}

fn ensure_same_origin(initial: &Url, candidate: &Url) -> CoreResult<()> {
    if initial.scheme() != candidate.scheme()
        || initial.host_str() != candidate.host_str()
        || initial.port_or_known_default() != candidate.port_or_known_default()
    {
        return Err(CoreError::invalid("远程文档跳转离开了初始源"));
    }
    Ok(())
}

fn validate_media_type(response: &Response) -> CoreResult<()> {
    let media_type = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .map(str::trim)
        .unwrap_or_default()
        .to_ascii_lowercase();
    if matches!(
        media_type.as_str(),
        "text/plain"
            | "text/markdown"
            | "text/x-markdown"
            | "application/json"
            | "application/octet-stream"
    ) {
        Ok(())
    } else {
        Err(CoreError::remote("远程文档响应类型不受支持", false))
    }
}

fn read_limited(mut response: Response) -> CoreResult<Vec<u8>> {
    if response
        .headers()
        .get(CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .is_some_and(|length| length > MAX_DOCUMENT_BYTES as u64)
    {
        return Err(CoreError::remote("远程文档超过 256 KiB", false));
    }
    let mut bytes = Vec::new();
    response
        .by_ref()
        .take(MAX_DOCUMENT_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| CoreError::remote("读取远程文档失败", true))?;
    if bytes.len() > MAX_DOCUMENT_BYTES {
        return Err(CoreError::remote("远程文档超过 256 KiB", false));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
        time::Duration,
    };

    use super::{fetch_text_with_policy, DocumentPolicy};

    fn read_request(stream: &mut std::net::TcpStream) {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut request = [0_u8; 2_048];
        let _ = stream.read(&mut request);
    }

    #[test]
    fn test_fetch_text_reads_bounded_utf8_document() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let body = "远程公告\n第二行".as_bytes().to_vec();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            read_request(&mut stream);
            let headers = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(headers.as_bytes()).unwrap();
            stream.write_all(&body).unwrap();
        });

        let result = fetch_text_with_policy(
            &format!("{origin}/docs/announcement.txt"),
            DocumentPolicy::Test {
                origin: origin.clone(),
            },
        )
        .unwrap();

        assert_eq!(result.text, "远程公告\n第二行");
        assert_eq!(result.source_kind, "remote_text");
        server.join().unwrap();
    }
}
