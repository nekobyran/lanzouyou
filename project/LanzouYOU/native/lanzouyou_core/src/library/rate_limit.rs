use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use crate::{
    error::{CoreError, CoreResult},
    operation::OperationHandle,
};

use super::session::wait_cooperatively;

pub(crate) struct RateLimiter {
    interval_override: Option<Duration>,
    next: Mutex<HashMap<String, Instant>>,
}

impl RateLimiter {
    pub(crate) fn production() -> Self {
        Self::profiled()
    }

    pub(crate) fn profiled() -> Self {
        Self {
            interval_override: None,
            next: Mutex::new(HashMap::new()),
        }
    }

    #[cfg(test)]
    pub(crate) fn new(interval: Duration) -> Self {
        Self {
            interval_override: Some(interval),
            next: Mutex::new(HashMap::new()),
        }
    }

    #[cfg(test)]
    pub(crate) fn wait_with_interval(
        &self,
        key: &str,
        deadline: Option<Instant>,
        requested_interval: Duration,
    ) -> CoreResult<()> {
        self.wait_with_interval_constrained(key, deadline, requested_interval, None)
    }

    pub(crate) fn wait_with_interval_constrained(
        &self,
        key: &str,
        deadline: Option<Instant>,
        requested_interval: Duration,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<()> {
        let interval = self.interval_override.unwrap_or(requested_interval);
        loop {
            if let Some(operation) = operation {
                operation.check_cancelled()?;
            }
            let wait = {
                let mut slots = self
                    .next
                    .lock()
                    .map_err(|_| CoreError::new("internal_error", "节流状态锁已损坏", false))?;
                let now = Instant::now();
                let next = slots.get(key).copied().unwrap_or(now);
                if now >= next {
                    slots.insert(key.to_owned(), now + interval);
                    return Ok(());
                }
                next.saturating_duration_since(now)
            };
            if deadline.is_some_and(|limit| Instant::now() + wait > limit) {
                return Err(CoreError::new("timeout", "蓝奏分页等待超时", true));
            }
            wait_cooperatively(wait.min(Duration::from_millis(200)), operation, deadline)?;
        }
    }

    pub(crate) fn defer(&self, key: &str, requested_delay: Duration) -> CoreResult<()> {
        let delay = self.interval_override.unwrap_or(requested_delay);
        if delay.is_zero() {
            return Ok(());
        }
        let mut slots = self
            .next
            .lock()
            .map_err(|_| CoreError::new("internal_error", "节流状态锁已损坏", false))?;
        let now = Instant::now();
        let deferred = now + delay;
        if slots.get(key).is_none_or(|current| *current < deferred) {
            slots.insert(key.to_owned(), deferred);
        }
        Ok(())
    }

    pub(crate) fn ready_at_ms(&self, key: &str) -> u64 {
        let left = self
            .next
            .lock()
            .ok()
            .and_then(|slots| slots.get(key).copied())
            .map(|next| next.saturating_duration_since(Instant::now()))
            .unwrap_or_default();
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .saturating_add(left)
            .as_millis()
            .try_into()
            .unwrap_or(u64::MAX)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rate_limiter_can_be_disabled_for_contract_tests() {
        let limiter = RateLimiter::new(Duration::ZERO);
        let before = Instant::now();
        limiter
            .wait_with_interval("one", None, Duration::from_secs(1))
            .unwrap();
        limiter
            .wait_with_interval("one", None, Duration::from_secs(1))
            .unwrap();
        assert!(before.elapsed() < Duration::from_millis(50));
    }

    #[test]
    fn test_rate_limiter_reports_future_ready_time() {
        let limiter = RateLimiter::new(Duration::from_millis(30));
        limiter
            .wait_with_interval("one", None, Duration::from_secs(1))
            .unwrap();
        let now: u64 = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis()
            .try_into()
            .unwrap();
        assert!(limiter.ready_at_ms("one") >= now);
    }

    #[test]
    fn test_profiled_rate_limiter_reserves_requested_interval_and_extends_backoff() {
        let limiter = RateLimiter::profiled();
        let now: u64 = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis()
            .try_into()
            .unwrap();

        limiter
            .wait_with_interval("directory", None, Duration::from_millis(80))
            .unwrap();
        let reserved = limiter.ready_at_ms("directory");
        assert!(reserved >= now + 40);

        limiter
            .defer("directory", Duration::from_millis(140))
            .unwrap();
        assert!(limiter.ready_at_ms("directory") >= reserved + 30);
    }

    #[test]
    fn test_zero_override_disables_profile_interval_and_defer_for_contract_tests() {
        let limiter = RateLimiter::new(Duration::ZERO);
        let before = Instant::now();
        limiter
            .wait_with_interval("directory", None, Duration::from_secs(2))
            .unwrap();
        limiter.defer("directory", Duration::from_secs(8)).unwrap();
        limiter
            .wait_with_interval("directory", None, Duration::from_secs(2))
            .unwrap();
        assert!(before.elapsed() < Duration::from_millis(50));
    }

    #[test]
    fn test_rate_limiter_wait_observes_operation_cancellation() {
        let operation_id = "library-rate-limit-cancel-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::LibrarySearch,
        )
        .unwrap()
        .unwrap();
        let limiter = std::sync::Arc::new(RateLimiter::new(Duration::from_secs(2)));
        limiter
            .wait_with_interval("cancel", None, Duration::ZERO)
            .unwrap();
        let started = Instant::now();
        let waiting_limiter = limiter.clone();
        let waiting_operation = operation.clone();
        let waiter = std::thread::spawn(move || {
            waiting_limiter.wait_with_interval_constrained(
                "cancel",
                None,
                Duration::ZERO,
                Some(&waiting_operation),
            )
        });
        std::thread::sleep(Duration::from_millis(30));
        crate::operation::cancel(operation_id).unwrap();
        let error = waiter.join().unwrap().unwrap_err();
        assert_eq!(error.code, "cancelled");
        assert!(started.elapsed() < Duration::from_millis(500));
        operation.finish_result::<()>(&Err(error));
        crate::operation::forget(operation_id).unwrap();
    }
}
