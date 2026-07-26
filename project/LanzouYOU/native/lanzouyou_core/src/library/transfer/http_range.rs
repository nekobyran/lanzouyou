use reqwest::{
    header::{
        HeaderMap, HeaderValue, ACCEPT_ENCODING, CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_RANGE,
        CONTENT_TYPE, IF_RANGE, RANGE,
    },
    StatusCode,
};

use crate::error::{CoreError, CoreResult};

use super::entity::{EntityComparison, EntityValidator};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct RangeRequest {
    pub offset: u64,
    pub validator: EntityValidator,
}

impl RangeRequest {
    pub(crate) fn headers(&self) -> CoreResult<HeaderMap> {
        let mut headers = HeaderMap::new();
        headers.insert(ACCEPT_ENCODING, HeaderValue::from_static("identity"));
        if self.offset > 0 {
            headers.insert(
                RANGE,
                HeaderValue::from_str(&format!("bytes={}-", self.offset))
                    .map_err(|_| range_invalid("Range 请求偏移无效"))?,
            );
            if let Some(if_range) = self.validator.if_range_value() {
                headers.insert(
                    IF_RANGE,
                    HeaderValue::from_str(if_range)
                        .map_err(|_| range_invalid("If-Range 校验值无效"))?,
                );
            }
        }
        Ok(headers)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RangeResponse {
    pub action: RangeResponseAction,
    pub validator: EntityValidator,
    pub expected_body_bytes: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RangeResponseAction {
    WriteFromStart,
    Append,
    RestartFromZero,
    AlreadyComplete,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RangeTransferResult {
    pub committed_bytes: u64,
    pub response_bytes: u64,
    pub total_bytes: Option<u64>,
    pub validator: EntityValidator,
    pub restarted: bool,
}

pub(crate) fn inspect_range_response(
    request: &RangeRequest,
    status: StatusCode,
    headers: &HeaderMap,
) -> CoreResult<RangeResponse> {
    if matches!(
        status,
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN | StatusCode::NOT_FOUND | StatusCode::GONE
    ) {
        return Err(CoreError::new(
            "direct_link_stale",
            "蓝奏直链已失效，需要重新解析",
            true,
        ));
    }
    if status == StatusCode::RANGE_NOT_SATISFIABLE {
        let total = parse_unsatisfied_total(headers)?;
        if request.offset > 0
            && request.offset == total
            && request.validator.total_bytes == Some(total)
        {
            return Ok(RangeResponse {
                action: RangeResponseAction::AlreadyComplete,
                validator: EntityValidator::from_headers(headers, Some(total))?,
                expected_body_bytes: Some(0),
            });
        }
        return Err(range_invalid("Range 416 响应与本地断点不一致"));
    }
    if !status.is_success() {
        return Err(CoreError::remote(
            format!("文件下载 HTTP {}", status.as_u16()),
            status.is_server_error(),
        ));
    }
    validate_representation_headers(headers)?;

    if status == StatusCode::OK {
        let body_bytes = parse_optional_u64_header(headers, CONTENT_LENGTH)?;
        let validator = EntityValidator::from_headers(headers, body_bytes)?;
        return Ok(RangeResponse {
            action: if request.offset == 0 {
                RangeResponseAction::WriteFromStart
            } else {
                RangeResponseAction::RestartFromZero
            },
            validator,
            expected_body_bytes: body_bytes,
        });
    }
    if status != StatusCode::PARTIAL_CONTENT {
        return Err(range_invalid("下载响应状态不符合 Range 语义"));
    }

    let content_range = header_text(headers, CONTENT_RANGE)?
        .ok_or_else(|| range_invalid("206 响应缺少 Content-Range"))?;
    let (start, end, total) = parse_satisfied_range(content_range)?;
    if start != request.offset || end < start || end >= total {
        return Err(range_invalid("Content-Range 与请求偏移不一致"));
    }
    let expected = end
        .checked_sub(start)
        .and_then(|value| value.checked_add(1))
        .ok_or_else(|| range_invalid("Content-Range 长度溢出"))?;
    if let Some(declared) = parse_optional_u64_header(headers, CONTENT_LENGTH)? {
        if declared != expected {
            return Err(range_invalid("Content-Length 与 Content-Range 不一致"));
        }
    }
    let validator = EntityValidator::from_headers(headers, Some(total))?;
    if request.offset > 0 && request.validator.compare(&validator) == EntityComparison::Changed {
        return Err(CoreError::new(
            "entity_changed",
            "远端文件实体已变化，需要安全重新开始",
            true,
        ));
    }
    Ok(RangeResponse {
        action: if request.offset == 0 {
            RangeResponseAction::WriteFromStart
        } else {
            RangeResponseAction::Append
        },
        validator,
        expected_body_bytes: Some(expected),
    })
}

pub(crate) fn inspect_payload_prefix(bytes: &[u8]) -> CoreResult<()> {
    let prefix = &bytes[..bytes.len().min(512)];
    let Ok(text) = std::str::from_utf8(prefix) else {
        return Ok(());
    };
    let lowercase = text
        .trim_start_matches(|character: char| character.is_whitespace() || character == '\u{feff}')
        .to_ascii_lowercase();
    if lowercase.starts_with("<!doctype html")
        || lowercase.starts_with("<html")
        || lowercase.starts_with("<head")
        || lowercase.starts_with("<body")
        || lowercase.starts_with('{')
        || lowercase.starts_with('[')
    {
        Err(CoreError::new(
            "unexpected_payload",
            "下载地址返回了网页或 JSON，而不是文件内容",
            true,
        ))
    } else {
        Ok(())
    }
}

fn validate_representation_headers(headers: &HeaderMap) -> CoreResult<()> {
    if let Some(encoding) = header_text(headers, CONTENT_ENCODING)? {
        if !encoding.eq_ignore_ascii_case("identity") {
            return Err(range_invalid("断点下载不允许压缩传输编码"));
        }
    }
    if let Some(content_type) = header_text(headers, CONTENT_TYPE)? {
        let media_type = content_type
            .split(';')
            .next()
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase();
        if media_type == "text/html"
            || media_type == "application/json"
            || media_type == "text/json"
            || media_type.ends_with("+json")
        {
            return Err(CoreError::new(
                "unexpected_payload",
                "下载地址返回了网页或 JSON，而不是文件内容",
                true,
            ));
        }
    }
    Ok(())
}

fn parse_satisfied_range(value: &str) -> CoreResult<(u64, u64, u64)> {
    let value = value
        .strip_prefix("bytes ")
        .ok_or_else(|| range_invalid("Content-Range 单位无效"))?;
    let (range, total) = value
        .split_once('/')
        .ok_or_else(|| range_invalid("Content-Range 格式无效"))?;
    if total.contains('/') {
        return Err(range_invalid("Content-Range 格式无效"));
    }
    let (start, end) = range
        .split_once('-')
        .ok_or_else(|| range_invalid("Content-Range 区间无效"))?;
    Ok((strict_u64(start)?, strict_u64(end)?, strict_u64(total)?))
}

fn parse_unsatisfied_total(headers: &HeaderMap) -> CoreResult<u64> {
    let value = header_text(headers, CONTENT_RANGE)?
        .ok_or_else(|| range_invalid("416 响应缺少 Content-Range"))?;
    strict_u64(
        value
            .strip_prefix("bytes */")
            .ok_or_else(|| range_invalid("416 Content-Range 格式无效"))?,
    )
}

fn parse_optional_u64_header(
    headers: &HeaderMap,
    name: reqwest::header::HeaderName,
) -> CoreResult<Option<u64>> {
    header_text(headers, name)?.map(strict_u64).transpose()
}

fn strict_u64(value: &str) -> CoreResult<u64> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(range_invalid("Range 数值格式无效"));
    }
    value.parse().map_err(|_| range_invalid("Range 数值溢出"))
}

fn header_text(headers: &HeaderMap, name: reqwest::header::HeaderName) -> CoreResult<Option<&str>> {
    headers
        .get(name)
        .map(|value| {
            value
                .to_str()
                .map_err(|_| range_invalid("下载响应头不是有效文本"))
        })
        .transpose()
}

fn range_invalid(message: &str) -> CoreError {
    CoreError::new("range_invalid", message, false)
}

#[cfg(test)]
mod tests {
    use reqwest::header::{
        HeaderMap, HeaderValue, CONTENT_ENCODING, CONTENT_TYPE, IF_RANGE, RANGE,
    };

    use super::*;

    fn headers(values: &[(&'static str, &'static str)]) -> HeaderMap {
        let mut headers = HeaderMap::new();
        for (name, value) in values {
            headers.insert(*name, HeaderValue::from_static(value));
        }
        headers
    }

    #[test]
    fn test_range_request_uses_identity_range_and_strong_if_range() {
        let request = RangeRequest {
            offset: 64,
            validator: EntityValidator {
                etag: Some("\"v1\"".to_owned()),
                last_modified: None,
                total_bytes: Some(128),
            },
        };

        let headers = request.headers().unwrap();

        assert_eq!(headers[RANGE], "bytes=64-");
        assert_eq!(headers[IF_RANGE], "\"v1\"");
        assert!(headers.get(CONTENT_ENCODING).is_none());
        assert_eq!(headers[reqwest::header::ACCEPT_ENCODING], "identity");
    }

    #[test]
    fn test_zero_offset_200_writes_from_start_with_declared_total() {
        let response = inspect_range_response(
            &RangeRequest::default(),
            StatusCode::OK,
            &headers(&[("content-length", "7"), ("etag", "\"one\"")]),
        )
        .unwrap();

        assert_eq!(response.action, RangeResponseAction::WriteFromStart);
        assert_eq!(response.expected_body_bytes, Some(7));
        assert_eq!(response.validator.total_bytes, Some(7));
    }

    #[test]
    fn test_resume_206_requires_exact_content_range_and_appends() {
        let request = RangeRequest {
            offset: 4,
            validator: EntityValidator {
                etag: Some("\"one\"".to_owned()),
                last_modified: None,
                total_bytes: Some(10),
            },
        };
        let response = inspect_range_response(
            &request,
            StatusCode::PARTIAL_CONTENT,
            &headers(&[
                ("content-range", "bytes 4-9/10"),
                ("content-length", "6"),
                ("etag", "\"one\""),
            ]),
        )
        .unwrap();

        assert_eq!(response.action, RangeResponseAction::Append);
        assert_eq!(response.expected_body_bytes, Some(6));
        assert_eq!(response.validator.total_bytes, Some(10));
    }

    #[test]
    fn test_resume_200_never_appends_and_requires_safe_restart() {
        let response = inspect_range_response(
            &RangeRequest {
                offset: 4,
                validator: EntityValidator::default(),
            },
            StatusCode::OK,
            &headers(&[("content-length", "10")]),
        )
        .unwrap();

        assert_eq!(response.action, RangeResponseAction::RestartFromZero);
        assert_eq!(response.expected_body_bytes, Some(10));
    }

    #[test]
    fn test_resume_rejects_wrong_start_length_total_and_entity() {
        let request = RangeRequest {
            offset: 4,
            validator: EntityValidator {
                etag: Some("\"old\"".to_owned()),
                last_modified: None,
                total_bytes: Some(10),
            },
        };
        for values in [
            vec![("content-range", "bytes 3-9/10"), ("content-length", "7")],
            vec![("content-range", "bytes 4-9/10"), ("content-length", "5")],
            vec![("content-range", "bytes 4-10/10"), ("content-length", "7")],
            vec![
                ("content-range", "bytes 4-9/10"),
                ("content-length", "6"),
                ("etag", "\"new\""),
            ],
        ] {
            let error =
                inspect_range_response(&request, StatusCode::PARTIAL_CONTENT, &headers(&values))
                    .unwrap_err();
            assert!(matches!(error.code, "range_invalid" | "entity_changed"));
        }
    }

    #[test]
    fn test_416_is_complete_only_when_offset_equals_known_total() {
        let complete = inspect_range_response(
            &RangeRequest {
                offset: 10,
                validator: EntityValidator {
                    total_bytes: Some(10),
                    ..EntityValidator::default()
                },
            },
            StatusCode::RANGE_NOT_SATISFIABLE,
            &headers(&[("content-range", "bytes */10")]),
        )
        .unwrap();
        assert_eq!(complete.action, RangeResponseAction::AlreadyComplete);

        let error = inspect_range_response(
            &RangeRequest {
                offset: 9,
                validator: EntityValidator {
                    total_bytes: Some(10),
                    ..EntityValidator::default()
                },
            },
            StatusCode::RANGE_NOT_SATISFIABLE,
            &headers(&[("content-range", "bytes */10")]),
        )
        .unwrap_err();
        assert_eq!(error.code, "range_invalid");
    }

    #[test]
    fn test_stale_direct_statuses_are_distinct_from_generic_http_errors() {
        for status in [
            StatusCode::UNAUTHORIZED,
            StatusCode::FORBIDDEN,
            StatusCode::NOT_FOUND,
            StatusCode::GONE,
        ] {
            assert_eq!(
                inspect_range_response(&RangeRequest::default(), status, &HeaderMap::new())
                    .unwrap_err()
                    .code,
                "direct_link_stale"
            );
        }
    }

    #[test]
    fn test_html_json_and_encoded_payloads_are_rejected() {
        for content_type in ["text/html", "application/json", "application/problem+json"] {
            let mut headers = HeaderMap::new();
            headers.insert(CONTENT_TYPE, content_type.parse().unwrap());
            assert_eq!(
                inspect_range_response(&RangeRequest::default(), StatusCode::OK, &headers)
                    .unwrap_err()
                    .code,
                "unexpected_payload"
            );
        }
        let mut encoded = HeaderMap::new();
        encoded.insert(CONTENT_ENCODING, HeaderValue::from_static("gzip"));
        assert_eq!(
            inspect_range_response(&RangeRequest::default(), StatusCode::OK, &encoded)
                .unwrap_err()
                .code,
            "range_invalid"
        );
        for prefix in [
            b"<!doctype html><html>blocked".as_slice(),
            b"  <html>blocked".as_slice(),
            br#" {"zt":0,"info":"expired"}"#.as_slice(),
            br#" [1,2,3]"#.as_slice(),
        ] {
            assert_eq!(
                inspect_payload_prefix(prefix).unwrap_err().code,
                "unexpected_payload"
            );
        }
        assert!(inspect_payload_prefix(b"PK\x03\x04binary").is_ok());
    }
}
