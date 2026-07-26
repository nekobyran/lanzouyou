import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';

import 'incremental_search_core.dart';

typedef IncrementalVisibleItemsCallback =
    void Function(List<LibraryItem> items);
typedef IncrementalSourcesCallback =
    void Function(List<IncrementalSearchSourceUpdate> sources);
typedef IncrementalOperationCallback =
    void Function(LibraryOperationStatus operation);
typedef IncrementalErrorCallback = void Function(Object error);

/// Pulls Rust journal batches without flooding the Flutter tree.
///
/// Rust may search at full speed. This consumer keeps at most 400 unseen items,
/// creates at most [viewRatePerSecond] visible items, notifies once per pump,
/// and acknowledges a journal batch only after all of its items were exposed.
class IncrementalSearchConsumer {
  IncrementalSearchConsumer({
    required this.core,
    required this.onVisibleItems,
    this.onSources,
    this.onOperation,
    this.onError,
    this.viewRatePerSecond = 100,
    this.viewPumpInterval = const Duration(milliseconds: 100),
    this.readIdleDelay = const Duration(milliseconds: 40),
    this.autoPump = true,
  }) : assert(viewRatePerSecond > 0 && viewRatePerSecond <= 1000),
       assert(viewPumpInterval > Duration.zero),
       assert(readIdleDelay > Duration.zero);

  final PublicLibraryIncrementalSearchCore core;
  final IncrementalVisibleItemsCallback onVisibleItems;
  final IncrementalSourcesCallback? onSources;
  final IncrementalOperationCallback? onOperation;
  final IncrementalErrorCallback? onError;
  final int viewRatePerSecond;
  final Duration viewPumpInterval;
  final Duration readIdleDelay;

  @visibleForTesting
  final bool autoPump;

  final Queue<_PendingSearchBatch> _pending = Queue();
  final Set<String> _visibleKeys = <String>{};
  final Set<String> _queuedCursors = <String>{};
  Timer? _viewTimer;
  Completer<void>? _completion;
  Future<void>? _drainFuture;
  String? _operationId;
  String _readCursor = '';
  String _acknowledgeCursor = '';
  int _lastJournalRevision = 0;
  bool _active = false;
  bool _disposed = false;
  bool _cancelRequested = false;

  LibraryOperationStatus? operation;
  LibraryOperationState? terminalState;
  int pendingItemCount = 0;

  bool get isActive => _active;

  Future<void> start({
    required String operationId,
    required String query,
    List<String> scopeIds = const [],
    LibrarySearchOptions options = const LibrarySearchOptions(),
  }) async {
    if (_disposed) throw StateError('incremental search consumer is disposed');
    if (_active || _completion != null) {
      throw StateError('incremental search consumer is single-use');
    }
    _active = true;
    _operationId = operationId;
    _completion = Completer<void>();
    try {
      final started = await core.startIncrementalSearch(
        operationId: operationId,
        query: query,
        scopeIds: scopeIds,
        options: options,
      );
      if (started.operationId != operationId) {
        throw const FormatException('incremental search identity mismatch');
      }
      _readCursor = started.cursor;
      operation = LibraryOperationStatus(
        operationId: operationId,
        kind: 'library_search',
        state: started.state,
        completedUnits: 0,
        totalUnits: 0,
        bytesTransferred: 0,
        totalBytes: 0,
        itemsFound: 0,
        revision: started.revision,
      );
      onOperation?.call(operation!);
      if (started.state.isTerminal) terminalState = started.state;
      if (autoPump) {
        _viewTimer = Timer.periodic(
          viewPumpInterval,
          (_) => unawaited(drainVisibleOnce()),
        );
      }
      unawaited(_readLoop());
    } on Object catch (error, stackTrace) {
      _finishError(error, stackTrace);
    }
    return _completion!.future;
  }

  Future<void> _readLoop() async {
    try {
      while (_active && !_disposed && terminalState == null) {
        if (pendingItemCount >= _maxPendingVisibleItems) {
          await Future<void>.delayed(readIdleDelay);
          continue;
        }
        final operationId = _operationId!;
        final acknowledgeCursor = _acknowledgeCursor;
        final read = await core.readIncrementalSearch(
          operationId: operationId,
          cursor: _readCursor,
          acknowledgeCursor: acknowledgeCursor,
          maxBatches: _maxReadBatches,
        );
        if (!_active || _disposed) return;
        if (acknowledgeCursor.isNotEmpty) {
          if (read.acknowledgedCursor != acknowledgeCursor) {
            throw const FormatException(
              'incremental search ack cursor mismatch',
            );
          }
          if (_acknowledgeCursor == acknowledgeCursor) {
            _acknowledgeCursor = '';
          }
        }
        _acceptRead(read);
        await _acknowledgeEmptyHeadBatches();
        if (terminalState != null) break;
        if (read.batches.isEmpty || !read.hasMore) {
          await Future<void>.delayed(readIdleDelay);
        }
      }
      await _finishIfReady();
    } on Object catch (error, stackTrace) {
      _finishError(error, stackTrace);
    }
  }

  void _acceptRead(IncrementalSearchRead read) {
    if (read.cursor.isEmpty) {
      throw const FormatException('incremental search read cursor is empty');
    }
    for (final batch in read.batches) {
      if (!_queuedCursors.add(batch.cursor)) continue;
      if (batch.revision <= _lastJournalRevision) {
        throw const FormatException('incremental search revision regressed');
      }
      _lastJournalRevision = batch.revision;
      pendingItemCount += batch.items.length;
      _pending.add(_PendingSearchBatch(batch));
      if (batch.sources.isNotEmpty) onSources?.call(batch.sources);
      final state = batch.state;
      if (state != null) {
        final current = operation;
        if (current != null && state.operationRevision >= current.revision) {
          operation = LibraryOperationStatus(
            operationId: current.operationId,
            kind: current.kind,
            state: state.state,
            completedUnits: current.completedUnits,
            totalUnits: current.totalUnits,
            bytesTransferred: current.bytesTransferred,
            totalBytes: current.totalBytes,
            itemsFound: current.itemsFound,
            revision: state.operationRevision,
          );
          onOperation?.call(operation!);
        }
        if (state.state.isTerminal) terminalState = state.state;
      }
    }
    _readCursor = read.cursor;
  }

  @visibleForTesting
  Future<void> drainVisibleOnce() {
    final active = _drainFuture;
    if (active != null) return active;
    late final Future<void> task;
    task = _drainVisible().whenComplete(() {
      if (identical(_drainFuture, task)) _drainFuture = null;
    });
    _drainFuture = task;
    return task;
  }

  Future<void> _drainVisible() async {
    if (_disposed || !_active) return;
    var allowance =
        (viewRatePerSecond * viewPumpInterval.inMicroseconds ~/ 1000000).clamp(
          1,
          viewRatePerSecond,
        );
    final visible = <LibraryItem>[];
    String? acknowledgeCursor;
    while (_pending.isNotEmpty) {
      final head = _pending.first;
      while (allowance > 0 && head.index < head.batch.items.length) {
        final item = head.batch.items[head.index++];
        pendingItemCount--;
        allowance--;
        if (_visibleKeys.add(item.stableKey)) visible.add(item);
      }
      if (head.index < head.batch.items.length) break;
      acknowledgeCursor = head.batch.cursor;
      _pending.removeFirst();
      if (allowance == 0) break;
    }
    if (visible.isNotEmpty) onVisibleItems(List.unmodifiable(visible));
    if (acknowledgeCursor != null) {
      _acknowledgeCursor = acknowledgeCursor;
      if (terminalState != null && _pending.isNotEmpty) {
        await _flushAcknowledgement();
      }
    }
    await _finishIfReady();
  }

  Future<void> _acknowledgeEmptyHeadBatches() async {
    if (_pending.isEmpty || _pending.first.batch.items.isNotEmpty) return;
    await drainVisibleOnce();
  }

  Future<void> pause() => _control(core.pauseIncrementalSearch);

  Future<void> resume() => _control(core.resumeIncrementalSearch);

  Future<void> cancel() async {
    _cancelRequested = true;
    await _control(core.cancelIncrementalSearch);
  }

  Future<void> _control(
    Future<IncrementalSearchControl> Function(String operationId) action,
  ) async {
    final operationId = _operationId;
    if (_disposed || !_active || operationId == null || terminalState != null) {
      return;
    }
    final result = await action(operationId);
    if (result.operation.operationId != operationId ||
        result.operation.kind != 'library_search') {
      throw const FormatException(
        'incremental search control identity mismatch',
      );
    }
    final current = operation;
    if (current == null || result.operation.revision >= current.revision) {
      operation = result.operation;
      onOperation?.call(result.operation);
    }
    if (result.operation.state.isTerminal) {
      terminalState = result.operation.state;
      await _finishIfReady();
    }
  }

  Future<void> _finishIfReady() async {
    if (!_active || terminalState == null || _pending.isNotEmpty) return;
    _active = false;
    _viewTimer?.cancel();
    _viewTimer = null;
    final operationId = _operationId!;
    await _flushAcknowledgement();
    try {
      await core.forgetIncrementalSearch(operationId);
    } on Object {
      // The bounded Rust registry also evicts terminal searches.
    }
    if (_completion case final completion? when !completion.isCompleted) {
      completion.complete();
    }
  }

  Future<void> _flushAcknowledgement() async {
    final acknowledgeCursor = _acknowledgeCursor;
    if (acknowledgeCursor.isEmpty) return;
    final read = await core.readIncrementalSearch(
      operationId: _operationId!,
      cursor: _readCursor,
      acknowledgeCursor: acknowledgeCursor,
      maxBatches: 1,
    );
    if (read.acknowledgedCursor != acknowledgeCursor ||
        read.batches.isNotEmpty) {
      throw const FormatException('incremental search final ack mismatch');
    }
    if (_acknowledgeCursor == acknowledgeCursor) _acknowledgeCursor = '';
  }

  void _finishError(Object error, StackTrace stackTrace) {
    if (_disposed) return;
    _active = false;
    _viewTimer?.cancel();
    _viewTimer = null;
    onError?.call(error);
    if (_completion case final completion? when !completion.isCompleted) {
      completion.completeError(error, stackTrace);
    }
  }

  void dispose() {
    if (_disposed) return;
    final operationId = _operationId;
    final shouldCancel =
        _active &&
        terminalState == null &&
        operationId != null &&
        !_cancelRequested;
    _disposed = true;
    _active = false;
    _viewTimer?.cancel();
    _viewTimer = null;
    _pending.clear();
    pendingItemCount = 0;
    if (shouldCancel) {
      unawaited(core.cancelIncrementalSearch(operationId));
    }
    if (_completion case final completion? when !completion.isCompleted) {
      completion.complete();
    }
  }
}

class _PendingSearchBatch {
  _PendingSearchBatch(this.batch);

  final IncrementalSearchBatch batch;
  int index = 0;
}

const _maxPendingVisibleItems = 400;
const _maxReadBatches = 8;
