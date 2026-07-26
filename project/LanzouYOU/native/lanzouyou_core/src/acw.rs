use regex::Regex;

use crate::error::{CoreError, CoreResult};

const MASK: &str = "3000176000856006061501533003690027800375";
const BOX: [usize; 40] = [
    15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11, 39, 18, 20, 8, 14,
    21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36,
];

#[cfg(test)]
pub fn calculate(html: &str) -> CoreResult<String> {
    let arg =
        challenge_argument(html)?.ok_or_else(|| CoreError::parse("无法解析 acw_sc__v2 挑战"))?;
    calculate_argument(arg)
}

pub fn challenge_cookie(html: &str) -> CoreResult<Option<String>> {
    challenge_argument(html)?
        .map(calculate_argument)
        .transpose()
}

fn challenge_argument(html: &str) -> CoreResult<Option<&str>> {
    let regex = Regex::new(r#"arg1=['\"]([0-9A-Fa-f]{40})['\"]"#)
        .map_err(|_| CoreError::parse("acw 规则初始化失败"))?;
    Ok(regex
        .captures(html)
        .and_then(|captures| captures.get(1))
        .map(|value| value.as_str()))
}

fn calculate_argument(arg: &str) -> CoreResult<String> {
    let mut unboxed = [b'0'; 40];
    for (index, byte) in arg.as_bytes().iter().enumerate() {
        let target = BOX
            .iter()
            .position(|position| *position == index + 1)
            .ok_or_else(|| CoreError::parse("acw_sc__v2 置换失败"))?;
        unboxed[target] = *byte;
    }

    let mut output = String::with_capacity(40);
    for index in (0..40).step_by(2) {
        let left = parse_hex_pair(&unboxed[index..index + 2])?;
        let right = parse_hex_pair(&MASK.as_bytes()[index..index + 2])?;
        output.push_str(&format!("{:02x}", left ^ right));
    }
    Ok(output)
}

fn parse_hex_pair(value: &[u8]) -> CoreResult<u8> {
    let text = std::str::from_utf8(value).map_err(|_| CoreError::parse("acw hex 无效"))?;
    u8::from_str_radix(text, 16).map_err(|_| CoreError::parse("acw hex 无效"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_calculate_known_vector() {
        let html = "<script>var arg1='0123456789ABCDEF0123456789ABCDEF01234567';</script>";
        assert_eq!(
            calculate(html).unwrap(),
            "d2c7186598ab1a508a4f6064e4fa746323ab17c6"
        );
    }

    #[test]
    fn test_calculate_rejects_missing_argument() {
        assert!(calculate("<html></html>").is_err());
    }

    #[test]
    fn test_challenge_cookie_detects_arg1_without_cookie_literal() {
        let html = "<script>var arg1='0123456789ABCDEF0123456789ABCDEF01234567';</script>";
        assert_eq!(
            challenge_cookie(html).unwrap().as_deref(),
            Some("d2c7186598ab1a508a4f6064e4fa746323ab17c6")
        );
        assert_eq!(challenge_cookie("var arg1='1234'").unwrap(), None);
    }
}
