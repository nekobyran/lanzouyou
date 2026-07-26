import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';
import 'package:lanzouyou/pages/public_library/incremental_search_consumer.dart';
import 'package:lanzouyou/pages/public_library/incremental_search_core.dart';

void main() {
  test(
    'creates at most 100 visible items per second and acks after display',
    () async {
      final core = _IncrementalCoreFake();
      final visible = <LibraryItem>[];
      final consumer = IncrementalSearchConsumer(
        core: core,
        viewRatePerSecond: 100,
        viewPumpInterval: const Duration(milliseconds: 100),
        autoPump: false,
        onVisibleItems: visible.addAll,
      );
      addTearDown(consumer.dispose);

      final completed = consumer.start(operationId: 'search-1', query: '工具');
      await _waitUntil(() => consumer.pendingItemCount == 150);

      await consumer.drainVisibleOnce();
      expect(visible, hasLength(10));
      expect(core.acknowledgedCursors, isEmpty);
      for (var index = 1; index < 10; index++) {
        await consumer.drainVisibleOnce();
      }
      expect(visible, hasLength(100));
      expect(core.acknowledgedCursors, ['sj.g0000000000000001.1']);

      for (var index = 0; index < 5; index++) {
        await consumer.drainVisibleOnce();
      }
      await completed;
      expect(visible, hasLength(150));
      expect(core.acknowledgedCursors, [
        'sj.g0000000000000001.1',
        'sj.g0000000000000001.2',
      ]);
      expect(consumer.terminalState, LibraryOperationState.succeeded);
    },
  );

  test('pause resume and cancel use dedicated linear controls', () async {
    final core = _IncrementalCoreFake(terminalInFirstRead: false);
    final consumer = IncrementalSearchConsumer(
      core: core,
      autoPump: false,
      onVisibleItems: (_) {},
    );
    addTearDown(consumer.dispose);
    final running = consumer.start(operationId: 'search-2', query: '工具');
    await _waitUntil(() => core.readCalls > 0);

    await consumer.pause();
    expect(consumer.operation?.state, LibraryOperationState.paused);
    await consumer.resume();
    expect(consumer.operation?.state, LibraryOperationState.running);
    await consumer.cancel();
    expect(core.controls, ['pause', 'resume', 'cancel']);

    core.completeCancelled();
    await running;
    expect(consumer.terminalState, LibraryOperationState.cancelled);
  });
}

class _IncrementalCoreFake implements PublicLibraryIncrementalSearchCore {
  _IncrementalCoreFake({this.terminalInFirstRead = true});

  final bool terminalInFirstRead;
  final List<String> acknowledgedCursors = [];
  final List<String> controls = [];
  int readCalls = 0;
  bool _sent = false;
  bool _cancelled = false;
  bool _cancelBatchSent = false;

  @override
  Future<IncrementalSearchStart> startIncrementalSearch({
    required String operationId,
    required String query,
    List<String> scopeIds = const [],
    LibrarySearchOptions options = const LibrarySearchOptions(),
  }) async => IncrementalSearchStart(
    operationId: operationId,
    cursor: 'sj.g0000000000000001.0',
    state: LibraryOperationState.running,
    revision: 1,
  );

  @override
  Future<IncrementalSearchRead> readIncrementalSearch({
    required String operationId,
    required String cursor,
    String acknowledgeCursor = '',
    int maxBatches = 8,
  }) async {
    readCalls++;
    if (acknowledgeCursor.isNotEmpty) {
      acknowledgedCursors.add(acknowledgeCursor);
    }
    if (_cancelled && !_cancelBatchSent) {
      _cancelBatchSent = true;
      return _cancelledRead(acknowledgeCursor);
    }
    if (_sent || !terminalInFirstRead) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return IncrementalSearchRead(
        cursor: cursor,
        acknowledgedCursor: acknowledgeCursor.isEmpty
            ? 'sj.g0000000000000001.0'
            : acknowledgeCursor,
        batches: const [],
        hasMore: false,
      );
    }
    _sent = true;
    return IncrementalSearchRead(
      cursor: 'sj.g0000000000000001.2',
      acknowledgedCursor: 'sj.g0000000000000001.0',
      hasMore: false,
      batches: [
        IncrementalSearchBatch(
          cursor: 'sj.g0000000000000001.1',
          revision: 1,
          items: _items(0, 100),
          sources: const [],
        ),
        IncrementalSearchBatch(
          cursor: 'sj.g0000000000000001.2',
          revision: 2,
          items: _items(100, 50),
          sources: const [],
          state: const IncrementalSearchStateUpdate(
            state: LibraryOperationState.succeeded,
            operationRevision: 3,
          ),
        ),
      ],
    );
  }

  IncrementalSearchRead _cancelledRead(String acknowledgeCursor) =>
      IncrementalSearchRead(
        cursor: 'sj.g0000000000000001.3',
        acknowledgedCursor: acknowledgeCursor.isEmpty
            ? 'sj.g0000000000000001.0'
            : acknowledgeCursor,
        hasMore: false,
        batches: const [
          IncrementalSearchBatch(
            cursor: 'sj.g0000000000000001.3',
            revision: 3,
            items: [],
            sources: [],
            state: IncrementalSearchStateUpdate(
              state: LibraryOperationState.cancelled,
              operationRevision: 4,
            ),
          ),
        ],
      );

  @override
  Future<IncrementalSearchControl> pauseIncrementalSearch(
    String operationId,
  ) async {
    controls.add('pause');
    return _control(operationId, LibraryOperationState.paused, 2);
  }

  @override
  Future<IncrementalSearchControl> resumeIncrementalSearch(
    String operationId,
  ) async {
    controls.add('resume');
    return _control(operationId, LibraryOperationState.running, 3);
  }

  @override
  Future<IncrementalSearchControl> cancelIncrementalSearch(
    String operationId,
  ) async {
    controls.add('cancel');
    return _control(operationId, LibraryOperationState.cancelling, 4);
  }

  void completeCancelled() => _cancelled = true;

  IncrementalSearchControl _control(
    String operationId,
    LibraryOperationState state,
    int revision,
  ) => IncrementalSearchControl(
    operation: LibraryOperationStatus(
      operationId: operationId,
      kind: 'library_search',
      state: state,
      completedUnits: 0,
      totalUnits: 1,
      bytesTransferred: 0,
      totalBytes: 0,
      itemsFound: 0,
      revision: revision,
    ),
    cursor: 'sj.g0000000000000001.$revision',
  );

  @override
  Future<IncrementalSearchForget> forgetIncrementalSearch(
    String operationId,
  ) async => IncrementalSearchForget(operationId: operationId, forgotten: true);
}

List<LibraryItem> _items(int start, int length) => List.generate(
  length,
  (offset) => LibraryItem(
    sourceId: 'source-${start + offset}',
    title: 'item-${start + offset}',
    url: 'https://www.lanzouw.com/i${start + offset}',
    shareUrl: 'https://www.lanzouw.com/i${start + offset}',
    isFolder: false,
  ),
);

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for incremental search state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
