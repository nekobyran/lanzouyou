#[cfg(any(target_os = "linux", target_os = "android"))]
use std::fs;

const MIB: u64 = 1024 * 1024;
const NETWORK_WORKING_SET_BYTES: u64 = 8 * MIB;
const BLOCKING_WORKING_SET_BYTES: u64 = 4 * MIB;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct DeviceCapacity {
    logical_cpus: usize,
    available_memory_bytes: Option<u64>,
}

impl DeviceCapacity {
    fn detect() -> Self {
        Self {
            logical_cpus: std::thread::available_parallelism()
                .expect("logical CPU count must be available")
                .get(),
            available_memory_bytes: available_memory_bytes(),
        }
    }

    fn cpu_network_capacity(self) -> usize {
        let logical = self.logical_cpus.max(1);
        logical.saturating_add(logical.saturating_sub(1) / 2).max(1)
    }

    fn memory_capacity(self, working_set_bytes: u64) -> usize {
        let Some(bytes) = self.available_memory_bytes else {
            return usize::MAX;
        };
        usize::try_from(bytes / working_set_bytes.max(1))
            .unwrap_or(usize::MAX)
            .max(1)
    }

    fn network_capacity(self) -> usize {
        self.cpu_network_capacity()
            .min(self.memory_capacity(NETWORK_WORKING_SET_BYTES))
            .max(1)
    }

    fn blocking_capacity(self) -> usize {
        self.cpu_network_capacity()
            .min(self.memory_capacity(BLOCKING_WORKING_SET_BYTES))
            .max(self.logical_cpus.max(1))
    }
}

pub(crate) fn device_parallelism() -> usize {
    DeviceCapacity::detect().logical_cpus
}

pub(crate) fn network_worker_capacity() -> usize {
    DeviceCapacity::detect().network_capacity()
}

pub(crate) fn network_workers(demand: usize) -> usize {
    if demand == 0 {
        return 0;
    }
    demand.min(network_worker_capacity()).max(1)
}

pub(crate) fn transfer_worker_capacity() -> usize {
    network_worker_capacity()
}

pub(crate) fn runtime_async_workers() -> usize {
    DeviceCapacity::detect().logical_cpus
}

pub(crate) fn runtime_blocking_workers() -> usize {
    DeviceCapacity::detect().blocking_capacity()
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn available_memory_bytes() -> Option<u64> {
    let raw = fs::read_to_string("/proc/meminfo").expect("/proc/meminfo must be readable");
    let line = raw
        .lines()
        .find(|line| line.starts_with("MemAvailable:"))
        .expect("/proc/meminfo must expose MemAvailable");
    let kib = line
        .split_whitespace()
        .nth(1)
        .expect("MemAvailable must contain a value")
        .parse::<u64>()
        .expect("MemAvailable must be an integer");
    Some(
        kib.checked_mul(1024)
            .expect("available memory byte count must fit u64"),
    )
}

#[cfg(target_os = "windows")]
fn available_memory_bytes() -> Option<u64> {
    use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};

    let mut status = unsafe { std::mem::zeroed::<MEMORYSTATUSEX>() };
    status.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
    let result = unsafe { GlobalMemoryStatusEx(&mut status) };
    assert_ne!(result, 0, "GlobalMemoryStatusEx must succeed");
    Some(status.ullAvailPhys)
}

#[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "android")))]
fn available_memory_bytes() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_parallelism_is_non_zero() {
        assert!(device_parallelism() > 0);
        assert!(network_worker_capacity() > 0);
        assert!(runtime_async_workers() > 0);
        assert!(runtime_blocking_workers() >= runtime_async_workers());
    }

    #[test]
    fn network_capacity_scales_with_device_and_memory() {
        let narrow = DeviceCapacity {
            logical_cpus: 2,
            available_memory_bytes: Some(64 * MIB),
        };
        let wide = DeviceCapacity {
            logical_cpus: 16,
            available_memory_bytes: Some(8 * 1024 * MIB),
        };
        assert!(wide.network_capacity() > narrow.network_capacity());

        let memory_limited = DeviceCapacity {
            logical_cpus: 32,
            available_memory_bytes: Some(NETWORK_WORKING_SET_BYTES),
        };
        assert_eq!(memory_limited.network_capacity(), 1);
    }

    #[test]
    fn demand_never_expands_device_concurrency() {
        let capacity = network_worker_capacity();
        assert_eq!(network_workers(0), 0);
        assert!(network_workers(capacity.saturating_add(1)) <= capacity);
    }
}
