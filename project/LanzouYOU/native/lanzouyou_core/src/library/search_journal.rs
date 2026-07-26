use std::collections::VecDeque;

use serde::Serialize;

use crate::{
    error::{CoreError, CoreResult},
    operation::OperationState,
};

use crate::library::model::LibraryItem;

pub(crate) const MAX_SEARCH_BATCH_ITEMS: usize = 100;
const MAX_SEARCH_JOURNAL_BATCHES: usize = 8_192;
const MAX_READ_BATCHES: usize = 100;
const MAX_PENDING_ITEMS: usize = 50_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SearchJournalState {
    Running,
    Paused,
    Cancelling,
    Succeeded,
    Cancelled,
    Failed,
}

impl From<OperationState> for SearchJournalState {
    fn from(value: OperationState) -> Self {
        match value {
            OperationState::Running => Self::Running,
            OperationState::Paused => Self::Paused,
            OperationState::Cancelling => Self::Cancelling,
            OperationState::Succeeded => Self::Succeeded,
            OperationState::Cancelled => Self::Cancelled,
            OperationState::Failed => Self::Failed,
        }
    }
}

impl SearchJournalState {
    fn is_terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Cancelled | Self::Failed)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SearchStateUpdate {
    pub(crate) state: SearchJournalState,
    pub(crate) operation_revision: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SearchSourceUpdate {
    pub(crate) source_id: String,
    pub(crate) title: String,
    pub(crate) found: usize,
    pub(crate) completed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SearchJournalBatch {
    pub(crate) cursor: String,
    pub(crate) revision: u64,
    pub(crate) items: Vec<LibraryItem>,
    pub(crate) sources: Vec<SearchSourceUpdate>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) state: Option<SearchStateUpdate>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SearchJournalRead {
    pub(crate) cursor: String,
    pub(crate) acknowledged_cursor: String,
    pub(crate) batches: Vec<SearchJournalBatch>,
    pub(crate) has_more: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SearchJournalAck {
    pub(crate) acknowledged_cursor: String,
    pub(crate) retained_batches: usize,
}

pub(crate) struct SearchJournal {
    journal_id: String,
    retained: VecDeque<SearchJournalBatch>,
    capacity: usize,
    next_revision: u64,
    acknowledged_revision: u64,
    highest_delivered_revision: u64,
    retained_items: usize,
}

impl SearchJournal {
    pub(crate) fn new(journal_id: &str) -> CoreResult<Self> {
        Self::with_capacity(journal_id, MAX_SEARCH_JOURNAL_BATCHES)
    }

    fn with_capacity(journal_id: &str, capacity: usize) -> CoreResult<Self> {
        if journal_id.is_empty()
            || journal_id.len() > 64
            || !journal_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Err(CoreError::invalid("增量搜索 journalId 无效"));
        }
        if capacity == 0 {
            return Err(CoreError::invalid("增量搜索 journal 容量必须大于零"));
        }
        Ok(Self {
            journal_id: journal_id.to_owned(),
            retained: VecDeque::with_capacity(capacity.min(512)),
            capacity,
            next_revision: 1,
            acknowledged_revision: 0,
            highest_delivered_revision: 0,
            retained_items: 0,
        })
    }

    #[cfg(test)]
    fn with_capacity_for_test(journal_id: &str, capacity: usize) -> CoreResult<Self> {
        Self::with_capacity(journal_id, capacity)
    }

    pub(crate) fn publish_items(&mut self, items: Vec<LibraryItem>) -> CoreResult<()> {
        if items.is_empty() {
            return Ok(());
        }
        if self.retained_items.saturating_add(items.len()) > MAX_PENDING_ITEMS {
            return Err(CoreError::new(
                "search_backpressure",
                "增量搜索待确认结果已达到 50000 项，请先读取并确认",
                true,
            ));
        }
        let additional = items.len().div_ceil(MAX_SEARCH_BATCH_ITEMS);
        self.ensure_capacity(additional, true)?;
        self.retained_items = self.retained_items.saturating_add(items.len());
        for chunk in items.chunks(MAX_SEARCH_BATCH_ITEMS) {
            self.push_batch(chunk.to_vec(), Vec::new(), None);
        }
        Ok(())
    }

    pub(crate) fn publish_source(&mut self, source: SearchSourceUpdate) -> CoreResult<()> {
        self.ensure_capacity(1, true)?;
        self.push_batch(Vec::new(), vec![source], None);
        Ok(())
    }

    pub(crate) fn publish_state(&mut self, state: SearchStateUpdate) -> CoreResult<()> {
        self.ensure_capacity(1, !state.state.is_terminal())?;
        self.push_batch(Vec::new(), Vec::new(), Some(state));
        Ok(())
    }

    pub(crate) fn read(
        &mut self,
        after_cursor: Option<&str>,
        max_batches: usize,
    ) -> CoreResult<SearchJournalRead> {
        let after_revision = match after_cursor {
            Some(cursor) => self.parse_cursor(cursor)?,
            None => 0,
        };
        if after_revision < self.acknowledged_revision {
            return Err(CoreError::new(
                "cursor_expired",
                "增量搜索游标已确认并释放，请从已确认游标继续读取",
                false,
            ));
        }
        let latest_revision = self.next_revision.saturating_sub(1);
        if after_revision > latest_revision {
            return Err(CoreError::invalid("增量搜索游标超出已发布范围"));
        }
        let limit = max_batches.clamp(1, MAX_READ_BATCHES);
        let batches = self
            .retained
            .iter()
            .filter(|batch| batch.revision > after_revision)
            .take(limit)
            .cloned()
            .collect::<Vec<_>>();
        let delivered_revision = batches
            .last()
            .map_or(after_revision, |batch| batch.revision);
        self.highest_delivered_revision = self.highest_delivered_revision.max(delivered_revision);
        let has_more = self
            .retained
            .iter()
            .any(|batch| batch.revision > delivered_revision);
        Ok(SearchJournalRead {
            cursor: self.cursor(delivered_revision),
            acknowledged_cursor: self.cursor(self.acknowledged_revision),
            batches,
            has_more,
        })
    }

    pub(crate) fn acknowledge(&mut self, cursor: &str) -> CoreResult<SearchJournalAck> {
        let revision = self.parse_cursor(cursor)?;
        if revision < self.acknowledged_revision {
            return Err(CoreError::new(
                "cursor_expired",
                "增量搜索游标已确认并释放",
                false,
            ));
        }
        if revision > self.highest_delivered_revision {
            return Err(CoreError::new(
                "cursor_not_delivered",
                "不能确认尚未交付的增量搜索游标",
                false,
            ));
        }
        self.acknowledged_revision = revision;
        while self
            .retained
            .front()
            .is_some_and(|batch| batch.revision <= revision)
        {
            if let Some(batch) = self.retained.pop_front() {
                self.retained_items = self.retained_items.saturating_sub(batch.items.len());
            }
        }
        Ok(SearchJournalAck {
            acknowledged_cursor: self.cursor(revision),
            retained_batches: self.retained.len(),
        })
    }

    pub(crate) fn latest_cursor(&self) -> String {
        self.cursor(self.next_revision.saturating_sub(1))
    }

    pub(crate) fn acknowledged_cursor(&self) -> String {
        self.cursor(self.acknowledged_revision)
    }

    #[cfg(test)]
    fn retained_len(&self) -> usize {
        self.retained.len()
    }

    fn ensure_capacity(&self, additional: usize, reserve_terminal: bool) -> CoreResult<()> {
        let usable_capacity = self.capacity.saturating_sub(usize::from(reserve_terminal));
        if self.retained.len().saturating_add(additional) > usable_capacity {
            return Err(CoreError::new(
                "search_backpressure",
                "增量搜索结果等待确认，请先读取并确认现有批次",
                true,
            ));
        }
        Ok(())
    }

    fn push_batch(
        &mut self,
        items: Vec<LibraryItem>,
        sources: Vec<SearchSourceUpdate>,
        state: Option<SearchStateUpdate>,
    ) {
        let revision = self.next_revision;
        self.next_revision = self.next_revision.saturating_add(1);
        self.retained.push_back(SearchJournalBatch {
            cursor: self.cursor(revision),
            revision,
            items,
            sources,
            state,
        });
    }

    fn cursor(&self, revision: u64) -> String {
        format!("sj.{}.{revision}", self.journal_id)
    }

    fn parse_cursor(&self, cursor: &str) -> CoreResult<u64> {
        let prefix = format!("sj.{}.", self.journal_id);
        let revision = cursor
            .strip_prefix(&prefix)
            .filter(|value| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()))
            .and_then(|value| value.parse::<u64>().ok())
            .ok_or_else(|| CoreError::invalid("增量搜索游标无效或不属于当前搜索"))?;
        if revision >= self.next_revision {
            return Err(CoreError::invalid("增量搜索游标超出已发布范围"));
        }
        Ok(revision)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(index: usize) -> LibraryItem {
        LibraryItem {
            source_id: "source".to_owned(),
            title: format!("item-{index}"),
            url: format!("https://www.lanzouw.com/item-{index}"),
            ..LibraryItem::default()
        }
    }

    fn running(revision: u64) -> SearchStateUpdate {
        SearchStateUpdate {
            state: SearchJournalState::Running,
            operation_revision: revision,
            error_code: None,
            error: None,
        }
    }

    #[test]
    fn test_item_publication_chunks_to_at_most_one_hundred() {
        let mut journal = SearchJournal::new("chunked-search").unwrap();
        journal.publish_items((0..201).map(item).collect()).unwrap();

        let read = journal.read(None, 10).unwrap();
        assert_eq!(read.batches.len(), 3);
        assert_eq!(read.batches[0].items.len(), 100);
        assert_eq!(read.batches[1].items.len(), 100);
        assert_eq!(read.batches[2].items.len(), 1);
        assert!(read.batches.iter().all(|batch| batch.items.len() <= 100));
    }

    #[test]
    fn test_cursor_replay_is_exact_until_ack_then_entries_are_removed() {
        let mut journal = SearchJournal::new("replay-search").unwrap();
        journal.publish_state(running(1)).unwrap();
        journal.publish_items(vec![item(1), item(2)]).unwrap();
        journal
            .publish_source(SearchSourceUpdate {
                source_id: "source".to_owned(),
                title: "Source".to_owned(),
                found: 2,
                completed: true,
                error_code: None,
                error: None,
            })
            .unwrap();

        let first = journal.read(None, 2).unwrap();
        let replay = journal.read(None, 2).unwrap();
        assert_eq!(
            serde_json::to_value(&first).unwrap(),
            serde_json::to_value(&replay).unwrap()
        );
        assert_eq!(first.batches.len(), 2);

        let ack = journal.acknowledge(&first.cursor).unwrap();
        assert_eq!(ack.acknowledged_cursor, first.cursor);
        assert_eq!(journal.retained_len(), 1);
        let next = journal.read(Some(&first.cursor), 2).unwrap();
        assert_eq!(next.batches.len(), 1);
        assert_ne!(next.cursor, first.cursor);
        assert_eq!(next.batches[0].sources[0].source_id, "source");
    }

    #[test]
    fn test_ack_cannot_skip_undelivered_data_or_reuse_expired_cursor() {
        let mut journal = SearchJournal::new("ordered-ack").unwrap();
        journal.publish_state(running(1)).unwrap();
        journal.publish_state(running(2)).unwrap();
        let all = journal.read(None, 1).unwrap();
        let latest = journal.latest_cursor();

        assert_eq!(
            journal.acknowledge(&latest).unwrap_err().code,
            "cursor_not_delivered"
        );
        journal.acknowledge(&all.cursor).unwrap();
        assert_eq!(journal.read(None, 1).unwrap_err().code, "cursor_expired");
    }

    #[test]
    fn test_bounded_journal_applies_backpressure_without_dropping_entries() {
        let mut journal = SearchJournal::with_capacity_for_test("bounded-search", 3).unwrap();
        journal.publish_state(running(1)).unwrap();
        journal.publish_state(running(2)).unwrap();
        let error = journal.publish_state(running(3)).unwrap_err();

        assert_eq!(error.code, "search_backpressure");
        journal
            .publish_state(SearchStateUpdate {
                state: SearchJournalState::Failed,
                operation_revision: 4,
                error_code: Some("search_backpressure".to_owned()),
                error: Some("bounded".to_owned()),
            })
            .unwrap();
        let read = journal.read(None, 10).unwrap();
        assert_eq!(read.batches.len(), 3);
        assert_eq!(
            read.batches[0].state.as_ref().unwrap().operation_revision,
            1
        );
        assert_eq!(
            read.batches[1].state.as_ref().unwrap().operation_revision,
            2
        );
        assert_eq!(
            read.batches[2].state.as_ref().unwrap().state,
            SearchJournalState::Failed
        );
    }
}
