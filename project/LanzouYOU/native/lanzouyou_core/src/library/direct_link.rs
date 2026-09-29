use std::{
    collections::HashMap,
    sync::{Arc, Condvar, Mutex, MutexGuard},
    time::{Duration, Instant},
};

use once_cell::sync::Lazy;

use reqwest::Url;

use crate::error::{CoreError, CoreResult};

use super::network_profile::UserAgentProfile;
use super::session::LibraryTransport;
use super::url::{normalize_public_share_url, SecurityPolicy};

pub(crate) const DIRECT_LINK_TTL: Duration = Duration::from_secs(60 * 60);
const MAX_DIRECT_LINK_ENTRIES: usize = 4_096;
const MAX_DIRECT_URL_BYTES: usize = 4 * 1024;

static PROCESS_DIRECT_LINK_CACHE: Lazy<DirectLinkCache> = Lazy::new(DirectLinkCache::new);

pub(crate) struct ResolvedDirectLink {
    direct_url: String,
    file_name: String,
    transport: Option<Arc<LibraryTransport>>,
    agent: UserAgentProfile,
}

impl ResolvedDirectLink {
    pub(crate) fn new(direct_url: String, file_name: String) -> CoreResult<Self> {
        if direct_url.len() > MAX_DIRECT_URL_BYTES {
            return Err(CoreError::parse("蓝奏直链长度异常"));
        }
        let parsed = Url::parse(&direct_url).map_err(|_| CoreError::parse("蓝奏直链格式无效"))?;
        if !matches!(parsed.scheme(), "http" | "https")
            || parsed.host_str().is_none()
            || !parsed.username().is_empty()
            || parsed.password().is_some()
        {
            return Err(CoreError::parse("蓝奏直链格式无效"));
        }
        crate::validation::safe_filename(&file_name)?;
        Ok(Self {
            direct_url,
            file_name,
            transport: None,
            agent: UserAgentProfile::MobileChrome,
        })
    }

    pub(crate) fn with_transport_and_agent(
        direct_url: String,
        file_name: String,
        transport: Arc<LibraryTransport>,
        agent: UserAgentProfile,
    ) -> CoreResult<Self> {
        let mut value = Self::new(direct_url, file_name)?;
        value.transport = Some(transport);
        value.agent = agent;
        Ok(value)
    }
}

#[derive(Clone)]
struct LeaseValue {
    lease_id: u64,
    value: Arc<ResolvedDirectLink>,
}

#[derive(Clone)]
pub(crate) struct DirectLinkLease {
    key: CacheKey,
    lease: LeaseValue,
}

impl DirectLinkLease {
    #[cfg(test)]
    pub(crate) fn lease_id(&self) -> u64 {
        self.lease.lease_id
    }

    pub(crate) fn direct_url(&self) -> &str {
        &self.lease.value.direct_url
    }

    pub(crate) fn file_name(&self) -> &str {
        &self.lease.value.file_name
    }

    pub(crate) fn transport(&self) -> Option<&Arc<LibraryTransport>> {
        self.lease.value.transport.as_ref()
    }

    pub(crate) fn user_agent(&self) -> &'static str {
        self.lease.value.agent.user_agent()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct CacheKey {
    canonical_url: String,
    access_code: String,
}

struct ReadyEntry {
    lease: LeaseValue,
    expires_at: Duration,
    last_access: u64,
}

enum CacheEntry {
    Flight(Arc<Flight>),
    Ready(ReadyEntry),
}

struct Flight {
    result: Mutex<Option<CoreResult<LeaseValue>>>,
    completed: Condvar,
}

impl Flight {
    fn new() -> Self {
        Self {
            result: Mutex::new(None),
            completed: Condvar::new(),
        }
    }

    fn wait(&self) -> CoreResult<LeaseValue> {
        let mut result = recover_lock(&self.result);
        while result.is_none() {
            result = self
                .completed
                .wait(result)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        result
            .as_ref()
            .expect("flight completion always stores a result")
            .clone()
    }

    fn finish(&self, result: CoreResult<LeaseValue>) {
        *recover_lock(&self.result) = Some(result);
        self.completed.notify_all();
    }
}

struct CacheState {
    entries: HashMap<CacheKey, CacheEntry>,
    next_lease_id: u64,
    sequence: u64,
}

pub(crate) struct DirectLinkCache {
    state: Mutex<CacheState>,
    ttl: Duration,
    started: Instant,
}

pub(crate) fn process_cache() -> &'static DirectLinkCache {
    &PROCESS_DIRECT_LINK_CACHE
}

impl DirectLinkCache {
    pub(crate) fn new() -> Self {
        Self::with_ttl(DIRECT_LINK_TTL)
    }

    fn with_ttl(ttl: Duration) -> Self {
        Self {
            state: Mutex::new(CacheState {
                entries: HashMap::new(),
                next_lease_id: 0,
                sequence: 0,
            }),
            ttl,
            started: Instant::now(),
        }
    }

    pub(crate) fn resolve<F>(
        &self,
        share_url: &str,
        access_code: &str,
        policy: &SecurityPolicy,
        resolver: F,
    ) -> CoreResult<DirectLinkLease>
    where
        F: FnOnce(&str) -> CoreResult<ResolvedDirectLink>,
    {
        self.resolve_at(
            share_url,
            access_code,
            policy,
            self.started.elapsed(),
            resolver,
        )
    }

    fn resolve_at<F>(
        &self,
        share_url: &str,
        access_code: &str,
        policy: &SecurityPolicy,
        now: Duration,
        resolver: F,
    ) -> CoreResult<DirectLinkLease>
    where
        F: FnOnce(&str) -> CoreResult<ResolvedDirectLink>,
    {
        validate_access_code(access_code)?;
        let canonical_url = normalize_public_share_url(share_url, policy)?;
        let key = cache_key(&canonical_url, access_code);

        let (flight, leader) = {
            let mut state = recover_lock(&self.state);
            state.sequence = state.sequence.wrapping_add(1);
            let access_sequence = state.sequence;
            let mut expired = false;
            let follower = if let Some(entry) = state.entries.get_mut(&key) {
                match entry {
                    CacheEntry::Ready(ready) if now < ready.expires_at => {
                        ready.last_access = access_sequence;
                        return Ok(DirectLinkLease {
                            key,
                            lease: ready.lease.clone(),
                        });
                    }
                    CacheEntry::Ready(_) => {
                        expired = true;
                        None
                    }
                    CacheEntry::Flight(flight) => Some(flight.clone()),
                }
            } else {
                None
            };
            if let Some(flight) = follower {
                (flight, false)
            } else {
                if expired {
                    state.entries.remove(&key);
                }
                let flight = Arc::new(Flight::new());
                prune_for_insert(&mut state, now)?;
                state
                    .entries
                    .insert(key.clone(), CacheEntry::Flight(flight.clone()));
                (flight, true)
            }
        };

        if !leader {
            return flight.wait().map(|lease| DirectLinkLease { key, lease });
        }

        let resolved = resolver(&canonical_url).map(Arc::new);
        let completed = {
            let mut state = recover_lock(&self.state);
            match resolved {
                Ok(value) => {
                    state.next_lease_id = state.next_lease_id.wrapping_add(1).max(1);
                    state.sequence = state.sequence.wrapping_add(1);
                    let lease = LeaseValue {
                        lease_id: state.next_lease_id,
                        value,
                    };
                    let still_current = state.entries.get(&key).is_some_and(|entry| {
                        matches!(entry, CacheEntry::Flight(current) if Arc::ptr_eq(current, &flight))
                    });
                    if still_current {
                        let last_access = state.sequence;
                        state.entries.insert(
                            key.clone(),
                            CacheEntry::Ready(ReadyEntry {
                                lease: lease.clone(),
                                expires_at: now.checked_add(self.ttl).unwrap_or(Duration::MAX),
                                last_access,
                            }),
                        );
                    }
                    Ok(lease)
                }
                Err(error) => {
                    let still_current = state.entries.get(&key).is_some_and(|entry| {
                        matches!(entry, CacheEntry::Flight(current) if Arc::ptr_eq(current, &flight))
                    });
                    if still_current {
                        state.entries.remove(&key);
                    }
                    Err(error)
                }
            }
        };
        flight.finish(completed.clone());
        completed.map(|lease| DirectLinkLease { key, lease })
    }

    /// Invalidates only the exact generation that observed a terminal direct
    /// response. A stale downloader therefore cannot evict a newer refreshed
    /// URL after a 401/403/404/410 or entity-change retry.
    pub(crate) fn invalidate(&self, lease: &DirectLinkLease) -> bool {
        let mut state = recover_lock(&self.state);
        let matches = state.entries.get(&lease.key).is_some_and(|entry| {
            matches!(entry, CacheEntry::Ready(ready) if ready.lease.lease_id == lease.lease.lease_id)
        });
        if matches {
            state.entries.remove(&lease.key);
        }
        matches
    }
}

fn validate_access_code(value: &str) -> CoreResult<()> {
    if value.chars().count() > 64 || value.chars().any(char::is_control) {
        Err(CoreError::invalid("分享密码格式无效"))
    } else {
        Ok(())
    }
}

fn cache_key(canonical_url: &str, access_code: &str) -> CacheKey {
    CacheKey {
        canonical_url: canonical_url.to_owned(),
        access_code: access_code.to_owned(),
    }
}

fn prune_for_insert(state: &mut CacheState, now: Duration) -> CoreResult<()> {
    state.entries.retain(|_, entry| match entry {
        CacheEntry::Flight(_) => true,
        CacheEntry::Ready(ready) => now < ready.expires_at,
    });
    while state.entries.len() >= MAX_DIRECT_LINK_ENTRIES {
        let oldest = state
            .entries
            .iter()
            .filter_map(|(key, entry)| match entry {
                CacheEntry::Ready(ready) => Some((key.clone(), ready.last_access)),
                CacheEntry::Flight(_) => None,
            })
            .min_by_key(|(_, sequence)| *sequence)
            .map(|(key, _)| key);
        let Some(oldest) = oldest else {
            return Err(CoreError::new(
                "direct_link_capacity",
                "同时解析的蓝奏直链过多，请稍后重试",
                true,
            ));
        };
        state.entries.remove(&oldest);
    }
    Ok(())
}

fn recover_lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{
            atomic::{AtomicUsize, Ordering},
            Arc, Barrier,
        },
        thread,
        time::Duration,
    };

    use super::*;

    fn resolved(name: &str) -> ResolvedDirectLink {
        ResolvedDirectLink::new(format!("https://cdn.example/{name}"), format!("{name}.apk"))
            .unwrap()
    }

    #[test]
    fn test_cache_ttl_is_fresh_at_3599999ms_and_expired_at_3600000ms() {
        let cache = DirectLinkCache::with_ttl(Duration::from_secs(60 * 60));
        let calls = AtomicUsize::new(0);
        let first = cache
            .resolve_at(
                "https://www.lanzouw.com/b1",
                "",
                &SecurityPolicy::Production,
                Duration::ZERO,
                |_| {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(resolved("first"))
                },
            )
            .unwrap();
        let cached = cache
            .resolve_at(
                "https://www.lanzouw.com/b1",
                "",
                &SecurityPolicy::Production,
                Duration::from_millis(3_599_999),
                |_| panic!("fresh entry must not resolve again"),
            )
            .unwrap();
        let refreshed = cache
            .resolve_at(
                "https://www.lanzouw.com/b1",
                "",
                &SecurityPolicy::Production,
                Duration::from_millis(3_600_000),
                |_| {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(resolved("second"))
                },
            )
            .unwrap();

        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(first.lease_id(), cached.lease_id());
        assert_ne!(first.lease_id(), refreshed.lease_id());
        assert_eq!(refreshed.file_name(), "second.apk");
    }

    #[test]
    fn test_cache_single_flights_one_hundred_concurrent_callers() {
        let cache = Arc::new(DirectLinkCache::with_ttl(DIRECT_LINK_TTL));
        let calls = Arc::new(AtomicUsize::new(0));
        let start = Arc::new(Barrier::new(101));
        let mut workers = Vec::new();
        for _ in 0..100 {
            let cache = cache.clone();
            let calls = calls.clone();
            let start = start.clone();
            workers.push(thread::spawn(move || {
                start.wait();
                cache
                    .resolve_at(
                        "https://www.lanzouw.com/b100",
                        "code",
                        &SecurityPolicy::Production,
                        Duration::ZERO,
                        |_| {
                            calls.fetch_add(1, Ordering::SeqCst);
                            thread::sleep(Duration::from_millis(80));
                            Ok(resolved("shared"))
                        },
                    )
                    .unwrap()
            }));
        }
        start.wait();
        let leases = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .collect::<Vec<_>>();

        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(leases
            .windows(2)
            .all(|pair| pair[0].lease_id() == pair[1].lease_id()));
    }

    #[test]
    fn test_cache_does_not_merge_different_access_codes() {
        let cache = DirectLinkCache::with_ttl(DIRECT_LINK_TTL);
        let calls = AtomicUsize::new(0);
        for code in ["one", "two", "one"] {
            cache
                .resolve_at(
                    "https://www.lanzouw.com/b-code",
                    code,
                    &SecurityPolicy::Production,
                    Duration::ZERO,
                    |_| {
                        calls.fetch_add(1, Ordering::SeqCst);
                        Ok(resolved(code))
                    },
                )
                .unwrap();
        }

        assert_eq!(calls.load(Ordering::SeqCst), 2);
        let first = cache_key("https://www.lanzouw.com/b-code", "one");
        let second = cache_key("https://www.lanzouw.com/b-code", "two");
        assert_ne!(first, second);
        assert_eq!(first.access_code, "one");
        assert_eq!(second.access_code, "two");
    }

    #[test]
    fn test_lease_invalidation_is_compare_and_swap() {
        let cache = DirectLinkCache::with_ttl(DIRECT_LINK_TTL);
        let first = cache
            .resolve_at(
                "https://www.lanzouw.com/b-cas",
                "",
                &SecurityPolicy::Production,
                Duration::ZERO,
                |_| Ok(resolved("one")),
            )
            .unwrap();
        assert!(cache.invalidate(&first));
        let second = cache
            .resolve_at(
                "https://www.lanzouw.com/b-cas",
                "",
                &SecurityPolicy::Production,
                Duration::from_millis(1),
                |_| Ok(resolved("two")),
            )
            .unwrap();

        assert!(!cache.invalidate(&first));
        let still_second = cache
            .resolve_at(
                "https://www.lanzouw.com/b-cas",
                "",
                &SecurityPolicy::Production,
                Duration::from_millis(2),
                |_| panic!("stale lease must not evict the new generation"),
            )
            .unwrap();
        assert_eq!(second.lease_id(), still_second.lease_id());
        assert_eq!(still_second.file_name(), "two.apk");
    }

    #[test]
    fn test_failed_flight_is_shared_but_later_call_can_retry() {
        let cache = Arc::new(DirectLinkCache::with_ttl(DIRECT_LINK_TTL));
        let calls = Arc::new(AtomicUsize::new(0));
        let start = Arc::new(Barrier::new(17));
        let mut workers = Vec::new();
        for _ in 0..16 {
            let cache = cache.clone();
            let calls = calls.clone();
            let start = start.clone();
            workers.push(thread::spawn(move || {
                start.wait();
                cache.resolve_at(
                    "https://www.lanzouw.com/b-fail",
                    "",
                    &SecurityPolicy::Production,
                    Duration::ZERO,
                    |_| {
                        calls.fetch_add(1, Ordering::SeqCst);
                        thread::sleep(Duration::from_millis(60));
                        Err(CoreError::remote("temporary", true))
                    },
                )
            }));
        }
        start.wait();
        for worker in workers {
            assert_eq!(worker.join().unwrap().err().unwrap().message, "temporary");
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        let retry = cache
            .resolve_at(
                "https://www.lanzouw.com/b-fail",
                "",
                &SecurityPolicy::Production,
                Duration::from_millis(1),
                |_| {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(resolved("retry"))
                },
            )
            .unwrap();
        assert_eq!(retry.file_name(), "retry.apk");
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }
}
