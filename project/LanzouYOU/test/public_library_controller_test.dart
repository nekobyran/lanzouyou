import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/library_preview.dart';
import 'package:lanzouyou/pages/public_library/public_library.dart';

void main() {
  test('initialization and pagination use opaque Rust catalog pages', () async {
    final core = _FakeCatalogCore(
      pages: {
        '': _page(
          nodes: [
            _node('source-1', PublicLibraryNodeKind.remoteSource),
            _node('collection-1', PublicLibraryNodeKind.composite),
          ],
          nextCursor: 'cursor-2',
          hasMore: true,
          total: 3,
        ),
        'cursor-2': _page(
          nodes: [_node('source-2', PublicLibraryNodeKind.remoteSource)],
          total: 3,
        ),
      },
    );
    final controller = PublicLibraryController(core: core, pageSize: 100);
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.status, PublicLibraryContentStatus.data);
    expect(controller.nodes, hasLength(2));
    expect(core.pageCalls.single.cursor, '');
    expect(core.pageCalls.single.limit, 100);

    await controller.loadMore();
    expect(controller.nodes.map((node) => node.id), [
      'source-1',
      'collection-1',
      'source-2',
    ]);
    expect(core.pageCalls.last.cursor, 'cursor-2');
  });

  test(
    'composites stay in catalog while remote sources browse through Rust',
    () async {
      final core = _FakeCatalogCore(
        pages: {
          '': _page(
            nodes: [
              _node(
                'collection-1',
                PublicLibraryNodeKind.composite,
                hasChildren: true,
              ),
              _node(
                'source-1',
                PublicLibraryNodeKind.remoteSource,
                hasChildren: true,
              ),
            ],
          ),
          'collection-1': _page(
            nodes: [_node('child-1', PublicLibraryNodeKind.singleSoftware)],
          ),
        },
        browseResult: const LibraryFolder(
          sourceId: 'source-1',
          title: '公开软件库',
          url: 'https://www.lanzouw.com/b123',
          items: [
            LibraryItem(
              sourceId: 'source-1',
              title: '真实软件.apk',
              url: 'https://www.lanzouw.com/i123',
              shareUrl: 'https://www.lanzouw.com/i123',
              source: '公开软件库',
              isFolder: false,
            ),
          ],
        ),
      );
      final controller = PublicLibraryController(core: core);
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.openNode(controller.nodes.first);
      expect(controller.nodes.single.id, 'child-1');
      expect(core.browseCalls, isEmpty);
      await controller.goBack();

      await controller.openNode(controller.nodes.last);
      expect(controller.items.single.title, '真实软件.apk');
      expect(core.browseCalls.single.nodeId, 'source-1');
      expect(core.browseCalls.single.itemRef, isNull);
    },
  );

  test(
    'software search is one Rust batch operation and can be cancelled',
    () async {
      final pending = Completer<LibrarySearchResult>();
      final core = _FakeCatalogCore(pages: {'': _page()})
        ..searchCompleter = pending;
      final controller = PublicLibraryController(core: core);
      addTearDown(controller.dispose);
      await controller.initialize();

      controller.updateQuery('工具');
      final search = controller.submitSearch();
      await Future<void>.delayed(Duration.zero);
      expect(core.searchCalls, hasLength(1));
      expect(core.searchCalls.single.query, '工具');
      expect(core.searchCalls.single.scopeIds, isEmpty);
      expect(controller.canCancelSearch, isTrue);

      await controller.cancelSearch();
      expect(core.cancelledOperationIds, [core.searchCalls.single.operationId]);
      pending.complete(const LibrarySearchResult());
      await search;
      expect(controller.searchWasCancelled, isTrue);
    },
  );

  test(
    'source search filters the Rust catalog rather than decoding assets',
    () async {
      final core = _FakeCatalogCore(
        pages: {
          '': _page(),
          'query:音乐': _page(
            nodes: [_node('music', PublicLibraryNodeKind.remoteSource)],
          ),
        },
      );
      final controller = PublicLibraryController(core: core);
      addTearDown(controller.dispose);
      await controller.initialize();
      controller
        ..setSearchMode(PublicLibrarySearchMode.sources)
        ..updateQuery('音乐');

      await controller.submitSearch();

      expect(core.searchCalls, isEmpty);
      expect(core.pageCalls.last.query, '音乐');
      expect(controller.nodes.single.id, 'music');
    },
  );

  test(
    'search result source opens by stable source id and restores search path',
    () async {
      final core = _FakeCatalogCore(
        pages: {
          '': _page(
            nodes: [_node('source-home', PublicLibraryNodeKind.remoteSource)],
          ),
        },
        browseResult: const LibraryFolder(
          sourceId: 'stable-source-id',
          title: '来源目录',
          url: 'https://www.lanzouw.com/source',
          items: <LibraryItem>[],
        ),
      );
      core.searchCompleter = Completer<LibrarySearchResult>()
        ..complete(
          const LibrarySearchResult(
            items: <LibraryItem>[
              LibraryItem(
                sourceId: 'stable-source-id',
                source: '真实来源',
                title: '工具.apk',
                url: 'https://www.lanzouw.com/folder',
                shareUrl: 'https://www.lanzouw.com/file',
                isFolder: false,
              ),
            ],
          ),
        );
      final controller = PublicLibraryController(core: core);
      addTearDown(controller.dispose);

      await controller.initialize();
      controller.updateQuery('工具');
      await controller.submitSearch();
      final searchItem = controller.items.single;

      await controller.openItemSource(searchItem);

      expect(core.browseCalls.last.nodeId, 'stable-source-id');
      expect(controller.contentKind, PublicLibraryContentKind.folder);
      expect(controller.query, isEmpty);
      expect(controller.canGoBack, isTrue);

      await controller.goBack();

      expect(controller.contentKind, PublicLibraryContentKind.searchResults);
      expect(controller.query, '工具');
      expect(controller.items.single.title, '工具.apk');

      await controller.clearSearch();
      expect(controller.contentKind, PublicLibraryContentKind.catalog);
      expect(controller.nodes.single.id, 'source-home');
    },
  );
}

PublicLibraryCatalogPage _page({
  List<PublicLibraryCatalogNode> nodes = const [],
  String nextCursor = '',
  bool hasMore = false,
  int? total,
}) => PublicLibraryCatalogPage(
  revision: 'revision-1',
  total: total ?? nodes.length,
  nextCursor: nextCursor,
  hasMore: hasMore,
  nodes: nodes,
);

PublicLibraryCatalogNode _node(
  String id,
  PublicLibraryNodeKind kind, {
  bool hasChildren = false,
}) => PublicLibraryCatalogNode(
  id: id,
  parentId: '',
  kind: kind,
  sourceId: id.startsWith('source') ? id : '',
  title: id,
  publisher: '真实来源',
  description: '',
  iconUrl: '',
  size: '',
  time: '',
  searchable: true,
  childDirectory: kind == PublicLibraryNodeKind.remoteSource,
  originPath: 's/$id',
  originUrl: 'https://www.lanzouw.com/$id',
  shareUrl: 'https://www.lanzouw.com/$id',
  hasChildren: hasChildren,
);

class _FakeCatalogCore implements PublicLibraryCatalogCore {
  _FakeCatalogCore({
    required this.pages,
    this.browseResult = const LibraryFolder(
      sourceId: 'fallback',
      title: '空目录',
      url: '',
      items: [],
    ),
  });

  final Map<String, PublicLibraryCatalogPage> pages;
  final LibraryFolder browseResult;
  final List<
    ({
      String parentId,
      String categoryId,
      String query,
      String cursor,
      int limit,
    })
  >
  pageCalls = [];
  final List<({String nodeId, PublicLibraryItemRef? itemRef, int page})>
  browseCalls = [];
  final List<({String query, List<String> scopeIds, String? operationId})>
  searchCalls = [];
  final List<String> cancelledOperationIds = [];
  Completer<LibrarySearchResult>? searchCompleter;

  @override
  Future<PublicLibraryCatalogSummary> catalogSummary() async =>
      const PublicLibraryCatalogSummary(
        revision: 'revision-1',
        officialCount: 2,
        compositeCount: 1,
        nodeCount: 3,
        searchableCount: 2,
      );

  @override
  Future<PublicLibraryCatalogPage> catalogPage({
    String parentId = '',
    String categoryId = 'all',
    String query = '',
    String cursor = '',
    int limit = 100,
  }) async {
    pageCalls.add((
      parentId: parentId,
      categoryId: categoryId,
      query: query,
      cursor: cursor,
      limit: limit,
    ));
    return pages[query.isNotEmpty
            ? 'query:$query'
            : (cursor.isEmpty ? parentId : cursor)] ??
        _page();
  }

  @override
  Future<LibraryFolder> catalogBrowse({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
    int page = 1,
    bool refresh = false,
  }) async {
    browseCalls.add((nodeId: nodeId, itemRef: itemRef, page: page));
    return browseResult;
  }

  @override
  Future<LibrarySearchResult> catalogSearch({
    required String query,
    List<String> scopeIds = const [],
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) {
    searchCalls.add((
      query: query,
      scopeIds: List<String>.of(scopeIds),
      operationId: operationId,
    ));
    return searchCompleter?.future ?? Future.value(const LibrarySearchResult());
  }

  @override
  Future<void> cancelOperation(String operationId) async {
    cancelledOperationIds.add(operationId);
  }

  @override
  Future<void> forgetOperation(String operationId) async {}

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) async =>
      LibraryOperationStatus(
        operationId: operationId,
        kind: 'library_search',
        state: LibraryOperationState.running,
        completedUnits: 0,
        totalUnits: 2,
        bytesTransferred: 0,
        totalBytes: 0,
        itemsFound: 0,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
