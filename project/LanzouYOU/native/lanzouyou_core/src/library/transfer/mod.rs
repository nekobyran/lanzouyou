mod control;
mod entity;
mod http_range;
mod metadata;
mod registry;

pub(crate) use control::{
    TransferControl, TransferState, TransferStatus, WorkerDirective, WorkerLease,
};
pub(crate) use entity::EntityValidator;
pub(crate) use http_range::{
    inspect_payload_prefix, inspect_range_response, RangeRequest, RangeResponse,
    RangeResponseAction, RangeTransferResult,
};
pub(crate) use metadata::{TransferMetadata, TransferPaths};
pub(crate) use registry::{process_transfers, TransferEvent, TransferEventPage, TransferRegistry};

pub(crate) const DEFAULT_TRANSFER_WORKERS: usize = 6;
pub(crate) const MAX_TRANSFER_WORKERS: usize = 32;

pub(crate) fn validate_worker_limit(value: usize) -> crate::error::CoreResult<usize> {
    if value == 0 || value > MAX_TRANSFER_WORKERS {
        Err(crate::error::CoreError::invalid("下载并发必须为 1-32"))
    } else {
        Ok(value)
    }
}
