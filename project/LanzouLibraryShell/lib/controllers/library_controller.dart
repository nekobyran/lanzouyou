import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../config/library_config.dart';
import '../models/download_history.dart';
import '../models/library_item.dart';
import '../services/download_coordinator.dart';
import '../services/library_core.dart';

enum LibraryContentStatus { loading, data, empty, error }

class LibraryBreadcrumb {
  const LibraryBreadcrumb({required this.title, required this.shareUrl});

  final String title;
  final String shareUrl;
}

/// Immutable display state used while temporarily opening one search result's
/// source. Restoring this snapshot does not contact the native core again.
class LibrarySearchViewSnapshot {
  const LibrarySearchViewSnapshot._({
    required this.status,
    required this.selectedSource,
    required this.folder,
    required this.items,
    required this.breadcrumbs,
    required this.query,
    required this.errorMessage,
    required this.searchWasCancelled,
    required this.searchCancellationError,
    required this.searchOperation,
  });

  final LibraryContentStatus status;
  final LibrarySource? selectedSource;
  final LibraryFolder? folder;
  final List<LibraryItem> items;
  final List<LibraryBreadcrumb> breadcrumbs;
  final String query;
  final String errorMessage;
  final bool searchWasCancelled;
  final String searchCancellationError;
  final LibraryOperationStatus? searchOperation;
}

class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.config,
    required this.core,
    this.downloads,
  }) {
    downloads?.addListener(_handleDownloadsChanged);
  }

  final LibraryConfig config;
  final LibraryCore core;
  final DownloadCoordinator? downloads;

  LibraryContentStatus status = LibraryContentStatus.loading;
  LibrarySource? selectedSource;
  LibraryFolder? folder;
  List<LibraryItem> items = const [];
  List<LibraryBreadcrumb> breadcrumbs = const [];
  LibraryItem? selectedItem;
  String query = '';
  String errorMessage = '';
  String detailError = '';
  String detailDescription = '';
  String descriptionError = '';
  String downloadActionError = '';
  bool isDescriptionLoading = false;
  bool isLoadingMore = false;
  bool isSearchCancelling = false;
  bool searchWasCancelled = false;
  String searchCancellationError = '';
  String loadMoreError = '';
  LibraryOperationStatus? searchOperation;
  int _generation = 0;
  int _descriptionGeneration = 0;
  int _operationSequence = 0;
  int _contentIntent = 0;
  int _cancelRequest = 0;
  String? _searchOperationId;
  bool _disposed = false;
  final LinkedHashMap<String, String> _descriptionCache = LinkedHashMap();
  final LinkedHashMap<String, Future<String>> _descriptionRequests =
      LinkedHashMap();
  final LinkedHashMap<String, Future<Uint8List?>> _assetCache = LinkedHashMap();
  final Queue<_PendingAssetFetch> _assetFetchQueue = Queue();
  int _activeAssetFetches = 0;
  Timer? _descriptionDebounce;
  _PendingDescription? _pendingDescription;
  Future<void>? _loadMoreFuture;

  bool get isSearching => query.isNotEmpty;

  LibrarySearchViewSnapshot? captureSearchView() {
    if (_disposed || !isSearching) return null;
    return LibrarySearchViewSnapshot._(
      status: status,
      selectedSource: selectedSource,
      folder: folder,
      items: List<LibraryItem>.unmodifiable(items),
      breadcrumbs: List<LibraryBreadcrumb>.unmodifiable(breadcrumbs),
      query: query,
      errorMessage: errorMessage,
      searchWasCancelled: searchWasCancelled,
      searchCancellationError: searchCancellationError,
      searchOperation: searchOperation,
    );
  }

  /// Restores a previously captured search view synchronously and invalidates
  /// any directory response still in flight, so it cannot overwrite the view.
  void restoreSearchView(LibrarySearchViewSnapshot snapshot) {
    if (_disposed || snapshot.query.isEmpty) return;
    _contentIntent++;
    _generation++;
    _cancelRequest++;
    _descriptionGeneration++;
    _descriptionDebounce?.cancel();
    _descriptionDebounce = null;
    _pendingDescription = null;
    _loadMoreFuture = null;
    _searchOperationId = null;

    status = snapshot.status;
    selectedSource = snapshot.selectedSource;
    folder = snapshot.folder;
    items = snapshot.items;
    breadcrumbs = snapshot.breadcrumbs;
    query = snapshot.query;
    errorMessage = snapshot.errorMessage;
    searchWasCancelled = snapshot.searchWasCancelled;
    searchCancellationError = snapshot.searchCancellationError;
    searchOperation = snapshot.searchOperation;
    isSearchCancelling = false;
    isLoadingMore = false;
    loadMoreError = '';
    selectedItem = null;
    detailError = '';
    detailDescription = '';
    descriptionError = '';
    isDescriptionLoading = false;
    notifyListeners();
  }

  bool get canCancelSearch {
    final operationState = searchOperation?.state;
    return isSearching &&
        _searchOperationId != null &&
        core is LibraryOperationCore &&
        status == LibraryContentStatus.loading &&
        !isSearchCancelling &&
        operationState == LibraryOperationState.running;
  }

  Future<Uint8List?> loadAsset(String url) {
    final normalized = url.trim();
    if (_disposed || normalized.isEmpty || core is! LibraryAssetCore) {
      return Future<Uint8List?>.value();
    }
    final cached = _assetCache.remove(normalized);
    if (cached != null) {
      _assetCache[normalized] = cached;
      return cached;
    }
    if (_assetFetchQueue.length >= _maxPendingAssetFetches &&
        _activeAssetFetches >= _maxConcurrentAssetFetches) {
      return Future<Uint8List?>.value();
    }
    final completer = Completer<Uint8List?>();
    final future = completer.future;
    _assetFetchQueue.add(_PendingAssetFetch(normalized, completer));
    _assetCache[normalized] = future;
    unawaited(
      future.then((bytes) {
        if (bytes == null && identical(_assetCache[normalized], future)) {
          _assetCache.remove(normalized);
        }
      }),
    );
    while (_assetCache.length > _maxAssetCacheEntries) {
      _assetCache.remove(_assetCache.keys.first);
    }
    _drainAssetFetchQueue();
    return future;
  }

  void _drainAssetFetchQueue() {
    if (_disposed) {
      while (_assetFetchQueue.isNotEmpty) {
        final request = _assetFetchQueue.removeFirst();
        if (!request.completer.isCompleted) request.completer.complete(null);
      }
      return;
    }
    while (_activeAssetFetches < _maxConcurrentAssetFetches &&
        _assetFetchQueue.isNotEmpty) {
      final request = _assetFetchQueue.removeFirst();
      _activeAssetFetches++;
      unawaited(_runAssetFetch(request));
    }
  }

  Future<void> _runAssetFetch(_PendingAssetFetch request) async {
    Uint8List? bytes;
    try {
      bytes = (await (core as LibraryAssetCore).fetchAsset(
        url: request.url,
      )).bytes;
    } on Object {
      bytes = null;
    } finally {
      _activeAssetFetches--;
      if (!request.completer.isCompleted) request.completer.complete(bytes);
      _drainAssetFetchQueue();
    }
  }

  Future<void> initialize() async {
    if (config.features.download && downloads != null) {
      unawaited(_initializeDownloads());
    }
    if (config.sources.isEmpty) {
      status = LibraryContentStatus.empty;
      notifyListeners();
      return;
    }
    selectedSource = config.sources.first;
    breadcrumbs = [
      LibraryBreadcrumb(
        title: selectedSource!.title,
        shareUrl: selectedSource!.shareUrl,
      ),
    ];
    if (!config.features.browse) {
      status = LibraryContentStatus.empty;
      notifyListeners();
      return;
    }
    await _browseCurrent();
  }

  Future<void> _initializeDownloads() async {
    try {
      await downloads!.initialize();
    } on Object catch (error) {
      downloadActionError = _safeDetailError(error, fallback: '无法读取下载记录，请稍后重试');
      notifyListeners();
    }
  }

  Future<void> reloadDownloads() async {
    final coordinator = downloads;
    if (!config.features.download || coordinator == null) return;
    downloadActionError = '';
    notifyListeners();
    await _initializeDownloads();
  }

  Future<void> selectSource(LibrarySource source) async {
    if (_disposed) return;
    if (selectedSource?.sourceId == source.sourceId && !isSearching) return;
    final intent = _beginContentIntent();
    final cancelled = await _cancelActiveSearch();
    if (!_isCurrentIntent(intent)) return;
    if (!cancelled) {
      _showSupersessionCancellationError();
      return;
    }
    selectedSource = source;
    query = '';
    searchWasCancelled = false;
    _clearSelectionState();
    breadcrumbs = [
      LibraryBreadcrumb(title: source.title, shareUrl: source.shareUrl),
    ];
    if (!config.features.browse) {
      status = LibraryContentStatus.empty;
      items = const [];
      notifyListeners();
      return;
    }
    await _browseCurrent();
  }

  Future<void> openFolder(LibraryItem item) async {
    if (!config.features.browse ||
        !item.isFolder ||
        item.navigationUrl.isEmpty) {
      return;
    }
    final source = config.sourceById(item.sourceId) ?? selectedSource;
    if (source == null) return;
    selectedSource = source;
    query = '';
    final next = [
      ...breadcrumbs,
      LibraryBreadcrumb(title: item.title, shareUrl: item.navigationUrl),
    ];
    await _browse(
      source: source,
      shareUrl: item.navigationUrl,
      nextBreadcrumbs: next,
    );
  }

  Future<void> openBreadcrumb(int index) async {
    if (index < 0 || index >= breadcrumbs.length) return;
    final source = selectedSource;
    if (source == null) return;
    query = '';
    await _browse(
      source: source,
      shareUrl: breadcrumbs[index].shareUrl,
      nextBreadcrumbs: breadcrumbs.take(index + 1).toList(growable: false),
    );
  }

  Future<void> search(String value) async {
    if (_disposed || !config.features.search) return;
    final normalized = value.trim();
    final intent = _beginContentIntent();
    final cancelled = await _cancelActiveSearch();
    if (!_isCurrentIntent(intent)) return;
    if (!cancelled) {
      _showSupersessionCancellationError();
      return;
    }
    if (normalized.isEmpty) {
      query = '';
      searchWasCancelled = false;
      await _browseCurrent();
      return;
    }
    query = normalized;
    searchWasCancelled = false;
    searchCancellationError = '';
    _clearSelectionState();
    final scope = config.sources
        .where((source) => source.searchable)
        .toList(growable: false);
    if (scope.isEmpty) {
      searchOperation = null;
      _searchOperationId = null;
      isSearchCancelling = false;
      final generation = _startLoading();
      if (generation != _generation) return;
      items = const [];
      folder = null;
      status = LibraryContentStatus.empty;
      notifyListeners();
      return;
    }
    final operationCore = core is LibraryOperationCore
        ? core as LibraryOperationCore
        : null;
    final operationId = operationCore == null ? null : _newOperationId();
    _searchOperationId = operationId;
    isSearchCancelling = false;
    searchOperation = operationId == null
        ? null
        : LibraryOperationStatus(
            operationId: operationId,
            kind: 'library_search',
            state: LibraryOperationState.running,
            completedUnits: 0,
            totalUnits: scope.length,
            bytesTransferred: 0,
            totalBytes: 0,
            itemsFound: 0,
          );
    final generation = _startLoading();
    if (operationId != null) {
      unawaited(_pollSearch(operationCore!, operationId, generation));
    }
    try {
      final result = await core.search(
        query: normalized,
        sources: scope,
        operationId: operationId,
      );
      if (generation != _generation) return;
      searchCancellationError = '';
      items = result.items;
      folder = null;
      status = items.isEmpty
          ? LibraryContentStatus.empty
          : LibraryContentStatus.data;
    } on Object catch (error) {
      if (generation != _generation) return;
      if (error is LibraryCoreFailure && error.code == 'cancelled') {
        searchCancellationError = '';
        items = const [];
        folder = null;
        status = LibraryContentStatus.empty;
        searchWasCancelled = true;
      } else {
        _setError(error);
      }
    } finally {
      if (operationId != null) {
        if (_searchOperationId == operationId) {
          _searchOperationId = null;
          isSearchCancelling = false;
        }
        unawaited(_forgetOperation(operationCore!, operationId));
      }
    }
    notifyListeners();
  }

  Future<void> cancelSearch() async {
    await _cancelActiveSearch();
  }

  Future<void> refresh() async {
    if (isSearching) {
      await search(query);
      return;
    }
    if (!config.features.browse) return;
    await _browseCurrent(refresh: true);
  }

  Future<void> retry() => refresh();

  Future<void> loadMore() {
    final active = _loadMoreFuture;
    if (active != null) return active;
    final currentFolder = folder;
    final source = selectedSource;
    if (currentFolder == null || source == null || !currentFolder.hasMore) {
      return Future<void>.value();
    }
    final expectedGeneration = _generation;
    late final Future<void> task;
    task =
        _loadMoreWhenReady(
          currentFolder: currentFolder,
          source: source,
          expectedGeneration: expectedGeneration,
        ).whenComplete(() {
          if (identical(_loadMoreFuture, task)) _loadMoreFuture = null;
        });
    _loadMoreFuture = task;
    return task;
  }

  Future<void> _loadMoreWhenReady({
    required LibraryFolder currentFolder,
    required LibrarySource source,
    required int expectedGeneration,
  }) async {
    final readyAt = currentFolder.nextPageReadyAtMs;
    while (readyAt != null) {
      final remaining = readyAt - DateTime.now().millisecondsSinceEpoch;
      if (remaining <= 0) break;
      await Future<void>.delayed(
        Duration(milliseconds: remaining.clamp(1, 60 * 1000)),
      );
      if (_disposed || expectedGeneration != _generation) return;
    }
    if (_disposed ||
        expectedGeneration != _generation ||
        !identical(folder, currentFolder) ||
        selectedSource?.sourceId != source.sourceId) {
      return;
    }
    final oldItems = items;
    final generation = _startLoading(loadingMore: true);
    loadMoreError = '';
    try {
      final next = await core.browse(
        sourceId: source.sourceId,
        shareUrl: breadcrumbs.last.shareUrl,
        password: source.password,
        page: currentFolder.page + 1,
      );
      if (generation != _generation) return;
      final keys = oldItems.map((item) => item.stableKey).toSet();
      items = [
        ...oldItems,
        ...next.items.where((item) => keys.add(item.stableKey)),
      ];
      folder = next;
      status = LibraryContentStatus.data;
      loadMoreError = '';
    } on Object catch (error) {
      if (generation != _generation) return;
      items = oldItems;
      folder = currentFolder;
      status = oldItems.isEmpty
          ? LibraryContentStatus.empty
          : LibraryContentStatus.data;
      loadMoreError = _safeDetailError(error, fallback: '下一页加载失败，请稍后重试');
    } finally {
      if (generation == _generation) {
        isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  void selectItem(LibraryItem item) {
    final generation = ++_descriptionGeneration;
    _descriptionDebounce?.cancel();
    _descriptionDebounce = null;
    _pendingDescription = null;
    selectedItem = item;
    detailError = '';
    descriptionError = '';
    detailDescription = item.description;

    final cachedDescription = _takeDescription(item.stableKey);
    if (cachedDescription != null) {
      detailDescription = cachedDescription;
      isDescriptionLoading = false;
      notifyListeners();
      return;
    }

    final source = config.sourceById(item.sourceId) ?? selectedSource;
    final shouldLoad =
        config.features.showDescription &&
        !item.isFolder &&
        item.description.isEmpty &&
        item.navigationUrl.isNotEmpty &&
        source != null;
    isDescriptionLoading = shouldLoad;
    notifyListeners();
    if (shouldLoad) {
      _descriptionDebounce = Timer(
        Duration.zero,
        () => _queueDescription(item, source, generation),
      );
    }
  }

  void clearSelection() {
    _clearSelectionState();
    notifyListeners();
  }

  void _queueDescription(
    LibraryItem item,
    LibrarySource source,
    int generation,
  ) {
    _descriptionDebounce = null;
    if (!_isCurrentDescription(item.stableKey, generation)) return;
    if (_descriptionRequests.length >= _maxConcurrentDescriptionRequests &&
        !_descriptionRequests.containsKey(item.stableKey)) {
      _pendingDescription = _PendingDescription(item, source, generation);
      return;
    }
    unawaited(_loadDescription(item, source, generation));
  }

  Future<void> _loadDescription(
    LibraryItem item,
    LibrarySource source,
    int generation,
  ) async {
    try {
      final description = await _descriptionFor(item, source);
      if (!_isCurrentDescription(item.stableKey, generation)) return;
      detailDescription = description;
    } on Object catch (error) {
      if (!_isCurrentDescription(item.stableKey, generation)) return;
      descriptionError = _safeDetailError(error, fallback: '无法加载简介，请稍后重试');
    }
    if (!_isCurrentDescription(item.stableKey, generation)) return;
    isDescriptionLoading = false;
    notifyListeners();
  }

  Future<String> _descriptionFor(LibraryItem item, LibrarySource source) {
    final stableKey = item.stableKey;
    final cached = _takeDescription(stableKey);
    if (cached != null) return Future<String>.value(cached);

    final existing = _descriptionRequests.remove(stableKey);
    if (existing != null) {
      _descriptionRequests[stableKey] = existing;
      return existing;
    }

    final completer = Completer<String>();
    final request = completer.future;
    _descriptionRequests[stableKey] = request;
    unawaited(
      _runDescriptionRequest(
        stableKey: stableKey,
        item: item,
        source: source,
        request: request,
        completer: completer,
      ),
    );
    return request;
  }

  Future<void> _runDescriptionRequest({
    required String stableKey,
    required LibraryItem item,
    required LibrarySource source,
    required Future<String> request,
    required Completer<String> completer,
  }) async {
    try {
      final result = await core.describe(
        sourceId: item.sourceId,
        shareUrl: item.navigationUrl,
        password: source.password,
      );
      _putDescription(stableKey, result.description);
      completer.complete(result.description);
    } on Object catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    } finally {
      if (identical(_descriptionRequests[stableKey], request)) {
        _descriptionRequests.remove(stableKey);
      }
      final pending = _pendingDescription;
      _pendingDescription = null;
      if (pending != null &&
          _isCurrentDescription(pending.item.stableKey, pending.generation)) {
        _queueDescription(pending.item, pending.source, pending.generation);
      }
    }
  }

  String? _takeDescription(String stableKey) {
    final cached = _descriptionCache.remove(stableKey);
    if (cached != null) _descriptionCache[stableKey] = cached;
    return cached;
  }

  void _putDescription(String stableKey, String description) {
    _descriptionCache.remove(stableKey);
    _descriptionCache[stableKey] = description;
    while (_descriptionCache.length > _maxDescriptionCacheEntries) {
      _descriptionCache.remove(_descriptionCache.keys.first);
    }
  }

  DownloadSnapshot? activeDownloadFor(LibraryItem item) {
    final coordinator = downloads;
    if (coordinator == null) return null;
    for (final download in coordinator.active.reversed) {
      if (download.itemStableKey == item.stableKey) return download;
    }
    return null;
  }

  DownloadHistoryEntry? latestDownloadFor(LibraryItem item) {
    final coordinator = downloads;
    if (coordinator == null) return null;
    DownloadHistoryEntry? latest;
    for (final entry in coordinator.history) {
      if (entry.itemStableKey != item.stableKey) continue;
      if (latest == null || entry.updatedAt.isAfter(latest.updatedAt)) {
        latest = entry;
      }
    }
    return latest;
  }

  Future<void> downloadItem(LibraryItem item) async {
    if (!config.features.download || item.isFolder) return;
    final coordinator = downloads;
    if (coordinator == null) {
      detailError = '下载服务未初始化，请重新打开应用';
      notifyListeners();
      return;
    }
    if (activeDownloadFor(item) != null) return;
    final source = config.sourceById(item.sourceId);
    if (source == null) {
      detailError = '文件来源不可用，无法下载';
      notifyListeners();
      return;
    }
    detailError = '';
    downloadActionError = '';
    notifyListeners();
    try {
      await coordinator.download(
        sourceId: item.sourceId,
        shareUrl: item.navigationUrl,
        password: source.password,
        itemStableKey: item.stableKey,
        displayName: item.title,
        suggestedFileName: item.title,
      );
    } on Object catch (error) {
      detailError = _safeDetailError(error, fallback: '下载失败，请稍后重试');
      notifyListeners();
    }
  }

  Future<void> cancelDownload(DownloadSnapshot download) async {
    final coordinator = downloads;
    if (coordinator == null || download.state.isTerminal) return;
    downloadActionError = '';
    try {
      await coordinator.cancel(download.operationId);
    } on Object catch (error) {
      downloadActionError = _safeDetailError(error, fallback: '无法取消下载，请稍后重试');
      notifyListeners();
    }
  }

  Future<void> retryDownload(DownloadHistoryEntry entry) async {
    final coordinator = downloads;
    final source = config.sourceById(entry.sourceId);
    if (coordinator == null) return;
    if (source == null) {
      downloadActionError = '原软件源已移除，无法重新下载';
      if (selectedItem?.stableKey == entry.itemStableKey) {
        detailError = downloadActionError;
      }
      notifyListeners();
      return;
    }
    final alreadyActive = coordinator.active.any(
      (task) =>
          task.itemStableKey == entry.itemStableKey && !task.state.isTerminal,
    );
    if (alreadyActive) {
      downloadActionError = '此项目已在下载队列中';
      if (selectedItem?.stableKey == entry.itemStableKey) {
        detailError = downloadActionError;
      }
      notifyListeners();
      return;
    }
    downloadActionError = '';
    detailError = '';
    notifyListeners();
    try {
      await coordinator.retry(entry, password: source.password);
    } on Object catch (error) {
      final message = _safeDetailError(error, fallback: '无法重新下载，请稍后重试');
      downloadActionError = message;
      if (selectedItem?.stableKey == entry.itemStableKey) detailError = message;
      notifyListeners();
    }
  }

  Future<void> openDownload(DownloadHistoryEntry entry) async {
    final coordinator = downloads;
    if (coordinator == null ||
        entry.status != DownloadHistoryStatus.succeeded) {
      return;
    }
    downloadActionError = '';
    detailError = '';
    notifyListeners();
    try {
      await coordinator.open(entry);
    } on Object catch (error) {
      final message = _safeDetailError(error, fallback: '无法打开文件，请确认文件仍然存在');
      downloadActionError = message;
      if (selectedItem?.stableKey == entry.itemStableKey) detailError = message;
      notifyListeners();
    }
  }

  Future<void> deleteDownloadHistory(DownloadHistoryEntry entry) async {
    final coordinator = downloads;
    if (coordinator == null) return;
    downloadActionError = '';
    try {
      await coordinator.deleteHistory(entry.id);
    } on Object catch (error) {
      downloadActionError = _safeDetailError(error, fallback: '无法移除下载记录，请稍后重试');
      notifyListeners();
    }
  }

  void _handleDownloadsChanged() => notifyListeners();

  Future<void> _browseCurrent({bool refresh = false}) async {
    if (!config.features.browse) {
      status = LibraryContentStatus.empty;
      notifyListeners();
      return;
    }
    final source = selectedSource;
    if (source == null) {
      status = LibraryContentStatus.empty;
      notifyListeners();
      return;
    }
    final shareUrl = breadcrumbs.isEmpty
        ? source.shareUrl
        : breadcrumbs.last.shareUrl;
    await _browse(
      source: source,
      shareUrl: shareUrl,
      nextBreadcrumbs: breadcrumbs.isEmpty
          ? [LibraryBreadcrumb(title: source.title, shareUrl: source.shareUrl)]
          : breadcrumbs,
      refresh: refresh,
    );
  }

  Future<void> _browse({
    required LibrarySource source,
    required String shareUrl,
    required List<LibraryBreadcrumb> nextBreadcrumbs,
    bool refresh = false,
  }) async {
    _clearSelectionState();
    final generation = _startLoading();
    try {
      final result = await core.browse(
        sourceId: source.sourceId,
        shareUrl: shareUrl,
        password: source.password,
        refresh: refresh,
      );
      if (generation != _generation) return;
      folder = result;
      items = result.items;
      breadcrumbs = nextBreadcrumbs;
      status = items.isEmpty
          ? LibraryContentStatus.empty
          : LibraryContentStatus.data;
    } on Object catch (error) {
      if (generation != _generation) return;
      _setError(error);
    }
    notifyListeners();
  }

  int _startLoading({bool loadingMore = false}) {
    if (!loadingMore) {
      _loadMoreFuture = null;
      loadMoreError = '';
    }
    final generation = ++_generation;
    isLoadingMore = loadingMore;
    status = LibraryContentStatus.loading;
    errorMessage = '';
    detailError = '';
    searchCancellationError = '';
    notifyListeners();
    return generation;
  }

  int _beginContentIntent() {
    final intent = ++_contentIntent;
    _generation++;
    return intent;
  }

  bool _isCurrentIntent(int intent) => !_disposed && intent == _contentIntent;

  String _newOperationId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final sequence = (++_operationSequence).toRadixString(36);
    return 'library-search-$timestamp-$sequence';
  }

  Future<bool> _cancelActiveSearch() async {
    final operationId = _searchOperationId;
    final operationCore = core is LibraryOperationCore
        ? core as LibraryOperationCore
        : null;
    if (operationId == null || operationCore == null) return true;
    final cancelRequest = ++_cancelRequest;
    isSearchCancelling = true;
    searchCancellationError = '';
    final progress = searchOperation;
    if (progress != null && !progress.state.isTerminal) {
      searchOperation = _withOperationState(
        progress,
        LibraryOperationState.cancelling,
      );
    }
    notifyListeners();

    final error = await _requestCancellation(
      operationCore,
      operationId,
      isAlreadyComplete: () => _searchOperationId != operationId,
    );
    if (_searchOperationId != operationId) return true;
    if (cancelRequest != _cancelRequest) return error == null;
    if (error == null) {
      isSearchCancelling = true;
      searchCancellationError = '';
      notifyListeners();
      return true;
    }

    isSearchCancelling = false;
    final current = searchOperation;
    if (current != null && current.state == LibraryOperationState.cancelling) {
      searchOperation = _withOperationState(
        current,
        LibraryOperationState.running,
      );
    }
    searchCancellationError = _safeDetailError(
      error,
      fallback: '无法取消当前搜索，请稍后重试',
    );
    notifyListeners();
    return false;
  }

  Future<void> _pollSearch(
    LibraryOperationCore operationCore,
    String operationId,
    int generation,
  ) async {
    var delayMs = _searchPollInitialDelayMs;
    while (_searchOperationId == operationId && generation == _generation) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (_searchOperationId != operationId || generation != _generation) {
        return;
      }
      try {
        final progress = await operationCore
            .operationStatus(operationId)
            .timeout(_operationControlTimeout);
        if (_searchOperationId != operationId || generation != _generation) {
          return;
        }
        if (progress.operationId != operationId ||
            progress.kind != 'library_search') {
          throw const FormatException('搜索进度身份不匹配');
        }
        final merged = _mergeSearchProgress(progress);
        final cancelling =
            merged.state == LibraryOperationState.cancelling ||
            merged.state == LibraryOperationState.cancelled;
        final changed =
            !_sameOperationStatus(searchOperation, merged) ||
            isSearchCancelling != cancelling;
        if (changed) {
          searchOperation = merged;
          isSearchCancelling = cancelling;
          notifyListeners();
          delayMs = _searchPollInitialDelayMs;
        } else if (delayMs < _searchPollMaxDelayMs) {
          delayMs += _searchPollBackoffStepMs;
          if (delayMs > _searchPollMaxDelayMs) {
            delayMs = _searchPollMaxDelayMs;
          }
        }
        if (merged.state.isTerminal) return;
      } on Object {
        // Registration and terminal cleanup can race a poll. The main search
        // response remains the authoritative result.
        delayMs = _searchPollMaxDelayMs;
      }
    }
  }

  Future<void> _forgetOperation(
    LibraryOperationCore operationCore,
    String operationId,
  ) async {
    try {
      await operationCore
          .forgetOperation(operationId)
          .timeout(_operationControlTimeout);
    } on Object {
      // The native registry is bounded and also evicts terminal operations.
    }
  }

  Future<Object?> _requestCancellation(
    LibraryOperationCore operationCore,
    String operationId, {
    bool Function()? isAlreadyComplete,
  }) async {
    for (var attempt = 0; ; attempt++) {
      if (isAlreadyComplete?.call() == true) return null;
      try {
        await operationCore
            .cancelOperation(operationId)
            .timeout(_operationControlTimeout);
        return null;
      } on LibraryCoreFailure catch (error) {
        if (isAlreadyComplete?.call() == true) return null;
        final canRetryRegistration =
            error.code == 'operation_not_found' &&
            attempt < _operationRegistrationRetryDelays.length;
        if (!canRetryRegistration) return error;
        await Future<void>.delayed(_operationRegistrationRetryDelays[attempt]);
      } on Object catch (error) {
        if (isAlreadyComplete?.call() == true) return null;
        return error;
      }
    }
  }

  LibraryOperationStatus _mergeSearchProgress(LibraryOperationStatus incoming) {
    final current = searchOperation;
    if (current == null || current.operationId != incoming.operationId) {
      return incoming;
    }
    var state = incoming.state;
    if (current.state == LibraryOperationState.cancelling &&
        state == LibraryOperationState.running) {
      state = LibraryOperationState.cancelling;
    } else if (current.state.isTerminal && !state.isTerminal) {
      state = current.state;
    }
    return LibraryOperationStatus(
      operationId: incoming.operationId,
      kind: incoming.kind,
      state: state,
      completedUnits: _maxInt(current.completedUnits, incoming.completedUnits),
      totalUnits: _maxInt(current.totalUnits, incoming.totalUnits),
      bytesTransferred: _maxInt(
        current.bytesTransferred,
        incoming.bytesTransferred,
      ),
      totalBytes: _maxInt(current.totalBytes, incoming.totalBytes),
      itemsFound: _maxInt(current.itemsFound, incoming.itemsFound),
      revision: _maxInt(current.revision, incoming.revision),
    );
  }

  LibraryOperationStatus _withOperationState(
    LibraryOperationStatus operation,
    LibraryOperationState state,
  ) => LibraryOperationStatus(
    operationId: operation.operationId,
    kind: operation.kind,
    state: state,
    completedUnits: operation.completedUnits,
    totalUnits: operation.totalUnits,
    bytesTransferred: operation.bytesTransferred,
    totalBytes: operation.totalBytes,
    itemsFound: operation.itemsFound,
    revision: operation.revision,
  );

  void _showSupersessionCancellationError() {
    status = LibraryContentStatus.error;
    errorMessage = searchCancellationError.isEmpty
        ? '无法取消当前搜索，请稍后重试'
        : searchCancellationError;
    notifyListeners();
  }

  void _setError(Object error) {
    status = LibraryContentStatus.error;
    errorMessage = _safeDetailError(error, fallback: '软件目录加载失败，请稍后重试');
  }

  bool _isCurrentDescription(String stableKey, int generation) =>
      generation == _descriptionGeneration &&
      selectedItem?.stableKey == stableKey;

  void _clearSelectionState() {
    _descriptionGeneration++;
    _descriptionDebounce?.cancel();
    _descriptionDebounce = null;
    _pendingDescription = null;
    _loadMoreFuture = null;
    selectedItem = null;
    detailError = '';
    detailDescription = '';
    descriptionError = '';
    isDescriptionLoading = false;
  }

  String _safeDetailError(Object error, {required String fallback}) {
    if (config.sources.any((source) => source.password.isNotEmpty)) {
      return fallback;
    }
    var message = switch (error) {
      LibraryCoreFailure() => error.message,
      DownloadCoordinatorFailure() => error.message,
      FormatException() => error.message,
      _ => fallback,
    };
    for (final source in config.sources) {
      if (source.password.isNotEmpty) {
        message = message.replaceAll(source.password, '***');
      }
    }
    return message.trim().isEmpty ? fallback : message;
  }

  @override
  void dispose() {
    if (_disposed) return;
    downloads?.removeListener(_handleDownloadsChanged);
    final operationId = _searchOperationId;
    final operationCore = core is LibraryOperationCore
        ? core as LibraryOperationCore
        : null;
    final lifecycle = core is LibraryCoreLifecycle
        ? core as LibraryCoreLifecycle
        : null;
    final downloadCoordinator = downloads;
    _disposed = true;
    _contentIntent++;
    _generation++;
    _loadMoreFuture = null;
    _descriptionGeneration++;
    _descriptionDebounce?.cancel();
    _descriptionDebounce = null;
    _pendingDescription = null;
    while (_assetFetchQueue.isNotEmpty) {
      final request = _assetFetchQueue.removeFirst();
      if (!request.completer.isCompleted) request.completer.complete(null);
    }
    _cancelRequest++;
    _searchOperationId = null;
    super.dispose();
    if (lifecycle != null ||
        downloadCoordinator != null ||
        (operationId != null && operationCore != null)) {
      unawaited(
        _shutdownOperationsAndCloseCore(
          lifecycle: lifecycle,
          operationCore: operationCore,
          operationId: operationId,
          downloadCoordinator: downloadCoordinator,
        ),
      );
    }
  }

  Future<void> _shutdownOperationsAndCloseCore({
    required LibraryCoreLifecycle? lifecycle,
    required LibraryOperationCore? operationCore,
    required String? operationId,
    required DownloadCoordinator? downloadCoordinator,
  }) async {
    if (operationId != null && operationCore != null) {
      await _requestCancellation(operationCore, operationId);
    }
    if (downloadCoordinator != null) {
      try {
        await downloadCoordinator.shutdown();
      } on Object {
        // Disposal cannot surface an error after the owning widget is gone.
      } finally {
        downloadCoordinator.dispose();
      }
    }
    if (lifecycle != null) {
      try {
        await lifecycle.close();
      } on Object {
        // Disposal cannot surface an error after the owning widget is gone.
      }
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}

const _operationControlTimeout = Duration(seconds: 2);
const _searchPollInitialDelayMs = 160;
const _searchPollBackoffStepMs = 80;
const _searchPollMaxDelayMs = 400;
const _maxConcurrentDescriptionRequests = 4;
const _maxDescriptionCacheEntries = 64;
const _maxAssetCacheEntries = 64;
const _maxConcurrentAssetFetches = 6;
const _maxPendingAssetFetches = 32;
const _operationRegistrationRetryDelays = <Duration>[
  Duration(milliseconds: 20),
  Duration(milliseconds: 40),
  Duration(milliseconds: 80),
  Duration(milliseconds: 120),
  Duration(milliseconds: 160),
  Duration(milliseconds: 200),
  Duration(milliseconds: 250),
];

int _maxInt(int left, int right) => left >= right ? left : right;

bool _sameOperationStatus(
  LibraryOperationStatus? left,
  LibraryOperationStatus right,
) =>
    left != null &&
    left.operationId == right.operationId &&
    left.kind == right.kind &&
    left.state == right.state &&
    left.completedUnits == right.completedUnits &&
    left.totalUnits == right.totalUnits &&
    left.bytesTransferred == right.bytesTransferred &&
    left.totalBytes == right.totalBytes &&
    left.itemsFound == right.itemsFound &&
    left.revision == right.revision;

class _PendingDescription {
  const _PendingDescription(this.item, this.source, this.generation);

  final LibraryItem item;
  final LibrarySource source;
  final int generation;
}

class _PendingAssetFetch {
  const _PendingAssetFetch(this.url, this.completer);

  final String url;
  final Completer<Uint8List?> completer;
}
