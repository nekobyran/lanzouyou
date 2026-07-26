use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU8, Ordering},
        Arc, Condvar, Mutex, MutexGuard,
    },
    time::{Duration, Instant},
};

use once_cell::sync::Lazy;
use rand::RngCore;
use reqwest::Url;
use sha2::{Digest, Sha256};

use crate::error::{CoreError, CoreResult};

use super::session::LibraryTransport;
use super::url::{normalize_public_share_url, SecurityPolicy};

pub(crate) const DIRECT_LINK_TTL: Duration = Duration::from_secs(60 * 60);
const MAX_DIRECT_LINK_ENTRIES: usize = 4_096;
const MAX_DIRECT_URL_BYTES: usize = 4 * 1024;

static PROCESS_DIRECT_LINK_CACHE: Lazy<DirectLinkCache> = Lazy::new(DirectLinkCache::new);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum ResolvePriority {
    Prewarm = 0,
    Confirmed = 1,
}

pub(crate) struct ResolvedDirectLink {
    direct_url: String,
    file_name: String,
    transport: Option<Arc<LibraryTransport>>,
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
        })
    }

    pub(crate) fn with_transport(
        direct_url: String,
        file_name: String,
        transport: Arc<LibraryTransport>,
    ) -> CoreResult<Self> {
        let mut value = Self::new(direct_url, file_name)?;
        value.transport = Some(transport);
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
}

#[derive(Clone)]
pub(crate) struct ResolveContext {
    priority: Arc<AtomicU8>,
}

impl ResolveContext {
    pub(crate) fn priority(&self) -> ResolvePriority {
        if self.priority.load(Ordering::Acquire) >= ResolvePriority::Confirmed as u8 {
            ResolvePriority::Confirmed
        } else {
            ResolvePriority::Prewarm
        }
    }
}

#[derive(Clone, PartialEq, Eq, Hash)]
struct CacheKey([u8; 32]);

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
    priority: Arc<AtomicU8>,
    result: Mutex<Option<CoreResult<LeaseValue>>>,
    completed: Condvar,
}

impl Flight {
    fn new(priority: ResolvePriority) -> Self {
        Self {
            priority: Arc::new(AtomicU8::new(priority as u8)),
            result: Mutex::new(None),
            completed: Condvar::new(),
        }
    }

    fn elevate(&self, priority: ResolvePriority) {
        self.priority.fetch_max(priority as u8, Ordering::AcqRel);
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
    salt: [u8; 32],
    ttl: Duration,
    started: Instant,
}

pub(crate) fn process_cache() -> &'static DirectLinkCache {
    &PROCESS_DIRECT_LINK_CACHE
}

impl DirectLinkCache {
    pub(crate) fn new() -> Self {
        let mut salt = [0_u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut salt);
        Self::with_ttl_and_salt(DIRECT_LINK_TTL, salt)
    }

    fn with_ttl_and_salt(ttl: Duration, salt: [u8; 32]) -> Self {
        Self {
            state: Mutex::new(CacheState {
                entries: HashMap::new(),
                next_lease_id: 0,
                sequence: 0,
            }),
            salt,
            ttl,
            started: Instant::now(),
        }
    }

    pub(crate) fn resolve<F>(
        &self,
        share_url: &str,
        access_code: &str,
        policy: &SecurityPolicy,
        priority: ResolvePriority,
        resolver: F,
    ) -> CoreResult<DirectLinkLease>
    where
        F: FnOnce(&str, ResolveContext) -> CoreResult<ResolvedDirectLink>,
    {
        self.resolve_at(
            share_url,
            access_code,
            policy,
            priority,
            self.started.elapsed(),
            resolver,
        )
    }

    fn resolve_at<F>(
        &self,
        share_url: &str,
        access_code: &str,
        policy: &SecurityPolicy,
        priority: ResolvePriority,
        now: Duration,
        resolver: F,
    ) -> CoreResult<DirectLinkLease>
    where
        F: FnOnce(&str, ResolveContext) -> CoreResult<ResolvedDirectLink>,
    {
        validate_access_code(access_code)?;
        let canonical_url = normalize_public_share_url(share_url, policy)?;
        let key = cache_key(&canonical_url, access_code, &self.salt);

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
                    CacheEntry::Flight(flight) => {
                        flight.elevate(priority);
                        Some(flight.clone())
                    }
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
                let flight = Arc::new(Flight::new(priority));
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

        let context = ResolveContext {
            priority: flight.priority.clone(),
        };
        let resolved = resolver(&canonical_url, context).map(Arc::new);
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

fn cache_key(canonical_url: &str, access_code: &str, salt: &[u8; 32]) -> CacheKey {
    let mut digest = Sha256::new();
    digest.update(salt);
    digest.update((canonical_url.len() as u64).to_be_bytes());
    digest.update(canonical_url.as_bytes());
    digest.update((access_code.len() as u64).to_be_bytes());
    digest.update(access_code.as_bytes());
    CacheKey(digest.finalize().into())
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
            mpsc, Arc, Barrier,
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
        let cache = DirectLinkCache::with_ttl_and_salt(Duration::from_secs(60 * 60), [7_u8; 32]);
        let calls = AtomicUsize::new(0);
        let first = cache
            .resolve_at(
                "https://www.lanzouw.com/b1",
                "",
                &SecurityPolicy::Production,
                ResolvePriority::Confirmed,
                Duration::ZERO,
                |_, _| {
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
                ResolvePriority::Confirmed,
                Duration::from_millis(3_599_999),
                |_, _| panic!("fresh entry must not resolve again"),
            )
            .unwrap();
        let refreshed = cache
            .resolve_at(
                "https://www.lanzouw.com/b1",
                "",
                &SecurityPolicy::Production,
                ResolvePriority::Confirmed,
                Duration::from_millis(3_600_000),
                |_, _| {
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
        let cache = Arc::new(DirectLinkCache::with_ttl_and_salt(
            DIRECT_LINK_TTL,
            [8_u8; 32],
        ));
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
                        ResolvePriority::Confirmed,
                        Duration::ZERO,
                        |_, _| {
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
        let cache = DirectLinkCache::with_ttl_and_salt(DIRECT_LINK_TTL, [9_u8; 32]);
        let calls = AtomicUsize::new(0);
        for code in ["one", "two", "one"] {
            cache
                .resolve_at(
                    "https://www.lanzouw.com/b-code",
                    code,
                    &SecurityPolicy::Production,
                    ResolvePriority::Confirmed,
                    Duration::ZERO,
                    |_, _| {
                        calls.fetch_add(1, Ordering::SeqCst);
                        Ok(resolved(code))
                    },
                )
                .unwrap();
        }

        assert_eq!(calls.load(Ordering::SeqCst), 2);
        let first = cache_key("https://www.lanzouw.com/b-code", "one", &[9_u8; 32]);
        let second = cache_key("https://www.lanzouw.com/b-code", "two", &[9_u8; 32]);
        assert_ne!(first.0, second.0);
        assert!(!first.0.windows(3).any(|window| window == b"one"));
    }

    #[test]
    fn test_confirmed_waiter_elevates_inflight_prewarm_priority() {
        let cache = Arc::new(DirectLinkCache::with_ttl_and_salt(
            DIRECT_LINK_TTL,
            [10_u8; 32],
        ));
        let (started_tx, started_rx) = mpsc::sync_channel(1);
        let leader_cache = cache.clone();
        let leader = thread::spawn(move || {
            leader_cache
                .resolve_at(
                    "https://www.lanzouw.com/b-priority",
                    "",
                    &SecurityPolicy::Production,
                    ResolvePriority::Prewarm,
                    Duration::ZERO,
                    |_, context| {
                        started_tx.send(()).unwrap();
                        let deadline = std::time::Instant::now() + Duration::from_secs(1);
                        while context.priority() != ResolvePriority::Confirmed {
                            assert!(std::time::Instant::now() < deadline);
                            thread::yield_now();
                        }
                        Ok(resolved("elevated"))
                    },
                )
                .unwrap()
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let waiter_cache = cache.clone();
        let waiter = thread::spawn(move || {
            waiter_cache
                .resolve_at(
                    "https://www.lanzouw.com/b-priority",
                    "",
                    &SecurityPolicy::Production,
                    ResolvePriority::Confirmed,
                    Duration::ZERO,
                    |_, _| panic!("confirmed waiter must join the prewarm flight"),
                )
                .unwrap()
        });

        let leader = leader.join().unwrap();
        let waiter = waiter.join().unwrap();
        assert_eq!(leader.lease_id(), waiter.lease_id());
    }

    #[test]
    fn test_lease_invalidation_is_compare_and_swap() {
        let cache = DirectLinkCache::with_ttl_and_salt(DIRECT_LINK_TTL, [11_u8; 32]);
        let first = cache
            .resolve_at(
                "https://www.lanzouw.com/b-cas",
                "",
                &SecurityPolicy::Production,
                ResolvePriority::Confirmed,
                Duration::ZERO,
                |_, _| Ok(resolved("one")),
            )
            .unwrap();
        assert!(cache.invalidate(&first));
        let second = cache
            .resolve_at(
                "https://www.lanzouw.com/b-cas",
                "",
                &SecurityPolicy::Production,
                ResolvePriority::Confirmed,
                Duration::from_millis(1),
                |_, _| Ok(resolved("two")),
            )
            .unwrap();

        assert!(!cache.invalidate(&first));
        let still_second = cache
            .resolve_at(
                "https://www.lanzouw.com/b-cas",
                "",
                &SecurityPolicy::Production,
                ResolvePriority::Confirmed,
                Duration::from_millis(2),
                |_, _| panic!("stale lease must not evict the new generation"),
            )
            .unwrap();
        assert_eq!(second.lease_id(), still_second.lease_id());
        assert_eq!(still_second.file_name(), "two.apk");
    }

    #[test]
    fn test_failed_flight_is_shared_but_later_call_can_retry() {
        let cache = Arc::new(DirectLinkCache::with_ttl_and_salt(
            DIRECT_LINK_TTL,
            [12_u8; 32],
        ));
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
                    ResolvePriority::Confirmed,
                    Duration::ZERO,
                    |_, _| {
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
                ResolvePriority::Confirmed,
                Duration::from_millis(1),
                |_, _| {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(resolved("retry"))
                },
            )
            .unwrap();
        assert_eq!(retry.file_name(), "retry.apk");
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }
}
