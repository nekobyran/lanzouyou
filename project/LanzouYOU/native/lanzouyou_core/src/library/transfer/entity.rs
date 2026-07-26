use reqwest::header::{HeaderMap, ETAG, LAST_MODIFIED};

use crate::error::{CoreError, CoreResult};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct EntityValidator {
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub total_bytes: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum EntityComparison {
    Unchanged,
    Changed,
}

impl EntityValidator {
    pub(crate) fn from_headers(headers: &HeaderMap, total_bytes: Option<u64>) -> CoreResult<Self> {
        Ok(Self {
            etag: bounded_header(headers, ETAG)?,
            last_modified: bounded_header(headers, LAST_MODIFIED)?,
            total_bytes,
        })
    }

    pub(crate) fn if_range_value(&self) -> Option<&str> {
        self.etag
            .as_deref()
            .filter(|etag| !etag.trim_start().starts_with("W/"))
            .or(self.last_modified.as_deref())
    }

    pub(crate) fn compare(&self, response: &Self) -> EntityComparison {
        let etag_changed = self
            .etag
            .as_ref()
            .zip(response.etag.as_ref())
            .is_some_and(|(stored, current)| stored != current);
        let modified_changed = self
            .last_modified
            .as_ref()
            .zip(response.last_modified.as_ref())
            .is_some_and(|(stored, current)| stored != current);
        let total_changed = self
            .total_bytes
            .zip(response.total_bytes)
            .is_some_and(|(stored, current)| stored != current);
        if etag_changed || modified_changed || total_changed {
            EntityComparison::Changed
        } else {
            EntityComparison::Unchanged
        }
    }
}

fn bounded_header(
    headers: &HeaderMap,
    name: reqwest::header::HeaderName,
) -> CoreResult<Option<String>> {
    let Some(value) = headers.get(name) else {
        return Ok(None);
    };
    let value = value
        .to_str()
        .map_err(|_| range_invalid("Range 实体校验头不是有效文本"))?;
    if value.is_empty() || value.len() > 512 || value.chars().any(char::is_control) {
        return Err(range_invalid("Range 实体校验头格式无效"));
    }
    Ok(Some(value.to_owned()))
}

fn range_invalid(message: &str) -> CoreError {
    CoreError::new("range_invalid", message, false)
}

#[cfg(test)]
mod tests {
    use reqwest::header::{HeaderMap, ETAG, LAST_MODIFIED};

    use super::*;

    #[test]
    fn test_strong_etag_wins_if_range_and_weak_etag_falls_back_to_last_modified() {
        let strong = EntityValidator {
            etag: Some("\"v1\"".to_owned()),
            last_modified: Some("Wed, 16 Jul 2026 00:00:00 GMT".to_owned()),
            total_bytes: Some(10),
        };
        let weak = EntityValidator {
            etag: Some("W/\"v1\"".to_owned()),
            ..strong.clone()
        };

        assert_eq!(strong.if_range_value(), Some("\"v1\""));
        assert_eq!(weak.if_range_value(), Some("Wed, 16 Jul 2026 00:00:00 GMT"));
    }

    #[test]
    fn test_response_entity_change_detects_etag_last_modified_and_total_mismatch() {
        let stored = EntityValidator {
            etag: Some("\"v1\"".to_owned()),
            last_modified: Some("old".to_owned()),
            total_bytes: Some(10),
        };
        for response in [
            EntityValidator {
                etag: Some("\"v2\"".to_owned()),
                ..stored.clone()
            },
            EntityValidator {
                etag: None,
                last_modified: Some("new".to_owned()),
                ..stored.clone()
            },
            EntityValidator {
                etag: None,
                last_modified: None,
                total_bytes: Some(11),
            },
        ] {
            assert_eq!(stored.compare(&response), EntityComparison::Changed);
        }
    }

    #[test]
    fn test_headers_are_bounded_and_control_free() {
        let mut headers = HeaderMap::new();
        headers.insert(ETAG, "\"safe\"".parse().unwrap());
        headers.insert(
            LAST_MODIFIED,
            "Wed, 16 Jul 2026 00:00:00 GMT".parse().unwrap(),
        );
        let entity = EntityValidator::from_headers(&headers, Some(12)).unwrap();
        assert_eq!(entity.etag.as_deref(), Some("\"safe\""));
        assert_eq!(entity.total_bytes, Some(12));

        headers.insert(ETAG, "x".repeat(513).parse().unwrap());
        assert_eq!(
            EntityValidator::from_headers(&headers, Some(12))
                .unwrap_err()
                .code,
            "range_invalid"
        );
    }
}
