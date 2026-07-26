import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/config/library_config.dart';
import 'package:lanzou_library_shell/controllers/library_controller.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';

void main() {
  test(
    'a stale description response cannot overwrite the later selection',
    () async {
      final core = ControlledLibraryCore();
      final controller = LibraryController(config: _config(), core: core);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(core.describeCalls, isEmpty, reason: '浏览目录时不得批量预取简介');

      controller.selectItem(_firstItem);
      await _waitUntil(() => core.describeCalls.length == 1);
      controller.selectItem(_secondItem);
      await _waitUntil(() => core.describeCalls.length == 2);
      expect(core.describeCalls.map((call) => call.stableUrl), [
        _firstItem.navigationUrl,
        _secondItem.navigationUrl,
      ]);

      core.completers[_firstItem.navigationUrl]!.complete(
        const LibraryDescribeResult(description: '旧选择的简介'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.selectedItem?.stableKey, _secondItem.stableKey);
      expect(controller.detailDescription, isNot('旧选择的简介'));

      core.completers[_secondItem.navigationUrl]!.complete(
        const LibraryDescribeResult(description: '当前选择的简介'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.selectedItem?.stableKey, _secondItem.stableKey);
      expect(controller.detailDescription, '当前选择的简介');
    },
  );

  test(
    'rapid selections coalesce and an in-flight description is reused',
    () async {
      final core = ControlledLibraryCore();
      final controller = LibraryController(config: _config(), core: core);
      addTearDown(controller.dispose);

      for (var index = 0; index < 500; index++) {
        controller.selectItem(
          LibraryItem(
            sourceId: 'main',
            title: '文件 $index',
            url: 'https://www.lanzouw.com/i$index',
            shareUrl: 'https://www.lanzouw.com/i$index',
            isFolder: false,
          ),
        );
      }
      await _waitUntil(() => core.describeCalls.length == 1);
      expect(core.describeCalls.single.stableUrl, endsWith('i499'));

      final selected = controller.selectedItem!;
      controller.selectItem(selected);
      await Future<void>.delayed(Duration.zero);
      expect(core.describeCalls, hasLength(1));

      core.completers[selected.navigationUrl]!.complete(
        const LibraryDescribeResult(description: '唯一请求结果'),
      );
      await _waitUntil(() => !controller.isDescriptionLoading);
      expect(controller.detailDescription, '唯一请求结果');
    },
  );

  test(
    'description cache is LRU-bounded instead of growing with the catalog',
    () async {
      final core = ImmediateDescriptionCore();
      final controller = LibraryController(config: _config(), core: core);
      addTearDown(controller.dispose);

      LibraryItem item(int index) => LibraryItem(
        sourceId: 'main',
        title: '文件 $index',
        url: 'https://www.lanzouw.com/icache$index',
        shareUrl: 'https://www.lanzouw.com/icache$index',
        isFolder: false,
      );

      for (var index = 0; index < 65; index++) {
        controller.selectItem(item(index));
        await _waitUntil(() => !controller.isDescriptionLoading);
      }
      expect(core.describeCallCount, 65);

      controller.selectItem(item(0));
      await _waitUntil(() => !controller.isDescriptionLoading);
      expect(core.describeCallCount, 66, reason: '第 65 个条目必须淘汰最早的缓存');
    },
  );

  test(
    'existing descriptions and disabled descriptions never call describe',
    () async {
      final existingCore = ControlledLibraryCore();
      final existingController = LibraryController(
        config: _config(),
        core: existingCore,
      );
      addTearDown(existingController.dispose);
      existingController.selectItem(
        const LibraryItem(
          sourceId: 'main',
          title: '已有简介',
          url: 'https://www.lanzouw.com/iexisting',
          shareUrl: 'https://www.lanzouw.com/iexisting',
          isFolder: false,
          description: '目录已返回简介',
        ),
      );
      expect(existingCore.describeCalls, isEmpty);
      expect(existingController.detailDescription, '目录已返回简介');

      final disabledCore = ControlledLibraryCore();
      final disabledController = LibraryController(
        config: _config(showDescription: false),
        core: disabledCore,
      );
      addTearDown(disabledController.dispose);
      disabledController.selectItem(_firstItem);
      expect(disabledCore.describeCalls, isEmpty);
    },
  );

  test(
    'remote icons are fetched only through the bounded Rust asset core',
    () async {
      final core = ControlledAssetCore();
      final controller = LibraryController(config: _config(), core: core);
      addTearDown(controller.dispose);

      final values = await Future.wait([
        controller.loadAsset('https://image.dmpdmp.com/icon.png'),
        controller.loadAsset('https://image.dmpdmp.com/icon.png'),
      ]);

      expect(core.assetCalls, 1);
      expect(values.first, isNotNull);
      expect(values.last, orderedEquals(values.first!));

      final unsupported = LibraryController(
        config: _config(),
        core: ControlledLibraryCore(),
      );
      addTearDown(unsupported.dispose);
      expect(
        await unsupported.loadAsset('https://example.invalid/icon.png'),
        isNull,
      );
    },
  );

  test(
    'password-protected sources never display encoded remote errors',
    () async {
      final core = ControlledLibraryCore()
        ..browseFailure = const LibraryCoreFailure(
          'remote',
          'remote echoed private%2Dvalue',
          retriable: true,
        );
      final controller = LibraryController(config: _config(), core: core);
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(controller.status, LibraryContentStatus.error);
      expect(controller.errorMessage, '软件目录加载失败，请稍后重试');
      expect(controller.errorMessage, isNot(contains('private')));
    },
  );
}

const _firstItem = LibraryItem(
  sourceId: 'main',
  title: '第一个文件',
  url: 'https://www.lanzouw.com/ifirst',
  shareUrl: 'https://www.lanzouw.com/ifirst',
  isFolder: false,
);

const _secondItem = LibraryItem(
  sourceId: 'main',
  title: '第二个文件',
  url: 'https://www.lanzouw.com/isecond',
  shareUrl: 'https://www.lanzouw.com/isecond',
  isFolder: false,
);

LibraryConfig _config({bool showDescription = true}) => LibraryConfig.fromJson({
  'schemaVersion': 1,
  'identity': {
    'projectId': 'description_test',
    'displayName': '简介测试',
    'applicationId': 'cc.example.descriptiontest',
    'versionName': '1.0.0',
    'versionCode': 1,
    'windowsExeName': 'description_test',
  },
  'branding': {
    'seedColor': '#2563EB',
    'themeMode': 'light',
    'officialUrl': '',
    'publisher': '',
    'logoAsset': 'assets/runtime/logo.png',
  },
  'sources': [
    {
      'sourceId': 'main',
      'title': '主源',
      'shareUrl': 'https://www.lanzouw.com/broot',
      'password': 'private-value',
      'searchable': true,
      'recommended': true,
    },
  ],
  'features': {
    'browse': true,
    'search': true,
    'download': true,
    'showDescription': showDescription,
  },
});

class ControlledLibraryCore implements LibraryCore {
  final List<DescribeCall> describeCalls = [];
  final Map<String, Completer<LibraryDescribeResult>> completers = {};
  LibraryCoreFailure? browseFailure;

  @override
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async {
    final failure = browseFailure;
    if (failure != null) throw failure;
    return const LibraryFolder(
      sourceId: 'main',
      title: '主源',
      url: 'https://www.lanzouw.com/broot',
      items: [_firstItem, _secondItem],
    );
  }

  @override
  Future<LibraryDescribeResult> describe({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) {
    describeCalls.add(DescribeCall(sourceId, shareUrl, password));
    return (completers[shareUrl] = Completer<LibraryDescribeResult>()).future;
  }

  @override
  Future<LibraryCollectResult> collect({
    required List<LibraryItem> items,
    required List<LibrarySource> sources,
  }) async => LibraryCollectResult(files: items, foldersScanned: 0);

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
          password: source.password,
        ),
      );

  @override
  Future<LibraryResolveResult> resolve({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryResolveResult(url: '', fileName: '');

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) async => const LibrarySearchResult();
}

class ControlledAssetCore extends ControlledLibraryCore
    implements LibraryAssetCore {
  int assetCalls = 0;

  @override
  Future<LibraryAssetResult> fetchAsset({required String url}) async {
    assetCalls++;
    return LibraryAssetResult.fromJson({
      'mediaType': 'image/png',
      'bytesBase64':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    });
  }
}

class ImmediateDescriptionCore extends ControlledLibraryCore {
  int describeCallCount = 0;

  @override
  Future<LibraryDescribeResult> describe({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async {
    describeCallCount++;
    return LibraryDescribeResult(description: '简介 $shareUrl');
  }
}

class DescribeCall {
  const DescribeCall(this.sourceId, this.stableUrl, this.password);

  final String sourceId;
  final String stableUrl;
  final String password;
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
    await Future<void>.delayed(Duration.zero);
  }
}
