//! Directory upload planning and execution.
//!
//! Stability contract:
//! - Entries Lanzou never accepts (unsafe remote names, containers that cannot be
//!   compatibility-wrapped) are skipped and reported without aborting the plan.
//! - Planning is streamed one entry batch at a time, so the entry count is not capped: a
//!   directory wider than one batch continues in the next batch.
//! - Cloud directories are created level by level, so a child directory is only created after
//!   its parent exists. Files may upload in parallel once their parent is available.
//! - Upload parallelism is derived from the device's available parallelism and the scanned
//!   workload, and admission is rate gated. No fixed concurrency number is used.
//! - Cancellation, progress and failure detail semantics stay compatible with the FFI
//!   contract consumed by the Dart client.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs,
    path::{Component, Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

use serde::Serialize;
use serde_json::Value;

use crate::{
    error::{CoreError, CoreResult},
    icon,
    model::UploadKind,
    operation::OperationHandle,
    session::SessionClient,
    transfer::DirectoryUploadedFile,
    validation,
};

/// Depth guard for the local walk. Kept as a hard limit because a cyclic local tree must never
/// turn into an unbounded walk.
pub(crate) const MAX_DIRECTORY_UPLOAD_DEPTH: usize = 64;

/// How many sibling entries one planning step materializes. This only bounds transient planner
/// memory; it is not a product limit, because the plan continues streaming afterwards. The name
/// is kept because the previous hard item cap used the same spelling and callers referenced it.
pub(crate) const MAX_DIRECTORY_UPLOAD_ITEMS: usize = 10_000;

/// Lanzou-recognized file containers. A file with one of these extensions uploads as-is; every
/// other container travels through the `.lzyou.zip` compatibility wrapper, so an unknown
/// extension is *not* an upload blocker. This list mirrors `compat::is_supported` (part of the
/// allow list used there) and only documents the direct-upload decision.
#[cfg(test)]
const LANZOU_SUPPORTED_EXTENSIONS: [&str; 66] = [
    "ppt",
    "xapk",
    "ke",
    "azw",
    "cpk",
    "gho",
    "dwg",
    "db",
    "docx",
    "deb",
    "e",
    "ttf",
    "xls",
    "bat",
    "crx",
    "rpm",
    "txf",
    "pdf",
    "apk",
    "ipa",
    "txt",
    "mobi",
    "osk",
    "dmg",
    "rp",
    "osz",
    "jar",
    "ttc",
    "z",
    "w3x",
    "xlsx",
    "cetrainer",
    "ct",
    "rar",
    "mp3",
    "pptx",
    "mobileconfig",
    "epub",
    "imazingapp",
    "doc",
    "iso",
    "img",
    "appimage",
    "7z",
    "rplib",
    "lolgezi",
    "exe",
    "azw3",
    "zip",
    "conf",
    "tar",
    "dll",
    "flac",
    "xpa",
    "lua",
    "cad",
    "hwt",
    "accdb",
    "ce",
    "xmind",
    "enc",
    "bds",
    "bdi",
    "ssf",
    "it",
    "gz",
];

/// Per-stream admission pacing. Derived from the effective parallelism, so a wider device
/// admits more streams per second while a small device stays gentle.
const BASE_START_INTERVAL_MS: u64 = 40;
const MIN_START_INTERVAL_MS: u64 = 1;

/// Average in-flight budget assumed for one parallel upload (about 1 MiB of buffers and
/// in-flight file slices per stream); used to narrow the pool for very large workloads.
const UPLOAD_IN_FLIGHT_BUDGET_BYTES: u64 = 1_048_576;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct DirectoryScanLimits {
    max_depth: usize,
    max_items: usize,
}

impl Default for DirectoryScanLimits {
    fn default() -> Self {
        Self {
            max_depth: MAX_DIRECTORY_UPLOAD_DEPTH,
            max_items: MAX_DIRECTORY_UPLOAD_ITEMS,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct PlannedEntry {
    absolute_path: PathBuf,
    relative_path: PathBuf,
    kind: PlannedEntryKind,
    bytes: u64,
    /// Modification stamp captured while the entry was planned. Uploading re-checks it so a file
    /// that changed between planning and execution is reported instead of silently uploaded.
    planned_modified: Option<std::time::SystemTime>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PlannedEntryKind {
    Directory,
    File,
}

/// Streaming directory plan.
///
/// The plan walks one directory level at a time. `current_level` is the level being emitted,
/// `pending` holds the next batch of that level, `pending_reader` continues a directory that still
/// has unread siblings, `pending_directories` holds the remaining directories of the emitted
/// level, and `pending_next_level` holds the directories discovered for the level below. A level
/// only advances once every directory of the current level was queued, so a child directory is
/// always created after its parent. Totals cover the whole planned tree and are known from the
/// pre-pass, while `max_items` bounds how many sibling entries one batch holds.
#[derive(Debug)]
struct DirectoryPlan {
    root: PathBuf,
    root_name: String,
    limits: DirectoryScanLimits,
    current_level: Option<usize>,
    /// Entries planned for the level being emitted that are waiting to be handed out.
    pending_buffer: Vec<PlannedEntry>,
    /// Directories of the emitted level that still need to be planned.
    pending_current: VecDeque<PathBuf>,
    /// Directories of the next level, discovered while the current level is emitted.
    pending_next_level: VecDeque<PathBuf>,
    total_directories: usize,
    total_files: usize,
    total_bytes: u64,
    /// Local entries that cannot be uploaded and were skipped, never planned.
    excluded_entries: usize,
}

/// Byte progress is owned by the backend: with an operation present the real client reports
/// every read through `OperationHandle::add_transferred_bytes`, which is additive and therefore
/// monotonic while several uploads run at once. The executor only seeds the planned totals.
struct DirectoryWave {
    entries: Vec<PlannedEntry>,
    has_more: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct DirectoryUploadFailure {
    relative_path: String,
    stage: &'static str,
    code: &'static str,
    message: &'static str,
    retriable: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct DirectoryUploadResult {
    state: &'static str,
    atomic: bool,
    partial_remote_retained: bool,
    root_name: String,
    remote_root_id: Option<String>,
    total_directories: usize,
    created_directories: usize,
    total_files: usize,
    processed_files: usize,
    uploaded_files: usize,
    total_bytes: u64,
    uploaded_bytes: u64,
    auto_apk_icons: bool,
    icon_bound_files: usize,
    failures: Vec<DirectoryUploadFailure>,
}

/// Paces the admission of new uploads so a wide device does not slam the endpoint with every
/// stream at the same instant. The interval is derived from the effective parallelism.
#[derive(Debug)]
struct UploadRateGate {
    interval: Duration,
    last_admission: Instant,
}

impl UploadRateGate {
    fn for_parallelism(parallelism: usize) -> Self {
        let parallelism = u64::try_from(parallelism).unwrap_or(u64::MAX).max(1);
        let interval = (BASE_START_INTERVAL_MS / parallelism).max(MIN_START_INTERVAL_MS);
        Self {
            interval: Duration::from_millis(interval),
            last_admission: Instant::now(),
        }
    }

    fn wait(&mut self) {
        let elapsed = self.last_admission.elapsed();
        if elapsed < self.interval {
            std::thread::sleep(self.interval - elapsed);
        }
        self.last_admission = Instant::now();
    }
}

/// Work queue, admission gate and stop condition shared by the upload workers of one wave.
struct WaveWorkerContext<'a> {
    queue: Mutex<VecDeque<PlannedEntry>>,
    gate: Mutex<UploadRateGate>,
    operation: Option<&'a OperationHandle>,
    max_in_flight: AtomicUsize,
}

impl<'a> WaveWorkerContext<'a> {
    fn new(
        entries: Vec<PlannedEntry>,
        operation: Option<&'a OperationHandle>,
        parallelism: usize,
    ) -> Self {
        Self {
            queue: Mutex::new(entries.into()),
            gate: Mutex::new(UploadRateGate::for_parallelism(parallelism)),
            operation,
            max_in_flight: AtomicUsize::new(0),
        }
    }

    fn record_in_flight(&self, active: usize) {
        let mut observed = self.max_in_flight.load(Ordering::Acquire);
        while active > observed {
            match self.max_in_flight.compare_exchange_weak(
                observed,
                active,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(current) => observed = current,
            }
        }
    }

    /// Whether another upload may start. Cancellation stops admission immediately, matching the
    /// previous per-item cancellation check. Pausing deliberately keeps admitting work so an
    /// already-started directory upload is not stranded; the operation reports the paused state
    /// through `OperationHandle` while its in-flight files finish.
    fn may_admit(&self) -> bool {
        match self.operation {
            None => true,
            Some(operation) => !operation.is_cancellation_requested(),
        }
    }
}

/// Bounded worker pool for one wave of files: each worker pulls the next unit from the shared
/// queue, so the pool is never wider than `parallelism` and never wider than the queued work.
fn run_parallel_wave<T, W>(
    entries: Vec<PlannedEntry>,
    context: &WaveWorkerContext<'_>,
    parallelism: usize,
    worker: W,
) -> Vec<T>
where
    T: Send,
    W: Fn(&PlannedEntry) -> T + Sync,
{
    let workers = parallelism.max(1).min(entries.len());
    if workers == 0 {
        return Vec::new();
    }
    let worker = &worker;
    std::thread::scope(|scope| {
        let handles = (0..workers)
            .map(|_| scope.spawn(move || run_worker(context, worker)))
            .collect::<Vec<_>>();
        let mut results = Vec::with_capacity(entries.len());
        for handle in handles {
            results.extend(handle.join().unwrap_or_default());
        }
        results
    })
}

fn run_worker<T>(
    context: &WaveWorkerContext<'_>,
    worker: &(impl Fn(&PlannedEntry) -> T + Sync),
) -> Vec<T> {
    let mut results = Vec::new();
    let mut active = 0_usize;
    loop {
        if !context.may_admit() {
            break;
        }
        let next = {
            let mut queue = lock_guard(&context.queue);
            queue.pop_front()
        };
        let Some(entry) = next else {
            break;
        };
        {
            let mut gate = lock_guard(&context.gate);
            gate.wait();
        }
        if !context.may_admit() {
            break;
        }
        active = active.saturating_add(1);
        context.record_in_flight(active);
        results.push(worker(&entry));
    }
    results
}

fn lock_guard<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Effective upload parallelism for one wave.
///
/// The width is derived from the device's available parallelism, the number of queued files and
/// the average payload size against a per-stream in-flight budget. No fixed worker count is baked
/// in: a single-core device stays at one stream, a wider device scales with its own cores, and a
/// workload dominated by very large payloads narrows itself instead of opening more sockets than
/// the device and network can feed.
fn directory_upload_parallelism(
    available_parallelism: usize,
    available_items: usize,
    total_bytes: u64,
) -> usize {
    let device = available_parallelism.max(1);
    let demand = available_items.min(device);
    if demand == 0 {
        return 0;
    }
    if total_bytes == 0 {
        return demand;
    }
    let device_budget =
        UPLOAD_IN_FLIGHT_BUDGET_BYTES.saturating_mul(u64::try_from(device).unwrap_or(u64::MAX));
    let average_bytes = (total_bytes / u64::try_from(available_items).unwrap_or(u64::MAX)).max(1);
    let byte_bound = usize::try_from(device_budget / average_bytes).unwrap_or(usize::MAX);
    demand.min(byte_bound.max(1))
}

trait DirectoryUploadBackend: Sync {
    fn create_folder(&self, parent_id: &str, name: &str) -> CoreResult<String>;

    #[allow(clippy::too_many_arguments)]
    fn upload_file(
        &self,
        folder_id: &str,
        path: &Path,
        compat_wrap: bool,
        kind: UploadKind,
        operation: Option<&OperationHandle>,
        planned_original_bytes: u64,
        aggregate_total_bytes: u64,
        allowed_root: &Path,
    ) -> CoreResult<DirectoryUploadedFile>;

    fn prepare_icon(&self, source_path: &Path) -> CoreResult<PathBuf>;

    fn set_icon(&self, file_id: &str, icon_path: &Path) -> CoreResult<()>;
}

fn execute_directory_plan<B: DirectoryUploadBackend>(
    backend: &B,
    cloud_parent_id: &str,
    plan: DirectoryPlan,
    compat_wrap: bool,
    kind: UploadKind,
    auto_apk_icons: bool,
    operation: Option<&OperationHandle>,
) -> CoreResult<DirectoryUploadResult> {
    execute_directory_plan_with_parallelism(
        backend,
        cloud_parent_id,
        plan,
        compat_wrap,
        kind,
        auto_apk_icons,
        operation,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
fn execute_directory_plan_with_parallelism<B: DirectoryUploadBackend>(
    backend: &B,
    cloud_parent_id: &str,
    mut plan: DirectoryPlan,
    compat_wrap: bool,
    kind: UploadKind,
    auto_apk_icons: bool,
    operation: Option<&OperationHandle>,
    parallelism_override: Option<usize>,
) -> CoreResult<DirectoryUploadResult> {
    if let Some(operation) = operation {
        operation.set_total_units(plan.total_files);
        operation.set_transfer_progress(0, plan.total_bytes);
        if operation.check_cancelled().is_err() {
            operation.finish_cancelled();
            return Ok(DirectoryUploadResult {
                state: "cancelled",
                atomic: false,
                partial_remote_retained: true,
                root_name: plan.root_name,
                remote_root_id: None,
                total_directories: plan.total_directories.saturating_add(1),
                created_directories: 0,
                total_files: plan.total_files,
                processed_files: 0,
                uploaded_files: 0,
                total_bytes: plan.total_bytes,
                uploaded_bytes: 0,
                auto_apk_icons,
                icon_bound_files: 0,
                failures: Vec::new(),
            });
        }
    }
    verify_root_unchanged(&plan.root)?;
    let root_id = backend.create_folder(cloud_parent_id, &plan.root_name)?;
    let mut result = DirectoryUploadResult {
        state: "succeeded",
        atomic: false,
        partial_remote_retained: true,
        root_name: plan.root_name.clone(),
        remote_root_id: Some(root_id.clone()),
        total_directories: plan.total_directories.saturating_add(1),
        created_directories: 1,
        total_files: plan.total_files,
        processed_files: 0,
        uploaded_files: 0,
        total_bytes: plan.total_bytes,
        uploaded_bytes: 0,
        auto_apk_icons,
        icon_bound_files: 0,
        failures: Vec::new(),
    };
    // Folders created so far: relative path -> remote id. Shared with the upload workers so a
    // file can resolve its parent without copying the whole map.
    let remote_folders = Arc::new(Mutex::new(HashMap::from([(PathBuf::new(), root_id)])));

    let mut wave = plan.take_wave()?;
    loop {
        if wave.entries.is_empty() && !wave.has_more {
            break;
        }
        if operation.is_some_and(OperationHandle::is_cancellation_requested) {
            result.state = "cancelled";
            break;
        }
        let has_more = wave.has_more;
        let collected = execute_wave(
            backend,
            &plan.root,
            wave.entries,
            compat_wrap,
            kind,
            auto_apk_icons,
            operation,
            plan.total_bytes,
            &remote_folders,
            parallelism_override,
        );
        result.created_directories = result
            .created_directories
            .saturating_add(collected.created_directories);
        result.processed_files = result
            .processed_files
            .saturating_add(collected.processed_files);
        result.uploaded_files = result
            .uploaded_files
            .saturating_add(collected.uploaded_files);
        result.uploaded_bytes = result
            .uploaded_bytes
            .saturating_add(collected.uploaded_bytes);
        result.icon_bound_files = result
            .icon_bound_files
            .saturating_add(collected.icon_bound_files);
        result.failures.extend(collected.failures);
        if collected.cancelled {
            result.state = "cancelled";
            break;
        }
        if !has_more {
            break;
        }
        wave = plan.take_wave()?;
    }
    if result.state != "cancelled" && !result.failures.is_empty() {
        result.state = "partial";
    }
    if let Some(operation) = operation {
        match result.state {
            "cancelled" => operation.finish_cancelled(),
            "partial" => operation.finish_failed(),
            _ => operation.finish_success(),
        }
    }
    Ok(result)
}

#[derive(Default)]
struct CollectedWave {
    created_directories: usize,
    processed_files: usize,
    uploaded_files: usize,
    uploaded_bytes: u64,
    icon_bound_files: usize,
    failures: Vec<DirectoryUploadFailure>,
    cancelled: bool,
}

#[allow(clippy::too_many_arguments)]
fn execute_wave<B: DirectoryUploadBackend>(
    backend: &B,
    root: &Path,
    entries: Vec<PlannedEntry>,
    compat_wrap: bool,
    kind: UploadKind,
    auto_apk_icons: bool,
    operation: Option<&OperationHandle>,
    planned_total_bytes: u64,
    remote_folders: &Arc<Mutex<HashMap<PathBuf, String>>>,
    parallelism_override: Option<usize>,
) -> CollectedWave {
    let mut collected = CollectedWave::default();
    let (directories, files): (Vec<_>, Vec<_>) = entries
        .into_iter()
        .partition(|entry| entry.kind == PlannedEntryKind::Directory);

    // Topology rule: create every directory of this level after its parent (created by an
    // earlier wave) exists, so the next wave always finds its parent mapping.
    for entry in &directories {
        if operation.is_some_and(OperationHandle::is_cancellation_requested) {
            collected.cancelled = true;
            return collected;
        }
        let parent = parent_path(&entry.relative_path);
        let parent_id = lock_guard(remote_folders).get(parent).cloned();
        let Some(parent_id) = parent_id else {
            collected.failures.push(directory_failure(
                entry,
                "create_folder",
                &parent_unavailable(),
            ));
            continue;
        };
        if let Err(error) = verify_planned_entry(root, entry) {
            collected
                .failures
                .push(directory_failure(entry, "create_folder", &error));
            continue;
        }
        let name = match entry_name(entry) {
            Ok(name) => name.to_owned(),
            Err(error) => {
                collected
                    .failures
                    .push(directory_failure(entry, "create_folder", &error));
                continue;
            }
        };
        match backend.create_folder(&parent_id, &name) {
            Ok(id) => {
                lock_guard(remote_folders).insert(entry.relative_path.clone(), id);
                collected.created_directories = collected.created_directories.saturating_add(1);
            }
            Err(error) => {
                collected
                    .failures
                    .push(directory_failure(entry, "create_folder", &error))
            }
        }
    }

    // Files wait for their parent, which either exists now or never will. A file whose parent
    // failed keeps the previous "parent_unavailable" detail instead of silently vanishing.
    let mut uploadable = Vec::new();
    for entry in files {
        if !lock_guard(remote_folders).contains_key(parent_path(&entry.relative_path)) {
            collected.processed_files = collected.processed_files.saturating_add(1);
            collected.failures.push(directory_failure(
                &entry,
                "parent_unavailable",
                &parent_unavailable(),
            ));
            if let Some(operation) = operation {
                operation.complete_unit(collected.uploaded_files);
            }
            continue;
        }
        uploadable.push(entry);
    }
    if uploadable.is_empty() {
        return collected;
    }

    let total_bytes = uploadable
        .iter()
        .fold(0_u64, |sum, entry| sum.saturating_add(entry.bytes));
    let parallelism = parallelism_override.unwrap_or_else(|| {
        directory_upload_parallelism(
            crate::parallelism::transfer_worker_capacity(),
            uploadable.len(),
            total_bytes,
        )
    });
    let context = WaveWorkerContext::new(uploadable.clone(), operation, parallelism.max(1));
    let worker = |entry: &PlannedEntry| {
        process_file(
            backend,
            root,
            remote_folders,
            entry,
            compat_wrap,
            kind,
            auto_apk_icons,
            operation,
            planned_total_bytes,
        )
    };
    let outcomes = run_parallel_wave(uploadable, &context, parallelism, worker);
    for outcome in outcomes {
        collected.processed_files = collected.processed_files.saturating_add(1);
        match outcome {
            FileOutcome::Uploaded {
                original_bytes,
                icon_bound,
                failure,
            } => {
                if let Some(failure) = failure {
                    collected.failures.push(failure);
                } else {
                    collected.uploaded_files = collected.uploaded_files.saturating_add(1);
                    collected.uploaded_bytes =
                        collected.uploaded_bytes.saturating_add(original_bytes);
                    if icon_bound {
                        collected.icon_bound_files = collected.icon_bound_files.saturating_add(1);
                    }
                }
            }
            FileOutcome::Failed(failure) => collected.failures.push(failure),
            FileOutcome::Skipped => {}
        }
        if let Some(operation) = operation {
            operation.complete_unit(collected.uploaded_files);
        }
    }
    if operation.is_some_and(OperationHandle::is_cancellation_requested) {
        collected.cancelled = true;
    }
    collected
}

#[allow(clippy::too_many_arguments)]
fn process_file<B: DirectoryUploadBackend>(
    backend: &B,
    root: &Path,
    remote_folders: &Arc<Mutex<HashMap<PathBuf, String>>>,
    entry: &PlannedEntry,
    compat_wrap: bool,
    kind: UploadKind,
    auto_apk_icons: bool,
    operation: Option<&OperationHandle>,
    planned_total_bytes: u64,
) -> FileOutcome {
    if operation.is_some_and(OperationHandle::is_cancellation_requested) {
        return FileOutcome::Skipped;
    }
    if let Err(error) = verify_planned_entry(root, entry) {
        return FileOutcome::Failed(directory_failure(entry, "upload_file", &error));
    }
    let parent_id = lock_guard(remote_folders)
        .get(parent_path(&entry.relative_path))
        .cloned();
    let Some(parent_id) = parent_id else {
        return FileOutcome::Failed(directory_failure(
            entry,
            "parent_unavailable",
            &parent_unavailable(),
        ));
    };
    let uploaded = match backend.upload_file(
        &parent_id,
        &entry.absolute_path,
        compat_wrap,
        kind,
        operation,
        entry.bytes,
        planned_total_bytes,
        root,
    ) {
        Ok(uploaded) => uploaded,
        Err(error) => {
            return FileOutcome::Failed(directory_failure(entry, "upload_file", &error));
        }
    };
    let mut outcome = FileOutcome::Uploaded {
        original_bytes: uploaded.original_bytes,
        icon_bound: false,
        failure: None,
    };
    if auto_apk_icons && is_apk(&entry.absolute_path) {
        match backend.prepare_icon(&entry.absolute_path) {
            Ok(path) => {
                let cleanup = PreparedIconCleanup::new(path);
                if operation.is_some_and(OperationHandle::is_cancellation_requested) {
                    return outcome;
                }
                match backend.set_icon(&uploaded.id, cleanup.path()) {
                    Ok(()) => {
                        if let FileOutcome::Uploaded { icon_bound, .. } = &mut outcome {
                            *icon_bound = true;
                        }
                    }
                    Err(error) if error.code == "cancelled" => {}
                    Err(error) => {
                        if let FileOutcome::Uploaded { failure, .. } = &mut outcome {
                            *failure = Some(directory_failure(entry, "set_icon", &error));
                        }
                    }
                }
            }
            Err(error) if error.code == "cancelled" => {}
            Err(error) => {
                if let FileOutcome::Uploaded { failure, .. } = &mut outcome {
                    *failure = Some(directory_failure(entry, "prepare_icon", &error));
                }
            }
        }
    }
    outcome
}

enum FileOutcome {
    Uploaded {
        original_bytes: u64,
        icon_bound: bool,
        failure: Option<DirectoryUploadFailure>,
    },
    Failed(DirectoryUploadFailure),
    Skipped,
}

fn parent_path(relative_path: &Path) -> &Path {
    relative_path.parent().unwrap_or_else(|| Path::new(""))
}

fn parent_unavailable() -> CoreError {
    CoreError::new("parent_unavailable", "父目录不可用", false)
}

impl SessionClient {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn upload_directory(
        &self,
        folder_id: &str,
        path: &str,
        compat_wrap: bool,
        kind: UploadKind,
        auto_apk_icons: bool,
        operation: Option<&OperationHandle>,
    ) -> CoreResult<Value> {
        validation::id(folder_id, "folderId")?;
        let plan = scan_directory(Path::new(path))?;
        let result = execute_directory_plan(
            self,
            folder_id,
            plan,
            compat_wrap,
            kind,
            auto_apk_icons,
            operation,
        )?;
        serde_json::to_value(result)
            .map_err(|_| CoreError::new("internal_error", "目录上传结果序列化失败", false))
    }
}

impl DirectoryUploadBackend for SessionClient {
    fn create_folder(&self, parent_id: &str, name: &str) -> CoreResult<String> {
        self.mkdir_id(parent_id, name, "")
    }

    #[allow(clippy::too_many_arguments)]
    fn upload_file(
        &self,
        folder_id: &str,
        path: &Path,
        compat_wrap: bool,
        kind: UploadKind,
        operation: Option<&OperationHandle>,
        planned_original_bytes: u64,
        aggregate_total_bytes: u64,
        allowed_root: &Path,
    ) -> CoreResult<DirectoryUploadedFile> {
        match operation {
            Some(operation) => self.upload_directory_file_with_operation(
                folder_id,
                path,
                compat_wrap,
                kind,
                operation,
                aggregate_total_bytes.saturating_sub(planned_original_bytes),
                aggregate_total_bytes,
                planned_original_bytes,
                allowed_root,
            ),
            None => {
                validate_file_for_upload(path, allowed_root, planned_original_bytes)?;
                let value = self.upload(
                    folder_id,
                    path.to_str()
                        .ok_or_else(|| CoreError::invalid("文件路径不是有效 UTF-8"))?,
                    compat_wrap,
                    kind,
                )?;
                let id = value["id"]
                    .as_str()
                    .ok_or_else(|| {
                        CoreError::new("missing_uploaded_file_id", "无法确认上传文件 ID", false)
                    })?
                    .to_owned();
                let original_bytes = value["originalBytes"]
                    .as_u64()
                    .unwrap_or(planned_original_bytes);
                let uploaded_bytes = value["uploadedBytes"].as_u64().unwrap_or(original_bytes);
                Ok(DirectoryUploadedFile {
                    id,
                    original_bytes,
                    uploaded_bytes,
                    aggregate_total_bytes: aggregate_total_bytes
                        .saturating_sub(planned_original_bytes)
                        .saturating_add(uploaded_bytes),
                })
            }
        }
    }

    fn prepare_icon(&self, source_path: &Path) -> CoreResult<PathBuf> {
        let value = icon::prepare_icon(
            source_path
                .to_str()
                .ok_or_else(|| CoreError::invalid("APK 路径不是有效 UTF-8"))?,
            None,
        )?;
        value["path"]
            .as_str()
            .map(PathBuf::from)
            .ok_or_else(|| CoreError::new("invalid_icon_result", "图标处理结果无效", false))
    }

    fn set_icon(&self, file_id: &str, icon_path: &Path) -> CoreResult<()> {
        self.set_icon(
            file_id,
            icon_path
                .to_str()
                .ok_or_else(|| CoreError::invalid("图标路径不是有效 UTF-8"))?,
        )?;
        Ok(())
    }
}

fn scan_directory(root: &Path) -> CoreResult<DirectoryPlan> {
    scan_directory_with_limits(root, DirectoryScanLimits::default())
}

fn scan_directory_with_limits(
    root: &Path,
    limits: DirectoryScanLimits,
) -> CoreResult<DirectoryPlan> {
    if !root.is_absolute()
        || root
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::CurDir))
    {
        return Err(CoreError::invalid("path 必须是无相对片段的绝对目录"));
    }
    reject_reparse_ancestors(root)?;
    let root_metadata = fs::symlink_metadata(root)?;
    if is_link_or_reparse(&root_metadata) {
        return Err(unsafe_local_path());
    }
    if !root_metadata.is_dir() {
        return Err(CoreError::invalid("path 必须指向本地目录"));
    }
    let root = fs::canonicalize(root)?;
    let root_name = root
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| CoreError::invalid("所选目录缺少可上传的名称"))?
        .to_owned();
    validate_upload_name(&root_name)?;
    let totals = count_planned_tree(&root, limits)?;
    Ok(DirectoryPlan {
        root: root.clone(),
        root_name,
        limits,
        current_level: None,
        pending_buffer: Vec::new(),
        pending_current: VecDeque::from([root]),
        pending_next_level: VecDeque::new(),
        total_directories: totals.directories,
        total_files: totals.files,
        total_bytes: totals.bytes,
        excluded_entries: totals.excluded,
    })
}

#[derive(Default)]
struct PlannedTotals {
    directories: usize,
    files: usize,
    bytes: u64,
    excluded: usize,
}

/// Counts the whole planned tree before execution so the operation exposes a stable total
/// without materializing every entry. Only counts are kept, so a tree of any size is fine.
fn count_planned_tree(root: &Path, limits: DirectoryScanLimits) -> CoreResult<PlannedTotals> {
    let mut totals = PlannedTotals::default();
    let mut stack = vec![(root.to_path_buf(), 0_usize)];
    let mut seen = HashSet::from([root.to_path_buf()]);
    while let Some((directory, depth)) = stack.pop() {
        for child in fs::read_dir(&directory)? {
            let child = child?;
            let Ok(name) = child.file_name().into_string() else {
                totals.excluded = totals.excluded.saturating_add(1);
                continue;
            };
            if validate_upload_name(&name).is_err() {
                totals.excluded = totals.excluded.saturating_add(1);
                continue;
            }
            if depth.saturating_add(1) > limits.max_depth {
                return Err(CoreError::new(
                    "directory_depth_limit",
                    format!("目录深度不能超过 {}", limits.max_depth),
                    false,
                ));
            }
            let path = child.path();
            let metadata = fs::symlink_metadata(&path)?;
            if is_link_or_reparse(&metadata) {
                return Err(unsafe_local_path());
            }
            let canonical = fs::canonicalize(&path)?;
            if !canonical.starts_with(root) {
                return Err(unsafe_local_path());
            }
            if metadata.is_dir() {
                if !seen.insert(canonical.clone()) {
                    return Err(unsafe_local_path());
                }
                totals.directories = totals.directories.saturating_add(1);
                stack.push((canonical, depth.saturating_add(1)));
            } else if metadata.is_file() {
                if skippable_file(&name).is_err() {
                    totals.excluded = totals.excluded.saturating_add(1);
                    continue;
                }
                totals.files = totals.files.saturating_add(1);
                totals.bytes = totals.bytes.saturating_add(metadata.len());
            } else {
                totals.excluded = totals.excluded.saturating_add(1);
            }
        }
    }
    Ok(totals)
}

impl DirectoryPlan {
    /// Produces the next batch of entries plus whether the plan has more work after it.
    ///
    /// One directory level is emitted at a time, so every directory entry in a batch belongs to
    /// the level currently being created and its parent was already created by a previous batch.
    /// A directory wider than one batch is drained through `pending_buffer`, so the entry count is
    /// never a plan limit; the level only advances after every directory of the current level was
    /// queued, which keeps directory creation topological.
    fn take_wave(&mut self) -> CoreResult<DirectoryWave> {
        if self.pending_buffer.is_empty() {
            self.expand_next_directory();
        }
        if self.pending_buffer.is_empty() {
            return Ok(DirectoryWave {
                entries: Vec::new(),
                has_more: false,
            });
        }
        let take = self.limits.max_items.max(1).min(self.pending_buffer.len());
        let entries = self.pending_buffer.drain(..take).collect::<Vec<_>>();
        let has_more = !self.pending_buffer.is_empty()
            || !self.pending_current.is_empty()
            || !self.pending_next_level.is_empty();
        Ok(DirectoryWave { entries, has_more })
    }

    /// Buffers the next directory of the current level, advancing the level when it is drained.
    ///
    /// Only one directory is buffered at a time, so planner memory is the width of a single
    /// directory rather than the size of the tree. The level only advances once every directory of
    /// the current level was planned, which keeps directory creation topological.
    fn expand_next_directory(&mut self) {
        loop {
            if let Some(directory) = self.pending_current.pop_front() {
                let buffer = self.expand_level(&directory);
                if buffer.is_empty() {
                    continue;
                }
                self.pending_buffer = buffer;
                return;
            }
            if self.pending_next_level.is_empty() {
                return;
            }
            self.current_level = Some(
                self.current_level
                    .map_or(1, |current| current.saturating_add(1)),
            );
            self.pending_current = std::mem::take(&mut self.pending_next_level);
        }
    }

    /// Plans one directory. Every child directory is queued for the next level, while files and
    /// directories of this level are returned as the batch rows.
    fn expand_level(&mut self, directory: &Path) -> Vec<PlannedEntry> {
        let limits = self.limits;
        let relative_directory = directory
            .strip_prefix(&self.root)
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let depth = relative_directory.components().count().saturating_add(1);
        let mut entries = Vec::new();
        let mut discovered = Vec::new();
        let reader = match fs::read_dir(directory) {
            Ok(reader) => reader,
            Err(_) => return entries,
        };
        for child in reader.flatten() {
            let Ok(name) = child.file_name().into_string() else {
                self.excluded_entries = self.excluded_entries.saturating_add(1);
                continue;
            };
            if validate_upload_name(&name).is_err() {
                self.excluded_entries = self.excluded_entries.saturating_add(1);
                continue;
            }
            if depth > limits.max_depth {
                self.excluded_entries = self.excluded_entries.saturating_add(1);
                continue;
            }
            let path = child.path();
            let Ok(metadata) = fs::symlink_metadata(&path) else {
                self.excluded_entries = self.excluded_entries.saturating_add(1);
                continue;
            };
            if is_link_or_reparse(&metadata) {
                self.excluded_entries = self.excluded_entries.saturating_add(1);
                continue;
            }
            let Ok(canonical) = fs::canonicalize(&path) else {
                self.excluded_entries = self.excluded_entries.saturating_add(1);
                continue;
            };
            if !canonical.starts_with(&self.root) {
                self.excluded_entries = self.excluded_entries.saturating_add(1);
                continue;
            }
            let relative_path = relative_directory.join(&name);
            if metadata.is_dir() {
                discovered.push(canonical.clone());
                entries.push(PlannedEntry {
                    absolute_path: canonical,
                    relative_path,
                    kind: PlannedEntryKind::Directory,
                    bytes: 0,
                    planned_modified: None,
                });
            } else if metadata.is_file() {
                if skippable_file(&name).is_err() {
                    self.excluded_entries = self.excluded_entries.saturating_add(1);
                    continue;
                }
                entries.push(PlannedEntry {
                    absolute_path: canonical,
                    relative_path,
                    kind: PlannedEntryKind::File,
                    bytes: metadata.len(),
                    planned_modified: metadata.modified().ok(),
                });
            } else {
                self.excluded_entries = self.excluded_entries.saturating_add(1);
            }
        }
        entries.sort_by(|first, second| first.relative_path.cmp(&second.relative_path));
        // A child directory is only ever queued for the level after the one that contains it.
        if depth > self.current_level.unwrap_or(0) {
            self.pending_next_level.extend(discovered);
        } else {
            self.pending_current.extend(discovered);
        }
        entries
    }
}

/// Classifies a local file before any network work.
///
/// Lanzou cannot represent an unsafe remote name (device names, control characters, trailing
/// dots/spaces, illegal characters), and `compat::prepare` rejects exactly those names. Such a
/// file can never be uploaded through any path, so the planner skips it instead of letting it
/// fail the plan. Every other container is uploadable: unknown extensions are compatibility
/// wrapped into `.lzyou.zip`.
fn skippable_file(name: &str) -> CoreResult<()> {
    if validation::safe_filename(name).is_err() {
        return Err(CoreError::new(
            "invalid_remote_name",
            "文件名不是蓝奏云可接受的安全名称",
            false,
        ));
    }
    Ok(())
}

/// Whether the container uploads directly instead of through the compatibility wrapper. Used by
/// the planner tests to model wrapper overhead; it never blocks an upload.
#[cfg(test)]
fn uploads_without_compat_wrapper(name: &str) -> bool {
    let extension = Path::new(name)
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();
    LANZOU_SUPPORTED_EXTENSIONS.contains(&extension.as_str())
}

fn validate_upload_name(name: &str) -> CoreResult<()> {
    validation::safe_filename(name)
}

fn reject_reparse_ancestors(path: &Path) -> CoreResult<()> {
    for ancestor in path.ancestors() {
        let metadata = match fs::symlink_metadata(ancestor) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        if is_link_or_reparse(&metadata) {
            return Err(unsafe_local_path());
        }
    }
    Ok(())
}

fn is_link_or_reparse(metadata: &fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if is_windows_reparse_attributes(metadata.file_attributes()) {
            return true;
        }
    }
    false
}

fn is_windows_reparse_attributes(attributes: u32) -> bool {
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;
    attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

fn unsafe_local_path() -> CoreError {
    CoreError::new(
        "unsafe_local_path",
        "目录包含链接、重解析点或越界路径，已在上传前拒绝",
        false,
    )
}

fn verify_root_unchanged(root: &Path) -> CoreResult<()> {
    reject_reparse_ancestors(root)?;
    let metadata = fs::symlink_metadata(root)?;
    if is_link_or_reparse(&metadata) || !metadata.is_dir() {
        return Err(unsafe_local_path());
    }
    if fs::canonicalize(root)? != root {
        return Err(unsafe_local_path());
    }
    Ok(())
}

fn verify_planned_entry(root: &Path, entry: &PlannedEntry) -> CoreResult<()> {
    reject_reparse_ancestors(&entry.absolute_path)?;
    let metadata = fs::symlink_metadata(&entry.absolute_path)?;
    if is_link_or_reparse(&metadata) {
        return Err(unsafe_local_path());
    }
    let canonical = fs::canonicalize(&entry.absolute_path)?;
    if !canonical.starts_with(root) {
        return Err(unsafe_local_path());
    }
    if canonical != entry.absolute_path {
        return Err(local_file_changed());
    }
    match entry.kind {
        PlannedEntryKind::Directory if !metadata.is_dir() => Err(local_file_changed()),
        PlannedEntryKind::File if !metadata.is_file() || metadata.len() != entry.bytes => {
            Err(local_file_changed())
        }
        _ => {
            if let (Some(planned), Ok(actual)) = (entry.planned_modified, metadata.modified()) {
                if planned != actual {
                    return Err(local_file_changed());
                }
            }
            Ok(())
        }
    }
}

fn validate_file_for_upload(path: &Path, root: &Path, expected_bytes: u64) -> CoreResult<()> {
    let entry = PlannedEntry {
        absolute_path: path.to_path_buf(),
        relative_path: path
            .strip_prefix(root)
            .map(Path::to_path_buf)
            .map_err(|_| unsafe_local_path())?,
        kind: PlannedEntryKind::File,
        bytes: expected_bytes,
        planned_modified: fs::symlink_metadata(path)
            .ok()
            .and_then(|metadata| metadata.modified().ok()),
    };
    verify_planned_entry(root, &entry)
}

fn local_file_changed() -> CoreError {
    CoreError::new(
        "local_file_changed",
        "本地项目在扫描后发生变化，请重新选择目录",
        false,
    )
}

fn entry_name(entry: &PlannedEntry) -> CoreResult<&str> {
    entry
        .relative_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| CoreError::invalid("目录项目名称不是有效 UTF-8"))
}

fn relative_display_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn directory_failure(
    entry: &PlannedEntry,
    stage: &'static str,
    error: &CoreError,
) -> DirectoryUploadFailure {
    let message = match stage {
        "create_folder" => "未能创建云端目录",
        "upload_file" => "未能上传该文件",
        "prepare_icon" => "未能从 APK 提取合规图标",
        "set_icon" => "文件已上传，但未能设置图标",
        "parent_unavailable" => "上级云端目录不可用，已跳过该项目",
        _ => "该项目未完成",
    };
    DirectoryUploadFailure {
        relative_path: relative_display_path(&entry.relative_path),
        stage,
        code: error.code,
        message,
        retriable: error.retriable,
    }
}

fn is_apk(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("apk"))
}

struct PreparedIconCleanup {
    path: PathBuf,
}

impl PreparedIconCleanup {
    fn new(path: PathBuf) -> Self {
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for PreparedIconCleanup {
    fn drop(&mut self) {
        cleanup_prepared_icon(&self.path);
    }
}

fn cleanup_prepared_icon(path: &Path) {
    let file_name = match path.file_name().and_then(|name| name.to_str()) {
        Some(name) if name.starts_with("prepared-") && name.ends_with(".png") => name,
        _ => return,
    };
    if file_name.len() > 255 {
        return;
    }
    let expected_root = std::env::temp_dir().join("lanzouyou_icons");
    let Ok(expected_root) = fs::canonicalize(expected_root) else {
        return;
    };
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return;
    };
    if is_link_or_reparse(&metadata) || !metadata.is_file() {
        return;
    }
    let Ok(canonical) = fs::canonicalize(path) else {
        return;
    };
    if canonical.parent() != Some(expected_root.as_path()) {
        return;
    }
    let _ = fs::remove_file(canonical);
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        sync::atomic::{AtomicU64, AtomicUsize, Ordering},
        time::Duration,
    };

    use tempfile::tempdir;

    use super::*;

    static TEST_ICON_COUNTER: AtomicU64 = AtomicU64::new(0);

    /// Test-only lock accessor that recovers a poisoned mutex instead of unwrapping: a panic in
    /// one worker must not hide the assertions of the main test body.
    fn test_lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
        mutex
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn collect_entries(root: &Path) -> Vec<PlannedEntry> {
        collect_entries_with_limits(root, DirectoryScanLimits::default()).unwrap()
    }

    fn collect_entries_with_limits(
        root: &Path,
        limits: DirectoryScanLimits,
    ) -> CoreResult<Vec<PlannedEntry>> {
        let mut plan = scan_directory_with_limits(root, limits)?;
        let mut entries = Vec::new();
        loop {
            let wave = plan.take_wave()?;
            entries.extend(wave.entries);
            if !wave.has_more {
                break;
            }
        }
        Ok(entries)
    }

    #[test]
    fn test_scan_directory_preserves_hierarchy_and_sorts_parents_first() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("软件合集");
        fs::create_dir_all(root.join("工具/网络")).unwrap();
        fs::write(root.join("根目录.txt"), b"root").unwrap();
        fs::write(root.join("工具/说明.txt"), b"docs").unwrap();
        fs::write(root.join("工具/网络/client.apk"), b"apk").unwrap();

        let plan = scan_directory(&root).unwrap();
        let rows = collect_entries(&root)
            .into_iter()
            .map(|entry| (relative_display_path(&entry.relative_path), entry.kind))
            .collect::<Vec<_>>();

        assert_eq!(plan.root_name, "软件合集");
        assert_eq!(plan.total_files, 3);
        assert_eq!(plan.total_bytes, 11);
        assert_eq!(plan.total_directories, 2);
        assert_eq!(plan.excluded_entries, 0);
        assert_eq!(
            rows,
            vec![
                ("工具".to_owned(), PlannedEntryKind::Directory),
                ("根目录.txt".to_owned(), PlannedEntryKind::File),
                ("工具/网络".to_owned(), PlannedEntryKind::Directory),
                ("工具/说明.txt".to_owned(), PlannedEntryKind::File),
                ("工具/网络/client.apk".to_owned(), PlannedEntryKind::File),
            ]
        );
    }

    #[test]
    fn test_scan_directory_rejects_relative_root_and_unsafe_remote_names() {
        assert_eq!(
            scan_directory(Path::new("relative/folder"))
                .unwrap_err()
                .code,
            "invalid_argument"
        );

        let temp = tempdir().unwrap();
        let root = temp.path().join("safe-root");
        fs::create_dir_all(&root).unwrap();
        #[cfg(not(windows))]
        {
            fs::write(root.join("name. "), b"bad").unwrap();
            // The unsafe name is skipped, and the plan still succeeds.
            let plan = scan_directory(&root).unwrap();
            assert_eq!(plan.excluded_entries, 1);
            assert_eq!(plan.total_files, 0);
        }
        #[cfg(windows)]
        {
            // Win32 normalizes trailing dots/spaces before a test fixture can
            // be created. The exact validator used by the scanner must still
            // reject the remote name before any network operation.
            assert_eq!(
                validate_upload_name("name. ").unwrap_err().code,
                "invalid_argument"
            );
        }
        assert_eq!(
            scan_directory(&root.join("missing")).unwrap_err().code,
            "io_error"
        );
    }

    #[test]
    fn test_scan_directory_enforces_depth_before_remote_work() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        fs::create_dir_all(root.join("a/b/c")).unwrap();
        assert_eq!(
            scan_directory_with_limits(
                &root,
                DirectoryScanLimits {
                    max_depth: 2,
                    max_items: 100,
                }
            )
            .unwrap_err()
            .code,
            "directory_depth_limit"
        );
    }

    #[test]
    fn test_scan_directory_rejects_symlink_or_reparse_escape() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        let outside = temp.path().join("outside.txt");
        fs::create_dir_all(&root).unwrap();
        fs::write(&outside, b"secret").unwrap();
        let link = root.join("escape.txt");

        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        #[cfg(windows)]
        if std::os::windows::fs::symlink_file(&outside, &link).is_err() {
            // Symlink creation can be disabled by local Windows policy. Other
            // scanner tests still exercise the same metadata path.
            return;
        }

        let error = scan_directory(&root).unwrap_err();
        assert_eq!(error.code, "unsafe_local_path");
    }

    #[test]
    fn test_windows_reparse_attribute_is_rejected_even_when_not_symlink() {
        assert!(is_windows_reparse_attributes(0x0400));
        assert!(is_windows_reparse_attributes(0x0420));
        assert!(!is_windows_reparse_attributes(0x0020));
    }

    #[test]
    fn test_upload_name_validation_rejects_ambiguous_and_reserved_components() {
        for value in [".", "..", "name. ", "CON", "LPT1.log", "bad\u{1}name"] {
            assert!(
                validate_upload_name(value).is_err(),
                "accepted unsafe upload component: {value:?}"
            );
        }
        assert!(validate_upload_name("合法软件.apk").is_ok());
    }

    #[test]
    fn test_unuploadable_names_are_skipped_without_failing_the_plan() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("软件合集");
        fs::create_dir_all(root.join("工具")).unwrap();
        fs::write(root.join("工具/App.APK"), b"apk").unwrap();
        fs::write(root.join("工具/用户数据.xyz"), b"wrapped").unwrap();
        fs::write(root.join("说明.txt"), b"text").unwrap();
        #[cfg(windows)]
        let expected_excluded = {
            // Win32 refuses to create a device-named file, so exercise the same classifier
            // entry point directly; the planner calls it for every entry it walks.
            assert_eq!(
                skippable_file("LPT1.txt").unwrap_err().code,
                "invalid_remote_name"
            );
            0
        };
        #[cfg(not(windows))]
        let expected_excluded = {
            fs::write(root.join("工具/LPT1.txt"), b"rejected").unwrap();
            1
        };

        let plan = scan_directory(&root).unwrap();

        assert_eq!(plan.excluded_entries, expected_excluded);
        // Unknown containers are not upload blockers: they travel through the wrapper.
        assert_eq!(plan.total_files, 3);
        let backend = FakeDirectoryBackend::default();
        let operation = test_operation("directory-skip-unsuitable-name");
        let result = execute_directory_plan(
            &backend,
            "-1",
            plan,
            true,
            UploadKind::Auto,
            false,
            Some(&operation),
        )
        .unwrap();

        // Skipping is not a per-file failure: the remaining plan still succeeds.
        assert_eq!(result.state, "succeeded");
        assert!(result.failures.is_empty());
        assert_eq!(result.processed_files, 3);
        assert_eq!(result.uploaded_files, 3);
        assert_eq!(test_lock(&backend.uploaded).len(), 3);
        assert_eq!(
            operation.status().state,
            crate::operation::OperationState::Succeeded
        );
        crate::operation::forget("directory-skip-unsuitable-name").unwrap();
    }

    #[test]
    fn test_unuploadable_classifier_matches_the_compatibility_wrapper_contract() {
        // Names the compatibility wrapper cannot represent are the only upload blockers.
        assert_eq!(
            skippable_file("LPT1.txt").unwrap_err().code,
            "invalid_remote_name"
        );
        assert_eq!(
            skippable_file("bad\u{1}name.bin").unwrap_err().code,
            "invalid_remote_name"
        );
        // Unknown containers and missing extensions are uploadable through the wrapper.
        assert!(skippable_file("用户数据.xyz").is_ok());
        assert!(skippable_file("no-extension").is_ok());
        assert!(skippable_file("合法软件.apk").is_ok());
        assert!(skippable_file("说明.TXT").is_ok());

        assert!(uploads_without_compat_wrapper("client.apk"));
        assert!(uploads_without_compat_wrapper("说明.TXT"));
        assert!(!uploads_without_compat_wrapper("用户数据.xyz"));
        assert!(!uploads_without_compat_wrapper("no-extension"));
    }

    #[test]
    fn test_wrapped_containers_upload_and_keep_progress_bounded_by_the_reported_total() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("a.xyz"), b"alpha").unwrap();
        fs::write(root.join("b.dat"), b"beta").unwrap();
        fs::write(root.join("c.apk"), b"apk").unwrap();
        let plan = scan_directory(&root).unwrap();
        let backend = FakeDirectoryBackend {
            wrap_overhead: 20,
            ..FakeDirectoryBackend::default()
        };
        let operation = test_operation("directory-compat-wrapper");

        let result = execute_directory_plan(
            &backend,
            "-1",
            plan,
            true,
            UploadKind::Auto,
            false,
            Some(&operation),
        )
        .unwrap();

        let status = operation.status();
        assert_eq!(result.state, "succeeded");
        assert_eq!(result.uploaded_files, 3);
        // `uploaded_bytes` stays on original bytes, while progress is additive wire bytes: the two
        // compatibility-wrapped containers transfer more than their local size.
        assert_eq!(result.uploaded_bytes, 12);
        assert_eq!(status.completed_units, 3);
        assert_eq!(status.bytes_transferred, 52);
        // `total_bytes` is the planned local total, so a wrapped upload may pass it. The client
        // clamps its display and never treats the extra wrapper bytes as a new file.
        assert_eq!(status.total_bytes, 12);
        crate::operation::forget("directory-compat-wrapper").unwrap();
    }

    #[test]
    fn test_directory_named_with_an_unrepresentable_name_skips_the_subtree() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(root.join("CON/sub")).unwrap();
        fs::write(root.join("CON/sub/hidden.apk"), b"apk").unwrap();
        fs::write(root.join("keep.txt"), b"keep").unwrap();

        let plan = scan_directory(&root).unwrap();
        // The unrepresentable local name is skipped, so its children lose their parent.
        assert!(plan.excluded_entries >= 1);
        assert_eq!(plan.total_files, 1);
        // Win32 cannot create a `CON` fixture, so the ordered subtree check is Unix-only.
        #[cfg(not(windows))]
        {
            let backend = FakeDirectoryBackend::default();
            let operation = test_operation("directory-unrepresentable-parent");
            let result = execute_directory_plan(
                &backend,
                "-1",
                plan,
                false,
                UploadKind::Auto,
                false,
                Some(&operation),
            )
            .unwrap();

            assert_eq!(result.state, "partial");
            assert_eq!(result.uploaded_files, 1);
            assert_eq!(result.failures.len(), 1);
            assert_eq!(result.failures[0].relative_path, "CON/sub/hidden.apk");
            assert_eq!(result.failures[0].stage, "parent_unavailable");
            assert_eq!(result.failures[0].code, "parent_unavailable");
            crate::operation::forget("directory-unrepresentable-parent").unwrap();
        }
    }

    #[test]
    fn test_entry_count_beyond_ten_thousand_is_batched_instead_of_failing() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("wide");
        fs::create_dir_all(&root).unwrap();
        let total = MAX_DIRECTORY_UPLOAD_ITEMS + 25;
        for index in 0..total {
            fs::write(root.join(format!("{index:05}.txt")), b"x").unwrap();
        }

        // The legacy hard cap used to reject this tree as `directory_item_limit`.
        let plan = scan_directory(&root).unwrap();
        assert_eq!(plan.total_files, MAX_DIRECTORY_UPLOAD_ITEMS + 25);
        let entries = collect_entries(&root);
        assert_eq!(entries.len(), total);
        assert_eq!(
            entries
                .iter()
                .filter(|entry| entry.kind == PlannedEntryKind::File)
                .count(),
            total
        );

        let backend = FakeDirectoryBackend::default();
        let operation = test_operation("directory-wide-batches");
        let result = execute_directory_plan(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            false,
            Some(&operation),
        )
        .unwrap();
        assert_eq!(result.state, "succeeded");
        assert_eq!(result.total_files, MAX_DIRECTORY_UPLOAD_ITEMS + 25);
        assert_eq!(result.processed_files, MAX_DIRECTORY_UPLOAD_ITEMS + 25);
        assert_eq!(result.uploaded_files, MAX_DIRECTORY_UPLOAD_ITEMS + 25);
        assert_eq!(
            test_lock(&backend.uploaded).len(),
            MAX_DIRECTORY_UPLOAD_ITEMS + 25
        );
        crate::operation::forget("directory-wide-batches").unwrap();
    }

    #[test]
    fn test_small_batch_limit_streams_a_wide_directory_across_many_batches() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("wide");
        fs::create_dir_all(&root).unwrap();
        for index in 0..40 {
            fs::write(root.join(format!("{index:02}.txt")), b"x").unwrap();
        }
        let limits = DirectoryScanLimits {
            max_depth: MAX_DIRECTORY_UPLOAD_DEPTH,
            max_items: 7,
        };

        let entries = collect_entries_with_limits(&root, limits).unwrap();
        assert_eq!(entries.len(), 40);

        let mut plan = scan_directory_with_limits(&root, limits).unwrap();
        let mut batches = 0_usize;
        loop {
            let wave = plan.take_wave().unwrap();
            assert!(wave.entries.len() <= 7);
            if !wave.entries.is_empty() {
                batches = batches.saturating_add(1);
            }
            if !wave.has_more {
                break;
            }
        }
        assert_eq!(batches, 6);
    }

    #[test]
    fn test_directory_upload_parallelism_is_device_and_workload_adaptive() {
        assert_eq!(directory_upload_parallelism(8, 0, 0), 0);
        assert_eq!(directory_upload_parallelism(8, 1, 1024), 1);
        // A single-core device stays at one stream instead of a fixed floor.
        assert_eq!(directory_upload_parallelism(1, 64, 64 * 1024), 1);
        // A wide workload on a wide device is allowed to use the derived device width.
        assert_eq!(directory_upload_parallelism(8, 64, 64 * 1024), 8);
        // A narrow workload gets a narrow pool.
        assert_eq!(directory_upload_parallelism(16, 5, 5 * 1024), 5);
        // The width keeps scaling with the device instead of a baked ceiling.
        assert_eq!(directory_upload_parallelism(64, 1024, 1024), 64);
        assert_eq!(directory_upload_parallelism(usize::MAX, 64, 1024), 64);
        // A workload far larger than the in-flight budget is narrowed, never rejected.
        assert_eq!(directory_upload_parallelism(16, 64, u64::MAX / 2), 1);
        // Different devices derive different widths instead of one fixed constant.
        assert_ne!(
            directory_upload_parallelism(2, 64, 64 * 1024),
            directory_upload_parallelism(12, 64, 64 * 1024)
        );
    }

    #[test]
    fn test_upload_rate_gate_paces_admission_instead_of_firing_at_once() {
        let mut gate = UploadRateGate::for_parallelism(4);
        assert!(gate.interval >= Duration::from_millis(MIN_START_INTERVAL_MS));
        assert_eq!(
            gate.interval,
            Duration::from_millis(BASE_START_INTERVAL_MS / 4)
        );
        let start = Instant::now();
        gate.wait();
        gate.wait();
        gate.wait();
        assert!(start.elapsed() >= gate.interval * 2);
    }

    #[test]
    fn test_wave_pool_uploads_in_parallel_without_exceeding_derived_concurrency() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        for index in 0..6 {
            fs::write(root.join(format!("app-{index}.apk")), b"apk").unwrap();
        }
        let plan = scan_directory(&root).unwrap();
        let backend = FakeDirectoryBackend {
            delay: Duration::from_millis(15),
            ..FakeDirectoryBackend::default()
        };
        let operation = test_operation("directory-parallel-wave");

        let result = execute_directory_plan_with_parallelism(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            false,
            Some(&operation),
            Some(4),
        )
        .unwrap();

        assert_eq!(result.state, "succeeded");
        assert_eq!(result.uploaded_files, 6);
        assert!(
            backend.max_in_flight.load(Ordering::Acquire) >= 2,
            "expected real concurrency, observed {}",
            backend.max_in_flight.load(Ordering::Acquire)
        );
        assert!(backend.max_in_flight.load(Ordering::Acquire) <= 4);
        crate::operation::forget("directory-parallel-wave").unwrap();
    }

    #[test]
    fn test_directories_keep_topological_order_while_files_run_in_parallel() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(root.join("工具/网络")).unwrap();
        fs::write(root.join("工具/a.apk"), b"a").unwrap();
        fs::write(root.join("工具/b.apk"), b"b").unwrap();
        fs::write(root.join("工具/网络/c.apk"), b"c").unwrap();
        let plan = scan_directory(&root).unwrap();
        let backend = FakeDirectoryBackend::default();
        let operation = test_operation("directory-topology-order");

        let result = execute_directory_plan_with_parallelism(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            false,
            Some(&operation),
            Some(4),
        )
        .unwrap();

        assert_eq!(result.state, "succeeded");
        let created = test_lock(&backend.created);
        assert_eq!(created.len(), 3);
        assert_eq!(created[0].0, "-1");
        assert_eq!(created[0].1, "apps");
        assert_eq!(created[1].0, created[0].2);
        assert_eq!(created[1].1, "工具");
        assert_eq!(created[2].0, created[1].2);
        assert_eq!(created[2].1, "网络");
        assert_eq!(test_lock(&backend.uploaded).len(), 3);
        crate::operation::forget("directory-topology-order").unwrap();
    }

    #[test]
    fn test_execute_directory_plan_preserves_empty_folders_and_only_icons_apks() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("软件合集");
        fs::create_dir_all(root.join("工具/空目录")).unwrap();
        fs::write(root.join("工具/App.APK"), b"apk").unwrap();
        fs::write(root.join("说明.txt"), b"text").unwrap();
        let plan = scan_directory(&root).unwrap();
        let backend = FakeDirectoryBackend::default();
        let operation = test_operation("directory-execute-success");

        let result = execute_directory_plan(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            true,
            Some(&operation),
        )
        .unwrap();

        assert_eq!(result.state, "succeeded");
        assert!(!result.atomic);
        assert!(result.partial_remote_retained);
        assert_eq!(result.total_directories, 3);
        assert_eq!(result.created_directories, 3);
        assert_eq!(result.total_files, 2);
        assert_eq!(result.processed_files, 2);
        assert_eq!(result.uploaded_files, 2);
        assert_eq!(result.icon_bound_files, 1);
        assert!(result.failures.is_empty());
        assert_eq!(test_lock(&backend.created).len(), 3);
        assert_eq!(test_lock(&backend.uploaded).len(), 2);
        assert_eq!(test_lock(&backend.prepared_icons).len(), 1);
        assert_eq!(test_lock(&backend.bound_icons).len(), 1);
        let prepared = test_lock(&backend.prepared_icons);
        assert!(!prepared[0].exists());
        drop(prepared);
        assert_eq!(
            operation.status().state,
            crate::operation::OperationState::Succeeded
        );
        crate::operation::forget("directory-execute-success").unwrap();
    }

    #[test]
    fn test_execute_directory_plan_partial_failure_retains_remote_root_and_continues() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("bad.apk"), b"bad").unwrap();
        fs::write(root.join("good.apk"), b"good").unwrap();
        let plan = scan_directory(&root).unwrap();
        let backend = FakeDirectoryBackend {
            fail_upload_name: Some("bad.apk".to_owned()),
            ..FakeDirectoryBackend::default()
        };
        let operation = test_operation("directory-execute-partial");

        let result = execute_directory_plan(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            false,
            Some(&operation),
        )
        .unwrap();

        assert_eq!(result.state, "partial");
        assert!(result.remote_root_id.is_some());
        assert_eq!(result.processed_files, 2);
        assert_eq!(result.uploaded_files, 1);
        assert_eq!(result.failures.len(), 1);
        assert_eq!(result.failures[0].relative_path, "bad.apk");
        assert_eq!(result.failures[0].stage, "upload_file");
        assert_eq!(
            operation.status().state,
            crate::operation::OperationState::Failed
        );
        crate::operation::forget("directory-execute-partial").unwrap();
    }

    #[test]
    fn test_progress_stays_monotonic_and_bounded_while_files_run_in_parallel() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        for index in 0..5 {
            fs::write(root.join(format!("app-{index}.apk")), b"apk").unwrap();
        }
        let plan = scan_directory(&root).unwrap();
        let backend = FakeDirectoryBackend {
            delay: Duration::from_millis(10),
            ..FakeDirectoryBackend::default()
        };
        let operation = test_operation("directory-progress-monotonic");

        let result = execute_directory_plan_with_parallelism(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            false,
            Some(&operation),
            Some(4),
        )
        .unwrap();

        let status = operation.status();
        assert_eq!(result.state, "succeeded");
        assert_eq!(status.total_units, 5);
        assert_eq!(status.completed_units, 5);
        assert_eq!(status.total_bytes, 15);
        assert_eq!(status.bytes_transferred, 15);
        crate::operation::forget("directory-progress-monotonic").unwrap();
    }

    #[test]
    fn test_execute_directory_plan_cancellation_stops_new_parallel_admission() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        for name in ["a.apk", "b.apk", "c.apk", "d.apk"] {
            fs::write(root.join(name), b"apk").unwrap();
        }
        let plan = scan_directory(&root).unwrap();
        let operation = test_operation("directory-execute-cancel");
        let backend = FakeDirectoryBackend {
            cancel_after_first_upload: Some(operation.clone()),
            ..FakeDirectoryBackend::default()
        };

        let result = execute_directory_plan_with_parallelism(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            false,
            Some(&operation),
            Some(2),
        )
        .unwrap();

        assert_eq!(result.state, "cancelled");
        assert!((1..=2).contains(&result.processed_files));
        assert_eq!(result.uploaded_files, result.processed_files);
        assert_eq!(test_lock(&backend.uploaded).len(), result.processed_files);
        assert_eq!(
            operation.status().state,
            crate::operation::OperationState::Cancelled
        );
        crate::operation::forget("directory-execute-cancel").unwrap();
    }

    #[test]
    fn test_paused_operation_still_finishes_its_in_flight_parallel_batch() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        for index in 0..8 {
            fs::write(root.join(format!("app-{index}.apk")), b"apk").unwrap();
        }
        let plan = scan_directory(&root).unwrap();
        let operation = test_operation("directory-execute-paused");
        operation.pause();
        let backend = FakeDirectoryBackend::default();

        let result = execute_directory_plan_with_parallelism(
            &backend,
            "-1",
            plan,
            false,
            UploadKind::Auto,
            false,
            Some(&operation),
            Some(4),
        )
        .unwrap();

        // Pausing keeps already-admitted work running, exactly like the previous sequential loop
        // which only stopped on cancellation.
        assert_eq!(result.state, "succeeded");
        assert_eq!(result.uploaded_files, 8);
        assert_eq!(result.processed_files, 8);
        assert_eq!(test_lock(&backend.uploaded).len(), 8);
        crate::operation::forget("directory-execute-paused").unwrap();
    }

    #[test]
    fn test_plan_entry_verification_rejects_content_changed_after_planning() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        let file = root.join("changed.apk");
        fs::write(&file, b"before").unwrap();
        // The planner records the size and modification stamp it planned against. `root` is
        // canonicalized because `verify_planned_entry` compares canonical local paths.
        let plan = scan_directory(&root).unwrap();
        let canonical_root = plan.root.clone();
        let entry = collect_entries(&root).into_iter().next().unwrap();
        assert_eq!(entry.bytes, 6);
        assert!(entry.planned_modified.is_some());
        verify_planned_entry(&canonical_root, &entry).unwrap();

        fs::write(&file, b"changed-after-scan").unwrap();
        assert_eq!(
            verify_planned_entry(&canonical_root, &entry)
                .unwrap_err()
                .code,
            "local_file_changed"
        );
    }

    #[test]
    fn test_prepared_icon_cleanup_is_exact_on_binding_failure() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("app.apk"), b"apk").unwrap();
        let icon_root = std::env::temp_dir().join("lanzouyou_icons");
        fs::create_dir_all(&icon_root).unwrap();
        let sibling = icon_root.join("prepared-sibling-must-stay.png");
        fs::write(&sibling, b"sibling").unwrap();
        let backend = FakeDirectoryBackend {
            fail_set_icon: true,
            ..FakeDirectoryBackend::default()
        };
        let operation = test_operation("directory-icon-failure-cleanup");

        let result = execute_directory_plan(
            &backend,
            "-1",
            scan_directory(&root).unwrap(),
            false,
            UploadKind::Auto,
            true,
            Some(&operation),
        )
        .unwrap();

        assert_eq!(result.state, "partial");
        assert_eq!(result.failures[0].stage, "set_icon");
        let prepared = test_lock(&backend.prepared_icons);
        assert!(!prepared[0].exists());
        drop(prepared);
        assert!(sibling.exists());
        fs::remove_file(sibling).unwrap();
        crate::operation::forget("directory-icon-failure-cleanup").unwrap();
    }

    #[test]
    fn test_prepared_icon_cleanup_runs_when_cancelled_after_prepare() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("apps");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("app.apk"), b"apk").unwrap();
        let operation = test_operation("directory-icon-cancel-cleanup");
        let backend = FakeDirectoryBackend {
            cancel_during_prepare: Some(operation.clone()),
            ..FakeDirectoryBackend::default()
        };

        let result = execute_directory_plan(
            &backend,
            "-1",
            scan_directory(&root).unwrap(),
            false,
            UploadKind::Auto,
            true,
            Some(&operation),
        )
        .unwrap();

        assert_eq!(result.state, "cancelled");
        let prepared = test_lock(&backend.prepared_icons);
        assert!(!prepared[0].exists());
        drop(prepared);
        assert!(test_lock(&backend.bound_icons).is_empty());
        crate::operation::forget("directory-icon-cancel-cleanup").unwrap();
    }

    #[derive(Default)]
    struct FakeDirectoryBackend {
        next_id: Mutex<u64>,
        created: Mutex<Vec<(String, String, String)>>,
        uploaded: Mutex<Vec<String>>,
        prepared_icons: Mutex<Vec<PathBuf>>,
        bound_icons: Mutex<Vec<(String, PathBuf)>>,
        max_in_flight: AtomicUsize,
        in_flight: AtomicUsize,
        delay: Duration,
        wrap_overhead: u64,
        fail_upload_name: Option<String>,
        cancel_after_first_upload: Option<OperationHandle>,
        fail_set_icon: bool,
        cancel_during_prepare: Option<OperationHandle>,
    }

    impl DirectoryUploadBackend for FakeDirectoryBackend {
        fn create_folder(&self, parent_id: &str, name: &str) -> CoreResult<String> {
            let mut next = test_lock(&self.next_id);
            *next += 1;
            let id = (100 + *next).to_string();
            drop(next);
            test_lock(&self.created).push((parent_id.to_owned(), name.to_owned(), id.clone()));
            Ok(id)
        }

        #[allow(clippy::too_many_arguments)]
        fn upload_file(
            &self,
            _folder_id: &str,
            path: &Path,
            compat_wrap: bool,
            _kind: UploadKind,
            operation: Option<&OperationHandle>,
            planned_original_bytes: u64,
            aggregate_total_bytes: u64,
            _allowed_root: &Path,
        ) -> CoreResult<DirectoryUploadedFile> {
            let active = self.in_flight.fetch_add(1, Ordering::AcqRel) + 1;
            let mut observed = self.max_in_flight.load(Ordering::Acquire);
            while active > observed {
                match self.max_in_flight.compare_exchange_weak(
                    observed,
                    active,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    Ok(_) => break,
                    Err(current) => observed = current,
                }
            }
            if !self.delay.is_zero() {
                std::thread::sleep(self.delay);
            }
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            if self.fail_upload_name.as_deref() == Some(name.as_str()) {
                self.in_flight.fetch_sub(1, Ordering::AcqRel);
                return Err(CoreError::remote("fixture upload failure", true));
            }
            test_lock(&self.uploaded).push(name.clone());
            // A wrapped container uploads as `.lzyou.zip`, which is larger than the original.
            let wrap = compat_wrap && !uploads_without_compat_wrapper(&name);
            let uploaded_bytes = if wrap {
                planned_original_bytes.saturating_add(self.wrap_overhead)
            } else {
                planned_original_bytes
            };
            if let Some(operation) = operation {
                operation
                    .add_transferred_bytes(usize::try_from(uploaded_bytes).unwrap_or(usize::MAX));
            }
            if test_lock(&self.uploaded).len() == 1 {
                if let Some(handle) = &self.cancel_after_first_upload {
                    handle.request_cancel();
                }
            }
            self.in_flight.fetch_sub(1, Ordering::AcqRel);
            Ok(DirectoryUploadedFile {
                id: format!("file-{}", test_lock(&self.uploaded).len()),
                original_bytes: planned_original_bytes,
                uploaded_bytes,
                aggregate_total_bytes,
            })
        }

        fn prepare_icon(&self, _source_path: &Path) -> CoreResult<PathBuf> {
            let root = std::env::temp_dir().join("lanzouyou_icons");
            fs::create_dir_all(&root)?;
            let path = root.join(format!(
                "prepared-directory-test-{}.png",
                TEST_ICON_COUNTER.fetch_add(1, Ordering::Relaxed)
            ));
            fs::write(&path, b"icon")?;
            test_lock(&self.prepared_icons).push(path.clone());
            if let Some(operation) = &self.cancel_during_prepare {
                operation.request_cancel();
            }
            Ok(path)
        }

        fn set_icon(&self, file_id: &str, icon_path: &Path) -> CoreResult<()> {
            if self.fail_set_icon {
                return Err(CoreError::remote("fixture icon binding failed", true));
            }
            test_lock(&self.bound_icons).push((file_id.to_owned(), icon_path.to_path_buf()));
            Ok(())
        }
    }

    fn test_operation(id: &str) -> OperationHandle {
        crate::operation::begin(Some(id), crate::operation::OperationKind::DirectoryUpload)
            .unwrap()
            .unwrap()
    }
}
