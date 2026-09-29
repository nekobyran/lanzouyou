import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/library_preview.dart';
import 'package:lanzouyou/pages/public_library/public_library.dart';
import 'package:lanzouyou/shared/app_motion.dart';

void main() {
  testWidgets('catalog uses a lazy list and shows live Rust summary', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final nodes = List<PublicLibraryCatalogNode>.generate(
      200,
      (index) => _node(
        'source-$index',
        title: '来源 $index',
        kind: PublicLibraryNodeKind.remoteSource,
      ),
    );
    final controller = PublicLibraryController(
      core: _PageCore(page: _page(nodes)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AppMotionScope(
          reduceMotion: false,
          child: PublicLibraryPage(controller: controller),
        ),
      ),
    );
    await _pumpLibrary(tester);

    expect(find.byKey(const Key('public-library-root')), findsOneWidget);
    expect(find.text('12 个官方来源'), findsOneWidget);
    expect(find.text('3 个合集'), findsOneWidget);
    expect(find.text('200 个节点'), findsOneWidget);
    expect(find.text('来源 0'), findsOneWidget);
    expect(find.text('来源 199'), findsNothing);
    expect(
      find.byKey(const Key('public-library-node-row')).evaluate().length,
      lessThan(30),
    );
  });

  testWidgets(
    'software search exposes cancellation and cancelled empty state',
    (tester) async {
      final pending = Completer<LibrarySearchResult>();
      final core = _PageCore(page: _page([_node('source-1')]))
        ..searchCompleter = pending;
      final controller = PublicLibraryController(core: core);

      await tester.pumpWidget(
        MaterialApp(home: PublicLibraryPage(controller: controller)),
      );
      await _pumpLibrary(tester);
      await tester.enterText(
        find.byKey(const Key('public-library-search-field')),
        '工具',
      );
      await tester.tap(find.byTooltip('搜索软件'));
      await tester.pump();

      expect(
        find.byKey(const Key('public-library-cancel-search')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('public-library-cancel-search')));
      await tester.pump();
      expect(core.cancelled, hasLength(1));

      pending.complete(const LibrarySearchResult());
      await _pumpLibrary(tester);
      expect(find.text('已取消搜索'), findsOneWidget);
    },
  );

  testWidgets('file row opens real asynchronous detail on compact layout', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final detail = Completer<LibraryDescribeResult>();
    final core = _PageCore(
      page: _page([
        _node(
          'software-1',
          title: '真实工具.apk',
          kind: PublicLibraryNodeKind.singleSoftware,
        ),
      ]),
    )..descriptionCompleter = detail;

    await tester.pumpWidget(
      MaterialApp(
        home: PublicLibraryPage(
          controller: PublicLibraryController(core: core),
        ),
      ),
    );
    await _pumpLibrary(tester);
    await tester.tap(find.text('真实工具.apk'));
    await tester.pump();

    expect(
      find.byKey(const Key('public-library-detail-sheet')),
      findsOneWidget,
    );
    expect(find.text('正在读取详情'), findsOneWidget);

    detail.complete(const LibraryDescribeResult(description: '来自蓝奏云的真实简介'));
    await _pumpLibrary(tester);
    expect(find.text('来自蓝奏云的真实简介'), findsOneWidget);
  });

  testWidgets('wide layout keeps details in a master-detail pane', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = _PageCore(
      page: _page([
        _node(
          'software-1',
          title: '宽屏软件',
          kind: PublicLibraryNodeKind.singleSoftware,
        ),
      ]),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PublicLibraryPage(
          controller: PublicLibraryController(core: core),
        ),
      ),
    );
    await _pumpLibrary(tester);
    await tester.tap(find.text('宽屏软件'));
    await _pumpLibrary(tester);

    expect(find.byKey(const Key('public-library-detail-pane')), findsOneWidget);
    expect(find.byKey(const Key('public-library-detail-sheet')), findsNothing);
    expect(find.text('真实简介'), findsOneWidget);
  });

  testWidgets('search result source is highlighted and returns to results', (
    tester,
  ) async {
    final search = Completer<LibrarySearchResult>()
      ..complete(
        const LibrarySearchResult(
          items: <LibraryItem>[
            LibraryItem(
              sourceId: 'stable-source-id',
              source: '真实来源',
              title: '真实工具.apk',
              url: 'https://www.lanzouw.com/folder',
              shareUrl: 'https://www.lanzouw.com/file',
              isFolder: false,
            ),
          ],
        ),
      );
    final core = _PageCore(page: _page([_node('source-1')]))
      ..searchCompleter = search;
    final controller = PublicLibraryController(core: core);

    await tester.pumpWidget(
      MaterialApp(home: PublicLibraryPage(controller: controller)),
    );
    await _pumpLibrary(tester);
    await tester.enterText(
      find.byKey(const Key('public-library-search-field')),
      '工具',
    );
    await tester.tap(find.byTooltip('搜索软件'));
    await _pumpLibrary(tester);

    final sourceLink = find.byKey(
      const Key('public-library-source-stable-source-id'),
    );
    expect(sourceLink, findsOneWidget);
    expect(
      tester.widget<TextButton>(sourceLink).style?.foregroundColor?.resolve({}),
      Theme.of(tester.element(sourceLink)).colorScheme.primary,
    );

    await tester.tap(sourceLink);
    await _pumpLibrary(tester);
    expect(core.browseNodeIds.last, 'stable-source-id');

    await controller.goBack();
    await _pumpLibrary(tester);
    expect(find.text('真实工具.apk'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
  });

  testWidgets(
    'compact high text scale keeps search and states inside safe area',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final core = _PageCore(page: _page([_node('source-1')]));

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: MaterialApp(
            home: PublicLibraryPage(
              controller: PublicLibraryController(core: core),
            ),
          ),
        ),
      );
      await _pumpLibrary(tester);

      expect(find.byKey(const Key('public-library-safe-area')), findsOneWidget);
      expect(
        find.byKey(const Key('public-library-search-mode-scroll')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('catalog error and empty states recover through real retry', (
    tester,
  ) async {
    final core = _PageCore(page: _page([_node('source-1')]))
      ..pageFailure = const LibraryCoreFailure(
        'temporary',
        '来源暂时不可用',
        retriable: true,
      );
    final controller = PublicLibraryController(core: core);

    await tester.pumpWidget(
      MaterialApp(home: PublicLibraryPage(controller: controller)),
    );
    await _pumpLibrary(tester);
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('来源暂时不可用'), findsOneWidget);

    core.pageFailure = null;
    await tester.tap(find.text('重试'));
    await _pumpLibrary(tester);
    expect(find.text('source-1'), findsOneWidget);

    core.pageOverride = _page(const <PublicLibraryCatalogNode>[]);
    await controller.refresh();
    await _pumpLibrary(tester);
    expect(find.text('暂无内容'), findsOneWidget);
  });

  testWidgets('summary and detail failures each expose a focused retry', (
    tester,
  ) async {
    final core =
        _PageCore(
            page: _page([
              _node(
                'software-1',
                title: '真实工具.apk',
                kind: PublicLibraryNodeKind.singleSoftware,
              ),
            ]),
          )
          ..summaryFailure = const LibraryCoreFailure(
            'temporary',
            '统计暂时不可用',
            retriable: true,
          )
          ..descriptionFailure = const LibraryCoreFailure(
            'temporary',
            '详情暂时不可用',
            retriable: true,
          );
    final controller = PublicLibraryController(core: core);

    await tester.pumpWidget(
      MaterialApp(home: PublicLibraryPage(controller: controller)),
    );
    await _pumpLibrary(tester);
    expect(find.text('统计暂时不可用'), findsOneWidget);

    core.summaryFailure = null;
    await tester.tap(find.byKey(const Key('retry-public-library-summary')));
    await _pumpLibrary(tester);
    expect(find.text('12 个官方来源'), findsOneWidget);

    await tester.tap(find.text('真实工具.apk'));
    await _pumpLibrary(tester);
    expect(find.text('详情暂时不可用'), findsOneWidget);

    core.descriptionFailure = null;
    await tester.tap(find.text('重试').last);
    await _pumpLibrary(tester);
    expect(find.text('真实简介'), findsOneWidget);
  });
}

PublicLibraryCatalogPage _page(List<PublicLibraryCatalogNode> nodes) =>
    PublicLibraryCatalogPage(
      revision: 'revision-1',
      total: nodes.length,
      nextCursor: '',
      hasMore: false,
      nodes: nodes,
    );

PublicLibraryCatalogNode _node(
  String id, {
  String? title,
  PublicLibraryNodeKind kind = PublicLibraryNodeKind.remoteSource,
}) => PublicLibraryCatalogNode(
  id: id,
  parentId: '',
  kind: kind,
  sourceId: 'source-1',
  title: title ?? id,
  publisher: '来源名称',
  description: '',
  iconUrl: '',
  size: kind == PublicLibraryNodeKind.singleSoftware ? '12 MB' : '',
  time: '',
  searchable: true,
  childDirectory: kind == PublicLibraryNodeKind.remoteSource,
  originPath: 's/$id',
  originUrl: 'https://www.lanzouw.com/$id',
  shareUrl: 'https://www.lanzouw.com/$id',
  hasChildren: kind == PublicLibraryNodeKind.remoteSource,
);

class _PageCore implements PublicLibraryCatalogCore {
  _PageCore({required this.page});

  final PublicLibraryCatalogPage page;
  PublicLibraryCatalogPage? pageOverride;
  Object? pageFailure;
  Object? summaryFailure;
  Object? descriptionFailure;
  Completer<LibrarySearchResult>? searchCompleter;
  Completer<LibraryDescribeResult>? descriptionCompleter;
  final List<String> cancelled = [];
  final List<String> browseNodeIds = [];

  @override
  Future<PublicLibraryCatalogSummary> catalogSummary() async {
    if (summaryFailure != null) throw summaryFailure!;
    return const PublicLibraryCatalogSummary(
      revision: 'revision-1',
      officialCount: 12,
      compositeCount: 3,
      nodeCount: 200,
      searchableCount: 10,
    );
  }

  @override
  Future<PublicLibraryCatalogPage> catalogPage({
    String parentId = '',
    String categoryId = 'all',
    String query = '',
    String cursor = '',
    int limit = 100,
  }) async {
    if (pageFailure != null) throw pageFailure!;
    return pageOverride ?? page;
  }

  @override
  Future<LibrarySearchResult> catalogSearch({
    required String query,
    List<String> scopeIds = const [],
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) => searchCompleter?.future ?? Future.value(const LibrarySearchResult());

  @override
  Future<LibraryFolder> catalogBrowse({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
    int page = 1,
    bool refresh = false,
  }) async {
    browseNodeIds.add(nodeId);
    return LibraryFolder(
      sourceId: nodeId,
      title: '真实来源',
      url: 'https://www.lanzouw.com/source',
      items: const <LibraryItem>[],
    );
  }

  @override
  Future<void> cancelOperation(String operationId) async {
    cancelled.add(operationId);
  }

  @override
  Future<LibraryDescribeResult> catalogDescribe({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
  }) {
    if (descriptionFailure != null) {
      return Future<LibraryDescribeResult>.error(descriptionFailure!);
    }
    return descriptionCompleter?.future ??
        Future.value(const LibraryDescribeResult(description: '真实简介'));
  }

  @override
  Future<void> forgetOperation(String operationId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pumpLibrary(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
