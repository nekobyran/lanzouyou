import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/config/library_config.dart';
import 'package:lanzou_library_shell/controllers/library_controller.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';

void main() {
  test('only the newest synchronously submitted search reaches Rust', () async {
    final core = RaceOperationCore();
    final controller = _controller(core);
    addTearDown(controller.dispose);
    await controller.initialize();

    final stale = controller.search('旧请求');
    final current = controller.search('新请求');
    await _waitUntil(() => core.searchQueries.isNotEmpty);

    expect(core.searchQueries, ['新请求']);
    core.completeAllSuccess();
    await Future.wait([stale, current]);
    expect(controller.query, '新请求');
  });

  test(
    'latest source switch wins out-of-order cancellation responses',
    () async {
      final core = RaceOperationCore()..completeSearchOnCancel = false;
      final controller = _controller(core);
      addTearDown(controller.dispose);
      await controller.initialize();

      final initialSearch = controller.search('初始搜索');
      await _waitUntil(() => core.searchQueries.length == 1);
      final initialOperationId = core.operationIds.single;

      final firstCancel = Completer<void>();
      final secondCancel = Completer<void>();
      core.cancelGates.addAll([firstCancel, secondCancel]);
      final supersededSearch = controller.search('不应执行');
      final latestSwitch = controller.selectSource(
        controller.config.sources[1],
      );
      await _waitUntil(() => core.cancelCalls.length == 2);

      secondCancel.complete();
      await latestSwitch;
      firstCancel.complete();
      await supersededSearch;

      expect(core.searchQueries, ['初始搜索']);
      expect(controller.selectedSource?.sourceId, 'two');
      expect(controller.query, isEmpty);

      core.completeCancelled(initialOperationId);
      await initialSearch;
    },
  );

  test('cancel retries while the native operation is registering', () async {
    final core = RaceOperationCore()..cancelNotFoundRemaining = 2;
    final controller = _controller(core);
    addTearDown(controller.dispose);
    await controller.initialize();

    final search = controller.search('注册竞态');
    await _waitUntil(() => core.searchQueries.isNotEmpty);
    await controller.cancelSearch();
    await search.timeout(const Duration(seconds: 2));

    expect(core.cancelCalls, hasLength(3));
    expect(controller.searchWasCancelled, isTrue);
    expect(controller.searchCancellationError, isEmpty);
  });

  test(
    'a real cancellation failure is visible and remains retryable',
    () async {
      final core = RaceOperationCore()
        ..cancelFailure = const LibraryCoreFailure(
          'coreUnavailable',
          '取消控制暂时不可用',
          retriable: true,
        )
        ..completeSearchOnCancel = false;
      final controller = _controller(core);
      addTearDown(controller.dispose);
      await controller.initialize();

      final search = controller.search('取消失败');
      await _waitUntil(() => core.searchQueries.isNotEmpty);
      await controller.cancelSearch();

      expect(controller.isSearchCancelling, isFalse);
      expect(controller.searchOperation?.state, LibraryOperationState.running);
      expect(controller.searchCancellationError, '取消控制暂时不可用');
      expect(controller.canCancelSearch, isTrue);

      core.completeAllSuccess();
      await search;
      expect(controller.searchCancellationError, isEmpty);
    },
  );

  test(
    'a stale running poll cannot roll cancellation state backward',
    () async {
      final status = Completer<LibraryOperationStatus>();
      final core = RaceOperationCore()
        ..completeSearchOnCancel = false
        ..statusGate = status;
      final controller = _controller(core);
      addTearDown(controller.dispose);
      await controller.initialize();

      final search = controller.search('陈旧进度');
      await _waitUntil(() => core.statusCalls == 1);
      await controller.cancelSearch();
      expect(
        controller.searchOperation?.state,
        LibraryOperationState.cancelling,
      );

      status.complete(core.statusFor(LibraryOperationState.running));
      await _waitUntil(() => controller.searchOperation?.completedUnits == 1);
      expect(
        controller.searchOperation?.state,
        LibraryOperationState.cancelling,
      );
      expect(controller.isSearchCancelling, isTrue);
      expect(controller.canCancelSearch, isFalse);

      core.completeAllCancelled();
      await search;
    },
  );

  test('a terminal progress state never exposes cancel again', () async {
    final core = RaceOperationCore()
      ..completeSearchOnCancel = false
      ..fixedStatusState = LibraryOperationState.cancelled;
    final controller = _controller(core);
    addTearDown(controller.dispose);
    await controller.initialize();

    final search = controller.search('终态');
    await _waitUntil(
      () =>
          controller.searchOperation?.state == LibraryOperationState.cancelled,
    );

    expect(controller.canCancelSearch, isFalse);
    expect(controller.isSearchCancelling, isTrue);
    core.completeAllCancelled();
    await search;
  });

  test(
    'disposing an active search cancels without post-dispose notify',
    () async {
      final core = RaceOperationCore();
      final controller = _controller(core);
      await controller.initialize();

      final search = controller.search('退出页面');
      await _waitUntil(() => core.searchQueries.isNotEmpty);
      controller.dispose();

      await expectLater(search.timeout(const Duration(seconds: 2)), completes);
      expect(core.cancelCalls, isNotEmpty);
      await _waitUntil(() => core.forgotten.isNotEmpty);
    },
  );
}

LibraryController _controller(RaceOperationCore core) =>
    LibraryController(config: _config(), core: core);

LibraryConfig _config() => LibraryConfig.fromJson({
  'schemaVersion': 1,
  'identity': {
    'projectId': 'search_race_test',
    'displayName': '搜索竞态测试',
    'applicationId': 'cc.example.searchrace',
    'versionName': '1.0.0',
    'versionCode': 1,
    'windowsExeName': 'search-race-test',
  },
  'branding': {
    'seedColor': '#2563EB',
    'themeMode': 'system',
    'officialUrl': '',
    'publisher': '',
    'logoAsset': 'assets/runtime/logo.png',
  },
  'sources': [
    {
      'sourceId': 'one',
      'title': '来源一',
      'shareUrl': 'https://www.lanzouw.com/bone',
      'password': '',
      'searchable': true,
      'recommended': true,
    },
    {
      'sourceId': 'two',
      'title': '来源二',
      'shareUrl': 'https://www.lanzoui.com/btwo',
      'password': '',
      'searchable': true,
      'recommended': false,
    },
  ],
  'features': {
    'browse': true,
    'search': true,
    'download': true,
    'showDescription': true,
  },
});

class RaceOperationCore implements LibraryCore, LibraryOperationCore {
  final List<String> searchQueries = [];
  final List<String> operationIds = [];
  final List<String> cancelCalls = [];
  final List<String> forgotten = [];
  final List<String> browseSourceIds = [];
  final Queue<Completer<void>> cancelGates = Queue();
  final Map<String, Completer<LibrarySearchResult>> _searches = {};

  int cancelNotFoundRemaining = 0;
  LibraryCoreFailure? cancelFailure;
  bool completeSearchOnCancel = true;
  Completer<LibraryOperationStatus>? statusGate;
  LibraryOperationState fixedStatusState = LibraryOperationState.running;
  int statusCalls = 0;

  @override
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async {
    browseSourceIds.add(sourceId);
    return LibraryFolder(
      sourceId: sourceId,
      title: sourceId,
      url: shareUrl,
      items: const [],
    );
  }

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) {
    final id = operationId!;
    searchQueries.add(query);
    operationIds.add(id);
    final completer = Completer<LibrarySearchResult>();
    _searches[id] = completer;
    return completer.future;
  }

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) {
    statusCalls++;
    final gate = statusGate;
    if (gate != null) return gate.future;
    return Future.value(statusFor(fixedStatusState, operationId: operationId));
  }

  LibraryOperationStatus statusFor(
    LibraryOperationState state, {
    String? operationId,
  }) => LibraryOperationStatus(
    operationId: operationId ?? operationIds.last,
    kind: 'library_search',
    state: state,
    completedUnits: 1,
    totalUnits: 2,
    bytesTransferred: 0,
    totalBytes: 0,
    itemsFound: 2,
  );

  @override
  Future<void> cancelOperation(String operationId) async {
    cancelCalls.add(operationId);
    if (cancelNotFoundRemaining > 0) {
      cancelNotFoundRemaining--;
      throw const LibraryCoreFailure('operation_not_found', '尚未注册');
    }
    final failure = cancelFailure;
    if (failure != null) throw failure;
    if (cancelGates.isNotEmpty) await cancelGates.removeFirst().future;
    if (completeSearchOnCancel) completeCancelled(operationId);
  }

  @override
  Future<void> forgetOperation(String operationId) async {
    forgotten.add(operationId);
  }

  void completeCancelled(String operationId) {
    final search = _searches[operationId];
    if (search != null && !search.isCompleted) {
      search.completeError(const LibraryCoreFailure('cancelled', '搜索已取消'));
    }
  }

  void completeAllCancelled() {
    for (final operationId in _searches.keys.toList(growable: false)) {
      completeCancelled(operationId);
    }
  }

  void completeAllSuccess() {
    for (final search in _searches.values) {
      if (!search.isCompleted) search.complete(const LibrarySearchResult());
    }
  }

  @override
  Future<LibraryCollectResult> collect({
    required List<LibraryItem> items,
    required List<LibrarySource> sources,
  }) async => LibraryCollectResult(files: items, foldersScanned: 0);

  @override
  Future<LibraryDescribeResult> describe({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryDescribeResult(description: '');

  @override
  Future<LibraryProbeResult> probe(LibrarySource source) async =>
      LibraryProbeResult(
        source: LibraryProbeSource(
          sourceId: source.sourceId,
          title: source.title,
          shareUrl: source.shareUrl,
          searchable: source.searchable,
        ),
        folder: LibraryFolder(
          sourceId: source.sourceId,
          title: source.title,
          url: source.shareUrl,
          items: const [],
        ),
      );

  @override
  Future<LibraryResolveResult> resolve({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryResolveResult(url: '', fileName: '');
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not reached', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
