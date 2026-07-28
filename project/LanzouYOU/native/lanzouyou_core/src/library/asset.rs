use std::{
    io::{Cursor, Read},
    net::{IpAddr, SocketAddr, ToSocketAddrs},
    time::Duration,
};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use image::{imageops::FilterType, DynamicImage, ImageFormat, ImageReader, Limits};
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

pub(crate) const MAX_ASSET_BYTES: usize = 1024 * 1024;
const MAX_ASSET_REDIRECTS: usize = 3;
const MAX_DECODE_DIMENSION: u32 = 4_096;
const MAX_DECODE_ALLOC: u64 = 64 * 1024 * 1024;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LibraryAsset {
    pub media_type: &'static str,
    pub bytes_base64: String,
}

#[derive(Clone, Debug)]
enum AssetPolicy {
    Production,
    #[cfg(test)]
    Test {
        origin: String,
    },
}

pub(crate) fn fetch_asset(value: &str) -> CoreResult<LibraryAsset> {
    fetch_asset_with_policy(value, AssetPolicy::Production)
}

fn fetch_asset_with_policy(value: &str, policy: AssetPolicy) -> CoreResult<LibraryAsset> {
    let initial = validate_asset_syntax(value, &policy)?;
    let client = build_client(&initial, &policy)?;
    let mut current = initial.clone();
    let mut redirects = 0usize;
    loop {
        let response = client
            .get(current.clone())
            .header(USER_AGENT, ANDROID_USER_AGENT)
            .header(
                ACCEPT,
                "image/png,image/jpeg,image/gif,image/webp,image/bmp,image/x-icon",
            )
            .send()
            .map_err(CoreError::from_reqwest)?;
        if response.status().is_redirection() {
            if redirects >= MAX_ASSET_REDIRECTS {
                return Err(CoreError::remote("图标跳转次数过多", false));
            }
            let location = response
                .headers()
                .get(LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or_else(|| CoreError::parse("图标跳转缺少地址"))?;
            if matches!(policy, AssetPolicy::Production) {
                reject_explicit_port_reference(location)
                    .map_err(|_| CoreError::parse("图标跳转包含显式端口"))?;
            }
            let next = current
                .join(location)
                .map_err(|_| CoreError::parse("图标跳转地址无效"))?;
            let next = validate_asset_syntax(next.as_str(), &policy)?;
            ensure_same_origin(&initial, &next)?;
            redirects += 1;
            current = next;
            continue;
        }
        if !response.status().is_success() {
            return Err(CoreError::remote(
                format!("图标请求 HTTP {}", response.status().as_u16()),
                response.status().is_server_error(),
            ));
        }
        let final_url = validate_asset_syntax(response.url().as_str(), &policy)?;
        ensure_same_origin(&initial, &final_url)?;
        let media_type = response_media_type(&response)?;
        let bytes = read_limited(response)?;
        return normalize_png(&bytes, &media_type);
    }
}

fn validate_asset_syntax(value: &str, policy: &AssetPolicy) -> CoreResult<Url> {
    if value.len() > 2_048 || value.chars().any(char::is_control) {
        return Err(CoreError::invalid("图标地址格式无效"));
    }
    let parsed = match policy {
        AssetPolicy::Production => {
            reject_explicit_port_reference(value)
                .map_err(|_| CoreError::invalid("图标地址包含显式端口"))?;
            let parsed =
                Url::parse(value.trim()).map_err(|_| CoreError::invalid("图标地址格式无效"))?;
            if parsed.scheme() != "https" || parsed.host_str().is_none() {
                return Err(CoreError::invalid("图标必须使用 HTTPS 公网地址"));
            }
            parsed
        }
        #[cfg(test)]
        AssetPolicy::Test { origin } => {
            let expected =
                Url::parse(origin).map_err(|_| CoreError::invalid("测试图标服务地址无效"))?;
            let parsed = Url::parse(value).map_err(|_| CoreError::invalid("图标地址格式无效"))?;
            if parsed.scheme() != expected.scheme()
                || parsed.host_str() != expected.host_str()
                || parsed.port_or_known_default() != expected.port_or_known_default()
            {
                return Err(CoreError::invalid("图标请求离开了测试源"));
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
        return Err(CoreError::invalid("图标地址路径不受信任"));
    }
    let path = parsed.path().to_ascii_lowercase();
    if ["%00", "%2f", "%5c"]
        .iter()
        .any(|encoded| path.contains(encoded))
    {
        return Err(CoreError::invalid("图标地址路径不受信任"));
    }
    Ok(parsed)
}

fn build_client(initial: &Url, policy: &AssetPolicy) -> CoreResult<Client> {
    let mut builder = Client::builder()
        .use_rustls_tls()
        .no_proxy()
        .redirect(Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(25));
    if matches!(policy, AssetPolicy::Production) {
        let host = initial
            .host_str()
            .ok_or_else(|| CoreError::invalid("图标地址缺少主机名"))?;
        let addresses = resolve_public_addresses(host)?;
        builder = builder.resolve_to_addrs(host, &addresses);
    }
    builder.build().map_err(CoreError::from_reqwest)
}

fn resolve_public_addresses(host: &str) -> CoreResult<Vec<SocketAddr>> {
    let addresses = (host, 443)
        .to_socket_addrs()
        .map_err(|_| CoreError::remote("无法验证图标主机", true))?
        .collect::<Vec<_>>();
    let ips = addresses
        .iter()
        .map(|address| address.ip())
        .collect::<Vec<_>>();
    ensure_public_addresses(&ips)?;
    Ok(addresses)
}

fn ensure_public_addresses(addresses: &[IpAddr]) -> CoreResult<()> {
    if addresses.is_empty() || addresses.iter().any(|address| !is_public_ip(*address)) {
        return Err(CoreError::invalid("图标主机解析到了非公网地址"));
    }
    Ok(())
}

fn ensure_same_origin(initial: &Url, candidate: &Url) -> CoreResult<()> {
    if initial.scheme() != candidate.scheme()
        || initial.host_str() != candidate.host_str()
        || initial.port_or_known_default() != candidate.port_or_known_default()
    {
        return Err(CoreError::invalid("图标跳转离开了初始源"));
    }
    Ok(())
}

fn response_media_type(response: &Response) -> CoreResult<String> {
    let media_type = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .map(str::trim)
        .unwrap_or_default();
    if matches!(
        media_type.to_ascii_lowercase().as_str(),
        "image/png"
            | "image/jpeg"
            | "image/gif"
            | "image/webp"
            | "image/bmp"
            | "image/x-icon"
            | "image/vnd.microsoft.icon"
    ) {
        Ok(media_type.to_owned())
    } else {
        Err(CoreError::remote("图标响应类型不受支持", false))
    }
}

fn read_limited(mut response: Response) -> CoreResult<Vec<u8>> {
    if response
        .headers()
        .get(CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .is_some_and(|length| length > MAX_ASSET_BYTES as u64)
    {
        return Err(CoreError::remote("图标响应超过 1 MiB", false));
    }
    let mut bytes = Vec::new();
    response
        .by_ref()
        .take(MAX_ASSET_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| CoreError::remote("读取图标响应失败", true))?;
    if bytes.len() > MAX_ASSET_BYTES {
        return Err(CoreError::remote("图标响应超过 1 MiB", false));
    }
    Ok(bytes)
}

fn normalize_png(bytes: &[u8], _media_type: &str) -> CoreResult<LibraryAsset> {
    let mut reader = ImageReader::new(Cursor::new(bytes));
    reader = reader
        .with_guessed_format()
        .map_err(|_| CoreError::parse("图标格式无法识别"))?;
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_DECODE_DIMENSION);
    limits.max_image_height = Some(MAX_DECODE_DIMENSION);
    limits.max_alloc = Some(MAX_DECODE_ALLOC);
    reader.limits(limits);
    let image = reader
        .decode()
        .map_err(|_| CoreError::parse("图标内容无法解码"))?;
    let image: DynamicImage = if image.width() > 256 || image.height() > 256 {
        image.resize(256, 256, FilterType::Lanczos3)
    } else {
        image
    };
    let mut output = Cursor::new(Vec::new());
    image
        .write_to(&mut output, ImageFormat::Png)
        .map_err(|_| CoreError::new("internal_error", "图标 PNG 编码失败", false))?;
    Ok(LibraryAsset {
        media_type: "image/png",
        bytes_base64: STANDARD.encode(output.into_inner()),
    })
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Cursor, Read, Write},
        net::{IpAddr, Ipv4Addr, TcpListener},
        thread,
        time::Duration,
    };

    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use image::{DynamicImage, GenericImageView, ImageFormat, Rgba, RgbaImage};

    use super::{
        ensure_public_addresses, fetch_asset_with_policy, validate_asset_syntax, AssetPolicy,
        MAX_ASSET_BYTES,
    };

    fn png(width: u32, height: u32) -> Vec<u8> {
        let image = DynamicImage::ImageRgba8(RgbaImage::from_pixel(
            width,
            height,
            Rgba([37, 99, 235, 255]),
        ));
        let mut output = Cursor::new(Vec::new());
        image.write_to(&mut output, ImageFormat::Png).unwrap();
        output.into_inner()
    }

    fn read_request(stream: &mut std::net::TcpStream) {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut request = [0_u8; 2_048];
        let _ = stream.read(&mut request);
    }

    fn response(content_type: &str, body: &[u8]) -> Vec<u8> {
        let mut output = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        output.extend_from_slice(body);
        output
    }

    #[test]
    fn test_asset_initial_url_rejects_untrusted_http_credentials_and_explicit_ports() {
        let policy = AssetPolicy::Production;
        for value in [
            "http://image.dmpdmp.com/image/a.png",
            "https://user@image.dmpdmp.com/image/a.png",
            "https://image.dmpdmp.com:443/image/a.png",
            "https://image.dmpdmp.com:444/image/a.png",
            "https://image.dmpdmp.com/",
        ] {
            assert!(validate_asset_syntax(value, &policy).is_err(), "{value}");
        }
    }

    #[test]
    fn test_asset_initial_url_accepts_user_configured_public_https_hosts() {
        let policy = AssetPolicy::Production;
        for value in [
            "https://cdn.example/image/a.png",
            "https://www.lanzouw.com/icon.png",
            "https://images.example.org/path/banner.webp?width=1280",
        ] {
            assert!(validate_asset_syntax(value, &policy).is_ok(), "{value}");
        }
    }

    #[test]
    fn test_asset_public_address_guard_rejects_loopback_private_and_mixed_dns() {
        for address in [
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)),
            "::ffff:192.168.1.1".parse().unwrap(),
        ] {
            assert!(ensure_public_addresses(&[address]).is_err(), "{address}");
        }
        assert!(ensure_public_addresses(&[
            IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8)),
            IpAddr::V4(Ipv4Addr::LOCALHOST),
        ])
        .is_err());
        assert!(ensure_public_addresses(&[IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8))]).is_ok());
    }

    #[test]
    fn test_asset_fetch_follows_legal_same_origin_redirect_and_normalizes_png() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let body = png(512, 128);
        let server = thread::spawn(move || {
            for index in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                read_request(&mut stream);
                if index == 0 {
                    stream
                        .write_all(
                            b"HTTP/1.1 302 Found\r\nLocation: /image/final.png\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        )
                        .unwrap();
                } else {
                    stream.write_all(&response("image/png", &body)).unwrap();
                }
            }
        });
        let result = fetch_asset_with_policy(
            &format!("{origin}/image/start.png"),
            AssetPolicy::Test {
                origin: origin.clone(),
            },
        )
        .unwrap();
        assert_eq!(result.media_type, "image/png");
        let public = serde_json::to_value(&result).unwrap();
        assert_eq!(public.as_object().unwrap().len(), 2);
        assert!(public.get("url").is_none());
        assert!(public.get("cookie").is_none());
        let bytes = STANDARD.decode(result.bytes_base64).unwrap();
        assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
        let decoded = image::load_from_memory(&bytes).unwrap();
        assert_eq!(decoded.dimensions(), (256, 64));
        server.join().unwrap();
    }

    #[test]
    fn test_asset_fetch_rejects_cross_origin_redirect_before_requesting_it() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let forbidden = TcpListener::bind("127.0.0.1:0").unwrap();
        forbidden.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let forbidden_url = format!(
            "http://{}/image/stolen.png",
            forbidden.local_addr().unwrap()
        );
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            read_request(&mut stream);
            let body = format!(
                "HTTP/1.1 302 Found\r\nLocation: {forbidden_url}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
            stream.write_all(body.as_bytes()).unwrap();
        });
        assert!(fetch_asset_with_policy(
            &format!("{origin}/image/start.png"),
            AssetPolicy::Test {
                origin: origin.clone(),
            },
        )
        .is_err());
        server.join().unwrap();
        thread::sleep(Duration::from_millis(30));
        assert!(matches!(
            forbidden.accept(),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock
        ));
    }

    #[test]
    fn test_asset_fetch_rejects_oversize_bad_mime_and_bad_image() {
        let cases = [
            ("image/png", vec![0_u8; MAX_ASSET_BYTES + 1]),
            ("text/html", png(8, 8)),
            ("image/png", b"not-an-image".to_vec()),
        ];
        for (content_type, body) in cases {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let origin = format!("http://{}", listener.local_addr().unwrap());
            let server = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                read_request(&mut stream);
                stream.write_all(&response(content_type, &body)).unwrap();
            });
            assert!(fetch_asset_with_policy(
                &format!("{origin}/image/a.png"),
                AssetPolicy::Test {
                    origin: origin.clone(),
                },
            )
            .is_err());
            server.join().unwrap();
        }
    }
}
