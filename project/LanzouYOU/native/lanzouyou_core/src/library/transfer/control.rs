use std::sync::{Mutex, MutexGuard};

use serde::Serialize;

use crate::error::{CoreError, CoreResult};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TransferState {
    Queued,
    Resolving,
    Downloading,
    Pausing,
    Paused,
    Cancelling,
    Succeeded,
    Cancelled,
    Failed,
}

impl TransferState {
    pub(crate) fn is_terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Cancelled | Self::Failed)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TransferStatus {
    pub transfer_id: String,
    pub state: TransferState,
    pub generation: u64,
    pub revision: u64,
    pub control_epoch: u64,
    pub committed_bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct WorkerLease {
    generation: u64,
    control_epoch: u64,
}

impl WorkerLease {
    pub(crate) fn generation(self) -> u64 {
        self.generation
    }

    pub(crate) fn control_epoch(self) -> u64 {
        self.control_epoch
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum WorkerDirective {
    Continue,
    Pause,
    Cancel,
    Stale,
}

struct ControlState {
    state: TransferState,
    generation: u64,
    revision: u64,
    control_epoch: u64,
    committed_bytes: u64,
    total_bytes: Option<u64>,
    error_code: Option<String>,
}

pub(crate) struct TransferControl {
    transfer_id: String,
    inner: Mutex<ControlState>,
}

impl TransferControl {
    pub(crate) fn new(transfer_id: &str) -> CoreResult<Self> {
        validate_transfer_id(transfer_id)?;
        Ok(Self {
            transfer_id: transfer_id.to_owned(),
            inner: Mutex::new(ControlState {
                state: TransferState::Queued,
                generation: 0,
                revision: 0,
                control_epoch: 0,
                committed_bytes: 0,
                total_bytes: None,
                error_code: None,
            }),
        })
    }

    pub(crate) fn status(&self) -> TransferStatus {
        self.snapshot(&recover_lock(&self.inner))
    }

    pub(crate) fn begin_resolution(&self) -> CoreResult<WorkerLease> {
        let mut inner = recover_lock(&self.inner);
        match inner.state {
            TransferState::Queued => {
                inner.state = TransferState::Resolving;
                bump_revision(&mut inner);
                Ok(worker_lease(&inner))
            }
            TransferState::Cancelling | TransferState::Cancelled => Err(CoreError::cancelled()),
            TransferState::Pausing | TransferState::Paused => {
                Err(CoreError::new("transfer_paused", "下载已暂停", false))
            }
            _ => Err(CoreError::new(
                "transfer_state",
                "下载任务当前状态不能开始解析",
                false,
            )),
        }
    }

    pub(crate) fn begin_downloading(&self, worker: WorkerLease) -> CoreResult<bool> {
        let mut inner = recover_lock(&self.inner);
        if !lease_is_current(&inner, worker) {
            return Ok(false);
        }
        if inner.state == TransferState::Resolving {
            inner.state = TransferState::Downloading;
            bump_revision(&mut inner);
            Ok(true)
        } else {
            Ok(false)
        }
    }

    pub(crate) fn directive(&self, worker: WorkerLease) -> WorkerDirective {
        let inner = recover_lock(&self.inner);
        if worker.generation != inner.generation {
            return WorkerDirective::Stale;
        }
        if worker.control_epoch == inner.control_epoch {
            return if inner.state.is_terminal() {
                WorkerDirective::Stale
            } else {
                WorkerDirective::Continue
            };
        }
        match inner.state {
            TransferState::Pausing => WorkerDirective::Pause,
            TransferState::Cancelling | TransferState::Cancelled => WorkerDirective::Cancel,
            _ => WorkerDirective::Stale,
        }
    }

    pub(crate) fn request_pause(&self) -> TransferStatus {
        let mut inner = recover_lock(&self.inner);
        if inner.state.is_terminal()
            || matches!(inner.state, TransferState::Paused | TransferState::Pausing)
            || inner.state == TransferState::Cancelling
        {
            return self.snapshot(&inner);
        }
        inner.control_epoch = inner.control_epoch.wrapping_add(1);
        inner.state = if inner.state == TransferState::Queued {
            TransferState::Paused
        } else {
            TransferState::Pausing
        };
        bump_revision(&mut inner);
        self.snapshot(&inner)
    }

    pub(crate) fn acknowledge_paused(
        &self,
        worker: WorkerLease,
        committed_bytes: u64,
    ) -> CoreResult<bool> {
        let mut inner = recover_lock(&self.inner);
        if inner.state != TransferState::Pausing
            || worker.generation != inner.generation
            || worker.control_epoch >= inner.control_epoch
        {
            return Ok(false);
        }
        inner.committed_bytes = committed_bytes;
        inner.state = TransferState::Paused;
        bump_revision(&mut inner);
        Ok(true)
    }

    pub(crate) fn resume(&self) -> CoreResult<TransferStatus> {
        let mut inner = recover_lock(&self.inner);
        match inner.state {
            TransferState::Paused | TransferState::Pausing => {
                inner.generation = inner.generation.wrapping_add(1);
                inner.control_epoch = inner.control_epoch.wrapping_add(1);
                inner.state = TransferState::Queued;
                inner.error_code = None;
                bump_revision(&mut inner);
                Ok(self.snapshot(&inner))
            }
            TransferState::Cancelling | TransferState::Cancelled => Err(CoreError::cancelled()),
            _ if inner.state.is_terminal() => Err(CoreError::new(
                "transfer_state",
                "终态下载任务不能继续",
                false,
            )),
            _ => Ok(self.snapshot(&inner)),
        }
    }

    pub(crate) fn request_cancel(&self) -> TransferStatus {
        let mut inner = recover_lock(&self.inner);
        if inner.state.is_terminal() || inner.state == TransferState::Cancelling {
            return self.snapshot(&inner);
        }
        inner.control_epoch = inner.control_epoch.wrapping_add(1);
        inner.state = if matches!(inner.state, TransferState::Queued | TransferState::Paused) {
            TransferState::Cancelled
        } else {
            TransferState::Cancelling
        };
        bump_revision(&mut inner);
        self.snapshot(&inner)
    }

    pub(crate) fn acknowledge_cancelled(
        &self,
        worker: WorkerLease,
        committed_bytes: u64,
    ) -> CoreResult<bool> {
        let mut inner = recover_lock(&self.inner);
        if inner.state != TransferState::Cancelling
            || worker.generation != inner.generation
            || worker.control_epoch >= inner.control_epoch
        {
            return Ok(false);
        }
        inner.committed_bytes = committed_bytes;
        inner.state = TransferState::Cancelled;
        bump_revision(&mut inner);
        Ok(true)
    }

    pub(crate) fn publish_progress(
        &self,
        worker: WorkerLease,
        committed_bytes: u64,
        total_bytes: Option<u64>,
    ) -> bool {
        let mut inner = recover_lock(&self.inner);
        if !lease_is_current(&inner, worker) || inner.state != TransferState::Downloading {
            return false;
        }
        inner.committed_bytes = committed_bytes;
        inner.total_bytes = total_bytes;
        bump_revision(&mut inner);
        true
    }

    pub(crate) fn finish_success(&self, worker: WorkerLease, committed_bytes: u64) -> bool {
        let mut inner = recover_lock(&self.inner);
        if !lease_is_current(&inner, worker) || inner.state != TransferState::Downloading {
            return false;
        }
        inner.committed_bytes = committed_bytes;
        inner.total_bytes = Some(committed_bytes);
        inner.state = TransferState::Succeeded;
        inner.error_code = None;
        bump_revision(&mut inner);
        true
    }

    pub(crate) fn finish_failure(&self, worker: WorkerLease, error_code: &str) -> bool {
        let mut inner = recover_lock(&self.inner);
        if !lease_is_current(&inner, worker)
            || !matches!(
                inner.state,
                TransferState::Resolving | TransferState::Downloading
            )
        {
            return false;
        }
        inner.state = TransferState::Failed;
        inner.error_code = Some(error_code.to_owned());
        bump_revision(&mut inner);
        true
    }

    fn snapshot(&self, inner: &ControlState) -> TransferStatus {
        TransferStatus {
            transfer_id: self.transfer_id.clone(),
            state: inner.state,
            generation: inner.generation,
            revision: inner.revision,
            control_epoch: inner.control_epoch,
            committed_bytes: inner.committed_bytes,
            total_bytes: inner.total_bytes,
            error_code: inner.error_code.clone(),
        }
    }
}

fn worker_lease(inner: &ControlState) -> WorkerLease {
    WorkerLease {
        generation: inner.generation,
        control_epoch: inner.control_epoch,
    }
}

fn lease_is_current(inner: &ControlState, worker: WorkerLease) -> bool {
    worker.generation == inner.generation && worker.control_epoch == inner.control_epoch
}

fn bump_revision(inner: &mut ControlState) {
    inner.revision = inner.revision.wrapping_add(1);
}

fn validate_transfer_id(value: &str) -> CoreResult<()> {
    if value.is_empty()
        || value.len() > 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        Err(CoreError::invalid(
            "transferId 必须为 1-64 位 ASCII 字母、数字、点、下划线或连字符",
        ))
    } else {
        Ok(())
    }
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
    fn test_pause_ack_requires_worker_then_resume_increments_generation() {
        let control = TransferControl::new("task-1").unwrap();
        let worker = control.begin_resolution().unwrap();
        assert!(control.begin_downloading(worker).unwrap());

        let pausing = control.request_pause();
        assert_eq!(pausing.state, TransferState::Pausing);
        assert_eq!(control.directive(worker), WorkerDirective::Pause);
        assert!(control.acknowledge_paused(worker, 128).unwrap());
        assert_eq!(control.status().state, TransferState::Paused);

        let resumed = control.resume().unwrap();
        assert_eq!(resumed.state, TransferState::Queued);
        assert_eq!(resumed.generation, 1);
        assert_eq!(control.directive(worker), WorkerDirective::Stale);
    }

    #[test]
    fn test_cancel_wins_pause_and_stale_complete_cannot_override_terminal_state() {
        for index in 0..1_000 {
            let control = TransferControl::new(&format!("task-{index}")).unwrap();
            let worker = control.begin_resolution().unwrap();
            control.begin_downloading(worker).unwrap();
            control.request_pause();
            let cancelling = control.request_cancel();

            assert_eq!(cancelling.state, TransferState::Cancelling);
            assert_eq!(control.directive(worker), WorkerDirective::Cancel);
            assert!(!control.acknowledge_paused(worker, 1).unwrap());
            assert!(control.acknowledge_cancelled(worker, 1).unwrap());
            assert!(!control.finish_success(worker, 1));
            assert_eq!(control.status().state, TransferState::Cancelled);
        }
    }

    #[test]
    fn test_old_generation_cannot_publish_progress_or_failure() {
        let control = TransferControl::new("generation-test").unwrap();
        let old = control.begin_resolution().unwrap();
        control.begin_downloading(old).unwrap();
        control.request_pause();
        control.acknowledge_paused(old, 64).unwrap();
        control.resume().unwrap();
        let current = control.begin_resolution().unwrap();
        control.begin_downloading(current).unwrap();

        assert!(!control.publish_progress(old, 999, Some(1_000)));
        assert!(!control.finish_failure(old, "old_failure"));
        assert!(control.publish_progress(current, 96, Some(1_000)));
        assert_eq!(control.status().committed_bytes, 96);
        assert_eq!(control.status().state, TransferState::Downloading);
    }

    #[test]
    fn test_success_is_linearized_and_terminal_state_is_immutable() {
        let control = TransferControl::new("success-test").unwrap();
        let worker = control.begin_resolution().unwrap();
        control.begin_downloading(worker).unwrap();
        assert!(control.finish_success(worker, 42));
        let succeeded = control.status();

        assert_eq!(succeeded.state, TransferState::Succeeded);
        assert_eq!(succeeded.committed_bytes, 42);
        assert_eq!(control.request_cancel(), succeeded);
        assert_eq!(control.request_pause(), succeeded);
        assert!(!control.finish_failure(worker, "late"));
        assert_eq!(control.status(), succeeded);
    }

    #[test]
    fn test_transfer_id_is_strict_and_status_has_no_secret_fields() {
        assert!(TransferControl::new("../unsafe").is_err());
        let control = TransferControl::new("safe.task_1").unwrap();
        let encoded = serde_json::to_value(control.status()).unwrap();
        assert_eq!(encoded["transferId"], "safe.task_1");
        assert!(encoded.get("directUrl").is_none());
        assert!(encoded.get("accessCode").is_none());
        assert!(encoded.get("cookie").is_none());
    }
}
