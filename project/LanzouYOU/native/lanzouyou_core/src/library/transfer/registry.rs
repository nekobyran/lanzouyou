use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Mutex, MutexGuard},
};

use once_cell::sync::Lazy;
use serde::Serialize;

use crate::error::{CoreError, CoreResult};

use super::{TransferControl, TransferStatus, WorkerLease};

const MAX_TRANSFERS: usize = 128;
const MAX_EVENTS: usize = 8_192;
const MAX_EVENT_READ: usize = 256;

static TRANSFERS: Lazy<TransferRegistry> = Lazy::new(TransferRegistry::new);

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TransferEvent {
    pub revision: u64,
    pub status: TransferStatus,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TransferEventPage {
    pub revision: u64,
    pub next_revision: u64,
    pub has_more: bool,
    pub events: Vec<TransferEvent>,
}

struct RegistryEntry {
    control: Arc<TransferControl>,
    sequence: u64,
}

struct RegistryState {
    entries: HashMap<String, RegistryEntry>,
    events: VecDeque<TransferEvent>,
    next_sequence: u64,
    revision: u64,
}

pub(crate) struct TransferRegistry {
    state: Mutex<RegistryState>,
}

pub(crate) fn process_transfers() -> &'static TransferRegistry {
    &TRANSFERS
}

impl TransferRegistry {
    pub(crate) fn new() -> Self {
        Self {
            state: Mutex::new(RegistryState {
                entries: HashMap::new(),
                events: VecDeque::new(),
                next_sequence: 0,
                revision: 0,
            }),
        }
    }

    pub(crate) fn start(&self, transfer_id: &str) -> CoreResult<Arc<TransferControl>> {
        let control = Arc::new(TransferControl::new(transfer_id)?);
        let mut state = recover_lock(&self.state);
        if state.entries.contains_key(transfer_id) {
            return Err(CoreError::new(
                "transfer_exists",
                "同名下载任务已存在",
                false,
            ));
        }
        while state.entries.len() >= MAX_TRANSFERS {
            let oldest_terminal = state
                .entries
                .iter()
                .filter(|(_, entry)| entry.control.status().state.is_terminal())
                .min_by_key(|(_, entry)| entry.sequence)
                .map(|(id, _)| id.clone());
            let Some(oldest_terminal) = oldest_terminal else {
                return Err(CoreError::new(
                    "transfer_capacity",
                    "同时保留的下载任务过多",
                    true,
                ));
            };
            state.entries.remove(&oldest_terminal);
        }
        state.next_sequence = state.next_sequence.wrapping_add(1);
        let sequence = state.next_sequence;
        state.entries.insert(
            transfer_id.to_owned(),
            RegistryEntry {
                control: control.clone(),
                sequence,
            },
        );
        push_event(&mut state, control.status());
        Ok(control)
    }

    pub(crate) fn control(&self, transfer_id: &str) -> CoreResult<Arc<TransferControl>> {
        recover_lock(&self.state)
            .entries
            .get(transfer_id)
            .map(|entry| entry.control.clone())
            .ok_or_else(transfer_not_found)
    }

    pub(crate) fn status(&self, transfer_id: &str) -> CoreResult<TransferStatus> {
        Ok(self.control(transfer_id)?.status())
    }

    pub(crate) fn pause(&self, transfer_id: &str) -> CoreResult<TransferStatus> {
        let control = self.control(transfer_id)?;
        let status = control.request_pause();
        self.record(status.clone());
        Ok(status)
    }

    pub(crate) fn resume(&self, transfer_id: &str) -> CoreResult<TransferStatus> {
        let control = self.control(transfer_id)?;
        let status = control.resume()?;
        self.record(status.clone());
        Ok(status)
    }

    pub(crate) fn cancel(&self, transfer_id: &str) -> CoreResult<TransferStatus> {
        let control = self.control(transfer_id)?;
        let status = control.request_cancel();
        self.record(status.clone());
        Ok(status)
    }

    pub(crate) fn publish_progress(
        &self,
        transfer_id: &str,
        worker: WorkerLease,
        committed_bytes: u64,
        total_bytes: Option<u64>,
    ) -> CoreResult<bool> {
        let control = self.control(transfer_id)?;
        let updated = control.publish_progress(worker, committed_bytes, total_bytes);
        if updated {
            self.record(control.status());
        }
        Ok(updated)
    }

    pub(crate) fn finish_success(
        &self,
        transfer_id: &str,
        worker: WorkerLease,
        committed_bytes: u64,
    ) -> CoreResult<bool> {
        let control = self.control(transfer_id)?;
        let updated = control.finish_success(worker, committed_bytes);
        if updated {
            self.record(control.status());
        }
        Ok(updated)
    }

    pub(crate) fn finish_failure(
        &self,
        transfer_id: &str,
        worker: WorkerLease,
        error_code: &str,
    ) -> CoreResult<bool> {
        let control = self.control(transfer_id)?;
        let updated = control.finish_failure(worker, error_code);
        if updated {
            self.record(control.status());
        }
        Ok(updated)
    }

    pub(crate) fn record(&self, status: TransferStatus) {
        push_event(&mut recover_lock(&self.state), status);
    }

    pub(crate) fn read_events(
        &self,
        after_revision: u64,
        limit: usize,
    ) -> CoreResult<TransferEventPage> {
        if limit == 0 || limit > MAX_EVENT_READ {
            return Err(CoreError::invalid("下载事件 limit 必须为 1-256"));
        }
        let state = recover_lock(&self.state);
        let oldest = state
            .events
            .front()
            .map_or(state.revision, |event| event.revision);
        if after_revision.saturating_add(1) < oldest {
            return Err(CoreError::new(
                "event_cursor_expired",
                "下载事件游标已过期，请重新读取任务状态",
                true,
            ));
        }
        let events = state
            .events
            .iter()
            .filter(|event| event.revision > after_revision)
            .take(limit)
            .cloned()
            .collect::<Vec<_>>();
        let next_revision = events
            .last()
            .map_or(after_revision.min(state.revision), |event| event.revision);
        Ok(TransferEventPage {
            revision: state.revision,
            next_revision,
            has_more: state.revision > next_revision,
            events,
        })
    }

    pub(crate) fn forget(&self, transfer_id: &str) -> CoreResult<()> {
        let mut state = recover_lock(&self.state);
        let entry = state
            .entries
            .get(transfer_id)
            .ok_or_else(transfer_not_found)?;
        if !entry.control.status().state.is_terminal() {
            return Err(CoreError::new(
                "transfer_active",
                "运行中的下载任务不能清理",
                false,
            ));
        }
        state.entries.remove(transfer_id);
        Ok(())
    }
}

fn push_event(state: &mut RegistryState, status: TransferStatus) {
    state.revision = state.revision.wrapping_add(1).max(1);
    state.events.push_back(TransferEvent {
        revision: state.revision,
        status,
    });
    while state.events.len() > MAX_EVENTS {
        state.events.pop_front();
    }
}

fn transfer_not_found() -> CoreError {
    CoreError::new("transfer_not_found", "未找到下载任务", false)
}

fn recover_lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_registry_events_are_monotonic_batched_and_secret_free() {
        let registry = TransferRegistry::new();
        let control = registry.start("transfer-1").unwrap();
        let worker = control.begin_resolution().unwrap();
        control.begin_downloading(worker).unwrap();
        registry.record(control.status());
        registry
            .publish_progress("transfer-1", worker, 5, Some(10))
            .unwrap();
        registry.finish_success("transfer-1", worker, 10).unwrap();

        let first = registry.read_events(0, 2).unwrap();
        assert_eq!(first.events.len(), 2);
        assert!(first.has_more);
        let second = registry.read_events(first.next_revision, 256).unwrap();
        assert!(!second.events.is_empty());
        assert!(!second.has_more);
        assert!(second
            .events
            .windows(2)
            .all(|pair| pair[0].revision < pair[1].revision));
        let json = serde_json::to_string(&second).unwrap().to_ascii_lowercase();
        for forbidden in ["accesscode", "password", "directurl", "cookie", "header"] {
            assert!(!json.contains(forbidden));
        }
    }

    #[test]
    fn test_registry_control_and_forget_obey_terminal_state() {
        let registry = TransferRegistry::new();
        registry.start("transfer-2").unwrap();
        assert_eq!(
            registry.pause("transfer-2").unwrap().state,
            super::super::TransferState::Paused
        );
        assert!(registry.forget("transfer-2").is_err());
        assert_eq!(
            registry.cancel("transfer-2").unwrap().state,
            super::super::TransferState::Cancelled
        );
        registry.forget("transfer-2").unwrap();
        assert_eq!(
            registry.status("transfer-2").unwrap_err().code,
            "transfer_not_found"
        );
    }
}
