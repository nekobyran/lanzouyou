import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/library_preview.dart'
    hide LibraryFeatures, LibraryIdentity;
import 'package:lanzouyou/models/cloud_item.dart';

import 'package:lanzouyou/pages/library_builder/library_preview/library_preview_page.dart';
import 'package:lanzouyou/pages/library_builder/library_recipe.dart';

void main() {
  const share = ShareInfo(
    id: 'folder-id',
    isFolder: true,
    name: '正式软件库',
    shareUrl: 'https://www.lanzouw.com/b123',
    password: 'a1b2',
    description: '',
  );
  testWidgets('embedded preview keeps the production wide source pane', (
    tester,
  ) async {
    await _setSurface(tester, const Size(1280, 800));
    final recipe = LibraryBuildRecipe.fromShareInfo(share);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPreviewPage.testHarness(
          recipe: recipe,
          core: _PreviewCore(),
          linkOpener: _FakeLinkOpener(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wide-source-pane')), findsOneWidget);
    expect(find.byKey(const Key('library-content-pane')), findsOneWidget);
    expect(find.byKey(const Key('wide-download-destination')), findsNothing);
  });

  testWidgets('embedded preview exposes error retry and empty states', (
    tester,
  ) async {
    await _setSurface(tester, const Size(390, 844));
    final core = _PreviewCore(failBrowse: true);
    final recipe = LibraryBuildRecipe.fromShareInfo(share);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPreviewPage.testHarness(
          recipe: recipe,
          core: core,
          linkOpener: _FakeLinkOpener(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-source-source-1')));
    await tester.pumpAndSettle();

    expect(find.text('加载失败'), findsOneWidget);
    core
      ..failBrowse = false
      ..items = const [];
    await tester.tap(find.widgetWithText(FilledButton, '重试'));
    await tester.pumpAndSettle();

    expect(find.text('此目录没有文件'), findsOneWidget);
    expect(core.browseCalls, hasLength(2));
  });
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 20));
  await tester.binding.setSurfaceSize(size);
  addTearDown(() {
    tester.binding.setSurfaceSize(null);
  });
}

class _PreviewCore implements LibraryCore, LibraryAssetCore {
  _PreviewCore({this.failBrowse = false});

  bool failBrowse;
  List<LibraryItem> items = const [
    LibraryItem(
      sourceId: 'source-1',
      title: '目录软件',
      url: 'https://www.lanzouw.com/i456',
      shareUrl: 'https://www.lanzouw.com/i456',
      isFolder: false,
    ),
  ];
  final List<(String, String, String)> browseCalls = [];
  final List<String> searchQueries = [];
  final List<(String, String, String)> describeCalls = [];
  final List<String> assetUrls = [];
  String? pendingSourceId;
  Completer<LibraryFolder>? pendingBrowse;

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
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async {
    browseCalls.add((sourceId, shareUrl, password));
    if (failBrowse) {
      throw const LibraryCoreFailure('network', '来源暂时不可用', retriable: true);
    }
    final pending = pendingBrowse;
    if (sourceId == pendingSourceId && pending != null) {
      return pending.future;
    }
    return LibraryFolder(
      sourceId: sourceId,
      title: '正式软件库',
      url: shareUrl,
      items: items,
    );
  }

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) async {
    searchQueries.add(query);
    return const LibrarySearchResult(
      items: [
        LibraryItem(
          sourceId: 'source-1',
          title: '搜索命中软件',
          url: 'https://www.lanzouw.com/i789',
          shareUrl: 'https://www.lanzouw.com/i789',
          iconUrl: 'https://img.lanzouw.com/icon.png',
          isFolder: false,
        ),
      ],
    );
  }

  @override
  Future<LibraryCollectResult> collect({
    required List<LibraryItem> items,
    required List<LibrarySource> sources,
  }) async => LibraryCollectResult(files: items, foldersScanned: 0);

  @override
  Future<LibraryResolveResult> resolve({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryResolveResult(url: '', fileName: '');

  @override
  Future<LibraryDescribeResult> describe({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async {
    describeCalls.add((sourceId, shareUrl, password));
    return const LibraryDescribeResult(description: '远端真实简介');
  }

  @override
  Future<LibraryAssetResult> fetchAsset({required String url}) async {
    assetUrls.add(url);
    return LibraryAssetResult.fromJson({
      'mediaType': 'image/png',
      'bytesBase64': _transparentPng,
    });
  }
}

class _FakeLinkOpener implements LinkOpener {
  @override
  Future<void> open(String url) async {}
}

const _transparentPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
