import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/config/library_config.dart';
import 'package:lanzou_library_shell/controllers/library_controller.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';

void main() {
  test(
    'large pagination de-duplicates once and emits only state transitions',
    () async {
      final core = PerformanceCore.largeCatalog();
      final controller = LibraryController(config: _config(), core: core);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.items, hasLength(10000));

      var notifications = 0;
      controller.addListener(() => notifications++);
      final stopwatch = Stopwatch()..start();
      await controller.loadMore();
      stopwatch.stop();

      expect(controller.items, hasLength(15000));
      expect(
        controller.items.map((item) => item.stableKey).toSet(),
        hasLength(15000),
      );
      expect(notifications, 2, reason: '大列表不得按条目通知 UI');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    },
  );

  test('load-more is single-flight across repeated viewport signals', () async {
    final core = PaginationCore();
    final controller = LibraryController(config: _config(), core: core);
    addTearDown(controller.dispose);
    await controller.initialize();

    final first = controller.loadMore();
    final second = controller.loadMore();
    await Future<void>.delayed(Duration.zero);

    expect(core.browseCalls, 2, reason: '初始化一次，下一页只能请求一次');
    core.completeNextPage();
    await Future.wait([first, second]);
    expect(controller.items.map((item) => item.title), ['第一页', '第二页']);
  });

  test('load-more respects the server next-page ready timestamp', () async {
    final core = PaginationCore(
      nextPageReadyAtMs: DateTime.now()
          .add(const Duration(milliseconds: 90))
          .millisecondsSinceEpoch,
    );
    final controller = LibraryController(config: _config(), core: core);
    addTearDown(controller.dispose);
    await controller.initialize();

    final loading = controller.loadMore();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(core.browseCalls, 1, reason: '限流时间到达前不得发下一页请求');
    core.completeNextPage();
    await loading;

    expect(core.browseCalls, 2);
    expect(controller.items.map((item) => item.title), ['第一页', '第二页']);
  });

  test('load-more failure keeps the current page visible', () async {
    final core = PaginationCore(nextPageFailure: true);
    final controller = LibraryController(config: _config(), core: core);
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.loadMore();

    expect(controller.status, LibraryContentStatus.data);
    expect(controller.items.single.title, '第一页');
    expect(controller.folder?.hasMore, isTrue);
  });

  test(
    'identical progress is silent and polling stops with the operation',
    () async {
      final core = PerformanceCore.pendingSearch();
      final controller = LibraryController(config: _config(), core: core);
      addTearDown(controller.dispose);
      await controller.initialize();

      var notifications = 0;
      controller.addListener(() => notifications++);
      final search = controller.search('性能');
      await _waitUntil(() => core.statusCalls >= 5);

      expect(notifications, 1, reason: '相同进度不得触发重复重建');
      core.completeSearch();
      await search;
      final terminalStatusCalls = core.statusCalls;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(core.statusCalls, terminalStatusCalls);
      expect(core.forgottenOperations, 1);
    },
  );

  test(
    'asset fetches are de-duplicated, bounded and notification-free',
    () async {
      final core = AssetPerformanceCore();
      final controller = LibraryController(config: _config(), core: core);
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);

      final duplicateA = controller.loadAsset(
        'https://assets.invalid/shared.png',
      );
      final duplicateB = controller.loadAsset(
        'https://assets.invalid/shared.png',
      );
      expect(identical(duplicateA, duplicateB), isTrue);
      final requests = <Future<Object?>>[
        duplicateA,
        for (var index = 0; index < 99; index++)
          controller.loadAsset('https://assets.invalid/$index.png'),
      ];
      await Future<void>.delayed(Duration.zero);

      expect(core.activeAssetFetches, 6);
      expect(core.maxActiveAssetFetches, 6);
      expect(core.assetCalls, 6);
      core.releaseAssets();
      final results = await Future.wait(requests);

      expect(core.maxActiveAssetFetches, lessThanOrEqualTo(6));
      expect(core.assetCalls, 38, reason: '队列最多保留 6 个活动请求和 32 个等待请求');
      expect(results.whereType<List<int>>(), hasLength(38));
      expect(notifications, 0, reason: '图标 Future 只能刷新自己的 FutureBuilder');
    },
  );

  test('controller disposal closes an owned core lifecycle once', () async {
    final core = LifecyclePerformanceCore();
    final controller = LibraryController(config: _config(), core: core);

    controller.dispose();
    controller.dispose();
    await _waitUntil(() => core.closeCalls == 1);
    expect(core.closeCalls, 1);
  });
}

class PerformanceCore implements LibraryCore, LibraryOperationCore {
  PerformanceCore.largeCatalog() : _largeCatalog = true;

  PerformanceCore.pendingSearch() : _largeCatalog = false;

  final bool _largeCatalog;
  final Completer<LibrarySearchResult> _search = Completer();
  int browseCalls = 0;
  int statusCalls = 0;
  int forgottenOperations = 0;
  String operationId = '';

  @override
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async {
    browseCalls++;
    if (!_largeCatalog) {
      return LibraryFolder(
        sourceId: sourceId,
        title: '主源',
        url: shareUrl,
        items: const [],
      );
    }
    final start = page == 1 ? 0 : 5000;
    final end = page == 1 ? 10000 : 15000;
    return LibraryFolder(
      sourceId: sourceId,
      title: '大型目录',
      url: shareUrl,
      page: page,
      hasMore: page == 1,
      items: List.generate(end - start, (offset) => _item(start + offset)),
    );
  }

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) {
    this.operationId = operationId!;
    return _search.future;
  }

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) async {
    statusCalls++;
    return LibraryOperationStatus(
      operationId: operationId,
      kind: 'library_search',
      state: LibraryOperationState.running,
      completedUnits: 0,
      totalUnits: 1,
      bytesTransferred: 0,
      totalBytes: 0,
      itemsFound: 0,
    );
  }

  @override
  Future<void> cancelOperation(String operationId) async {
    if (!_search.isCompleted) {
      _search.completeError(const LibraryCoreFailure('cancelled', '搜索已取消'));
    }
  }

  @override
  Future<void> forgetOperation(String operationId) async {
    forgottenOperations++;
  }

  void completeSearch() {
    if (!_search.isCompleted) {
      _search.complete(const LibrarySearchResult());
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
        folder: await browse(
          sourceId: source.sourceId,
          shareUrl: source.shareUrl,
        ),
      );

  @override
  Future<LibraryResolveResult> resolve({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryResolveResult(url: '', fileName: '');
}

class PaginationCore implements LibraryCore {
  PaginationCore({this.nextPageReadyAtMs, this.nextPageFailure = false});

  final int? nextPageReadyAtMs;
  final bool nextPageFailure;
  final Completer<LibraryFolder> _nextPage = Completer<LibraryFolder>();
  int browseCalls = 0;

  @override
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async {
    browseCalls++;
    if (page == 1) {
      return LibraryFolder(
        sourceId: sourceId,
        title: '分页目录',
        url: shareUrl,
        page: 1,
        hasMore: true,
        nextPageReadyAtMs: nextPageReadyAtMs,
        items: [_itemNamed('第一页', 'page-one')],
      );
    }
    if (nextPageFailure) {
      throw const LibraryCoreFailure('rate_limited', '下一页暂时不可用');
    }
    return _nextPage.future;
  }

  void completeNextPage() {
    if (_nextPage.isCompleted) return;
    _nextPage.complete(
      LibraryFolder(
        sourceId: 'main',
        title: '分页目录',
        url: 'https://www.lanzouw.com/bperformance',
        page: 2,
        items: [_itemNamed('第二页', 'page-two')],
      ),
    );
  }

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) async => const LibrarySearchResult();

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
        folder: await browse(
          sourceId: source.sourceId,
          shareUrl: source.shareUrl,
        ),
      );

  @override
  Future<LibraryResolveResult> resolve({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryResolveResult(url: '', fileName: '');
}

class AssetPerformanceCore extends PerformanceCore implements LibraryAssetCore {
  AssetPerformanceCore() : super.pendingSearch();

  final Completer<void> _assetGate = Completer<void>();
  int assetCalls = 0;
  int activeAssetFetches = 0;
  int maxActiveAssetFetches = 0;

  @override
  Future<LibraryAssetResult> fetchAsset({required String url}) async {
    assetCalls++;
    activeAssetFetches++;
    if (activeAssetFetches > maxActiveAssetFetches) {
      maxActiveAssetFetches = activeAssetFetches;
    }
    await _assetGate.future;
    activeAssetFetches--;
    return LibraryAssetResult.fromJson(const {
      'mediaType': 'image/png',
      'bytesBase64': 'iVBORw0KGgo=',
    });
  }

  void releaseAssets() {
    if (!_assetGate.isCompleted) _assetGate.complete();
  }
}

class LifecyclePerformanceCore extends PerformanceCore
    implements LibraryCoreLifecycle {
  LifecyclePerformanceCore() : super.pendingSearch();

  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

LibraryItem _item(int index) => LibraryItem(
  sourceId: 'main',
  title: '文件 $index',
  url: 'https://www.lanzouw.com/i$index',
  shareUrl: 'https://www.lanzouw.com/i$index',
  isFolder: false,
);

LibraryItem _itemNamed(String title, String id) => LibraryItem(
  sourceId: 'main',
  title: title,
  url: 'https://www.lanzouw.com/i$id',
  shareUrl: 'https://www.lanzouw.com/i$id',
  isFolder: false,
);

LibraryConfig _config() => LibraryConfig.fromJson({
  'schemaVersion': 1,
  'identity': {
    'projectId': 'performance_test',
    'displayName': '性能测试',
    'applicationId': 'cc.nkbr.performancetest',
    'versionName': '1.0.0',
    'versionCode': 1,
    'windowsExeName': 'performance_test',
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
      'sourceId': 'main',
      'title': '主源',
      'shareUrl': 'https://www.lanzouw.com/bperformance',
      'password': '',
      'searchable': true,
      'recommended': true,
    },
  ],
  'features': {
    'browse': true,
    'search': true,
    'download': true,
    'showDescription': true,
  },
});

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
