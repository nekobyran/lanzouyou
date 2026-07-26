import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/config/library_config.dart';
import 'package:lanzou_library_shell/controllers/library_controller.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';

void main() {
  test(
    'search reports per-source progress and cancels the running Rust job',
    () async {
      final core = ControlledOperationCore();
      final controller = LibraryController(config: _config(), core: core);
      addTearDown(controller.dispose);
      await controller.initialize();

      final search = controller.search('工具');
      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(core.searchOperationId, isNotNull);
      expect(controller.searchOperation?.completedUnits, 1);
      expect(controller.searchOperation?.totalUnits, 2);
      expect(controller.searchOperation?.itemsFound, 4);
      expect(controller.searchOperation?.fraction, 0.5);
      expect(controller.canCancelSearch, isTrue);

      await controller.cancelSearch();
      await search;

      expect(core.cancelled, [core.searchOperationId]);
      expect(core.forgotten, [core.searchOperationId]);
      expect(controller.status, LibraryContentStatus.empty);
      expect(controller.searchWasCancelled, isTrue);
      expect(controller.errorMessage, isEmpty);
    },
  );
}

LibraryConfig _config() => LibraryConfig.fromJson({
  'schemaVersion': 1,
  'identity': {
    'projectId': 'search_test',
    'displayName': '搜索测试',
    'applicationId': 'cc.nkbr.searchtest',
    'versionName': '1.0.0',
    'versionCode': 1,
    'windowsExeName': 'search-test',
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

class ControlledOperationCore implements LibraryCore, LibraryOperationCore {
  final Completer<LibrarySearchResult> _search = Completer();
  final List<String?> cancelled = [];
  final List<String?> forgotten = [];
  String? searchOperationId;

  @override
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async => LibraryFolder(
    sourceId: sourceId,
    title: '来源',
    url: shareUrl,
    items: const [],
  );

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) {
    searchOperationId = operationId;
    return _search.future;
  }

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) async =>
      LibraryOperationStatus(
        operationId: operationId,
        kind: 'library_search',
        state: LibraryOperationState.running,
        completedUnits: 1,
        totalUnits: 2,
        bytesTransferred: 0,
        totalBytes: 0,
        itemsFound: 4,
      );

  @override
  Future<void> cancelOperation(String operationId) async {
    cancelled.add(operationId);
    if (!_search.isCompleted) {
      _search.completeError(const LibraryCoreFailure('cancelled', '搜索已取消'));
    }
  }

  @override
  Future<void> forgetOperation(String operationId) async {
    forgotten.add(operationId);
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
