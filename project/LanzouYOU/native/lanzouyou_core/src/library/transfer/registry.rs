use std::{
    collections::HashMap,
    sync::{Arc, Mutex, MutexGuard},
};

use once_cell::sync::Lazy;

use crate::error::{CoreError, CoreResult};

use super::{TransferControl, TransferStatus};

const MAX_TRANSFERS: usize = 128;

static TRANSFERS: Lazy<TransferRegistry> = Lazy::new(TransferRegistry::new);

struct RegistryEntry {
    control: Arc<TransferControl>,
    sequence: u64,
}

struct RegistryState {
    entries: HashMap<String, RegistryEntry>,
    next_sequence: u64,
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
                next_sequence: 0,
            }),
        }
    }

    pub(crate) fn start(&self, transfer_id: &str) -> CoreResult<Arc<TransferControl>> {
        let control = Arc::new(TransferControl::new(transfer_id)?);
        let mut state = recover_lock(&self.state);
        if let Some(existing) = state.entries.get(transfer_id) {
            if existing.control.status().state.is_terminal() {
                state.entries.remove(transfer_id);
            } else {
                return Err(CoreError::new(
                    "transfer_exists",
                    "同名下载任务已存在",
                    false,
                ));
            }
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
        Ok(control)
    }

    pub(crate) fn control(&self, transfer_id: &str) -> CoreResult<Arc<TransferControl>> {
        recover_lock(&self.state)
            .entries
            .get(transfer_id)
            .map(|entry| entry.control.clone())
            .ok_or_else(transfer_not_found)
    }

    pub(crate) fn pause(&self, transfer_id: &str) -> CoreResult<TransferStatus> {
        Ok(self.control(transfer_id)?.request_pause())
    }

    pub(crate) fn resume(&self, transfer_id: &str) -> CoreResult<TransferStatus> {
        self.control(transfer_id)?.resume()
    }

    pub(crate) fn cancel(&self, transfer_id: &str) -> CoreResult<TransferStatus> {
        Ok(self.control(transfer_id)?.request_cancel())
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
        let error = match registry.control("transfer-2") {
            Ok(_) => panic!("forgotten transfer must not remain addressable"),
            Err(error) => error,
        };
        assert_eq!(error.code, "transfer_not_found");
    }
}
