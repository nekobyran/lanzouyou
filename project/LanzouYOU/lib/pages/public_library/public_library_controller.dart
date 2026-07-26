import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:lanzou_library_shell/library_preview.dart';

import 'incremental_search_consumer.dart';
import 'incremental_search_core.dart';
import 'public_library_core.dart';
import 'public_library_models.dart';

enum PublicLibraryContentStatus { loading, data, empty, error }

enum PublicLibraryContentKind { catalog, folder, searchResults }

enum PublicLibrarySearchMode { software, sources }

class PublicLibraryController extends ChangeNotifier {
  PublicLibraryController({
    required this.core,
    this.pageSize = 100,
    this.searchOptions = const LibrarySearchOptions(),
    this.searchViewRatePerSecond = 100,
    this.searchViewPumpInterval = const Duration(milliseconds: 100),
  }) : assert(pageSize >= 1 && pageSize <= 200),
       assert(
         searchViewRatePerSecond > 0 && searchViewRatePerSecond <= 1000,
       );

  final PublicLibraryCatalogCore core;
  final int pageSize;
  final LibrarySearchOptions searchOptions;
  final int searchViewRatePerSecond;
  final Duration searchViewPumpInterval;

  PublicLibraryCatalogSummary? summary;
  bool summaryLoading = false;
  String summaryError = '';
  PublicLibraryContentStatus status = PublicLibraryContentStatus.loading;
  PublicLibraryContentKind contentKind = PublicLibraryContentKind.catalog;
  PublicLibrarySearchMode searchMode = PublicLibrarySearchMode.software;
  List<PublicLibraryCatalogNode> nodes = const [];
  List<LibraryItem> items = const [];
  LibraryFolder? folder;
  PublicLibraryCatalogNode? selectedNode;
  LibraryItem? selectedItem;
  String description = '';
  String descriptionError = '';
  bool isDescriptionLoading = false;
  String errorMessage = '';
  String query = '';
  String title = '全部来源';
  bool isLoadingMore = false;
  bool isSearchCancelling = false;
  bool isSearchControlPending = false;
  bool searchWasCancelled = false;
  String searchCancellationError = '';
  LibraryOperationStatus? searchOperation;
  List<IncrementalSearchSourceUpdate> searchSources = const [];
  int total = 0;
  String _cursor = '';
  bool _hasMore = false;
  int _folderPage = 1;
  String _currentParentId = '';
  String _currentCategoryId = 'all';
  String _catalogQuery = '';
  String _browseNodeId = '';
  PublicLibraryItemRef? _browseItemRef;
  String? _activeSearchOperationId;
  String? _cancelledSearchOperationId;
  IncrementalSearchConsumer? _incrementalSearchConsumer;
  final Map<String, IncrementalSearchSourceUpdate> _searchSourcesById = {};
  _PublicLibrarySnapshot? _searchBase;
  final List<_PublicLibraryHistoryEntry> _history = [];
  int _generation = 0;
  int _operationSequence = 0;
  int _descriptionGeneration = 0;
  bool _initialized = false;
  bool _disposed = false;

  bool get hasMore => _hasMore;

  bool get canGoBack => _history.isNotEmpty || _searchBase != null;

  bool get canCancelSearch {
    final state = searchOperation?.state;
    return _activeSearchOperationId != null &&
        !isSearchCancelling &&
        !isSearchControlPending &&
        (state == null ||
            (state != LibraryOperationState.cancelling && !state.isTerminal));
  }

  bool get canPauseSearch =>
      _incrementalSearchConsumer != null &&
      searchOperation?.state == LibraryOperationState.running &&
      !isSearchControlPending &&
      !isSearchCancelling;

  bool get canResumeSearch =>
      _incrementalSearchConsumer != null &&
      searchOperation?.state == LibraryOperationState.paused &&
      !isSearchControlPending &&
      !isSearchCancelling;

  bool get isSearchPaused =>
      searchOperation?.state == LibraryOperationState.paused;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    final summaryFuture = _loadSummary();
    await _loadCatalog(parentId: '', title: '全部来源');
    await summaryFuture;
  }

  Future<void> _loadSummary() async {
    if (_disposed || summaryLoading) return;
    summaryLoading = true;
    summaryError = '';
    notifyListeners();
    try {
      summary = await core.catalogSummary();
      summaryError = '';
    } on Object catch (error) {
      summaryError = _errorText(error, fallback: '无法读取来源统计');
    } finally {
      summaryLoading = false;
      notifyListeners();
    }
  }

  Future<void> retrySummary() => _loadSummary();

  void updateQuery(String value) {
    if (query == value) return;
    query = value;
    searchWasCancelled = false;
    searchCancellationError = '';
    notifyListeners();
  }

  void setSearchMode(PublicLibrarySearchMode mode) {
    if (searchMode == mode) return;
    searchMode = mode;
    searchWasCancelled = false;
    searchCancellationError = '';
    notifyListeners();
  }

  Future<void> submitSearch() async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      await clearSearch();
      return;
    }
    _searchBase ??= _snapshot(queryOverride: '');
    searchWasCancelled = false;
    searchCancellationError = '';
    if (searchMode == PublicLibrarySearchMode.sources) {
      await _loadCatalog(
        parentId: _searchBase!._currentParentId,
        title: '来源搜索',
        query: normalized,
      );
      return;
    }
    await _searchSoftware(normalized);
  }

  Future<void> _searchSoftware(String normalized) async {
    final incrementalCore = core is PublicLibraryIncrementalSearchCore
        ? core as PublicLibraryIncrementalSearchCore
        : null;
    if (incrementalCore != null) {
      await _searchSoftwareIncrementally(incrementalCore, normalized);
      return;
    }
    await _searchSoftwareBatch(normalized);
  }

  Future<void> _searchSoftwareBatch(String normalized) async {
    final generation = ++_generation;
    final operationId = _newOperationId();
    _activeSearchOperationId = operationId;
    _cancelledSearchOperationId = null;
    contentKind = PublicLibraryContentKind.searchResults;
    status = PublicLibraryContentStatus.loading;
    title = '软件搜索';
    nodes = const [];
    items = const [];
    folder = null;
    total = 0;
    errorMessage = '';
    _hasMore = false;
    _clearSelection();
    notifyListeners();
    try {
      final result = await core.catalogSearch(
        query: normalized,
        scopeIds: _searchScopeIds(),
        options: searchOptions,
        operationId: operationId,
      );
      if (!_isCurrent(generation) ||
          _cancelledSearchOperationId == operationId) {
        return;
      }
      items = result.items;
      total = result.items.length;
      status = items.isEmpty
          ? PublicLibraryContentStatus.empty
          : PublicLibraryContentStatus.data;
    } on Object catch (error) {
      if (!_isCurrent(generation) ||
          _cancelledSearchOperationId == operationId) {
        return;
      }
      status = PublicLibraryContentStatus.error;
      errorMessage = _errorText(error, fallback: '软件搜索失败，请稍后重试');
    } finally {
      if (_activeSearchOperationId == operationId) {
        _activeSearchOperationId = null;
        isSearchCancelling = false;
      }
      unawaited(_forgetOperation(operationId));
      notifyListeners();
    }
  }

  List<String> _searchScopeIds() {
    final base = _searchBase;
    if (base == null || base._currentParentId.isEmpty) return const [];
    return <String>[base._currentParentId];
  }

  Future<void> cancelSearch() async {
    final operationId = _activeSearchOperationId;
    if (operationId == null || isSearchCancelling) return;
    isSearchCancelling = true;
    searchCancellationError = '';
    notifyListeners();
    try {
      final consumer = _incrementalSearchConsumer;
      if (consumer != null) {
        await consumer.cancel();
        searchOperation = _mergeSearchOperation(
          searchOperation,
          consumer.operation,
        );
      } else {
        await core.cancelOperation(operationId);
      }
      _cancelledSearchOperationId = operationId;
      if (consumer == null) {
        searchWasCancelled = true;
        status = PublicLibraryContentStatus.empty;
        items = const [];
        total = 0;
      }
    } on Object catch (error) {
      searchCancellationError = _errorText(error, fallback: '无法取消搜索，请稍后重试');
    } finally {
      isSearchCancelling =
          _incrementalSearchConsumer?.operation?.state ==
          LibraryOperationState.cancelling;
      notifyListeners();
    }
  }

  Future<void> pauseSearch() => _controlIncrementalSearch(resume: false);

  Future<void> resumeSearch() => _controlIncrementalSearch(resume: true);

  Future<void> _controlIncrementalSearch({required bool resume}) async {
    final consumer = _incrementalSearchConsumer;
    if (consumer == null || isSearchControlPending || isSearchCancelling) return;
    final allowed = resume ? canResumeSearch : canPauseSearch;
    if (!allowed) return;
    isSearchControlPending = true;
    searchCancellationError = '';
    notifyListeners();
    try {
      if (resume) {
        await consumer.resume();
      } else {
        await consumer.pause();
      }
      searchOperation = _mergeSearchOperation(
        searchOperation,
        consumer.operation,
      );
    } on Object catch (error) {
      searchCancellationError = _errorText(
        error,
        fallback: resume ? '无法继续搜索，请稍后重试' : '无法暂停搜索，请稍后重试',
      );
    } finally {
      isSearchControlPending = false;
      notifyListeners();
    }
  }

  Future<void> clearSearch() async {
    final operationId = _activeSearchOperationId;
    final consumer = _incrementalSearchConsumer;
    if (consumer != null) {
      ++_generation;
      if (operationId != null) await cancelSearch();
      consumer.dispose();
      if (identical(_incrementalSearchConsumer, consumer)) {
        _incrementalSearchConsumer = null;
      }
      if (_activeSearchOperationId == operationId) {
        _activeSearchOperationId = null;
      }
    } else if (operationId != null) {
      await cancelSearch();
    }
    query = '';
    searchWasCancelled = false;
    searchCancellationError = '';
    searchOperation = null;
    searchSources = const [];
    _searchSourcesById.clear();
    final base = _searchBase;
    _searchBase = null;
    if (base != null) {
      _restore(base);
      notifyListeners();
    }
  }

  Future<void> openNode(PublicLibraryCatalogNode node) async {
    if (node.opensRemoteFolder) {
      _pushHistory();
      _searchBase = null;
      query = '';
      await _loadFolder(nodeId: node.id, title: node.title);
      return;
    }
    if (node.opensCatalog && node.hasChildren) {
      _pushHistory();
      _searchBase = null;
      query = '';
      await _loadCatalog(parentId: node.id, title: node.title);
      return;
    }
    await selectNode(node);
  }

  Future<void> openItem(LibraryItem item) async {
    if (item.isFolder) {
      _pushHistory();
      _searchBase = null;
      query = '';
      await _loadFolder(
        itemRef: PublicLibraryItemRef.fromItem(item),
        title: item.title,
      );
      return;
    }
    await selectItem(item);
  }

  /// Opens the root of the real source that produced a search result.
  ///
  /// [LibraryItem.sourceId] is an opaque Rust-owned identity. Flutter never
  /// scans catalog pages or reconstructs source URLs to guess the target.
  Future<void> openItemSource(LibraryItem item) async {
    final sourceId = item.sourceId.trim();
    if (sourceId.isEmpty) return;
    _pushHistory();
    _searchBase = null;
    query = '';
    final sourceTitle = item.source.trim().isEmpty ? '来源' : item.source.trim();
    await _loadFolder(nodeId: sourceId, title: sourceTitle);
  }

  Future<void> selectNode(PublicLibraryCatalogNode node) async {
    selectedNode = node;
    selectedItem = null;
    description = node.description;
    descriptionError = '';
    notifyListeners();
    if (!node.isSoftware) return;
    await _loadDescription(nodeId: node.id);
  }

  Future<void> selectItem(LibraryItem item) async {
    selectedItem = item;
    selectedNode = null;
    description = item.description;
    descriptionError = '';
    notifyListeners();
    await _loadDescription(itemRef: PublicLibraryItemRef.fromItem(item));
  }

  Future<void> retryDescription() async {
    final node = selectedNode;
    final item = selectedItem;
    if (node != null) {
      await _loadDescription(nodeId: node.id);
    } else if (item != null) {
      await _loadDescription(itemRef: PublicLibraryItemRef.fromItem(item));
    }
  }

  Future<void> _loadDescription({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
  }) async {
    final generation = ++_descriptionGeneration;
    isDescriptionLoading = true;
    descriptionError = '';
    notifyListeners();
    try {
      final result = await core.catalogDescribe(
        nodeId: nodeId,
        itemRef: itemRef,
      );
      if (generation != _descriptionGeneration || _disposed) return;
      description = result.description;
    } on Object catch (error) {
      if (generation != _descriptionGeneration || _disposed) return;
      descriptionError = _errorText(error, fallback: '无法读取软件详情');
    } finally {
      if (generation == _descriptionGeneration && !_disposed) {
        isDescriptionLoading = false;
        notifyListeners();
      }
    }
  }

  void clearSelection() {
    _clearSelection();
    notifyListeners();
  }

  Future<void> _searchSoftwareIncrementally(
    PublicLibraryIncrementalSearchCore incrementalCore,
    String normalized,
  ) async {
    final generation = ++_generation;
    final operationId = _newOperationId();
    _activeSearchOperationId = operationId;
    _cancelledSearchOperationId = null;
    contentKind = PublicLibraryContentKind.searchResults;
    status = PublicLibraryContentStatus.loading;
    title = '软件搜索';
    nodes = const [];
    items = const [];
    folder = null;
    total = 0;
    errorMessage = '';
    searchCancellationError = '';
    searchOperation = null;
    searchSources = const [];
    _searchSourcesById.clear();
    _hasMore = false;
    _clearSelection();

    late final IncrementalSearchConsumer consumer;
    consumer = IncrementalSearchConsumer(
      core: incrementalCore,
      viewRatePerSecond: searchViewRatePerSecond,
      viewPumpInterval: searchViewPumpInterval,
      onVisibleItems: (visible) {
        if (!_isActiveIncrementalSearch(generation, operationId, consumer)) {
          return;
        }
        final merged = _dedupeItems(<LibraryItem>[...items, ...visible]);
        merged.sort((left, right) {
          if (left.isFolder == right.isFolder) return 0;
          return left.isFolder ? -1 : 1;
        });
        items = List<LibraryItem>.unmodifiable(merged);
        total = items.length;
        status = PublicLibraryContentStatus.data;
        notifyListeners();
      },
      onSources: (updates) {
        if (!_isActiveIncrementalSearch(generation, operationId, consumer)) {
          return;
        }
        for (final update in updates) {
          _searchSourcesById[update.sourceId] = update;
        }
        searchSources = List<IncrementalSearchSourceUpdate>.unmodifiable(
          _searchSourcesById.values,
        );
        notifyListeners();
      },
      onOperation: (operation) {
        if (!_isActiveIncrementalSearch(generation, operationId, consumer)) {
          return;
        }
        searchOperation = _mergeSearchOperation(searchOperation, operation);
        notifyListeners();
      },
    );
    _incrementalSearchConsumer = consumer;
    notifyListeners();
    unawaited(_pollIncrementalOperation(generation, operationId, consumer));

    try {
      await consumer.start(
        operationId: operationId,
        query: normalized,
        scopeIds: _searchScopeIds(),
        options: searchOptions,
      );
      if (!_isCurrent(generation) ||
          _activeSearchOperationId != operationId) {
        return;
      }
      final terminal = consumer.terminalState ?? searchOperation?.state;
      searchOperation = _operationWithState(searchOperation, terminal);
      if (terminal == LibraryOperationState.cancelled) {
        searchWasCancelled = true;
      }
      if (terminal == LibraryOperationState.failed && items.isEmpty) {
        status = PublicLibraryContentStatus.error;
        errorMessage = '软件搜索失败，请稍后重试';
      } else {
        status = items.isEmpty
            ? PublicLibraryContentStatus.empty
            : PublicLibraryContentStatus.data;
      }
    } on Object catch (error) {
      if (!_isCurrent(generation) ||
          _activeSearchOperationId != operationId) {
        return;
      }
      status = items.isEmpty
          ? PublicLibraryContentStatus.error
          : PublicLibraryContentStatus.data;
      errorMessage = _errorText(error, fallback: '软件搜索失败，请稍后重试');
    } finally {
      if (_activeSearchOperationId == operationId) {
        _activeSearchOperationId = null;
        isSearchCancelling = false;
        isSearchControlPending = false;
      }
      if (identical(_incrementalSearchConsumer, consumer)) {
        _incrementalSearchConsumer = null;
      }
      consumer.dispose();
      notifyListeners();
    }
  }

  Future<void> goBack() async {
    if (_history.isNotEmpty) {
      ++_generation;
      final entry = _history.removeLast();
      _restore(entry.view);
      _searchBase = entry.searchBase;
      notifyListeners();
      return;
    }
    if (_searchBase != null) await clearSearch();
  }

  Future<void> loadMore() async {
    if (!_hasMore ||
        isLoadingMore ||
        status == PublicLibraryContentStatus.loading) {
      return;
    }
    isLoadingMore = true;
    errorMessage = '';
    notifyListeners();
    try {
      if (contentKind == PublicLibraryContentKind.catalog) {
        final page = await core.catalogPage(
          parentId: _currentParentId,
          categoryId: _currentCategoryId,
          query: _catalogQuery,
          cursor: _cursor,
          limit: pageSize,
        );
        nodes = _dedupeNodes(<PublicLibraryCatalogNode>[
          ...nodes,
          ...page.nodes,
        ]);
        total = page.total;
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
        errorMessage = '';
      } else if (contentKind == PublicLibraryContentKind.folder) {
        final nextPage = _folderPage + 1;
        final next = await core.catalogBrowse(
          nodeId: _browseNodeId,
          itemRef: _browseItemRef,
          page: nextPage,
        );
        items = _dedupeItems(<LibraryItem>[...items, ...next.items]);
        folder = next;
        _folderPage = next.page;
        _hasMore = next.hasMore;
        total = items.length;
        errorMessage = '';
      }
    } on Object catch (error) {
      errorMessage = _errorText(error, fallback: '无法继续加载');
    } finally {
      isLoadingMore = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (query.trim().isNotEmpty) {
      await submitSearch();
      return;
    }
    if (contentKind == PublicLibraryContentKind.folder) {
      await _loadFolder(
        nodeId: _browseNodeId,
        itemRef: _browseItemRef,
        title: title,
        refresh: true,
      );
    } else {
      await Future.wait([
        _loadCatalog(parentId: _currentParentId, title: title),
        _loadSummary(),
      ]);
    }
  }

  Future<void> retry() => refresh();

  Future<void> _loadCatalog({
    required String parentId,
    required String title,
    String query = '',
  }) async {
    final generation = _startLoading();
    contentKind = PublicLibraryContentKind.catalog;
    this.title = title;
    _currentParentId = parentId;
    _catalogQuery = query;
    _browseNodeId = '';
    _browseItemRef = null;
    _folderPage = 1;
    folder = null;
    items = const [];
    nodes = const [];
    notifyListeners();
    try {
      final page = await core.catalogPage(
        parentId: parentId,
        categoryId: _currentCategoryId,
        query: query,
        limit: pageSize,
      );
      if (!_isCurrent(generation)) return;
      nodes = page.nodes;
      total = page.total;
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      status = nodes.isEmpty
          ? PublicLibraryContentStatus.empty
          : PublicLibraryContentStatus.data;
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      status = PublicLibraryContentStatus.error;
      errorMessage = _errorText(error, fallback: '蓝奏来源加载失败');
    }
    notifyListeners();
  }

  Future<void> _loadFolder({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
    required String title,
    bool refresh = false,
  }) async {
    final generation = _startLoading();
    contentKind = PublicLibraryContentKind.folder;
    this.title = title;
    _browseNodeId = nodeId;
    _browseItemRef = itemRef;
    _folderPage = 1;
    nodes = const [];
    items = const [];
    folder = null;
    notifyListeners();
    try {
      final result = await core.catalogBrowse(
        nodeId: nodeId,
        itemRef: itemRef,
        refresh: refresh,
      );
      if (!_isCurrent(generation)) return;
      folder = result;
      items = result.items;
      total = result.items.length;
      _folderPage = result.page;
      _hasMore = result.hasMore;
      status = items.isEmpty
          ? PublicLibraryContentStatus.empty
          : PublicLibraryContentStatus.data;
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      status = PublicLibraryContentStatus.error;
      errorMessage = _errorText(error, fallback: '软件目录加载失败');
    }
    notifyListeners();
  }

  int _startLoading() {
    final generation = ++_generation;
    status = PublicLibraryContentStatus.loading;
    errorMessage = '';
    total = 0;
    _cursor = '';
    _hasMore = false;
    _clearSelection();
    return generation;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  String _newOperationId() =>
      'catalog-search-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${(++_operationSequence).toRadixString(36)}';

  bool _isActiveIncrementalSearch(
    int generation,
    String operationId,
    IncrementalSearchConsumer consumer,
  ) =>
      _isCurrent(generation) &&
      _activeSearchOperationId == operationId &&
      identical(_incrementalSearchConsumer, consumer);

  Future<void> _pollIncrementalOperation(
    int generation,
    String operationId,
    IncrementalSearchConsumer consumer,
  ) async {
    var delay = const Duration(milliseconds: 100);
    while (_isActiveIncrementalSearch(generation, operationId, consumer) &&
        consumer.isActive) {
      await Future<void>.delayed(delay);
      if (!_isActiveIncrementalSearch(generation, operationId, consumer)) {
        return;
      }
      try {
        final incoming = await core.operationStatus(operationId);
        if (!_isActiveIncrementalSearch(generation, operationId, consumer) ||
            incoming.operationId != operationId ||
            incoming.kind != 'library_search') {
          return;
        }
        final merged = _mergeSearchOperation(searchOperation, incoming);
        if (!_sameSearchOperation(searchOperation, merged)) {
          searchOperation = merged;
          notifyListeners();
          delay = const Duration(milliseconds: 100);
        } else if (delay < const Duration(milliseconds: 500)) {
          delay += const Duration(milliseconds: 80);
        }
        if (incoming.state.isTerminal) return;
      } on Object {
        delay = const Duration(milliseconds: 500);
      }
    }
  }

  LibraryOperationStatus? _mergeSearchOperation(
    LibraryOperationStatus? current,
    LibraryOperationStatus? incoming,
  ) {
    if (incoming == null) return current;
    if (current == null || current.operationId != incoming.operationId) {
      return incoming;
    }
    final useIncomingState = incoming.revision > current.revision ||
        (incoming.revision == current.revision &&
            !(current.state == LibraryOperationState.cancelling &&
                incoming.state == LibraryOperationState.running));
    return LibraryOperationStatus(
      operationId: incoming.operationId,
      kind: incoming.kind,
      state: useIncomingState ? incoming.state : current.state,
      completedUnits: _max(current.completedUnits, incoming.completedUnits),
      totalUnits: _max(current.totalUnits, incoming.totalUnits),
      bytesTransferred: _max(
        current.bytesTransferred,
        incoming.bytesTransferred,
      ),
      totalBytes: _max(current.totalBytes, incoming.totalBytes),
      itemsFound: _max(current.itemsFound, incoming.itemsFound),
      revision: _max(current.revision, incoming.revision),
    );
  }

  LibraryOperationStatus? _operationWithState(
    LibraryOperationStatus? current,
    LibraryOperationState? state,
  ) {
    if (current == null || state == null) return current;
    return LibraryOperationStatus(
      operationId: current.operationId,
      kind: current.kind,
      state: state,
      completedUnits: current.completedUnits,
      totalUnits: current.totalUnits,
      bytesTransferred: current.bytesTransferred,
      totalBytes: current.totalBytes,
      itemsFound: current.itemsFound,
      revision: current.revision,
    );
  }

  Future<void> _forgetOperation(String operationId) async {
    try {
      await core.forgetOperation(operationId);
    } on Object {
      // The native registry is bounded and evicts completed operations.
    }
  }

  void _clearSelection() {
    _descriptionGeneration++;
    selectedNode = null;
    selectedItem = null;
    description = '';
    descriptionError = '';
    isDescriptionLoading = false;
  }

  _PublicLibrarySnapshot _snapshot({String? queryOverride}) =>
      _PublicLibrarySnapshot(
        status: status,
        contentKind: contentKind,
        nodes: nodes,
        items: items,
        folder: folder,
        title: title,
        total: total,
        cursor: _cursor,
        hasMore: _hasMore,
        folderPage: _folderPage,
        currentParentId: _currentParentId,
        currentCategoryId: _currentCategoryId,
        catalogQuery: _catalogQuery,
        browseNodeId: _browseNodeId,
        browseItemRef: _browseItemRef,
        query: queryOverride ?? query,
        searchMode: searchMode,
        searchWasCancelled: searchWasCancelled,
        searchCancellationError: searchCancellationError,
      );

  void _pushHistory() {
    _history.add(
      _PublicLibraryHistoryEntry(view: _snapshot(), searchBase: _searchBase),
    );
  }

  void _restore(_PublicLibrarySnapshot snapshot) {
    status = snapshot.status;
    contentKind = snapshot.contentKind;
    nodes = snapshot.nodes;
    items = snapshot.items;
    folder = snapshot.folder;
    title = snapshot.title;
    total = snapshot.total;
    _cursor = snapshot.cursor;
    _hasMore = snapshot.hasMore;
    _folderPage = snapshot.folderPage;
    _currentParentId = snapshot.currentParentId;
    _currentCategoryId = snapshot.currentCategoryId;
    _catalogQuery = snapshot.catalogQuery;
    _browseNodeId = snapshot.browseNodeId;
    _browseItemRef = snapshot.browseItemRef;
    query = snapshot.query;
    searchMode = snapshot.searchMode;
    searchWasCancelled = snapshot.searchWasCancelled;
    searchCancellationError = snapshot.searchCancellationError;
    errorMessage = '';
    _clearSelection();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _descriptionGeneration++;
    final operationId = _activeSearchOperationId;
    _activeSearchOperationId = null;
    if (operationId != null) {
      unawaited(core.cancelOperation(operationId).catchError((_) {}));
      unawaited(_forgetOperation(operationId));
    }
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}

class _PublicLibrarySnapshot {
  const _PublicLibrarySnapshot({
    required this.status,
    required this.contentKind,
    required this.nodes,
    required this.items,
    required this.folder,
    required this.title,
    required this.total,
    required this.cursor,
    required this.hasMore,
    required this.folderPage,
    required this.currentParentId,
    required this.currentCategoryId,
    required this.catalogQuery,
    required this.browseNodeId,
    required this.browseItemRef,
    required this.query,
    required this.searchMode,
    required this.searchWasCancelled,
    required this.searchCancellationError,
  });

  final PublicLibraryContentStatus status;
  final PublicLibraryContentKind contentKind;
  final List<PublicLibraryCatalogNode> nodes;
  final List<LibraryItem> items;
  final LibraryFolder? folder;
  final String title;
  final int total;
  final String cursor;
  final bool hasMore;
  final int folderPage;
  final String currentParentId;
  final String currentCategoryId;
  final String catalogQuery;
  final String browseNodeId;
  final PublicLibraryItemRef? browseItemRef;
  final String query;
  final PublicLibrarySearchMode searchMode;
  final bool searchWasCancelled;
  final String searchCancellationError;

  String get _currentParentId => currentParentId;
}

class _PublicLibraryHistoryEntry {
  const _PublicLibraryHistoryEntry({required this.view, this.searchBase});

  final _PublicLibrarySnapshot view;
  final _PublicLibrarySnapshot? searchBase;
}

List<PublicLibraryCatalogNode> _dedupeNodes(
  List<PublicLibraryCatalogNode> values,
) {
  final ids = <String>{};
  return values.where((value) => ids.add(value.id)).toList(growable: false);
}

List<LibraryItem> _dedupeItems(List<LibraryItem> values) {
  final ids = <String>{};
  return values
      .where((value) => ids.add(value.stableKey))
      .toList(growable: false);
}

int _max(int left, int right) => left >= right ? left : right;

bool _sameSearchOperation(
  LibraryOperationStatus? left,
  LibraryOperationStatus? right,
) =>
    identical(left, right) ||
    (left != null &&
        right != null &&
        left.operationId == right.operationId &&
        left.kind == right.kind &&
        left.state == right.state &&
        left.completedUnits == right.completedUnits &&
        left.totalUnits == right.totalUnits &&
        left.bytesTransferred == right.bytesTransferred &&
        left.totalBytes == right.totalBytes &&
        left.itemsFound == right.itemsFound &&
        left.revision == right.revision);

String _errorText(Object error, {required String fallback}) {
  final message = switch (error) {
    LibraryCoreFailure() => error.message,
    FormatException() => error.message,
    _ => fallback,
  };
  final normalized = message.trim();
  return normalized.isEmpty ? fallback : normalized;
}
