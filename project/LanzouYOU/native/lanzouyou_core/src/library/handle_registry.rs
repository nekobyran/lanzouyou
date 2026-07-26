use std::{
    collections::{HashMap, VecDeque},
    sync::Mutex,
    time::{Duration, Instant},
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use once_cell::sync::Lazy;
use rand::{rngs::OsRng, RngCore};

use crate::error::{CoreError, CoreResult};

const DEFAULT_CAPACITY: usize = 8_192;
const DEFAULT_TTL: Duration = Duration::from_secs(15 * 60);
const HANDLE_PREFIX: &str = "item:";
const HANDLE_RANDOM_BYTES: usize = 24;

/// A server-owned public-library target. This type intentionally implements
/// neither `Serialize` nor `Debug`: access codes and resolved URLs must not be
/// copied into FFI responses, logs or diagnostic formatting.
#[derive(Clone)]
pub(crate) struct HandleTarget {
    pub(crate) source_id: String,
    pub(crate) title: String,
    pub(crate) url: String,
    pub(crate) share_url: String,
    pub(crate) is_folder: bool,
    pub(crate) single_software: bool,
    pub(crate) password: String,
}

struct HandleEntry {
    target: HandleTarget,
    expires_at: Instant,
}

pub(crate) struct HandleRegistry {
    capacity: usize,
    ttl: Duration,
    entries: HashMap<String, HandleEntry>,
    insertion_order: VecDeque<String>,
}

impl HandleRegistry {
    pub(crate) fn new(capacity: usize, ttl: Duration) -> Self {
        Self {
            capacity: capacity.max(1),
            ttl,
            entries: HashMap::with_capacity(capacity.max(1)),
            insertion_order: VecDeque::with_capacity(capacity.max(1)),
        }
    }

    pub(crate) fn insert_at(&mut self, target: HandleTarget, now: Instant) -> String {
        self.remove_expired(now);
        while self.entries.len() >= self.capacity {
            let Some(oldest) = self.insertion_order.pop_front() else {
                break;
            };
            self.entries.remove(&oldest);
        }

        let handle = loop {
            let mut bytes = [0_u8; HANDLE_RANDOM_BYTES];
            OsRng.fill_bytes(&mut bytes);
            let candidate = format!("{HANDLE_PREFIX}{}", URL_SAFE_NO_PAD.encode(bytes));
            if !self.entries.contains_key(&candidate) {
                break candidate;
            }
        };
        self.insertion_order.push_back(handle.clone());
        self.entries.insert(
            handle.clone(),
            HandleEntry {
                target,
                expires_at: now + self.ttl,
            },
        );
        handle
    }

    pub(crate) fn resolve_at(&mut self, handle: &str, now: Instant) -> CoreResult<HandleTarget> {
        if !valid_handle_shape(handle) {
            return Err(expired_handle());
        }
        self.remove_expired(now);
        self.entries
            .get(handle)
            .map(|entry| entry.target.clone())
            .ok_or_else(expired_handle)
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.len()
    }

    fn remove_expired(&mut self, now: Instant) {
        while let Some(handle) = self.insertion_order.front() {
            let expired = self
                .entries
                .get(handle)
                .is_none_or(|entry| entry.expires_at <= now);
            if !expired {
                break;
            }
            let handle = self.insertion_order.pop_front().expect("front existed");
            self.entries.remove(&handle);
        }
    }
}

fn valid_handle_shape(value: &str) -> bool {
    value.len() == HANDLE_PREFIX.len() + 32
        && value.starts_with(HANDLE_PREFIX)
        && value[HANDLE_PREFIX.len()..]
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn expired_handle() -> CoreError {
    CoreError::new(
        "catalog_handle_expired",
        "软件项目引用已失效，请刷新目录或重新搜索",
        true,
    )
}

static HANDLES: Lazy<Mutex<HandleRegistry>> =
    Lazy::new(|| Mutex::new(HandleRegistry::new(DEFAULT_CAPACITY, DEFAULT_TTL)));

pub(crate) fn register(target: HandleTarget) -> CoreResult<String> {
    HANDLES
        .lock()
        .map_err(|_| CoreError::new("internal_error", "软件项目引用表已损坏", false))
        .map(|mut registry| registry.insert_at(target, Instant::now()))
}

pub(crate) fn resolve(handle: &str) -> CoreResult<HandleTarget> {
    HANDLES
        .lock()
        .map_err(|_| CoreError::new("internal_error", "软件项目引用表已损坏", false))?
        .resolve_at(handle, Instant::now())
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::{HandleRegistry, HandleTarget};

    fn target(url: &str) -> HandleTarget {
        HandleTarget {
            source_id: "source-one".to_owned(),
            title: "Tool.apk".to_owned(),
            url: url.to_owned(),
            share_url: url.to_owned(),
            is_folder: false,
            single_software: false,
            password: "private-code".to_owned(),
        }
    }

    #[test]
    fn test_handle_registry_uses_random_opaque_bounded_handles() {
        let now = Instant::now();
        let mut registry = HandleRegistry::new(2, Duration::from_secs(60));

        let first = registry.insert_at(target("https://www.lanzouw.com/a"), now);
        let second = registry.insert_at(target("https://www.lanzouw.com/b"), now);
        let third = registry.insert_at(target("https://www.lanzouw.com/c"), now);

        assert!(first.starts_with("item:"));
        assert_ne!(first, second);
        assert_ne!(second, third);
        assert_eq!(registry.len(), 2);
        assert!(registry.resolve_at(&first, now).is_err());
        assert_eq!(
            registry.resolve_at(&third, now).unwrap().password,
            "private-code"
        );
    }

    #[test]
    fn test_handle_registry_expires_without_trusting_client_urls() {
        let now = Instant::now();
        let mut registry = HandleRegistry::new(8, Duration::from_secs(30));
        let handle = registry.insert_at(target("https://www.lanzouw.com/real"), now);

        let resolved = registry
            .resolve_at(&handle, now + Duration::from_secs(29))
            .unwrap();
        assert_eq!(resolved.share_url, "https://www.lanzouw.com/real");
        assert!(registry
            .resolve_at(&handle, now + Duration::from_secs(31))
            .is_err());
    }
}
