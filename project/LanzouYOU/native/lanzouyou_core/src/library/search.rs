use std::{
    collections::{HashMap, HashSet, VecDeque},
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

use once_cell::sync::Lazy;
use serde::Serialize;

#[path = "search_journal.rs"]
mod search_journal;

const MAX_SEARCH_RESULTS: usize = 50_000;
const MAX_LIBRARY_SOURCES: usize = 4_096;
const MAX_SEARCH_FOLDERS: usize = 10_000;
const MAX_DIRECTORY_PAGES: u32 = 100;
const DIRECTORY_PAGE_SIZE: usize = 50;
const MAX_GLOBAL_SEARCH_WORKERS: usize = 32;
const SEARCH_NETWORK_BUDGET: Duration = Duration::from_secs(12);
const MAX_INCREMENTAL_SEARCHES: usize = 128;

#[cfg(test)]
type SearchOneSuccess = (String, String, Vec<LibraryItem>);
#[cfg(test)]
type SearchOneError = (String, String, Vec<LibraryItem>, CoreError);
#[cfg(test)]
type SearchOneResult = Result<SearchOneSuccess, SearchOneError>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SearchPhase {
    Api,
    Directory,
}

#[derive(Clone)]
struct SearchPhaseJob {
    source_index: usize,
    source: LibrarySource,
    phase: SearchPhase,
}

struct SearchPhaseResult {
    source_index: usize,
    phase: SearchPhase,
    source_id: String,
    fallback_title: String,
    title: Option<String>,
    items: Vec<LibraryItem>,
    error: Option<CoreError>,
}

struct SourcePublicationProgress {
    title: String,
    item_keys: HashSet<String>,
    api_error: Option<CoreError>,
    directory_error: Option<CoreError>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PhaseScheduleState {
    Pending,
    Queued,
    Submitted,
    InFlight,
    Done,
}

struct SourceScheduleEntry {
    active: bool,
    activated_at: Instant,
    phases: [PhaseScheduleState; 2],
}

impl SourceScheduleEntry {
    fn new() -> Self {
        Self {
            active: false,
            activated_at: Instant::now(),
            phases: [PhaseScheduleState::Pending; 2],
        }
    }

    fn complete(&self) -> bool {
        self.phases
            .iter()
            .all(|phase| *phase == PhaseScheduleState::Done)
    }
}

struct SourceSchedule {
    entries: Vec<SourceScheduleEntry>,
    waiting: VecDeque<usize>,
    ready: VecDeque<(usize, SearchPhase)>,
    active_sources: usize,
    max_active_sources: usize,
    finished: bool,
}

impl SourceSchedule {
    fn new(source_count: usize, max_active_sources: usize) -> Self {
        let mut schedule = Self {
            entries: (0..source_count)
                .map(|_| SourceScheduleEntry::new())
                .collect(),
            waiting: (0..source_count).collect(),
            ready: VecDeque::new(),
            active_sources: 0,
            max_active_sources: max_active_sources.clamp(1, source_count.max(1)),
            finished: false,
        };
        schedule.refill_active();
        schedule
    }

    fn phase_index(phase: SearchPhase) -> usize {
        match phase {
            SearchPhase::Api => 0,
            SearchPhase::Directory => 1,
        }
    }

    fn queue_pending_phases(&mut self, source_index: usize) {
        for phase in [SearchPhase::Api, SearchPhase::Directory] {
            let phase_index = Self::phase_index(phase);
            if self.entries[source_index].phases[phase_index] == PhaseScheduleState::Pending {
                self.entries[source_index].phases[phase_index] = PhaseScheduleState::Queued;
                self.ready.push_back((source_index, phase));
            }
        }
    }

    fn refill_active(&mut self) {
        while self.active_sources < self.max_active_sources {
            let Some(source_index) = self.waiting.pop_front() else {
                break;
            };
            if self.entries[source_index].complete() || self.entries[source_index].active {
                continue;
            }
            self.entries[source_index].active = true;
            self.entries[source_index].activated_at = Instant::now();
            self.active_sources += 1;
            self.queue_pending_phases(source_index);
        }
    }

    fn take_ready_for_submission(&mut self) -> Option<(usize, SearchPhase)> {
        while let Some((source_index, phase)) = self.ready.pop_front() {
            let phase_index = Self::phase_index(phase);
            if self.entries[source_index].active
                && self.entries[source_index].phases[phase_index] == PhaseScheduleState::Queued
            {
                self.entries[source_index].phases[phase_index] = PhaseScheduleState::Submitted;
                return Some((source_index, phase));
            }
        }
        None
    }

    fn start_submitted_phase(&mut self, source_index: usize, phase: SearchPhase) -> bool {
        let Some(entry) = self.entries.get_mut(source_index) else {
            return false;
        };
        let phase_index = Self::phase_index(phase);
        if self.finished
            || !entry.active
            || entry.phases[phase_index] != PhaseScheduleState::Submitted
        {
            if entry.phases[phase_index] == PhaseScheduleState::Submitted {
                entry.phases[phase_index] = PhaseScheduleState::Pending;
            }
            return false;
        }
        entry.phases[phase_index] = PhaseScheduleState::InFlight;
        true
    }

    fn complete_phase(&mut self, source_index: usize, phase: SearchPhase) -> CoreResult<bool> {
        let Some(entry) = self.entries.get_mut(source_index) else {
            return Err(CoreError::new(
                "internal_error",
                "软件源调度索引无效",
                false,
            ));
        };
        let phase_index = Self::phase_index(phase);
        if entry.phases[phase_index] != PhaseScheduleState::InFlight {
            return Err(CoreError::new(
                "internal_error",
                "软件源调度阶段状态无效",
                false,
            ));
        }
        entry.phases[phase_index] = PhaseScheduleState::Done;
        let source_complete = entry.complete();
        if source_complete && entry.active {
            entry.active = false;
            self.active_sources = self.active_sources.saturating_sub(1);
            self.refill_active();
        }
        Ok(source_complete)
    }

    fn rotate_due(&mut self, delay: Duration, now: Instant) -> usize {
        if delay.is_zero() || self.waiting.is_empty() {
            return 0;
        }
        let due = self
            .entries
            .iter()
            .enumerate()
            .filter_map(|(index, entry)| {
                (entry.active && now.saturating_duration_since(entry.activated_at) >= delay)
                    .then_some(index)
            })
            .collect::<Vec<_>>();
        let mut rotated = 0usize;
        for source_index in due {
            if self.waiting.is_empty() {
                break;
            }
            self.ready.retain(|(index, _)| *index != source_index);
            let entry = &mut self.entries[source_index];
            if !entry.active || entry.complete() {
                continue;
            }
            entry.active = false;
            for phase in &mut entry.phases {
                if matches!(
                    phase,
                    PhaseScheduleState::Queued | PhaseScheduleState::Submitted
                ) {
                    *phase = PhaseScheduleState::Pending;
                }
            }
            self.active_sources = self.active_sources.saturating_sub(1);
            self.waiting.push_back(source_index);
            rotated += 1;
            self.refill_active();
        }
        rotated
    }

    fn next_rotation_deadline(&self, delay: Duration) -> Option<Instant> {
        (!delay.is_zero() && !self.waiting.is_empty()).then(|| {
            self.entries
                .iter()
                .filter(|entry| entry.active)
                .map(|entry| entry.activated_at + delay)
                .min()
                .unwrap_or_else(Instant::now)
        })
    }
}

type GlobalSearchTask = Box<dyn FnOnce() + Send + 'static>;

struct GlobalSearchExecutor {
    sender: std::sync::mpsc::Sender<GlobalSearchTask>,
}

impl GlobalSearchExecutor {
    fn new() -> Self {
        let (sender, receiver) = std::sync::mpsc::channel::<GlobalSearchTask>();
        let receiver = Arc::new(Mutex::new(receiver));
        for worker_index in 0..MAX_GLOBAL_SEARCH_WORKERS {
            let receiver = receiver.clone();
            thread::Builder::new()
                .name(format!("lanzou-search-{worker_index}"))
                .spawn(move || loop {
                    let task = receiver
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .recv();
                    match task {
                        Ok(task) => task(),
                        Err(_) => break,
                    }
                })
                .expect("the bounded Lanzou search worker can start");
        }
        Self { sender }
    }

    fn submit(&self, task: GlobalSearchTask) -> CoreResult<()> {
        self.sender
            .send(task)
            .map_err(|_| CoreError::new("internal_error", "全局软件源搜索执行器已停止", false))
    }
}

static GLOBAL_SEARCH_EXECUTOR: Lazy<GlobalSearchExecutor> = Lazy::new(GlobalSearchExecutor::new);

struct SharedSourceSchedule {
    state: Mutex<SourceSchedule>,
}

enum SearchPhaseMessage {
    Completed(SearchPhaseResult),
    Skipped,
}

type SearchPhaseRunner = Arc<dyn Fn(SearchPhaseJob) -> SearchPhaseResult + Send + Sync + 'static>;

fn panic_phase_result(job: &SearchPhaseJob) -> SearchPhaseResult {
    SearchPhaseResult {
        source_index: job.source_index,
        phase: job.phase,
        source_id: job.source.source_id.clone(),
        fallback_title: source_fallback_title(&job.source),
        title: None,
        items: Vec::new(),
        error: Some(CoreError::new(
            "internal_error",
            "软件源搜索线程异常退出",
            false,
        )),
    }
}

fn submit_ready_phases(
    shared: &Arc<SharedSourceSchedule>,
    sources: &Arc<Vec<LibrarySource>>,
    sender: &std::sync::mpsc::Sender<SearchPhaseMessage>,
    runner: &SearchPhaseRunner,
    operation: Option<&OperationHandle>,
    available_admissions: usize,
) -> CoreResult<usize> {
    let mut submitted = 0usize;
    while submitted < available_admissions {
        if !operation.map_or(Ok(true), OperationHandle::admits_new_work)? {
            break;
        }
        let ready = shared
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take_ready_for_submission();
        let Some((source_index, phase)) = ready else {
            break;
        };
        let source = sources
            .get(source_index)
            .cloned()
            .ok_or_else(|| CoreError::new("internal_error", "软件源调度来源索引无效", false))?;
        let job = SearchPhaseJob {
            source_index,
            source,
            phase,
        };
        let task_shared = shared.clone();
        let task_sender = sender.clone();
        let task_runner = runner.clone();
        GLOBAL_SEARCH_EXECUTOR.submit(Box::new(move || {
            let should_run = task_shared
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .start_submitted_phase(job.source_index, job.phase);
            if !should_run {
                let _ = task_sender.send(SearchPhaseMessage::Skipped);
                return;
            }
            let result = catch_unwind(AssertUnwindSafe(|| task_runner(job.clone())))
                .unwrap_or_else(|_| panic_phase_result(&job));
            let _ = task_sender.send(SearchPhaseMessage::Completed(result));
        }))?;
        submitted += 1;
    }
    Ok(submitted)
}

fn run_search_phase_jobs<O>(
    sources: &[LibrarySource],
    max_active_sources: usize,
    rotation_delay: Duration,
    operation: Option<&OperationHandle>,
    runner: SearchPhaseRunner,
    mut observe: O,
) -> CoreResult<Vec<SearchPhaseResult>>
where
    O: FnMut(&SearchPhaseResult, bool) -> CoreResult<()>,
{
    check_cancelled(operation)?;
    let result_count = sources.len().saturating_mul(2);
    let sources = Arc::new(sources.to_vec());
    let shared = Arc::new(SharedSourceSchedule {
        state: Mutex::new(SourceSchedule::new(sources.len(), max_active_sources)),
    });
    let (sender, receiver) = std::sync::mpsc::channel();
    let mut outstanding = submit_ready_phases(
        &shared,
        &sources,
        &sender,
        &runner,
        operation,
        MAX_GLOBAL_SEARCH_WORKERS,
    )?;
    let mut slots = std::iter::repeat_with(|| None)
        .take(result_count)
        .collect::<Vec<Option<SearchPhaseResult>>>();
    let mut received = 0usize;
    while received < result_count {
        if let Err(error) = check_cancelled(operation) {
            shared
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .finished = true;
            return Err(error);
        }
        let wait = shared
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .next_rotation_deadline(rotation_delay)
            .map(|deadline| {
                deadline
                    .saturating_duration_since(Instant::now())
                    .min(Duration::from_millis(20))
            })
            .unwrap_or(Duration::from_millis(20));
        match receiver.recv_timeout(wait) {
            Ok(SearchPhaseMessage::Completed(result)) => {
                outstanding = outstanding.saturating_sub(1);
                let slot_index = result
                    .source_index
                    .saturating_mul(2)
                    .saturating_add(SourceSchedule::phase_index(result.phase));
                if slot_index >= result_count || slots[slot_index].is_some() {
                    return Err(CoreError::new(
                        "internal_error",
                        "软件源搜索阶段结果顺序无效",
                        false,
                    ));
                }
                let source_complete = shared
                    .state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .complete_phase(result.source_index, result.phase)?;
                if let Err(error) = observe(&result, source_complete) {
                    shared
                        .state
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .finished = true;
                    return Err(error);
                }
                slots[slot_index] = Some(result);
                received += 1;
            }
            Ok(SearchPhaseMessage::Skipped) => {
                outstanding = outstanding.saturating_sub(1);
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                return Err(CoreError::new(
                    "internal_error",
                    "软件源搜索结果通道异常关闭",
                    false,
                ));
            }
        }
        {
            let mut schedule = shared
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            schedule.rotate_due(rotation_delay, Instant::now());
        }
        outstanding += submit_ready_phases(
            &shared,
            &sources,
            &sender,
            &runner,
            operation,
            MAX_GLOBAL_SEARCH_WORKERS.saturating_sub(outstanding),
        )?;
    }
    shared
        .state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .finished = true;
    check_cancelled(operation)?;
    slots
        .into_iter()
        .map(|result| {
            result.ok_or_else(|| CoreError::new("internal_error", "软件源搜索阶段结果缺失", false))
        })
        .collect()
}

use crate::error::{CoreError, CoreResult};
use crate::operation::{self, OperationHandle, OperationKind, OperationState, OperationStatus};

use super::{
    api::PageState,
    browse::{validate_source, Browser},
    model::{
        LibraryItem, LibrarySearchOptions, LibrarySearchResult, LibrarySource, LibrarySourceStatus,
    },
    rate_limit::RateLimiter,
    security::sanitize_access_code_error,
    session::LibraryTransport,
    url::{parse_folder_target, validate_page_url, SecurityPolicy},
};
use search_journal::{
    SearchJournal, SearchJournalAck, SearchJournalRead, SearchJournalState, SearchSourceUpdate,
    SearchStateUpdate,
};

#[derive(Clone)]
struct IncrementalSearchSession {
    operation: OperationHandle,
    publisher: Arc<IncrementalPublisher>,
    sequence: u64,
}

struct IncrementalSearchRegistry {
    sessions: Mutex<HashMap<String, Arc<IncrementalSearchSession>>>,
    next_sequence: AtomicU64,
}

impl IncrementalSearchRegistry {
    fn new() -> Self {
        Self {
            sessions: Mutex::new(HashMap::new()),
            next_sequence: AtomicU64::new(0),
        }
    }

    fn register(
        &self,
        operation: OperationHandle,
        publisher: Arc<IncrementalPublisher>,
    ) -> CoreResult<Arc<IncrementalSearchSession>> {
        let operation_id = operation.operation_id().to_owned();
        let mut sessions = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(existing) = sessions.get(&operation_id) {
            if !existing.operation.status().state.is_terminal() {
                return Err(CoreError::new(
                    "operation_active",
                    "同名增量搜索仍在执行",
                    false,
                ));
            }
            sessions.remove(&operation_id);
        }
        while sessions.len() >= MAX_INCREMENTAL_SEARCHES {
            let evicted = sessions
                .iter()
                .filter(|(_, session)| session.operation.status().state.is_terminal())
                .min_by_key(|(_, session)| session.sequence)
                .map(|(operation_id, _)| operation_id.clone());
            if let Some(operation_id) = evicted {
                sessions.remove(&operation_id);
            } else {
                return Err(CoreError::new(
                    "operation_capacity",
                    "同时运行的增量搜索过多，请等待现有搜索结束",
                    true,
                ));
            }
        }
        let session = Arc::new(IncrementalSearchSession {
            operation,
            publisher,
            sequence: self.next_sequence.fetch_add(1, Ordering::Relaxed),
        });
        sessions.insert(operation_id, session.clone());
        Ok(session)
    }

    fn session(&self, operation_id: &str) -> CoreResult<Arc<IncrementalSearchSession>> {
        self.sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(operation_id)
            .cloned()
            .ok_or_else(|| CoreError::new("operation_not_found", "未找到指定增量搜索", false))
    }

    fn remove(&self, operation_id: &str) {
        self.sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(operation_id);
    }
}

static INCREMENTAL_SEARCHES: Lazy<IncrementalSearchRegistry> =
    Lazy::new(IncrementalSearchRegistry::new);
static NEXT_SEARCH_JOURNAL_GENERATION: AtomicU64 = AtomicU64::new(1);

struct IncrementalPublisher {
    policy: SecurityPolicy,
    journal: Arc<Mutex<SearchJournal>>,
    published_keys: Mutex<HashSet<String>>,
    last_state_revision: Mutex<u64>,
    item_mapper: Option<IncrementalItemMapper>,
}

pub(crate) type IncrementalItemMapper =
    Arc<dyn Fn(LibraryItem) -> CoreResult<LibraryItem> + Send + Sync + 'static>;

impl IncrementalPublisher {
    fn new(policy: SecurityPolicy, item_mapper: Option<IncrementalItemMapper>) -> CoreResult<Self> {
        let generation = NEXT_SEARCH_JOURNAL_GENERATION.fetch_add(1, Ordering::Relaxed);
        let journal_id = format!("g{generation:016x}");
        Ok(Self {
            policy,
            journal: Arc::new(Mutex::new(SearchJournal::new(&journal_id)?)),
            published_keys: Mutex::new(HashSet::new()),
            last_state_revision: Mutex::new(0),
            item_mapper,
        })
    }

    fn publish_items(&self, items: &[LibraryItem]) -> CoreResult<()> {
        if items.is_empty() {
            return Ok(());
        }
        // Keep journal and key updates in one lock order. A failed bounded
        // append therefore never marks an item as published or creates gaps.
        let mut journal = self
            .journal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut published = self
            .published_keys
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut fresh = Vec::new();
        let mut keys = HashSet::new();
        for item in items {
            let key = search_item_key(item, &self.policy);
            if !published.contains(&key) && keys.insert(key) {
                fresh.push(match &self.item_mapper {
                    Some(mapper) => mapper(item.clone())?,
                    None => item.clone(),
                });
            }
        }
        journal.publish_items(fresh)?;
        published.extend(keys);
        Ok(())
    }

    fn publish_source(&self, source: SearchSourceUpdate) -> CoreResult<()> {
        self.journal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .publish_source(source)
    }

    fn publish_operation(
        &self,
        status: &OperationStatus,
        error: Option<&CoreError>,
    ) -> CoreResult<()> {
        let mut last_revision = self
            .last_state_revision
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if status.revision <= *last_revision {
            return Ok(());
        }
        self.journal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .publish_state(SearchStateUpdate {
                state: status.state.into(),
                operation_revision: status.revision,
                error_code: error.map(|error| error.code.to_owned()),
                error: error.map(|error| error.message.clone()),
            })?;
        *last_revision = status.revision;
        Ok(())
    }

    fn read(&self, cursor: Option<&str>, max_batches: usize) -> CoreResult<SearchJournalRead> {
        self.journal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .read(cursor, max_batches)
    }

    fn acknowledge(&self, cursor: &str) -> CoreResult<SearchJournalAck> {
        self.journal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .acknowledge(cursor)
    }

    fn latest_cursor(&self) -> String {
        self.journal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .latest_cursor()
    }

    fn acknowledged_cursor(&self) -> String {
        self.journal
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .acknowledged_cursor()
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IncrementalSearchStart {
    pub(crate) operation_id: String,
    pub(crate) cursor: String,
    pub(crate) state: SearchJournalState,
    pub(crate) revision: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IncrementalSearchControl {
    pub(crate) operation: OperationStatus,
    pub(crate) cursor: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IncrementalSearchForget {
    pub(crate) operation_id: String,
    pub(crate) forgotten: bool,
}

pub(crate) fn start_incremental_search(
    operation_id: &str,
    query: String,
    sources: Vec<LibrarySource>,
    options: LibrarySearchOptions,
    policy: SecurityPolicy,
    limiter: Arc<RateLimiter>,
    initial_items: Vec<LibraryItem>,
    item_mapper: Option<IncrementalItemMapper>,
) -> CoreResult<IncrementalSearchStart> {
    let operation = operation::begin(Some(operation_id), OperationKind::LibrarySearch)?
        .ok_or_else(|| CoreError::new("internal_error", "增量搜索操作未注册", false))?;
    let publisher = match IncrementalPublisher::new(policy.clone(), item_mapper) {
        Ok(publisher) => Arc::new(publisher),
        Err(error) => {
            operation.finish_failed();
            let _ = operation::forget(operation_id);
            return Err(error);
        }
    };
    let initial = operation.status();
    if let Err(error) = publisher.publish_operation(&initial, None) {
        operation.finish_failed();
        let _ = operation::forget(operation_id);
        return Err(error);
    }
    if let Err(error) = publisher.publish_items(&initial_items) {
        operation.finish_failed();
        let _ = publisher.publish_operation(&operation.status(), Some(&error));
        let _ = operation::forget(operation_id);
        return Err(error);
    }
    let session = match INCREMENTAL_SEARCHES.register(operation.clone(), publisher.clone()) {
        Ok(session) => session,
        Err(error) => {
            operation.finish_failed();
            let _ = operation::forget(operation_id);
            return Err(error);
        }
    };
    let worker_operation = operation.clone();
    let worker_publisher = publisher.clone();
    let spawn = thread::Builder::new()
        .name(format!("lanzou-search-coordinator-{operation_id}"))
        .spawn(move || {
            let result = search_inner(
                query,
                sources,
                options,
                policy,
                limiter,
                Some(worker_operation.clone()),
                Some(worker_publisher.clone()),
            );
            worker_operation.finish_result(&result);
            let status = worker_operation.status();
            let _ = worker_publisher.publish_operation(&status, result.as_ref().err());
        });
    if spawn.is_err() {
        INCREMENTAL_SEARCHES.remove(operation_id);
        operation.finish_failed();
        let _ = publisher.publish_operation(&operation.status(), None);
        let _ = operation::forget(operation_id);
        return Err(CoreError::new(
            "internal_error",
            "无法启动增量搜索协调线程",
            true,
        ));
    }
    Ok(IncrementalSearchStart {
        operation_id: session.operation.operation_id().to_owned(),
        cursor: publisher.acknowledged_cursor(),
        state: initial.state.into(),
        revision: initial.revision,
    })
}

pub(crate) fn read_incremental_search(
    operation_id: &str,
    after_cursor: Option<&str>,
    acknowledge_cursor: Option<&str>,
    limit: usize,
) -> CoreResult<SearchJournalRead> {
    if !(1..=8).contains(&limit) {
        return Err(CoreError::invalid("增量搜索公开读取 limit 必须为 1-8"));
    }
    let session = INCREMENTAL_SEARCHES.session(operation_id)?;
    if let Some(cursor) = acknowledge_cursor.filter(|cursor| !cursor.is_empty()) {
        session.publisher.acknowledge(cursor)?;
    }
    session.publisher.read(after_cursor, limit)
}

pub(crate) fn pause_incremental_search(operation_id: &str) -> CoreResult<IncrementalSearchControl> {
    control_incremental_search(operation_id, OperationState::Paused)
}

pub(crate) fn resume_incremental_search(
    operation_id: &str,
) -> CoreResult<IncrementalSearchControl> {
    control_incremental_search(operation_id, OperationState::Running)
}

pub(crate) fn cancel_incremental_search(
    operation_id: &str,
) -> CoreResult<IncrementalSearchControl> {
    control_incremental_search(operation_id, OperationState::Cancelling)
}

pub(crate) fn forget_incremental_search(operation_id: &str) -> CoreResult<IncrementalSearchForget> {
    let session = INCREMENTAL_SEARCHES.session(operation_id)?;
    if !session.operation.status().state.is_terminal() {
        return Err(CoreError::new(
            "operation_active",
            "运行中的增量搜索不能清理",
            false,
        ));
    }
    operation::forget(operation_id)?;
    INCREMENTAL_SEARCHES.remove(operation_id);
    Ok(IncrementalSearchForget {
        operation_id: operation_id.to_owned(),
        forgotten: true,
    })
}

fn control_incremental_search(
    operation_id: &str,
    requested: OperationState,
) -> CoreResult<IncrementalSearchControl> {
    let session = INCREMENTAL_SEARCHES.session(operation_id)?;
    let status = match requested {
        OperationState::Paused => session.operation.pause(),
        OperationState::Running => session.operation.resume(),
        OperationState::Cancelling => session.operation.request_cancel(),
        _ => {
            return Err(CoreError::new(
                "internal_error",
                "增量搜索控制状态无效",
                false,
            ))
        }
    };
    session.publisher.publish_operation(&status, None)?;
    Ok(IncrementalSearchControl {
        operation: status,
        cursor: session.publisher.latest_cursor(),
    })
}

pub(crate) fn search(
    query: String,
    sources: Vec<LibrarySource>,
    options: LibrarySearchOptions,
    policy: SecurityPolicy,
    limiter: Arc<RateLimiter>,
    operation: Option<OperationHandle>,
) -> CoreResult<LibrarySearchResult> {
    let has_access_code = sources.iter().any(|source| !source.password.is_empty());
    search_inner(query, sources, options, policy, limiter, operation, None)
        .map_err(|error| sanitize_search_source_error(error, has_access_code))
}

fn search_inner(
    query: String,
    sources: Vec<LibrarySource>,
    options: LibrarySearchOptions,
    policy: SecurityPolicy,
    limiter: Arc<RateLimiter>,
    operation: Option<OperationHandle>,
    publisher: Option<Arc<IncrementalPublisher>>,
) -> CoreResult<LibrarySearchResult> {
    if let Some(operation) = &operation {
        operation.check_cancelled()?;
    }
    let query = query.trim().to_owned();
    if query.is_empty() || query.chars().count() > 100 || query.chars().any(char::is_control) {
        return Err(CoreError::invalid("搜索关键词必须为 1-100 个有效字符"));
    }
    if sources.is_empty() || sources.len() > MAX_LIBRARY_SOURCES {
        return Err(CoreError::invalid("软件源数量必须为 1-4096 个"));
    }
    let options = options.normalized();
    let mut unique_sources = Vec::new();
    let mut source_ids = HashSet::new();
    for source in sources {
        validate_source(&source)?;
        if source_ids.insert(source.source_id.clone()) {
            unique_sources.push(source);
        }
    }
    if let Some(operation) = &operation {
        operation.set_total_units(unique_sources.len());
        operation.check_cancelled()?;
    }
    if query.chars().count() == 1 {
        let folded_query = query.to_lowercase();
        let sources = unique_sources
            .iter()
            .filter_map(|source| {
                let title = source_fallback_title(source);
                title
                    .to_lowercase()
                    .contains(&folded_query)
                    .then_some(LibrarySourceStatus {
                        source_id: source.source_id.clone(),
                        title,
                        found: 0,
                        error_code: None,
                        error: None,
                    })
            })
            .collect::<Vec<_>>();
        if let Some(publisher) = &publisher {
            for source in &sources {
                publisher.publish_source(SearchSourceUpdate {
                    source_id: source.source_id.clone(),
                    title: source.title.clone(),
                    found: source.found,
                    completed: true,
                    error_code: None,
                    error: None,
                })?;
            }
        }
        if let Some(operation) = &operation {
            for _ in &unique_sources {
                operation.check_cancelled()?;
                operation.complete_unit(sources.len());
            }
        }
        return Ok(LibrarySearchResult {
            items: Vec::new(),
            sources,
        });
    }
    let mut progress_urls = HashSet::new();
    let runner_query = query.clone();
    let runner_options = options.clone();
    let runner_policy = policy.clone();
    let runner_limiter = limiter.clone();
    let runner_operation = operation.clone();
    let runner_publisher = publisher.clone();
    let runner: SearchPhaseRunner = Arc::new(move |job| {
        search_phase(
            job,
            &runner_query,
            &runner_options,
            runner_policy.clone(),
            runner_limiter.clone(),
            runner_operation.clone(),
            runner_publisher.clone(),
        )
    });
    let mut source_progress = HashMap::<String, SourcePublicationProgress>::new();
    let phase_results = run_search_phase_jobs(
        &unique_sources,
        options.concurrency,
        Duration::from_millis(options.source_switch_delay_ms),
        operation.as_ref(),
        runner,
        |result, source_complete| {
            if let Some(error) = result
                .error
                .as_ref()
                .filter(|error| error.code == "search_backpressure")
            {
                return Err(error.clone());
            }
            if progress_urls.len() <= MAX_SEARCH_RESULTS {
                for item in &result.items {
                    progress_urls.insert(item.url.clone());
                    if progress_urls.len() > MAX_SEARCH_RESULTS {
                        break;
                    }
                }
            }
            if let Some(publisher) = &publisher {
                let progress = source_progress
                    .entry(result.source_id.clone())
                    .or_insert_with(|| SourcePublicationProgress {
                        title: result.fallback_title.clone(),
                        item_keys: HashSet::new(),
                        api_error: None,
                        directory_error: None,
                    });
                if let Some(title) = result
                    .title
                    .as_ref()
                    .filter(|title| !title.trim().is_empty())
                {
                    progress.title = title.clone();
                }
                progress.item_keys.extend(
                    result
                        .items
                        .iter()
                        .map(|item| search_item_key(item, &policy)),
                );
                match result.phase {
                    SearchPhase::Api => progress.api_error = result.error.clone(),
                    SearchPhase::Directory => progress.directory_error = result.error.clone(),
                }
                if source_complete {
                    let error = select_source_error(
                        progress.api_error.as_ref(),
                        progress.directory_error.as_ref(),
                    );
                    publisher.publish_source(SearchSourceUpdate {
                        source_id: result.source_id.clone(),
                        title: progress.title.clone(),
                        found: progress.item_keys.len(),
                        completed: true,
                        error_code: error.map(|error| error.code.to_owned()),
                        error: error.map(|error| error.message.clone()),
                    })?;
                }
            }
            if source_complete {
                if let Some(operation) = &operation {
                    operation.complete_unit(progress_urls.len());
                }
            }
            Ok(())
        },
    )?;
    check_cancelled(operation.as_ref())?;
    merge_phase_results(unique_sources, phase_results, &policy)
}

fn append_unique(
    output: &mut Vec<LibraryItem>,
    seen: &mut HashSet<String>,
    items: Vec<LibraryItem>,
    policy: &SecurityPolicy,
) -> CoreResult<usize> {
    let mut fresh = 0usize;
    for item in items {
        if seen.insert(search_item_key(&item, policy)) {
            output.push(item);
            fresh += 1;
            if output.len() > MAX_SEARCH_RESULTS {
                return Err(CoreError::remote("搜索结果超过 50000 条，停止收集", false));
            }
        }
    }
    Ok(fresh)
}

#[cfg(test)]
fn collect_search_results(
    receiver: std::sync::mpsc::Receiver<(usize, SearchOneResult)>,
    result_count: usize,
    operation: Option<&OperationHandle>,
    progress_urls: &mut HashSet<String>,
) -> CoreResult<Vec<SearchOneResult>> {
    let mut slots = std::iter::repeat_with(|| None)
        .take(result_count)
        .collect::<Vec<Option<SearchOneResult>>>();
    for _ in 0..result_count {
        let (index, result) = receiver
            .recv()
            .map_err(|_| CoreError::new("internal_error", "软件源搜索结果通道异常关闭", false))?;
        if index >= result_count || slots[index].is_some() {
            return Err(CoreError::new(
                "internal_error",
                "软件源搜索结果顺序无效",
                false,
            ));
        }
        let items = match &result {
            Ok((_, _, items)) => items,
            Err((_, _, items, _)) => items,
        };
        if progress_urls.len() <= MAX_SEARCH_RESULTS {
            for item in items {
                progress_urls.insert(item.url.clone());
                if progress_urls.len() > MAX_SEARCH_RESULTS {
                    break;
                }
            }
        }
        slots[index] = Some(result);
        if let Some(operation) = operation {
            operation.complete_unit(progress_urls.len());
        }
    }
    slots
        .into_iter()
        .map(|result| {
            result.ok_or_else(|| CoreError::new("internal_error", "软件源搜索结果缺失", false))
        })
        .collect()
}

fn source_fallback_title(source: &LibrarySource) -> String {
    if source.title.is_empty() {
        "软件库".to_owned()
    } else {
        source.title.clone()
    }
}

fn search_phase(
    job: SearchPhaseJob,
    query: &str,
    options: &LibrarySearchOptions,
    policy: SecurityPolicy,
    limiter: Arc<RateLimiter>,
    operation: Option<OperationHandle>,
    publisher: Option<Arc<IncrementalPublisher>>,
) -> SearchPhaseResult {
    let source = job.source;
    let source_id = source.source_id.clone();
    let fallback_title = source_fallback_title(&source);
    let has_access_code = !source.password.is_empty();
    let source_template = source.clone();
    let mut items = Vec::new();
    let result = (|| -> CoreResult<String> {
        check_cancelled(operation.as_ref())?;
        let mut browser = Browser::open_with_constraints(
            source,
            LibraryTransport::build(policy.clone())?,
            limiter.clone(),
            operation.as_ref(),
            Some(search_step_deadline()),
        )?;
        check_cancelled(operation.as_ref())?;
        let title = browser.source_title().to_owned();
        let mut seen = HashSet::new();
        match job.phase {
            SearchPhase::Api => search_remote_fast_path(
                &mut browser,
                query,
                options,
                &policy,
                operation.as_ref(),
                &mut items,
                &mut seen,
                publisher.as_deref(),
            )?,
            SearchPhase::Directory => search_directory_tree(
                &source_template,
                &mut browser,
                query,
                options,
                &policy,
                limiter,
                operation.as_ref(),
                &mut items,
                &mut seen,
                publisher.as_deref(),
            )?,
        }
        check_cancelled(operation.as_ref())?;
        Ok(title)
    })();
    match result {
        Ok(title) => SearchPhaseResult {
            source_index: job.source_index,
            phase: job.phase,
            source_id,
            fallback_title,
            title: Some(title),
            items,
            error: None,
        },
        Err(error) => SearchPhaseResult {
            source_index: job.source_index,
            phase: job.phase,
            source_id,
            fallback_title,
            title: None,
            items,
            error: Some(sanitize_search_source_error(error, has_access_code)),
        },
    }
}

fn merge_phase_results(
    sources: Vec<LibrarySource>,
    phase_results: Vec<SearchPhaseResult>,
    policy: &SecurityPolicy,
) -> CoreResult<LibrarySearchResult> {
    let mut phases = std::iter::repeat_with(Vec::new)
        .take(sources.len())
        .collect::<Vec<Vec<SearchPhaseResult>>>();
    for result in phase_results {
        let Some(source_phases) = phases.get_mut(result.source_index) else {
            return Err(CoreError::new(
                "internal_error",
                "软件源搜索阶段索引无效",
                false,
            ));
        };
        source_phases.push(result);
    }

    let mut output = LibrarySearchResult::default();
    let mut global_urls = HashSet::new();
    for (source_index, source) in sources.into_iter().enumerate() {
        let source_phases = &mut phases[source_index];
        if source_phases.len() != 2 {
            return Err(CoreError::new(
                "internal_error",
                "软件源搜索阶段结果缺失",
                false,
            ));
        }
        source_phases.sort_by_key(|result| match result.phase {
            SearchPhase::Api => 0_u8,
            SearchPhase::Directory => 1_u8,
        });
        let mut title = source_fallback_title(&source);
        let mut source_items = Vec::new();
        let mut source_urls = HashSet::new();
        let mut api_error = None;
        let mut directory_error = None;
        for result in source_phases.drain(..) {
            if result.source_id != source.source_id || result.fallback_title.is_empty() {
                return Err(CoreError::new(
                    "internal_error",
                    "软件源搜索阶段身份无效",
                    false,
                ));
            }
            if let Some(value) = result.title.filter(|value| !value.trim().is_empty()) {
                title = value;
            }
            for item in result.items {
                if source_urls.insert(search_item_key(&item, policy)) {
                    source_items.push(item);
                }
            }
            match result.phase {
                SearchPhase::Api => api_error = result.error,
                SearchPhase::Directory => directory_error = result.error,
            }
        }
        let error = select_source_error(api_error.as_ref(), directory_error.as_ref()).cloned();
        let fresh = append_unique(&mut output.items, &mut global_urls, source_items, policy)?;
        output.sources.push(LibrarySourceStatus {
            source_id: source.source_id,
            title,
            found: fresh,
            error_code: error.as_ref().map(|error| error.code.to_owned()),
            error: error.map(|error| error.message),
        });
    }
    Ok(output)
}

fn select_source_error<'a>(
    api_error: Option<&'a CoreError>,
    directory_error: Option<&'a CoreError>,
) -> Option<&'a CoreError> {
    ["share_cancelled", "password_required"]
        .into_iter()
        .find_map(|code| {
            api_error
                .filter(|error| error.code == code)
                .or_else(|| directory_error.filter(|error| error.code == code))
        })
        .or(directory_error)
}

fn search_step_deadline() -> Instant {
    Instant::now() + SEARCH_NETWORK_BUDGET
}

fn sanitize_search_source_error(error: CoreError, has_access_code: bool) -> CoreError {
    if error.code == "share_cancelled" {
        error
    } else {
        sanitize_access_code_error(error, has_access_code)
    }
}

// Keep cancellation, budget, and mutable result state explicit at this private
// boundary so recursive network work cannot accidentally lose one of them.
#[allow(clippy::too_many_arguments)]
fn search_remote_fast_path(
    browser: &mut Browser,
    query: &str,
    options: &LibrarySearchOptions,
    policy: &SecurityPolicy,
    operation: Option<&OperationHandle>,
    items: &mut Vec<LibraryItem>,
    seen: &mut HashSet<String>,
    publisher: Option<&IncrementalPublisher>,
) -> CoreResult<()> {
    check_cancelled(operation)?;
    if !browser
        .ensure_search_capability_with_constraints(operation, Some(search_step_deadline()))?
    {
        return Ok(());
    }
    let mut expected_total = None;
    for page in 1..=options.page_limit() {
        check_cancelled(operation)?;
        let page_state = browser.search_page_with_constraints(
            query,
            page,
            Some(search_step_deadline()),
            operation,
        )?;
        check_cancelled(operation)?;
        match page_state {
            PageState::End => break,
            PageState::Busy => continue,
            PageState::Items {
                items: page_items,
                total,
                ..
            } => {
                if let Some(total) = total {
                    expected_total = Some(total);
                }
                let before = items.len();
                for item in page_items {
                    append_matching(items, seen, item, query, policy)?;
                }
                if let Some(publisher) = publisher {
                    publisher.publish_items(&items[before..])?;
                }
                if expected_total.is_some_and(|total| seen.len() >= total) {
                    break;
                }
                if items.len() == before {
                    if expected_total.is_some_and(|total| seen.len() < total) {
                        return Err(CoreError::remote("源内搜索分页重复，结果未完整获取", false));
                    }
                    break;
                }
            }
        }
    }
    Ok(())
}

// The tree coordinator owns both traversal queues and the source-level output;
// grouping them into opaque state would make the security/budget flow harder to audit.
#[allow(clippy::too_many_arguments)]
fn search_directory_tree(
    source: &LibrarySource,
    root_browser: &mut Browser,
    query: &str,
    options: &LibrarySearchOptions,
    policy: &SecurityPolicy,
    limiter: Arc<RateLimiter>,
    operation: Option<&OperationHandle>,
    items: &mut Vec<LibraryItem>,
    seen: &mut HashSet<String>,
    publisher: Option<&IncrementalPublisher>,
) -> CoreResult<()> {
    let mut folders = VecDeque::new();
    let mut folder_keys = HashSet::new();
    if let Some(key) = search_folder_key(&source.share_url, policy) {
        folder_keys.insert(key);
    }
    scan_directory(
        root_browser,
        query,
        options,
        policy,
        operation,
        items,
        seen,
        &mut folders,
        &mut folder_keys,
        publisher,
    )?;

    let mut scanned_folders = 1usize;
    let mut first_child_error = None;
    while let Some(folder) = folders.pop_front() {
        check_cancelled(operation)?;
        scanned_folders += 1;
        if scanned_folders > MAX_SEARCH_FOLDERS {
            return Err(CoreError::remote("目录数量超过 10000 个，停止搜索", false));
        }
        let mut nested_source = source.clone();
        nested_source.share_url = folder.url;
        let nested_result = LibraryTransport::build(policy.clone()).and_then(|transport| {
            Browser::open_with_constraints(
                nested_source,
                transport,
                limiter.clone(),
                operation,
                Some(search_step_deadline()),
            )
        });
        check_cancelled(operation)?;
        let mut nested_browser = match nested_result {
            Ok(browser) => browser,
            Err(error) => {
                first_child_error.get_or_insert(error);
                continue;
            }
        };
        if let Err(error) = scan_directory(
            &mut nested_browser,
            query,
            options,
            policy,
            operation,
            items,
            seen,
            &mut folders,
            &mut folder_keys,
            publisher,
        ) {
            check_cancelled(operation)?;
            first_child_error.get_or_insert(error);
        }
    }
    check_cancelled(operation)?;
    first_child_error.map_or(Ok(()), Err)
}

// Page scanning deliberately receives the same audited limits and dedupe sets
// as the coordinator instead of hiding them in shared or global state.
#[allow(clippy::too_many_arguments)]
fn scan_directory(
    browser: &mut Browser,
    query: &str,
    options: &LibrarySearchOptions,
    policy: &SecurityPolicy,
    operation: Option<&OperationHandle>,
    items: &mut Vec<LibraryItem>,
    seen: &mut HashSet<String>,
    folders: &mut VecDeque<LibraryItem>,
    folder_keys: &mut HashSet<String>,
    publisher: Option<&IncrementalPublisher>,
) -> CoreResult<()> {
    let page_limit = options.page_limit().min(MAX_DIRECTORY_PAGES);
    let mut first_folder_count = 0usize;
    for page in 1..=page_limit {
        check_cancelled(operation)?;
        let listing =
            browser.browse_page_with_constraints(page, operation, Some(search_step_deadline()))?;
        check_cancelled(operation)?;
        if page == 1 {
            first_folder_count = listing.api_folder_count;
        }
        let before = items.len();
        for item in listing.items {
            if item.is_folder {
                enqueue_search_folder(folders, folder_keys, item.clone(), policy)?;
            }
            append_matching(items, seen, item, query, policy)?;
        }
        if let Some(publisher) = publisher {
            publisher.publish_items(&items[before..])?;
        }
        if !listing.has_more {
            break;
        }
        if page == page_limit && options.max_pages == 0 {
            return Err(CoreError::remote("目录搜索超过 100 页，未完整获取", false));
        }
    }

    if first_folder_count >= DIRECTORY_PAGE_SIZE && page_limit >= 2 {
        for page in 2..=page_limit {
            check_cancelled(operation)?;
            let (page_items, raw_count) = browser.folder_page_with_constraints(
                page,
                operation,
                Some(search_step_deadline()),
            )?;
            check_cancelled(operation)?;
            let before = items.len();
            for item in page_items {
                enqueue_search_folder(folders, folder_keys, item.clone(), policy)?;
                append_matching(items, seen, item, query, policy)?;
            }
            if let Some(publisher) = publisher {
                publisher.publish_items(&items[before..])?;
            }
            if raw_count < DIRECTORY_PAGE_SIZE {
                break;
            }
            if page == page_limit && options.max_pages == 0 {
                return Err(CoreError::remote(
                    "目录子文件夹超过 100 页，未完整获取",
                    false,
                ));
            }
        }
    }
    Ok(())
}

fn enqueue_search_folder(
    queue: &mut VecDeque<LibraryItem>,
    keys: &mut HashSet<String>,
    item: LibraryItem,
    policy: &SecurityPolicy,
) -> CoreResult<()> {
    if !item.is_folder || item.url.is_empty() {
        return Ok(());
    }
    let Some(key) = search_folder_key(&item.url, policy) else {
        return Ok(());
    };
    if keys.insert(key) {
        if keys.len() > MAX_SEARCH_FOLDERS {
            return Err(CoreError::remote("目录数量超过 10000 个，停止搜索", false));
        }
        queue.push_back(item);
    }
    Ok(())
}

fn search_folder_key(value: &str, policy: &SecurityPolicy) -> Option<String> {
    let target = parse_folder_target(value);
    let mut root = validate_page_url(&target.root_url, policy).ok()?;
    root.set_fragment(None);
    Some(format!("{}\n{}", root, target.folder_id))
}

fn append_matching(
    items: &mut Vec<LibraryItem>,
    seen: &mut HashSet<String>,
    item: LibraryItem,
    query: &str,
    policy: &SecurityPolicy,
) -> CoreResult<()> {
    if title_matches(&item, query) && seen.insert(search_item_key(&item, policy)) {
        if items.len() >= MAX_SEARCH_RESULTS {
            return Err(CoreError::remote("搜索结果超过 50000 条，停止收集", false));
        }
        items.push(item);
    }
    Ok(())
}

fn search_item_key(item: &LibraryItem, policy: &SecurityPolicy) -> String {
    if item.is_folder {
        if let Some(key) = search_folder_key(&item.url, policy) {
            return format!("folder\n{key}");
        }
    }
    let normalized = validate_page_url(&item.url, policy)
        .map(|mut url| {
            url.set_fragment(None);
            url.to_string()
        })
        .unwrap_or_else(|_| item.url.clone());
    format!("file\n{normalized}")
}

fn check_cancelled(operation: Option<&OperationHandle>) -> CoreResult<()> {
    operation.map_or(Ok(()), OperationHandle::check_cancelled)
}

fn title_matches(item: &LibraryItem, query: &str) -> bool {
    query.trim().is_empty()
        || item
            .title
            .to_lowercase()
            .contains(&query.trim().to_lowercase())
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::{
            atomic::{AtomicBool, AtomicUsize, Ordering},
            Mutex,
        },
    };

    use super::*;

    fn read_mock_request(stream: &mut std::net::TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut bytes = Vec::new();
        let mut buffer = [0_u8; 1_024];
        let mut expected = None;
        loop {
            let read = stream.read(&mut buffer).unwrap_or(0);
            if read == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..read]);
            if let Some(header_end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                let header_len = header_end + 4;
                if expected.is_none() {
                    let headers = String::from_utf8_lossy(&bytes[..header_len]);
                    let content_length = headers.lines().find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .and_then(|value| value.trim().parse::<usize>().ok())
                    });
                    expected = Some(header_len + content_length.unwrap_or(0));
                }
                if bytes.len() >= expected.unwrap_or(header_len) {
                    break;
                }
            }
        }
        String::from_utf8_lossy(&bytes).into_owned()
    }

    fn write_mock_response(stream: &mut std::net::TcpStream, content_type: &str, body: &str) {
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).unwrap();
    }

    #[test]
    fn test_search_deduplicates_sources_before_network() {
        let source = LibrarySource {
            source_id: "same".to_owned(),
            title: "x-one".to_owned(),
            share_url: "https://invalid.example/source".to_owned(),
            password: String::new(),
        };
        let result = search(
            "x".to_owned(),
            vec![source.clone(), source],
            LibrarySearchOptions::default(),
            SecurityPolicy::Production,
            Arc::new(RateLimiter::new(Duration::ZERO)),
            None,
        )
        .unwrap();
        assert_eq!(result.sources.len(), 1);
    }

    fn invalid_sources(count: usize) -> Vec<LibrarySource> {
        (0..count)
            .map(|index| LibrarySource {
                source_id: format!("s{index}"),
                title: format!("源 {index}"),
                share_url: "https://invalid.example/source".to_owned(),
                password: String::new(),
            })
            .collect()
    }

    #[test]
    fn test_search_accepts_current_606_source_catalog_and_deduplicates_with_bounded_workers() {
        let options = LibrarySearchOptions {
            concurrency: 7,
            ..LibrarySearchOptions::default()
        };

        let result = search(
            "tool".to_owned(),
            {
                let mut sources = invalid_sources(606);
                sources.push(sources[0].clone());
                sources
            },
            options,
            SecurityPolicy::Production,
            Arc::new(RateLimiter::new(Duration::ZERO)),
            None,
        )
        .unwrap();

        assert_eq!(result.sources.len(), 606);
        assert!(result.sources.iter().all(|status| status.error.is_some()));
    }

    #[test]
    fn test_search_rejects_more_than_4096_sources() {
        let error = search(
            "tool".to_owned(),
            invalid_sources(4_097),
            LibrarySearchOptions::default(),
            SecurityPolicy::Production,
            Arc::new(RateLimiter::new(Duration::ZERO)),
            None,
        )
        .unwrap_err();

        assert_eq!(error.code, "invalid_argument");
        assert_eq!(error.message, "软件源数量必须为 1-4096 个");
    }

    #[test]
    fn test_search_remote_fast_path_always_completes_recursive_directory_tree() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let request_trace = Arc::new(Mutex::new(Vec::new()));
        let server_trace = request_trace.clone();
        let stop_server = Arc::new(AtomicBool::new(false));
        let server_stop = stop_server.clone();
        let server = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(20);
            let mut connections = Vec::new();
            while !server_stop.load(Ordering::SeqCst) && Instant::now() < deadline {
                let (stream, _) = match listener.accept() {
                    Ok(connection) => connection,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(error) => panic!("mock listener failed: {error}"),
                };
                let connection_trace = server_trace.clone();
                connections.push(thread::spawn(move || {
                    let mut stream = stream;
                    let request = read_mock_request(&mut stream);
                    let first_line = request.lines().next().unwrap_or_default();
                    if first_line.is_empty() {
                        return;
                    }
                    connection_trace.lock().unwrap().push(format!(
                        "{first_line}; folder42={}",
                        request.contains("folder_id=42")
                    ));
                    let body = if first_line.starts_with("GET /source ") {
                        r#"<title>完整软件库</title><script>
                    var token='x';
                    const files={url:'/filemoreajax.php?file=9'};
                    const folders={url:'/foldermoreajax.php?file=9'};
                    const search={url:'/search/s.php?file=9','sign':'sig','t':token,'uid':'7'};
                    </script>"#
                    } else if first_line.starts_with("POST /search/s.php?file=9 ") {
                        assert!(request.contains("pwd=secret"));
                        r#"{"zt":1,"total":1,"item":[{"id":"/same","name_all":"RemoteHit.apk"}]}"#
                    } else if first_line.starts_with("POST /foldermoreajax.php?file=9 ") {
                        assert!(request.contains("pwd=secret"));
                        if request.contains("folder_id=42") {
                            r#"{"zt":2}"#
                        } else {
                            r#"{"zt":1,"text":[{"fol_id":"42","name":"子目录"}]}"#
                        }
                    } else if first_line.starts_with("POST /filemoreajax.php?file=9 ") {
                        assert!(request.contains("pwd=secret"));
                        if request.contains("folder_id=42") {
                            r#"{"zt":1,"text":[{"id":"nested","name_all":"NestedHit.apk"}]}"#
                        } else {
                            r#"{"zt":1,"text":[{"id":"same","name_all":"RemoteHit.apk"},{"id":"directory","name_all":"DirectoryHit.apk"}]}"#
                        }
                    } else {
                        panic!("unexpected mock request: {first_line}");
                    };
                    write_mock_response(
                        &mut stream,
                        if first_line.starts_with("GET ") {
                            "text/html"
                        } else {
                            "application/json"
                        },
                        body,
                    );
                }));
            }
            for connection in connections {
                connection.join().unwrap();
            }
        });
        let operation = crate::operation::begin(
            Some("search-api-directory-completion-test"),
            crate::operation::OperationKind::LibrarySearch,
        )
        .unwrap()
        .unwrap();
        let result = search(
            "Hit".to_owned(),
            vec![LibrarySource {
                source_id: "mock".to_owned(),
                title: "完整软件库".to_owned(),
                share_url: format!("{origin}/source"),
                password: "secret".to_owned(),
            }],
            LibrarySearchOptions {
                concurrency: 1,
                source_switch_delay_ms: 0,
                until_last_page: true,
                max_pages: 4,
            },
            SecurityPolicy::Test {
                origin: origin.clone(),
            },
            Arc::new(RateLimiter::new(Duration::ZERO)),
            Some(operation.clone()),
        );
        stop_server.store(true, Ordering::SeqCst);
        server.join().unwrap();
        let result = result.unwrap();

        assert_eq!(result.sources.len(), 1);
        let titles = result
            .items
            .iter()
            .map(|item| item.title.as_str())
            .collect::<HashSet<_>>();
        assert_eq!(
            result.sources[0].found,
            3,
            "titles: {titles:?}; status: {}; requests: {:?}",
            serde_json::to_string(&result.sources[0]).unwrap(),
            request_trace.lock().unwrap()
        );
        let trace = request_trace.lock().unwrap();
        assert!(trace
            .iter()
            .any(|entry| entry.starts_with("POST /search/s.php")));
        assert!(trace
            .iter()
            .any(|entry| entry.starts_with("POST /filemoreajax.php")
                && entry.ends_with("folder42=true")));
        drop(trace);
        assert!(result.sources[0].error.is_none());
        assert_eq!(
            titles,
            HashSet::from(["RemoteHit.apk", "DirectoryHit.apk", "NestedHit.apk"])
        );
        let json = serde_json::to_string(&result).unwrap();
        assert!(!json.contains("secret"));
        assert!(!json.to_ascii_lowercase().contains("password"));
        let status = crate::operation::status("search-api-directory-completion-test").unwrap();
        assert_eq!(status["completedUnits"], 1);
        assert_eq!(status["totalUnits"], 1);
        assert_eq!(status["itemsFound"], 3);
        operation.finish_success();
        crate::operation::forget("search-api-directory-completion-test").unwrap();
    }

    #[test]
    fn test_enqueue_search_folder_uses_virtual_key_and_rejects_untrusted_url() {
        let mut queue = std::collections::VecDeque::new();
        let mut keys = HashSet::new();
        let first = LibraryItem {
            url: "https://www.lanzouw.com/b1#lanzou-folder=42&title=one".to_owned(),
            is_folder: true,
            ..LibraryItem::default()
        };
        let duplicate = LibraryItem {
            url: "https://www.lanzouw.com/b1#lanzou-folder=42&title=two".to_owned(),
            is_folder: true,
            ..LibraryItem::default()
        };
        let advertisement = LibraryItem {
            url: "https://evil.example/folder".to_owned(),
            is_folder: true,
            ..LibraryItem::default()
        };

        enqueue_search_folder(&mut queue, &mut keys, first, &SecurityPolicy::Production).unwrap();
        enqueue_search_folder(
            &mut queue,
            &mut keys,
            duplicate,
            &SecurityPolicy::Production,
        )
        .unwrap();
        enqueue_search_folder(
            &mut queue,
            &mut keys,
            advertisement,
            &SecurityPolicy::Production,
        )
        .unwrap();

        assert_eq!(queue.len(), 1);
        assert_eq!(keys.len(), 1);
    }

    #[test]
    fn test_title_matches_is_unicode_case_insensitive() {
        let item = LibraryItem {
            title: "Rust工具箱".to_owned(),
            ..LibraryItem::default()
        };
        assert!(title_matches(&item, "rust"));
        assert!(!title_matches(&item, "flutter"));
    }

    #[test]
    fn test_source_error_with_password_uses_fixed_safe_message() {
        let error = sanitize_search_source_error(
            CoreError::remote("password=secret&amp;secret%3D1", false),
            true,
        );
        assert_eq!(
            error.message,
            super::super::security::ACCESS_CODE_REMOTE_ERROR
        );
    }

    #[test]
    fn test_share_cancelled_source_error_stays_explicit_with_password() {
        let error = sanitize_search_source_error(
            CoreError::new("share_cancelled", "分享已取消", false),
            true,
        );

        assert_eq!(error.code, "share_cancelled");
        assert_eq!(error.message, "分享已取消");
        assert!(!error.retriable);
    }

    #[test]
    fn test_password_required_source_error_keeps_code_with_safe_message() {
        let error = sanitize_search_source_error(
            CoreError::new(
                "password_required",
                "password=not-serialized is incorrect",
                false,
            ),
            true,
        );
        assert_eq!(error.code, "password_required");
        assert_eq!(
            error.message,
            super::super::security::ACCESS_CODE_REMOTE_ERROR
        );
        assert!(!error.message.contains("not-serialized"));
    }

    #[test]
    fn test_merge_phase_results_preserves_share_cancelled_code_with_password() {
        let source = LibrarySource {
            source_id: "protected".to_owned(),
            title: "受保护源".to_owned(),
            share_url: "https://www.lanzouw.com/protected".to_owned(),
            password: "not-serialized".to_owned(),
        };
        let phase_results = vec![
            SearchPhaseResult {
                source_index: 0,
                phase: SearchPhase::Api,
                source_id: source.source_id.clone(),
                fallback_title: source.title.clone(),
                title: None,
                items: Vec::new(),
                error: Some(CoreError::new("share_cancelled", "分享已取消", false)),
            },
            SearchPhaseResult {
                source_index: 0,
                phase: SearchPhase::Directory,
                source_id: source.source_id.clone(),
                fallback_title: source.title.clone(),
                title: None,
                items: Vec::new(),
                error: Some(CoreError::remote("password=not-serialized", false)),
            },
        ];

        let result = merge_phase_results(
            vec![source.clone()],
            phase_results,
            &SecurityPolicy::Production,
        )
        .unwrap();
        assert_eq!(
            result.sources[0].error_code.as_deref(),
            Some("share_cancelled")
        );
        assert_eq!(result.sources[0].error.as_deref(), Some("分享已取消"));
        let json = serde_json::to_string(&result).unwrap();
        assert!(!json.contains("not-serialized"));
        assert!(json.contains("share_cancelled"));
    }

    #[test]
    fn test_merge_phase_results_normalizes_virtual_folder_identity() {
        let source = LibrarySource {
            source_id: "folders".to_owned(),
            title: "目录源".to_owned(),
            share_url: "https://www.lanzouw.com/root".to_owned(),
            password: String::new(),
        };
        let phase = |phase, title: &str| SearchPhaseResult {
            source_index: 0,
            phase,
            source_id: source.source_id.clone(),
            fallback_title: source.title.clone(),
            title: Some(source.title.clone()),
            items: vec![LibraryItem {
                source_id: source.source_id.clone(),
                title: title.to_owned(),
                url: format!("https://www.lanzouw.com/root#lanzou-folder=42&title={title}"),
                is_folder: true,
                ..LibraryItem::default()
            }],
            error: None,
        };

        let phase_results = vec![
            phase(SearchPhase::Api, "api-name"),
            phase(SearchPhase::Directory, "directory-name"),
        ];
        let result = merge_phase_results(
            vec![source.clone()],
            phase_results,
            &SecurityPolicy::Production,
        )
        .unwrap();
        assert_eq!(result.items.len(), 1);
        assert_eq!(result.sources[0].found, 1);
    }

    #[test]
    fn test_append_unique_keeps_partial_source_results() {
        let mut output = vec![LibraryItem {
            title: "existing".to_owned(),
            url: "https://www.lanzouw.com/a".to_owned(),
            ..LibraryItem::default()
        }];
        let mut seen = HashSet::from([search_item_key(&output[0], &SecurityPolicy::Production)]);
        let fresh = append_unique(
            &mut output,
            &mut seen,
            vec![
                LibraryItem {
                    title: "duplicate".to_owned(),
                    url: "https://www.lanzouw.com/a".to_owned(),
                    ..LibraryItem::default()
                },
                LibraryItem {
                    title: "partial".to_owned(),
                    url: "https://www.lanzouw.com/b".to_owned(),
                    ..LibraryItem::default()
                },
            ],
            &SecurityPolicy::Production,
        )
        .unwrap();
        assert_eq!(fresh, 1);
        assert_eq!(output.len(), 2);
        assert_eq!(output[1].title, "partial");
    }

    #[test]
    fn test_search_updates_progress_after_each_source() {
        let operation = crate::operation::begin(
            Some("search-progress-test"),
            crate::operation::OperationKind::LibrarySearch,
        )
        .unwrap()
        .unwrap();
        let sources = ["one", "two"]
            .into_iter()
            .map(|id| LibrarySource {
                source_id: id.to_owned(),
                title: id.to_owned(),
                share_url: "https://invalid.example/source".to_owned(),
                password: String::new(),
            })
            .collect();

        let result = search(
            "tool".to_owned(),
            sources,
            LibrarySearchOptions::default(),
            SecurityPolicy::Production,
            Arc::new(RateLimiter::new(Duration::ZERO)),
            Some(operation.clone()),
        )
        .unwrap();
        assert_eq!(result.sources.len(), 2);
        let status = crate::operation::status("search-progress-test").unwrap();
        assert_eq!(status["completedUnits"], 2);
        assert_eq!(status["totalUnits"], 2);
        assert_eq!(status["itemsFound"], 0);
        operation.finish_success();
        crate::operation::forget("search-progress-test").unwrap();
    }

    #[test]
    fn test_search_honors_cancellation_before_network() {
        let operation = crate::operation::begin(
            Some("search-cancel-test"),
            crate::operation::OperationKind::LibrarySearch,
        )
        .unwrap()
        .unwrap();
        crate::operation::cancel("search-cancel-test").unwrap();
        let source = LibrarySource {
            source_id: "source".to_owned(),
            title: "source".to_owned(),
            share_url: "https://www.lanzouw.com/b1".to_owned(),
            password: "not-exposed".to_owned(),
        };

        let error = search(
            "tool".to_owned(),
            vec![source],
            LibrarySearchOptions::default(),
            SecurityPolicy::Production,
            Arc::new(RateLimiter::new(Duration::ZERO)),
            Some(operation.clone()),
        )
        .unwrap_err();
        assert_eq!(error.code, "cancelled");
        assert_eq!(error.message, "操作已取消");
        operation.finish_result::<()>(&Err(error));
        crate::operation::forget("search-cancel-test").unwrap();
    }

    fn completed_source(source_id: &str, url: &str) -> SearchOneSuccess {
        (
            source_id.to_owned(),
            source_id.to_owned(),
            vec![LibraryItem {
                source_id: source_id.to_owned(),
                title: source_id.to_owned(),
                url: url.to_owned(),
                ..LibraryItem::default()
            }],
        )
    }

    #[test]
    fn test_concurrent_sources_publish_fast_completion_before_slow_source_finishes() {
        let operation = crate::operation::begin(
            Some("search-mid-batch-progress-test"),
            crate::operation::OperationKind::LibrarySearch,
        )
        .unwrap()
        .unwrap();
        operation.set_total_units(2);
        let (result_sender, result_receiver) = std::sync::mpsc::channel();
        let (fast_sent, fast_observed) = std::sync::mpsc::channel();
        let (release_slow, slow_released) = std::sync::mpsc::channel();

        let slow_sender = result_sender.clone();
        let slow = std::thread::spawn(move || {
            slow_released.recv().unwrap();
            slow_sender
                .send((
                    0,
                    Ok(completed_source("slow", "https://www.lanzouw.com/slow")),
                ))
                .unwrap();
        });
        let fast = std::thread::spawn(move || {
            result_sender
                .send((
                    1,
                    Ok(completed_source("fast", "https://www.lanzouw.com/fast")),
                ))
                .unwrap();
            fast_sent.send(()).unwrap();
        });
        let collector_operation = operation.clone();
        let collector = std::thread::spawn(move || {
            let mut progress_urls = HashSet::new();
            collect_search_results(
                result_receiver,
                2,
                Some(&collector_operation),
                &mut progress_urls,
            )
        });

        fast_observed.recv().unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let status = crate::operation::status("search-mid-batch-progress-test").unwrap();
            if status["completedUnits"] == 1 {
                assert_eq!(status["totalUnits"], 2);
                assert_eq!(status["itemsFound"], 1);
                break;
            }
            assert!(
                Instant::now() < deadline,
                "fast source progress was not published"
            );
            std::thread::sleep(Duration::from_millis(1));
        }

        release_slow.send(()).unwrap();
        let results = collector.join().unwrap().unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].as_ref().unwrap().0, "slow");
        assert_eq!(results[1].as_ref().unwrap().0, "fast");
        fast.join().unwrap();
        slow.join().unwrap();
        operation.finish_success();
        crate::operation::forget("search-mid-batch-progress-test").unwrap();
    }

    fn scheduled_source(source_id: &str) -> LibrarySource {
        LibrarySource {
            source_id: source_id.to_owned(),
            title: source_id.to_owned(),
            share_url: format!("https://www.lanzouw.com/{source_id}"),
            password: String::new(),
        }
    }

    fn completed_phase(job: SearchPhaseJob) -> SearchPhaseResult {
        SearchPhaseResult {
            source_index: job.source_index,
            phase: job.phase,
            source_id: job.source.source_id.clone(),
            fallback_title: job.source.title.clone(),
            title: Some(job.source.title),
            items: Vec::new(),
            error: None,
        }
    }

    #[test]
    fn test_phase_scheduler_refills_completed_source_without_batch_barrier() {
        let sources = vec![
            scheduled_source("slow"),
            scheduled_source("fast"),
            scheduled_source("refill"),
        ];
        let (release_slow, slow_release) = std::sync::mpsc::channel();
        let slow_release = Arc::new(Mutex::new(slow_release));
        let (events, observed) = std::sync::mpsc::channel();
        let runner: SearchPhaseRunner = Arc::new(move |job| {
            events.send(job.source.source_id.clone()).unwrap();
            if job.source.source_id == "slow" && job.phase == SearchPhase::Api {
                slow_release.lock().unwrap().recv().unwrap();
            }
            completed_phase(job)
        });
        let coordinator = std::thread::spawn(move || {
            run_search_phase_jobs(&sources, 2, Duration::ZERO, None, runner, |_, _| Ok(()))
        });

        let mut refill_started = false;
        for _ in 0..6 {
            let source_id = observed.recv_timeout(Duration::from_secs(2)).unwrap();
            refill_started |= source_id == "refill";
            if refill_started {
                break;
            }
        }
        assert!(
            refill_started,
            "a completed source must immediately refill its slot"
        );
        release_slow.send(()).unwrap();
        assert_eq!(coordinator.join().unwrap().unwrap().len(), 6);
    }

    #[test]
    fn test_phase_scheduler_is_global_across_concurrent_search_calls() {
        let active = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let worker_ids = Arc::new(Mutex::new(HashSet::new()));
        let start = Arc::new(std::sync::Barrier::new(3));
        let mut coordinators = Vec::new();
        for invocation in 0..2 {
            let active = active.clone();
            let peak = peak.clone();
            let worker_ids = worker_ids.clone();
            let start = start.clone();
            coordinators.push(std::thread::spawn(move || {
                let sources = (0..32)
                    .map(|index| scheduled_source(&format!("{invocation}-{index}")))
                    .collect::<Vec<_>>();
                let runner: SearchPhaseRunner = Arc::new(move |job| {
                    let now = active.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(now, Ordering::SeqCst);
                    worker_ids
                        .lock()
                        .unwrap()
                        .insert(format!("{:?}", std::thread::current().id()));
                    assert!(std::thread::current()
                        .name()
                        .is_some_and(|name| name.starts_with("lanzou-search-")));
                    std::thread::sleep(Duration::from_millis(20));
                    active.fetch_sub(1, Ordering::SeqCst);
                    completed_phase(job)
                });
                start.wait();
                run_search_phase_jobs(
                    &sources,
                    sources.len(),
                    Duration::ZERO,
                    None,
                    runner,
                    |_, _| Ok(()),
                )
                .unwrap()
            }));
        }
        start.wait();
        for coordinator in coordinators {
            assert_eq!(coordinator.join().unwrap().len(), 64);
        }
        assert!(peak.load(Ordering::SeqCst) <= MAX_GLOBAL_SEARCH_WORKERS);
        assert!(worker_ids.lock().unwrap().len() <= MAX_GLOBAL_SEARCH_WORKERS);
    }

    #[test]
    fn test_phase_scheduler_runs_authoritative_directory_while_api_is_hanging() {
        let sources = vec![scheduled_source("source")];
        let (release_api, api_release) = std::sync::mpsc::channel();
        let api_release = Arc::new(Mutex::new(api_release));
        let (events, observed) = std::sync::mpsc::channel();
        let runner: SearchPhaseRunner = Arc::new(move |job| {
            match job.phase {
                SearchPhase::Api => {
                    events.send("api-start").unwrap();
                    api_release.lock().unwrap().recv().unwrap();
                }
                SearchPhase::Directory => events.send("directory-complete").unwrap(),
            }
            completed_phase(job)
        });
        let coordinator = std::thread::spawn(move || {
            run_search_phase_jobs(&sources, 1, Duration::ZERO, None, runner, |_, _| Ok(()))
        });

        let before_release = (0..2)
            .map(|_| observed.recv_timeout(Duration::from_secs(2)).unwrap())
            .collect::<HashSet<_>>();
        assert_eq!(
            before_release,
            HashSet::from(["api-start", "directory-complete"])
        );
        release_api.send(()).unwrap();
        assert_eq!(coordinator.join().unwrap().unwrap().len(), 2);
    }

    #[test]
    fn test_source_rotation_yields_capacity_without_discarding_slow_result() {
        let sources = vec![scheduled_source("slow"), scheduled_source("rotated")];
        let (release_slow, slow_release) = std::sync::mpsc::channel();
        let slow_release = Arc::new(Mutex::new(slow_release));
        let (events, observed) = std::sync::mpsc::channel();
        let runner: SearchPhaseRunner = Arc::new(move |job| {
            events
                .send((job.source.source_id.clone(), job.phase))
                .unwrap();
            if job.source.source_id == "slow" && job.phase == SearchPhase::Api {
                slow_release.lock().unwrap().recv().unwrap();
            }
            completed_phase(job)
        });
        let coordinator = std::thread::spawn(move || {
            run_search_phase_jobs(
                &sources,
                1,
                Duration::from_millis(30),
                None,
                runner,
                |_, _| Ok(()),
            )
        });

        let mut rotated_started = false;
        for _ in 0..4 {
            let (source_id, _) = observed.recv_timeout(Duration::from_secs(2)).unwrap();
            rotated_started |= source_id == "rotated";
            if rotated_started {
                break;
            }
        }
        assert!(
            rotated_started,
            "the next source must start before the slow result arrives"
        );
        release_slow.send(()).unwrap();
        let results = coordinator.join().unwrap().unwrap();
        assert_eq!(results.len(), 4);
        assert_eq!(
            results
                .iter()
                .filter(|result| result.source_id == "slow")
                .count(),
            2
        );
    }

    #[test]
    fn test_phase_scheduler_cancels_while_coordinator_is_waiting() {
        let operation_id = "search-scheduler-wait-cancel-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::LibrarySearch,
        )
        .unwrap()
        .unwrap();
        let worker_operation = operation.clone();
        let scheduler_operation = operation.clone();
        let (started, observed) = std::sync::mpsc::channel();
        let began = Instant::now();
        let phase_runner: SearchPhaseRunner = Arc::new(move |job| {
            started.send(()).unwrap();
            while !worker_operation.is_cancellation_requested() {
                std::thread::sleep(Duration::from_millis(5));
            }
            completed_phase(job)
        });
        let coordinator = std::thread::spawn(move || {
            run_search_phase_jobs(
                &[scheduled_source("blocked")],
                1,
                Duration::ZERO,
                Some(&scheduler_operation),
                phase_runner,
                |_, _| Ok(()),
            )
        });
        observed.recv_timeout(Duration::from_secs(2)).unwrap();
        crate::operation::cancel(operation_id).unwrap();
        let error = match coordinator.join().unwrap() {
            Ok(_) => panic!("cancelled scheduling must not complete successfully"),
            Err(error) => error,
        };
        assert_eq!(error.code, "cancelled");
        assert!(began.elapsed() < Duration::from_millis(500));
        operation.finish_result::<()>(&Err(error));
        crate::operation::forget(operation_id).unwrap();
    }

    #[test]
    fn test_paused_scheduler_finishes_admitted_work_but_stops_new_admission() {
        let operation_id = "search-scheduler-pause-admission-test";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::LibrarySearch,
        )
        .unwrap()
        .unwrap();
        let sources = vec![scheduled_source("first"), scheduled_source("second")];
        let (events, observed) = std::sync::mpsc::channel();
        let (release_api, api_release) = std::sync::mpsc::channel();
        let api_release = Arc::new(Mutex::new(api_release));
        let runner: SearchPhaseRunner = Arc::new(move |job| {
            events
                .send((job.source.source_id.clone(), job.phase))
                .unwrap();
            if job.source.source_id == "first" && job.phase == SearchPhase::Api {
                api_release.lock().unwrap().recv().unwrap();
            }
            completed_phase(job)
        });
        let scheduler_operation = operation.clone();
        let coordinator = std::thread::spawn(move || {
            run_search_phase_jobs(
                &sources,
                1,
                Duration::ZERO,
                Some(&scheduler_operation),
                runner,
                |_, _| Ok(()),
            )
        });

        let first_two = (0..2)
            .map(|_| observed.recv_timeout(Duration::from_secs(2)).unwrap())
            .collect::<Vec<_>>();
        assert!(first_two.iter().all(|(source_id, _)| source_id == "first"));
        operation.pause();
        release_api.send(()).unwrap();
        assert!(observed.recv_timeout(Duration::from_millis(150)).is_err());

        operation.resume();
        let resumed = observed.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(resumed.0, "second");
        assert_eq!(coordinator.join().unwrap().unwrap().len(), 4);
        operation.finish_success();
        crate::operation::forget(operation_id).unwrap();
    }

    #[test]
    fn test_single_character_search_is_name_only_and_performs_zero_network_requests() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(AtomicUsize::new(0));
        let server_requests = requests.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let server_stop = stop.clone();
        let server = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(2);
            while !server_stop.load(Ordering::SeqCst) && Instant::now() < deadline {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        server_requests.fetch_add(1, Ordering::SeqCst);
                        let _ = read_mock_request(&mut stream);
                        write_mock_response(&mut stream, "text/html", "<title>unexpected</title>");
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    Err(error) => panic!("mock listener failed: {error}"),
                }
            }
        });

        let result = search(
            "库".to_owned(),
            vec![LibrarySource {
                source_id: "name-only".to_owned(),
                title: "软件库".to_owned(),
                share_url: format!("{origin}/source"),
                password: String::new(),
            }],
            LibrarySearchOptions::default(),
            SecurityPolicy::Test {
                origin: origin.clone(),
            },
            Arc::new(RateLimiter::new(Duration::ZERO)),
            None,
        )
        .unwrap();
        stop.store(true, Ordering::SeqCst);
        server.join().unwrap();

        assert_eq!(requests.load(Ordering::SeqCst), 0);
        assert!(result.items.is_empty());
        assert_eq!(result.sources.len(), 1);
        assert_eq!(result.sources[0].title, "软件库");
    }

    #[test]
    fn test_incremental_start_read_ack_and_forget_have_no_synchronous_fallback() {
        let operation_id = "incremental-primitives-name-only";
        let origin = "http://127.0.0.1:9".to_owned();
        let started = start_incremental_search(
            operation_id,
            "库".to_owned(),
            vec![LibrarySource {
                source_id: "name-only".to_owned(),
                title: "软件库".to_owned(),
                share_url: format!("{origin}/source"),
                password: String::new(),
            }],
            LibrarySearchOptions::default(),
            SecurityPolicy::Test {
                origin: origin.clone(),
            },
            Arc::new(RateLimiter::new(Duration::ZERO)),
            Vec::new(),
            None,
        )
        .unwrap();
        assert_eq!(started.operation_id, operation_id);
        assert_eq!(started.state, SearchJournalState::Running);

        let mut cursor = started.cursor;
        let mut states = Vec::new();
        let mut source_updates = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let read = read_incremental_search(operation_id, Some(&cursor), None, 8).unwrap();
            for batch in &read.batches {
                assert!(batch.items.len() <= 100);
                if let Some(state) = &batch.state {
                    states.push(state.state);
                }
                source_updates.extend(batch.sources.iter().cloned());
            }
            if !read.batches.is_empty() {
                cursor = read.cursor.clone();
            }
            if states
                .iter()
                .any(|state| *state == SearchJournalState::Succeeded)
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "incremental search did not finish"
            );
            std::thread::sleep(Duration::from_millis(1));
        }

        assert_eq!(states.first(), Some(&SearchJournalState::Running));
        assert_eq!(states.last(), Some(&SearchJournalState::Succeeded));
        assert_eq!(source_updates.len(), 1);
        assert_eq!(source_updates[0].source_id, "name-only");
        let acknowledged =
            read_incremental_search(operation_id, Some(&cursor), Some(&cursor), 8).unwrap();
        assert_eq!(acknowledged.acknowledged_cursor, cursor);
        assert!(forget_incremental_search(operation_id).unwrap().forgotten);
    }

    #[test]
    fn test_incremental_pause_resume_cancel_primitives_publish_linear_state_updates() {
        let operation_id = "incremental-control-primitives";
        let operation = crate::operation::begin(
            Some(operation_id),
            crate::operation::OperationKind::LibrarySearch,
        )
        .unwrap()
        .unwrap();
        let publisher =
            Arc::new(IncrementalPublisher::new(SecurityPolicy::Production, None).unwrap());
        publisher
            .publish_operation(&operation.status(), None)
            .unwrap();
        INCREMENTAL_SEARCHES
            .register(operation.clone(), publisher.clone())
            .unwrap();

        let paused = pause_incremental_search(operation_id).unwrap();
        assert_eq!(paused.operation.state, OperationState::Paused);
        let resumed = resume_incremental_search(operation_id).unwrap();
        assert_eq!(resumed.operation.state, OperationState::Running);
        let cancelling = cancel_incremental_search(operation_id).unwrap();
        assert_eq!(cancelling.operation.state, OperationState::Cancelling);
        assert!(cancelling.operation.revision > resumed.operation.revision);
        operation.finish_success();
        publisher
            .publish_operation(&operation.status(), None)
            .unwrap();

        let read = read_incremental_search(operation_id, None, None, 8).unwrap();
        let states = read
            .batches
            .iter()
            .filter_map(|batch| batch.state.as_ref().map(|state| state.state))
            .collect::<Vec<_>>();
        assert_eq!(
            states,
            vec![
                SearchJournalState::Running,
                SearchJournalState::Paused,
                SearchJournalState::Running,
                SearchJournalState::Cancelling,
                SearchJournalState::Cancelled,
            ]
        );
        let acknowledged =
            read_incremental_search(operation_id, Some(&read.cursor), Some(&read.cursor), 8)
                .unwrap();
        assert_eq!(acknowledged.acknowledged_cursor, read.cursor);
        assert!(forget_incremental_search(operation_id).unwrap().forgotten);
    }

    #[test]
    fn test_incremental_cursor_generation_rejects_stale_cursor_after_id_reuse() {
        let first = IncrementalPublisher::new(SecurityPolicy::Production, None).unwrap();
        let stale_cursor = first.acknowledged_cursor();
        let second = IncrementalPublisher::new(SecurityPolicy::Production, None).unwrap();

        assert_ne!(stale_cursor, second.acknowledged_cursor());
        assert_eq!(
            second.read(Some(&stale_cursor), 1).unwrap_err().code,
            "invalid_argument"
        );
    }
}
