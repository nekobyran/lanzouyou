use serde::Serialize;
use serde_json::Value;

pub type CoreResult<T> = Result<T, CoreError>;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
    pub retriable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct CoreError {
    pub code: &'static str,
    pub message: String,
    pub retriable: bool,
    pub details: Option<Value>,
}

impl CoreError {
    pub fn new(code: &'static str, message: impl Into<String>, retriable: bool) -> Self {
        Self {
            code,
            message: message.into(),
            retriable,
            details: None,
        }
    }

    pub fn with_details(mut self, details: Value) -> Self {
        self.details = Some(details);
        self
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new("invalid_argument", message, false)
    }

    pub fn parse(message: impl Into<String>) -> Self {
        Self::new("parse_error", message, false)
    }

    pub fn remote(message: impl Into<String>, retriable: bool) -> Self {
        Self::new("remote_error", message, retriable)
    }

    pub fn session_expired() -> Self {
        Self::new("session_expired", "登录状态已过期，请重新登录", false)
    }

    pub fn unauthenticated() -> Self {
        Self::new("unauthenticated", "尚未登录", false)
    }

    pub fn ambiguous(message: impl Into<String>) -> Self {
        Self::new("ambiguous_result", message, false)
    }

    pub fn cancelled() -> Self {
        Self::new("cancelled", "操作已取消", false)
    }

    pub fn io(error: impl std::fmt::Display) -> Self {
        Self::new("io_error", format!("本地文件操作失败: {error}"), false)
    }

    pub fn from_reqwest(error: reqwest::Error) -> Self {
        if error.is_timeout() {
            Self::new("timeout", "请求超时", true)
        } else {
            Self::new("network_error", "网络请求失败", true)
        }
    }

    pub fn body(&self) -> ErrorBody {
        ErrorBody {
            code: self.code.to_owned(),
            message: self.message.clone(),
            retriable: self.retriable,
            details: self.details.clone(),
        }
    }
}

impl From<std::io::Error> for CoreError {
    fn from(value: std::io::Error) -> Self {
        Self::io(value)
    }
}

#[derive(Debug, Serialize)]
pub struct Envelope {
    pub ok: bool,
    pub data: Value,
    pub error: Option<ErrorBody>,
}

impl Envelope {
    pub fn success(data: Value) -> Self {
        Self {
            ok: true,
            data,
            error: None,
        }
    }

    pub fn failure(error: CoreError) -> Self {
        Self {
            ok: false,
            data: Value::Null,
            error: Some(error.body()),
        }
    }
}
