use crate::error::CoreError;

pub(crate) const ACCESS_CODE_REMOTE_ERROR: &str = "带访问码的蓝奏请求失败，请检查访问码或稍后重试";

pub(crate) fn sanitize_access_code_error(mut error: CoreError, has_access_code: bool) -> CoreError {
    if has_access_code && !matches!(error.code, "invalid_argument" | "cancelled") {
        error.message = ACCESS_CODE_REMOTE_ERROR.to_owned();
    }
    error
}

#[cfg(test)]
mod tests {
    use crate::error::CoreError;

    use super::sanitize_access_code_error;

    #[test]
    fn test_access_code_remote_error_uses_fixed_message_without_encoded_echoes() {
        let original = CoreError::new(
            "remote_error",
            "form=p%40ss percent=%70%40ss html=&#112;%40ss raw=p@ss",
            true,
        );
        let sanitized = sanitize_access_code_error(original, true);
        assert_eq!(sanitized.code, "remote_error");
        assert!(sanitized.retriable);
        assert_eq!(
            sanitized.message,
            "带访问码的蓝奏请求失败，请检查访问码或稍后重试"
        );
        for forbidden in ["p@ss", "%70%40ss", "&#112;", "form="] {
            assert!(!sanitized.message.contains(forbidden));
        }
    }

    #[test]
    fn test_access_code_sanitizer_keeps_local_validation_and_empty_code_errors() {
        let validation = CoreError::invalid("本地输入无效");
        let sanitized = sanitize_access_code_error(validation, true);
        assert_eq!(sanitized.message, "本地输入无效");

        let remote = CoreError::remote("不含访问码的详细错误", false);
        let unchanged = sanitize_access_code_error(remote, false);
        assert_eq!(unchanged.message, "不含访问码的详细错误");
    }

    #[test]
    fn test_access_code_sanitizer_preserves_safe_cancellation_contract() {
        let sanitized = sanitize_access_code_error(CoreError::cancelled(), true);
        assert_eq!(sanitized.code, "cancelled");
        assert_eq!(sanitized.message, "操作已取消");
        assert!(!sanitized.retriable);
    }
}
