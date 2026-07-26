use std::path::{Component, Path};

use crate::error::{CoreError, CoreResult};

pub fn required(value: &str, field: &str, max: usize) -> CoreResult<()> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(CoreError::invalid(format!("{field} 不能为空")));
    }
    if trimmed.chars().count() > max {
        return Err(CoreError::invalid(format!("{field} 过长")));
    }
    if value.contains(['\r', '\n', '\0']) {
        return Err(CoreError::invalid(format!("{field} 包含非法字符")));
    }
    Ok(())
}

pub fn id(value: &str, field: &str) -> CoreResult<()> {
    required(value, field, 64)?;
    if value != "-1" && !value.chars().all(|ch| ch.is_ascii_digit()) {
        return Err(CoreError::invalid(format!("{field} 必须是数字 ID")));
    }
    Ok(())
}

pub fn cookie(value: &str) -> CoreResult<()> {
    required(value, "cookie", 8192)?;
    for part in value.split(';').filter(|part| !part.trim().is_empty()) {
        let (name, _) = part
            .trim()
            .split_once('=')
            .ok_or_else(|| CoreError::invalid("cookie 格式无效"))?;
        if name.is_empty()
            || !name
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.'))
        {
            return Err(CoreError::invalid("cookie 名称无效"));
        }
    }
    Ok(())
}

pub fn safe_filename(name: &str) -> CoreResult<()> {
    required(name, "name", 255)?;
    let path = Path::new(name);
    if path.is_absolute()
        || name.len() > 255
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
        || name.contains(['/', '\\', ':', '*', '?', '"', '<', '>', '|'])
        || name.chars().any(char::is_control)
        || name.trim_end_matches(['.', ' ']) != name
        || is_windows_device_name(name)
    {
        return Err(CoreError::invalid("name 不是安全文件名"));
    }
    Ok(())
}

fn is_windows_device_name(name: &str) -> bool {
    let stem = name.split('.').next().unwrap_or_default();
    let upper = stem.to_ascii_uppercase();
    matches!(
        upper.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CLOCK$" | "CONIN$" | "CONOUT$"
    ) || upper
        .strip_prefix("COM")
        .or_else(|| upper.strip_prefix("LPT"))
        .is_some_and(|suffix| {
            matches!(
                suffix,
                "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cookie_rejects_header_injection() {
        assert!(cookie("ylogin=1\r\nX-Evil: 1").is_err());
    }

    #[test]
    fn test_safe_filename_rejects_traversal() {
        assert!(safe_filename("../secret.txt").is_err());
        assert!(safe_filename("ok.txt").is_ok());
    }

    #[test]
    fn test_safe_filename_rejects_windows_devices_controls_and_ambiguous_suffixes() {
        for value in [
            "CON",
            "con.txt",
            "AUX.apk",
            "COM¹.apk",
            "LPT³",
            "CONOUT$.log",
            "name.",
            "name ",
            "bad\u{1}name.apk",
        ] {
            assert!(
                safe_filename(value).is_err(),
                "accepted unsafe name: {value:?}"
            );
        }
        assert!(safe_filename("console.apk").is_ok());
    }
}
