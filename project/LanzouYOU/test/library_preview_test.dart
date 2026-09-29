import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/library_preview.dart'
    hide LibraryFeatures, LibraryIdentity;
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/pages/library_builder/library_builder_page.dart';
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

  test('preview config maps the live recipe and disables downloads only', () {
    final base = LibraryBuildRecipe.fromShareInfo(share);
    final recipe = base.copyWith(
      identity: base.identity.copyWith(
        displayName: '即时预览库',
        versionName: '2.4.1',
      ),
      branding: base.branding.copyWith(
        seedColor: '#6750A4',
        officialUrl: 'https://lanzoumax.nkbr.cc/',
        publisher: '千城软件库',
        themeMode: 'dark',
      ),
      sources: [
        base.sources.single,
        base.sources.single.copyWith(
          sourceId: 'mirror-source',
          title: '备用来源',
          shareUrl: 'https://pan.lanzoui.com/b456',
          password: 'mirror-pass',
          recommended: false,
        ),
      ],
      features: const LibraryFeatures(
        browse: true,
        search: true,
        download: true,
        showDescription: true,
      ),
    );

    final config = libraryPreviewConfigFromRecipe(recipe);

    expect(config.identity.displayName, '即时预览库');
    expect(config.identity.versionName, '2.4.1');
    expect(config.branding.seedColor, const Color(0xFF6750A4));
    expect(config.branding.officialUrl, 'https://lanzoumax.nkbr.cc/');
    expect(config.branding.publisher, '千城软件库');
    expect(config.branding.themeMode, LibraryThemeMode.dark);
    expect(config.sources, hasLength(2));
    expect(config.sources.last.password, 'mirror-pass');
    expect(config.features.browse, isTrue);
    expect(config.features.search, isTrue);
    expect(config.features.showDescription, isTrue);
    expect(config.features.download, isFalse);
    expect(recipe.features.download, isTrue);
  });

  test('preview eligibility rejects zero or invalid sources', () {
    final empty = LibraryBuildRecipe.newProject();
    final invalid = LibraryBuildRecipe.fromShareInfo(share).copyWith(
      sources: [
        LibraryBuildRecipe.fromShareInfo(
          share,
        ).sources.single.copyWith(shareUrl: 'https://example.com/not-lanzou'),
      ],
    );

    expect(isLibraryRecipePreviewable(empty), isFalse);
    expect(isLibraryRecipePreviewable(invalid), isFalse);
    expect(
      () => libraryPreviewConfigFromRecipe(empty),
      throwsA(isA<LibraryConfigException>()),
    );
  });

  testWidgets('builder enables preview only after a valid source exists', (
    tester,
  ) async {
    await _setSurface(tester, const Size(390, 844));

    await tester.pumpWidget(
      const MaterialApp(home: LibraryBuilderPage.newProject()),
    );
    await tester.pumpAndSettle();

    final preview = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('library-preview-button')),
    );
    expect(preview.onPressed, isNull);
    expect(find.byTooltip('完善配置并添加至少一个有效来源后可预览'), findsOneWidget);
  });

  testWidgets(
    'builder opens the embedded production list and reuses browse search detail and asset paths',
    (tester) async {
      await _setSurface(tester, const Size(390, 844));
      final core = _PreviewCore();

      await tester.pumpWidget(
        MaterialApp(
          home: LibraryBuilderPage(
            shareInfo: Future.value(share),
            previewCore: core,
            previewLinkOpener: _FakeLinkOpener(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('library-preview-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library-preview-root')), findsOneWidget);
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(Navigator), findsOneWidget);
      expect(find.text('预览模式 · 下载已停用'), findsOneWidget);
      expect(core.browseCalls, [
        ('source-1', 'https://www.lanzouw.com/b123', 'a1b2'),
      ]);

      await tester.enterText(
        find.byKey(const Key('compact-home-search')),
        '工具',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('开始搜索'));
      await tester.pumpAndSettle();

      expect(core.searchQueries, ['工具']);
      expect(find.text('搜索命中软件'), findsOneWidget);
      expect(core.assetUrls, ['https://img.lanzouw.com/icon.png']);

      await tester.tap(find.text('搜索命中软件'));
      await tester.pumpAndSettle();

      expect(core.describeCalls, [
        ('source-1', 'https://www.lanzouw.com/i789', 'a1b2'),
      ]);
      expect(find.text('远端真实简介'), findsOneWidget);
    },
  );

  testWidgets('preview route has an explicit return to the editor', (
    tester,
  ) async {
    await _setSurface(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBuilderPage(
          shareInfo: Future.value(share),
          previewCore: _PreviewCore(),
          previewLinkOpener: _FakeLinkOpener(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('library-preview-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回编辑'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-preview-root')), findsNothing);
    expect(find.byKey(const Key('library-preview-button')), findsOneWidget);
  });

  testWidgets(
    'embedded preview switches source through the real loading state',
    (tester) async {
      await _setSurface(tester, const Size(390, 844));
      final base = LibraryBuildRecipe.fromShareInfo(share);
      final recipe = base.copyWith(
        sources: [
          base.sources.single,
          base.sources.single.copyWith(
            sourceId: 'mirror-source',
            title: '备用来源',
            shareUrl: 'https://pan.lanzoui.com/b456',
            password: 'mirror-pass',
            recommended: false,
          ),
        ],
      );
      final pending = Completer<LibraryFolder>();
      final core = _PreviewCore()
        ..pendingSourceId = 'mirror-source'
        ..pendingBrowse = pending;

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

      await tester.tap(find.byKey(const ValueKey('home-source-mirror-source')));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(core.browseCalls.last, (
        'mirror-source',
        'https://pan.lanzoui.com/b456',
        'mirror-pass',
      ));

      pending.complete(
        const LibraryFolder(
          sourceId: 'mirror-source',
          title: '备用来源',
          url: 'https://pan.lanzoui.com/b456',
          items: [
            LibraryItem(
              sourceId: 'mirror-source',
              title: '备用源软件',
              url: 'https://pan.lanzoui.com/i999',
              shareUrl: 'https://pan.lanzoui.com/i999',
              isFolder: false,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('备用源软件'), findsOneWidget);
    },
  );
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
  _PreviewCore();

  bool failBrowse = false;
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
