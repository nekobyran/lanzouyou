use reqwest::Url;
use serde::{Deserialize, Serialize};

use crate::error::{CoreError, CoreResult};

use super::url::{normalize_public_share_url, SecurityPolicy};

pub(crate) const MAX_TEXT_BYTES: usize = 64 * 1024;
pub(crate) const MAX_TOKEN_BYTES: usize = 4 * 1024;
pub(crate) const MAX_LINK_TOKENS: usize = 256;

const PRODUCT_RELEASE_HOSTS: [&str; 2] = ["lanzoumax.nkbr.cc", "lanzouplus.nkbr.cc"];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum LinkKind {
    LanzouShare,
    External,
    ProductRelease,
    Blocked,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LinkToken {
    pub text: String,
    pub start_utf16: usize,
    pub end_utf16: usize,
    pub kind: LinkKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub canonical_url: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum LinkPreference {
    Ask,
    Parse,
    Browser,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum LinkAction {
    Ask,
    Parse,
    Browser,
    Blocked,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LinkRoute {
    pub action: LinkAction,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub route_handle: Option<String>,
}

/// Finds bounded HTTP(S) links without ever merging adjacent CJK text into a
/// URL. Offsets use UTF-16 code units so Flutter/Android text selections can
/// apply them directly without rescanning the input.
pub(crate) fn tokenize_links(text: &str) -> CoreResult<Vec<LinkToken>> {
    if text.len() > MAX_TEXT_BYTES {
        return Err(CoreError::invalid("链接文本不能超过 64 KiB"));
    }

    let mut output = Vec::new();
    let mut byte_offset = 0_usize;
    let mut utf16_offset = 0_usize;
    while byte_offset < text.len() {
        let tail = &text[byte_offset..];
        if !starts_with_http_scheme(tail) {
            let character = tail
                .chars()
                .next()
                .expect("byte offset always remains on a character boundary");
            byte_offset += character.len_utf8();
            utf16_offset += character.len_utf16();
            continue;
        }

        let start_byte = byte_offset;
        let start_utf16 = utf16_offset;
        let mut raw_end = start_byte;
        let mut raw_utf16 = 0_usize;
        for character in text[start_byte..].chars() {
            if !is_url_character(character) {
                break;
            }
            raw_end += character.len_utf8();
            raw_utf16 += character.len_utf16();
            if raw_end - start_byte > MAX_TOKEN_BYTES {
                return Err(CoreError::invalid("单个链接不能超过 4 KiB"));
            }
        }

        let token_end = trim_sentence_punctuation(text, start_byte, raw_end);
        if token_end > start_byte {
            if output.len() == MAX_LINK_TOKENS {
                return Err(CoreError::invalid("单段文本最多包含 256 个链接"));
            }
            let value = &text[start_byte..token_end];
            let (kind, canonical_url) = classify_link(value);
            output.push(LinkToken {
                text: value.to_owned(),
                start_utf16,
                end_utf16: start_utf16 + value.encode_utf16().count(),
                kind,
                canonical_url,
            });
        }

        // Consume punctuation scanned as part of the raw candidate exactly
        // once. The next URL search therefore remains O(n), even for hostile
        // input containing thousands of trailing punctuation characters.
        byte_offset = raw_end;
        utf16_offset += raw_utf16;
    }
    Ok(output)
}

pub(crate) fn route_link(token: &LinkToken, preference: LinkPreference) -> LinkRoute {
    let action = match token.kind {
        LinkKind::LanzouShare => match preference {
            LinkPreference::Ask => LinkAction::Ask,
            LinkPreference::Parse => LinkAction::Parse,
            LinkPreference::Browser => LinkAction::Browser,
        },
        LinkKind::External | LinkKind::ProductRelease => LinkAction::Browser,
        LinkKind::Blocked => LinkAction::Blocked,
    };
    let target_url = (action != LinkAction::Blocked).then(|| {
        token
            .canonical_url
            .clone()
            .unwrap_or_else(|| token.text.clone())
    });
    LinkRoute {
        action,
        target_url,
        route_handle: None,
    }
}

fn starts_with_http_scheme(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes
        .get(..7)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case(b"http://"))
        || bytes
            .get(..8)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case(b"https://"))
}

fn is_url_character(character: char) -> bool {
    (character.is_ascii_graphic() && !matches!(character, '"' | '\'' | '<' | '>' | '`' | '\\'))
        || matches!(character, '。' | '．')
}

fn trim_sentence_punctuation(text: &str, start: usize, mut end: usize) -> usize {
    loop {
        let Some(character) = text[start..end].chars().next_back() else {
            break;
        };
        let trim = matches!(
            character,
            '.' | ','
                | ';'
                | ':'
                | '!'
                | '?'
                | '。'
                | '．'
                | '，'
                | '；'
                | '：'
                | '！'
                | '？'
                | '、'
        ) || matches!(character, ')' | ']' | '}')
            && has_unmatched_closer(&text[start..end], character);
        if !trim {
            break;
        }
        end -= character.len_utf8();
    }
    end
}

fn has_unmatched_closer(value: &str, closer: char) -> bool {
    let opener = match closer {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        _ => return false,
    };
    value.chars().filter(|entry| *entry == closer).count()
        > value.chars().filter(|entry| *entry == opener).count()
}

fn classify_link(value: &str) -> (LinkKind, Option<String>) {
    let normalized_dots = value.replace(['。', '．'], ".");
    let parsed = Url::parse(&normalized_dots);
    if parsed.as_ref().is_ok_and(is_exact_product_release) {
        return (LinkKind::ProductRelease, None);
    }
    if let Ok(canonical) = normalize_public_share_url(&normalized_dots, &SecurityPolicy::Production)
    {
        return (LinkKind::LanzouShare, Some(canonical));
    }

    let Ok(parsed) = parsed else {
        return (LinkKind::Blocked, None);
    };
    if !matches!(parsed.scheme(), "http" | "https")
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || looks_like_protected_brand(&normalized_dots, &parsed)
    {
        return (LinkKind::Blocked, None);
    }
    (LinkKind::External, Some(parsed.to_string()))
}

fn is_exact_product_release(url: &Url) -> bool {
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
        && url
            .host_str()
            .is_some_and(|host| PRODUCT_RELEASE_HOSTS.contains(&host))
}

fn looks_like_protected_brand(raw: &str, parsed: &Url) -> bool {
    let lowercase = raw.to_ascii_lowercase();
    let host = parsed.host_str().unwrap_or_default().to_ascii_lowercase();
    ["lanzou", "laozou", "lanzoumax", "lanzouplus"]
        .iter()
        .any(|marker| lowercase.contains(marker) || host.contains(marker))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tokenizer_separates_chinese_and_reports_utf16_offsets() {
        let text = "😀前缀https://www.lanzouw.com/b00abc中文";

        let tokens = tokenize_links(text).unwrap();

        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].text, "https://www.lanzouw.com/b00abc");
        assert_eq!(tokens[0].start_utf16, 4);
        assert_eq!(tokens[0].end_utf16, 34);
        assert_eq!(tokens[0].kind, LinkKind::LanzouShare);
        assert_eq!(
            tokens[0].canonical_url.as_deref(),
            Some("https://www.lanzouw.com/b00abc")
        );
    }

    #[test]
    fn test_tokenizer_canonicalizes_legacy_and_fullwidth_lanzou_domains() {
        let tokens = tokenize_links(
            "旧源 http://pan.lanzoux.com/i-old，新源 https://www。lanzouq．com/i-new。",
        )
        .unwrap();

        assert_eq!(tokens.len(), 2);
        assert!(tokens
            .iter()
            .all(|token| token.kind == LinkKind::LanzouShare));
        assert_eq!(
            tokens[0].canonical_url.as_deref(),
            Some("https://www.lanzouw.com/i-old")
        );
        assert_eq!(
            tokens[1].canonical_url.as_deref(),
            Some("https://www.lanzouw.com/i-new")
        );
    }

    #[test]
    fn test_tokenizer_classifies_exact_product_release_pages_without_parsing_them() {
        let tokens = tokenize_links(
            "https://lanzoumax.nkbr.cc/ https://lanzouplus.nkbr.cc/releases/current",
        )
        .unwrap();

        assert_eq!(tokens.len(), 2);
        assert!(tokens
            .iter()
            .all(|token| token.kind == LinkKind::ProductRelease));
        assert!(tokens.iter().all(|token| token.canonical_url.is_none()));
        for preference in [
            LinkPreference::Ask,
            LinkPreference::Parse,
            LinkPreference::Browser,
        ] {
            assert!(tokens
                .iter()
                .all(|token| route_link(token, preference).action == LinkAction::Browser));
        }
    }

    #[test]
    fn test_tokenizer_blocks_lanzou_lookalikes_and_unsafe_authorities() {
        let text = [
            "https://evil-lanzouw.com/b1",
            "https://www.lanzouw.com.evil.example/b1",
            "https://user@www.lanzouw.com/b1",
            "https://www.lanzouw.com:443/b1",
            "https://www.lanzouw.com./b1",
            "https://xn--evil-9za.lanzouq.com/b1",
        ]
        .join(" ");

        let tokens = tokenize_links(&text).unwrap();

        assert_eq!(tokens.len(), 6);
        assert!(tokens.iter().all(|token| token.kind == LinkKind::Blocked));
        assert!(tokens.iter().all(|token| token.canonical_url.is_none()));
    }

    #[test]
    fn test_tokenizer_trims_sentence_punctuation_and_keeps_url_query_fragment() {
        let tokens =
            tokenize_links("看(https://example.com/a?q=1#part)，再看 https://www.lanzouw.com/b1。")
                .unwrap();

        assert_eq!(tokens.len(), 2);
        assert_eq!(tokens[0].text, "https://example.com/a?q=1#part");
        assert_eq!(tokens[0].kind, LinkKind::External);
        assert_eq!(tokens[1].text, "https://www.lanzouw.com/b1");
    }

    #[test]
    fn test_tokenizer_enforces_input_token_length_and_count_limits() {
        let too_large = "a".repeat(MAX_TEXT_BYTES + 1);
        assert_eq!(
            tokenize_links(&too_large).unwrap_err().code,
            "invalid_argument"
        );

        let too_long_url = format!("https://example.com/{}", "a".repeat(MAX_TOKEN_BYTES));
        assert_eq!(
            tokenize_links(&too_long_url).unwrap_err().code,
            "invalid_argument"
        );

        let too_many = std::iter::repeat_n("https://example.com/x", MAX_LINK_TOKENS + 1)
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(
            tokenize_links(&too_many).unwrap_err().code,
            "invalid_argument"
        );
    }

    #[test]
    fn test_route_link_applies_preference_only_to_trusted_lanzou_share() {
        let tokens = tokenize_links("https://www.lanzouw.com/b1 https://example.com/").unwrap();
        let share = &tokens[0];
        let external = &tokens[1];

        assert_eq!(
            route_link(share, LinkPreference::Ask).action,
            LinkAction::Ask
        );
        assert_eq!(
            route_link(share, LinkPreference::Parse).action,
            LinkAction::Parse
        );
        assert_eq!(
            route_link(share, LinkPreference::Browser).action,
            LinkAction::Browser
        );
        assert_eq!(
            route_link(external, LinkPreference::Parse).action,
            LinkAction::Browser
        );
    }
}
