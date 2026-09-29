use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, MutexGuard,
    },
};

use once_cell::sync::Lazy;
use serde::Serialize;
use serde_json::{json, Value};

use crate::error::{CoreError, CoreResult};

pub(crate) const MAX_OPERATIONS: usize = 128;
const MAX_OPERATION_ID_BYTES: usize = 64;

static REGISTRY: Lazy<OperationRegistry> = Lazy::new(OperationRegistry::new);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum OperationKind {
    Upload,
    DirectoryUpload,
    ReplaceFile,
    Download,
    LibrarySearch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum OperationState {
    Running,
    Paused,
    Cancelling,
    Succeeded,
    Cancelled,
    Failed,
}

impl OperationState {
    pub(crate) fn is_terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Cancelled | Self::Failed)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OperationStatus {
    pub operation_id: String,
    pub kind: OperationKind,
    pub state: OperationState,
    pub completed_units: u64,
    pub total_units: u64,
    pub bytes_transferred: u64,
    pub total_bytes: u64,
    pub items_found: u64,
    pub revision: u64,
}

#[derive(Clone, Debug)]
struct OperationProgress {
    state: OperationState,
    completed_units: u64,
    total_units: u64,
    bytes_transferred: u64,
    total_bytes: u64,
    items_found: u64,
    revision: u64,
}

struct OperationEntry {
    operation_id: String,
    kind: OperationKind,
    progress: Mutex<OperationProgress>,
    cancellation_requested: AtomicBool,
    sequence: u64,
}

impl OperationEntry {
    fn status(&self) -> OperationStatus {
        let progress = recover_lock(&self.progress);
        OperationStatus {
            operation_id: self.operation_id.clone(),
            kind: self.kind,
            state: progress.state,
            completed_units: progress.completed_units,
            total_units: progress.total_units,
            bytes_transferred: progress.bytes_transferred,
            total_bytes: progress.total_bytes,
            items_found: progress.items_found,
            revision: progress.revision,
        }
    }
}

#[derive(Clone)]
pub(crate) struct OperationHandle {
    entry: Arc<OperationEntry>,
}

impl OperationHandle {
    pub(crate) fn operation_id(&self) -> &str {
        &self.entry.operation_id
    }

    pub(crate) fn status(&self) -> OperationStatus {
        self.entry.status()
    }

    pub(crate) fn check_cancelled(&self) -> CoreResult<()> {
        if self.entry.cancellation_requested.load(Ordering::Acquire) {
            Err(CoreError::cancelled())
        } else {
            Ok(())
        }
    }

    pub(crate) fn is_cancellation_requested(&self) -> bool {
        self.entry.cancellation_requested.load(Ordering::Acquire)
    }

    pub(crate) fn set_total_units(&self, total: usize) {
        let total = saturating_u64(total);
        self.update_progress(|progress| {
            if progress.total_units == total {
                false
            } else {
                progress.total_units = total;
                true
            }
        });
    }

    pub(crate) fn complete_unit(&self, items_found: usize) {
        self.update_progress(|progress| {
            progress.completed_units = progress.completed_units.saturating_add(1);
            progress.items_found = saturating_u64(items_found);
            true
        });
    }

    pub(crate) fn set_transfer_progress(&self, transferred: u64, total: u64) {
        self.update_progress(|progress| {
            if progress.bytes_transferred == transferred && progress.total_bytes == total {
                false
            } else {
                progress.bytes_transferred = transferred;
                progress.total_bytes = total;
                true
            }
        });
    }

    pub(crate) fn add_transferred_bytes(&self, bytes: usize) {
        let bytes = saturating_u64(bytes);
        if bytes != 0 {
            self.update_progress(|progress| {
                progress.bytes_transferred = progress.bytes_transferred.saturating_add(bytes);
                true
            });
        }
    }

    /// Reports whether the scheduler may admit another unit of work.
    /// Already-admitted work deliberately keeps running while paused.
    pub(crate) fn admits_new_work(&self) -> CoreResult<bool> {
        if self.is_cancellation_requested() {
            return Err(CoreError::cancelled());
        }
        match recover_lock(&self.entry.progress).state {
            OperationState::Running => Ok(true),
            OperationState::Paused => Ok(false),
            OperationState::Cancelling | OperationState::Cancelled => Err(CoreError::cancelled()),
            OperationState::Succeeded | OperationState::Failed => Ok(false),
        }
    }

    pub(crate) fn pause(&self) -> OperationStatus {
        self.transition_control(OperationState::Paused)
    }

    pub(crate) fn resume(&self) -> OperationStatus {
        self.transition_control(OperationState::Running)
    }

    pub(crate) fn request_cancel(&self) -> OperationStatus {
        // Publish the cancellation bit before waiting for the state lock so a
        // concurrent finisher cannot report success after cancellation won.
        self.entry
            .cancellation_requested
            .store(true, Ordering::Release);
        let mut progress = recover_lock(&self.entry.progress);
        if !progress.state.is_terminal() && progress.state != OperationState::Cancelling {
            progress.state = OperationState::Cancelling;
            progress.revision = progress.revision.saturating_add(1);
        }
        self.status_from_progress(&progress)
    }

    pub(crate) fn finish_success(&self) {
        self.finish(OperationState::Succeeded);
    }

    pub(crate) fn finish_cancelled(&self) {
        self.finish(OperationState::Cancelled);
    }

    pub(crate) fn finish_failed(&self) {
        self.finish(OperationState::Failed);
    }

    pub(crate) fn finish_result<T>(&self, result: &CoreResult<T>) {
        match result {
            Ok(_) => self.finish_success(),
            Err(error) if error.code == "cancelled" => self.finish_cancelled(),
            Err(_) => self.finish_failed(),
        }
    }

    fn finish(&self, state: OperationState) {
        let mut progress = recover_lock(&self.entry.progress);
        if progress.state.is_terminal() {
            return;
        }
        progress.state =
            if self.is_cancellation_requested() || progress.state == OperationState::Cancelling {
                OperationState::Cancelled
            } else {
                state
            };
        progress.revision = progress.revision.saturating_add(1);
    }

    fn transition_control(&self, requested: OperationState) -> OperationStatus {
        let mut progress = recover_lock(&self.entry.progress);
        let next = if self.is_cancellation_requested() {
            OperationState::Cancelling
        } else {
            match (progress.state, requested) {
                (OperationState::Running, OperationState::Paused) => OperationState::Paused,
                (OperationState::Paused, OperationState::Running) => OperationState::Running,
                (current, _) => current,
            }
        };
        if next != progress.state && !progress.state.is_terminal() {
            progress.state = next;
            progress.revision = progress.revision.saturating_add(1);
        }
        self.status_from_progress(&progress)
    }

    fn update_progress(&self, update: impl FnOnce(&mut OperationProgress) -> bool) {
        let mut progress = recover_lock(&self.entry.progress);
        if progress.state.is_terminal() {
            return;
        }
        if update(&mut progress) {
            progress.revision = progress.revision.saturating_add(1);
        }
    }

    fn status_from_progress(&self, progress: &OperationProgress) -> OperationStatus {
        OperationStatus {
            operation_id: self.entry.operation_id.clone(),
            kind: self.entry.kind,
            state: progress.state,
            completed_units: progress.completed_units,
            total_units: progress.total_units,
            bytes_transferred: progress.bytes_transferred,
            total_bytes: progress.total_bytes,
            items_found: progress.items_found,
            revision: progress.revision,
        }
    }
}

pub(crate) struct OperationRegistry {
    entries: Mutex<HashMap<String, Arc<OperationEntry>>>,
    next_sequence: AtomicU64,
}

impl OperationRegistry {
    fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            next_sequence: AtomicU64::new(0),
        }
    }

    fn begin(&self, operation_id: &str, kind: OperationKind) -> CoreResult<OperationHandle> {
        validate_operation_id(operation_id)?;
        let mut entries = recover_lock(&self.entries);
        if let Some(existing) = entries.get(operation_id) {
            if !recover_lock(&existing.progress).state.is_terminal() {
                return Err(CoreError::new(
                    "operation_active",
                    "同名操作仍在执行，请更换 operationId 或等待完成",
                    false,
                ));
            }
            entries.remove(operation_id);
        }
        while entries.len() >= MAX_OPERATIONS {
            let terminal = entries
                .iter()
                .filter(|(_, entry)| recover_lock(&entry.progress).state.is_terminal())
                .min_by_key(|(_, entry)| entry.sequence)
                .map(|(id, _)| id.clone());
            if let Some(id) = terminal {
                entries.remove(&id);
            } else {
                return Err(CoreError::new(
                    "operation_capacity",
                    "同时运行的可控操作过多，请等待现有操作完成",
                    true,
                ));
            }
        }
        let entry = Arc::new(OperationEntry {
            operation_id: operation_id.to_owned(),
            kind,
            progress: Mutex::new(OperationProgress {
                state: OperationState::Running,
                completed_units: 0,
                total_units: 0,
                bytes_transferred: 0,
                total_bytes: 0,
                items_found: 0,
                revision: 1,
            }),
            cancellation_requested: AtomicBool::new(false),
            sequence: self.next_sequence.fetch_add(1, Ordering::Relaxed),
        });
        entries.insert(operation_id.to_owned(), entry.clone());
        Ok(OperationHandle { entry })
    }

    fn entry(&self, operation_id: &str) -> CoreResult<OperationHandle> {
        validate_operation_id(operation_id)?;
        recover_lock(&self.entries)
            .get(operation_id)
            .cloned()
            .map(|entry| OperationHandle { entry })
            .ok_or_else(operation_not_found)
    }

    fn status(&self, operation_id: &str) -> CoreResult<OperationStatus> {
        Ok(self.entry(operation_id)?.entry.status())
    }

    fn pause(&self, operation_id: &str) -> CoreResult<OperationStatus> {
        let handle = self.entry(operation_id)?;
        Ok(handle.pause())
    }

    fn resume(&self, operation_id: &str) -> CoreResult<OperationStatus> {
        let handle = self.entry(operation_id)?;
        Ok(handle.resume())
    }

    fn cancel(&self, operation_id: &str) -> CoreResult<OperationStatus> {
        let handle = self.entry(operation_id)?;
        Ok(handle.request_cancel())
    }

    fn forget(&self, operation_id: &str) -> CoreResult<Value> {
        validate_operation_id(operation_id)?;
        let mut entries = recover_lock(&self.entries);
        let entry = entries.get(operation_id).ok_or_else(operation_not_found)?;
        if !recover_lock(&entry.progress).state.is_terminal() {
            return Err(CoreError::new(
                "operation_active",
                "运行中的操作不能清理，请先取消并等待结束",
                false,
            ));
        }
        entries.remove(operation_id);
        Ok(json!({"operationId": operation_id, "forgotten": true}))
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        recover_lock(&self.entries).len()
    }
}

pub(crate) fn begin(
    operation_id: Option<&str>,
    kind: OperationKind,
) -> CoreResult<Option<OperationHandle>> {
    operation_id
        .map(|operation_id| REGISTRY.begin(operation_id, kind))
        .transpose()
}

pub(crate) fn status(operation_id: &str) -> CoreResult<Value> {
    serde_json::to_value(REGISTRY.status(operation_id)?)
        .map_err(|_| CoreError::new("internal_error", "操作状态序列化失败", false))
}

pub(crate) fn pause(operation_id: &str) -> CoreResult<Value> {
    serde_json::to_value(REGISTRY.pause(operation_id)?)
        .map_err(|_| CoreError::new("internal_error", "操作状态序列化失败", false))
}

pub(crate) fn resume(operation_id: &str) -> CoreResult<Value> {
    serde_json::to_value(REGISTRY.resume(operation_id)?)
        .map_err(|_| CoreError::new("internal_error", "操作状态序列化失败", false))
}

pub(crate) fn cancel(operation_id: &str) -> CoreResult<Value> {
    serde_json::to_value(REGISTRY.cancel(operation_id)?)
        .map_err(|_| CoreError::new("internal_error", "操作状态序列化失败", false))
}

pub(crate) fn forget(operation_id: &str) -> CoreResult<Value> {
    REGISTRY.forget(operation_id)
}

fn validate_operation_id(value: &str) -> CoreResult<()> {
    if value.is_empty()
        || value.len() > MAX_OPERATION_ID_BYTES
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(CoreError::invalid(
            "operationId 必须为 1-64 位 ASCII 字母、数字、点、下划线或连字符",
        ));
    }
    Ok(())
}

fn operation_not_found() -> CoreError {
    CoreError::new("operation_not_found", "未找到指定操作", false)
}

fn recover_lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn saturating_u64(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_registry_rejects_unsafe_ids_and_duplicate_active_operation() {
        let registry = OperationRegistry::new();
        assert!(registry.begin("../secret", OperationKind::Upload).is_err());
        let first = registry
            .begin("upload-1", OperationKind::Upload)
            .expect("safe id should register");
        assert!(registry.begin("upload-1", OperationKind::Download).is_err());
        first.finish_success();
        assert!(registry.begin("upload-1", OperationKind::Download).is_ok());
    }

    #[test]
    fn test_status_has_fixed_non_nullable_progress_contract() {
        let registry = OperationRegistry::new();
        let operation = registry
            .begin("search-1", OperationKind::LibrarySearch)
            .unwrap();
        operation.set_total_units(3);
        operation.complete_unit(7);
        let value = serde_json::to_value(registry.status("search-1").unwrap()).unwrap();
        assert_eq!(value["operationId"], "search-1");
        assert_eq!(value["kind"], "library_search");
        assert_eq!(value["state"], "running");
        assert_eq!(value["completedUnits"], 1);
        assert_eq!(value["totalUnits"], 3);
        assert_eq!(value["bytesTransferred"], 0);
        assert_eq!(value["totalBytes"], 0);
        assert_eq!(value["itemsFound"], 7);
    }

    #[test]
    fn test_replace_file_kind_serializes_without_reusing_upload_kind() {
        let registry = OperationRegistry::new();
        let operation = registry
            .begin("replace-1", OperationKind::ReplaceFile)
            .unwrap();
        operation.set_total_units(4);
        let value = serde_json::to_value(registry.status("replace-1").unwrap()).unwrap();
        assert_eq!(value["kind"], "replace_file");
    }

    #[test]
    fn test_cancel_is_cooperative_and_terminal_entries_can_be_forgotten() {
        let registry = OperationRegistry::new();
        let operation = registry
            .begin("download-1", OperationKind::Download)
            .unwrap();
        let status = registry.cancel("download-1").unwrap();
        assert_eq!(status.state, OperationState::Cancelling);
        assert_eq!(operation.check_cancelled().unwrap_err().code, "cancelled");
        operation.finish_cancelled();
        assert_eq!(
            registry.status("download-1").unwrap().state,
            OperationState::Cancelled
        );
        assert!(registry.forget("download-1").is_ok());
        assert!(registry.status("download-1").is_err());
    }

    #[test]
    fn test_registry_never_exceeds_capacity_and_evicts_terminal_entries() {
        let registry = OperationRegistry::new();
        for index in 0..MAX_OPERATIONS {
            registry
                .begin(&format!("active-{index}"), OperationKind::Upload)
                .unwrap();
        }
        assert!(registry.begin("overflow", OperationKind::Upload).is_err());
        registry.entry("active-0").unwrap().finish_success();
        assert!(registry.begin("replacement", OperationKind::Upload).is_ok());
        assert_eq!(registry.len(), MAX_OPERATIONS);
        assert!(registry.status("active-0").is_err());
    }

    #[test]
    fn test_pause_only_blocks_new_admission_and_resume_advances_revision() {
        let registry = OperationRegistry::new();
        let operation = registry
            .begin("incremental-pause", OperationKind::LibrarySearch)
            .unwrap();
        let running = operation.status();
        assert_eq!(running.state, OperationState::Running);
        assert!(operation.admits_new_work().unwrap());

        let paused = operation.pause();
        assert_eq!(paused.state, OperationState::Paused);
        assert!(paused.revision > running.revision);
        assert!(!operation.admits_new_work().unwrap());
        operation.complete_unit(1);
        assert_eq!(operation.status().completed_units, 1);

        let resumed = operation.resume();
        assert_eq!(resumed.state, OperationState::Running);
        assert!(resumed.revision > paused.revision);
        assert!(operation.admits_new_work().unwrap());
    }

    #[test]
    fn test_cancel_has_priority_and_terminal_finish_never_regresses() {
        let registry = OperationRegistry::new();
        let operation = registry
            .begin("incremental-cancel", OperationKind::LibrarySearch)
            .unwrap();
        operation.pause();
        let cancelling = operation.request_cancel();
        assert_eq!(cancelling.state, OperationState::Cancelling);
        assert_eq!(operation.resume().state, OperationState::Cancelling);
        assert_eq!(operation.admits_new_work().unwrap_err().code, "cancelled");

        operation.finish_success();
        let cancelled = operation.status();
        assert_eq!(cancelled.state, OperationState::Cancelled);
        operation.finish_failed();
        assert_eq!(operation.status(), cancelled);
    }

    #[test]
    fn test_revision_covers_linearizable_progress_snapshot() {
        let registry = OperationRegistry::new();
        let operation = registry
            .begin("incremental-revision", OperationKind::LibrarySearch)
            .unwrap();
        let initial = operation.status();
        operation.set_total_units(606);
        let total = operation.status();
        operation.complete_unit(100);
        let completed = operation.status();

        assert_eq!(total.total_units, 606);
        assert_eq!(completed.completed_units, 1);
        assert_eq!(completed.items_found, 100);
        assert!(initial.revision < total.revision && total.revision < completed.revision);
    }

    #[test]
    fn test_cancel_bit_wins_race_with_successful_finisher() {
        let registry = OperationRegistry::new();
        let operation = registry
            .begin("incremental-linear-race", OperationKind::LibrarySearch)
            .unwrap();
        let progress_guard = recover_lock(&operation.entry.progress);
        let cancel_operation = operation.clone();
        let canceller = std::thread::spawn(move || cancel_operation.request_cancel());
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while !operation.is_cancellation_requested() {
            assert!(std::time::Instant::now() < deadline);
            std::thread::yield_now();
        }
        let finish_operation = operation.clone();
        let finisher = std::thread::spawn(move || finish_operation.finish_success());
        drop(progress_guard);

        canceller.join().unwrap();
        finisher.join().unwrap();
        assert_eq!(operation.status().state, OperationState::Cancelled);
    }
}
