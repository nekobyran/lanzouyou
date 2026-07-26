import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/source_registry.dart';
import '../../services/library_core.dart';
import '../../services/source_registry_core.dart';

enum SourceRegistryStatus { loading, data, empty, error }

class SourceRegistryController extends ChangeNotifier {
  SourceRegistryController({required this.core});

  final SourceRegistryCore core;

  SourceRegistryStatus status = SourceRegistryStatus.loading;
  SourceRegistrySnapshot? snapshot;
  List<SourceRegistrySource> sources = const [];
  String query = '';
  String categoryId = 'all';
  SourceRegistryFilter filter = const SourceRegistryFilter();
  String errorMessage = '';
  String loadMoreErrorMessage = '';
  String actionMessage = '';
  bool isLoadingMore = false;
  bool isMutating = false;
  bool hasMore = false;
  int total = 0;
  Set<String> selectedIds = const {};

  String _nextCursor = '';
  int _generation = 0;
  Timer? _queryTimer;
  bool _disposed = false;
  Future<void>? _loadMoreFuture;

  List<SourceRegistryCategory> get categories =>
      snapshot?.categories ?? const [];

  int get registryGeneration => snapshot?.generation ?? 0;

  bool get selectionMode => selectedIds.isNotEmpty;

  List<SourceRegistrySource> get selectedSources => sources
      .where((source) => selectedIds.contains(source.id))
      .toList(growable: false);

  List<String> get selectedRetestableIds => selectedSources
      .where((source) => source.kind == SourceRegistrySourceKind.official)
      .map((source) => source.id)
      .take(256)
      .toList(growable: false);

  bool get canAdd => core is SourceRegistryAddCore;
  bool get canRetest => core is SourceRegistryRetestCore;
  bool get canMutateSources => core is SourceRegistrySourceMutationCore;
  bool get canManageCategories => core is SourceRegistryCategoryCore;
  bool get canManageComposites => core is SourceRegistryCompositeCore;
  bool get canPreviewImport => core is SourceRegistryImportPreviewCore;
  bool get canManageRules => core is SourceRegistryRulesCore;
  bool get canRestore => core is SourceRegistryRestoreCore;

  bool get hasAnyActionCapability =>
      canAdd ||
      canManageCategories ||
      canManageComposites ||
      canPreviewImport ||
      canManageRules ||
      canRestore;

  Future<void> initialize() async {
    if (snapshot != null || _disposed) return;
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    status = SourceRegistryStatus.loading;
    errorMessage = '';
    loadMoreErrorMessage = '';
    actionMessage = '';
    hasMore = false;
    _nextCursor = '';
    notifyListeners();
    try {
      final values = await Future.wait<Object>([
        core.sourceRegistrySnapshot(),
        core.sourceRegistryPage(
          limit: 100,
          query: query,
          categoryId: categoryId,
          kind: filter.wireKind,
          searchable: filter.searchable,
          childDirectory: filter.childDirectory,
          builtIn: filter.builtIn,
        ),
      ]);
      if (!_isCurrent(generation)) return;
      final nextSnapshot = values[0] as SourceRegistrySnapshot;
      final page = values[1] as SourceRegistryPage;
      if (nextSnapshot.generation != page.generation) {
        throw const LibraryCoreFailure(
          'generationConflict',
          '来源在读取时发生变化，请重试',
          retriable: true,
        );
      }
      snapshot = nextSnapshot;
      sources = page.sources;
      total = page.total;
      hasMore = page.hasMore;
      _nextCursor = page.nextCursor;
      final visible = sources.map((source) => source.id).toSet();
      selectedIds = selectedIds.where(visible.contains).toSet();
      status = sources.isEmpty
          ? SourceRegistryStatus.empty
          : SourceRegistryStatus.data;
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      status = SourceRegistryStatus.error;
      errorMessage = _safeError(error, '无法读取来源');
    }
    notifyListeners();
  }

  void updateQuery(String value) {
    final normalized = value.trim();
    if (normalized == query) return;
    query = normalized;
    _queryTimer?.cancel();
    notifyListeners();
    _queryTimer = Timer(const Duration(milliseconds: 280), () {
      if (!_disposed) unawaited(refresh());
    });
  }

  Future<void> selectCategory(String value) async {
    if (value == categoryId) return;
    categoryId = value;
    clearSelection();
    await refresh();
  }

  Future<void> applyFilter(SourceRegistryFilter value) async {
    if (value == filter) return;
    filter = value;
    clearSelection();
    await refresh();
  }

  Future<void> loadMore() {
    if (_loadMoreFuture != null) return _loadMoreFuture!;
    if (!hasMore || isLoadingMore || status != SourceRegistryStatus.data) {
      return Future.value();
    }
    final future = _loadMore();
    _loadMoreFuture = future;
    return future.whenComplete(() {
      if (identical(_loadMoreFuture, future)) _loadMoreFuture = null;
    });
  }

  Future<void> _loadMore() async {
    final generation = _generation;
    final cursor = _nextCursor;
    isLoadingMore = true;
    loadMoreErrorMessage = '';
    notifyListeners();
    try {
      final page = await core.sourceRegistryPage(
        cursor: cursor,
        limit: 100,
        query: query,
        categoryId: categoryId,
        kind: filter.wireKind,
        searchable: filter.searchable,
        childDirectory: filter.childDirectory,
        builtIn: filter.builtIn,
      );
      if (!_isCurrent(generation) || cursor != _nextCursor) return;
      if (page.generation != registryGeneration) {
        await refresh();
        return;
      }
      final known = sources.map((source) => source.id).toSet();
      sources = <SourceRegistrySource>[
        ...sources,
        ...page.sources.where((source) => known.add(source.id)),
      ];
      total = page.total;
      hasMore = page.hasMore;
      _nextCursor = page.nextCursor;
    } on Object catch (error) {
      if (_isCurrent(generation)) {
        loadMoreErrorMessage = _safeError(error, '无法继续加载来源');
      }
    } finally {
      if (_isCurrent(generation)) {
        isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  void toggleSelection(SourceRegistrySource source) {
    final next = selectedIds.toSet();
    next.contains(source.id) ? next.remove(source.id) : next.add(source.id);
    selectedIds = next;
    notifyListeners();
  }

  void selectAllVisible() {
    selectedIds = sources.map((source) => source.id).toSet();
    notifyListeners();
  }

  void clearSelection() {
    if (selectedIds.isEmpty) return;
    selectedIds = const {};
    notifyListeners();
  }

  Future<SourceRegistryImportResult?> addSources(
    List<SourceRegistrySourceDraft> drafts,
  ) async {
    final capability = core is SourceRegistryAddCore
        ? core as SourceRegistryAddCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryBatchImport(
        expectedGeneration: registryGeneration,
        sources: drafts,
      ),
      success: (result) =>
          '已添加 ${result.added} 个，重复 ${result.duplicates} 个，无效 ${result.invalid} 个',
    );
  }

  Future<SourceRegistryImportPreview?> previewRawImport(
    SourceRegistryRawImportDraft draft,
  ) async {
    final capability = core is SourceRegistryImportPreviewCore
        ? core as SourceRegistryImportPreviewCore
        : null;
    if (capability == null || isMutating || _disposed) {
      return null;
    }
    isMutating = true;
    errorMessage = '';
    actionMessage = '';
    notifyListeners();
    try {
      return await capability.sourceRegistryImportPreview(
        expectedGeneration: registryGeneration,
        rawText: draft.rawText,
        categoryId: draft.categoryId,
      );
    } on Object catch (error) {
      errorMessage = _safeError(error, '无法预览来源');
      return null;
    } finally {
      isMutating = false;
      notifyListeners();
    }
  }

  Future<SourceRegistryImportResult?> commitRawImport(
    SourceRegistryImportPreview preview,
  ) async {
    final capability = core is SourceRegistryImportPreviewCore
        ? core as SourceRegistryImportPreviewCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryCommitImportPreview(
        expectedGeneration: preview.generation,
        previewId: preview.previewId,
      ),
      success: (result) =>
          '已添加 ${result.added} 个，重复 ${result.duplicates} 个，无效 ${result.invalid} 个',
    );
  }

  Future<SourceRegistryMutation?> retestSelected() async {
    final capability = core is SourceRegistryRetestCore
        ? core as SourceRegistryRetestCore
        : null;
    final ids = selectedRetestableIds;
    if (capability == null || ids.isEmpty) return null;
    return _mutate(
      () => capability.sourceRegistryRetest(
        expectedGeneration: registryGeneration,
        sourceIds: ids,
      ),
      success: (_) => '已重新测试 ${ids.length} 个来源',
    );
  }

  Future<SourceRegistryMutation?> updateSource(
    SourceRegistrySourceUpdateDraft draft,
  ) async {
    final capability = core is SourceRegistrySourceMutationCore
        ? core as SourceRegistrySourceMutationCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryUpdateSource(
        expectedGeneration: registryGeneration,
        update: draft,
      ),
      success: (_) => '来源已更新',
    );
  }

  Future<SourceRegistryDeleteResult?> deleteSelected() async {
    return deleteSources(selectedIds.take(256).toList(growable: false));
  }

  Future<SourceRegistryDeleteResult?> deleteSources(
    List<String> sourceIds,
  ) async {
    final capability = core is SourceRegistrySourceMutationCore
        ? core as SourceRegistrySourceMutationCore
        : null;
    final ids = sourceIds.take(256).toList(growable: false);
    if (capability == null || ids.isEmpty) {
      return null;
    }
    return _mutate(
      () => capability.sourceRegistryDeleteSources(
        expectedGeneration: registryGeneration,
        sourceIds: ids,
      ),
      success: (result) => '已移除 ${result.removed} 个、隐藏 ${result.hidden} 个来源',
    );
  }

  Future<SourceRegistryMutation?> upsertCategory(
    SourceRegistryCategoryDraft draft,
  ) async {
    final capability = core is SourceRegistryCategoryCore
        ? core as SourceRegistryCategoryCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryUpsertCategory(
        expectedGeneration: registryGeneration,
        category: draft,
      ),
      success: (_) => '分类已保存',
    );
  }

  Future<SourceRegistryMutation?> setCategoryMembers(
    String categoryId,
    List<String> sourceIds,
  ) async {
    final capability = core is SourceRegistryCategoryCore
        ? core as SourceRegistryCategoryCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistrySetCategoryMembers(
        expectedGeneration: registryGeneration,
        categoryId: categoryId,
        sourceIds: sourceIds,
      ),
      success: (_) => '分类成员已更新',
    );
  }

  Future<SourceRegistryMutation?> deleteCategory(String id) async {
    final capability = core is SourceRegistryCategoryCore
        ? core as SourceRegistryCategoryCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryDeleteCategory(
        expectedGeneration: registryGeneration,
        categoryId: id,
      ),
      success: (_) => '分类已删除',
    );
  }

  Future<SourceRegistryCompositeMutation?> upsertComposite(
    SourceRegistryCompositeDraft draft,
  ) async {
    final capability = core is SourceRegistryCompositeCore
        ? core as SourceRegistryCompositeCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryUpsertComposite(
        expectedGeneration: registryGeneration,
        composite: draft,
      ),
      success: (_) => '自建合集已保存',
    );
  }

  Future<SourceRegistryMutation?> deleteSelectedComposite() async {
    final capability = core is SourceRegistryCompositeCore
        ? core as SourceRegistryCompositeCore
        : null;
    final selected = selectedSources;
    if (capability == null ||
        selected.length != 1 ||
        selected.single.builtIn ||
        selected.single.kind != SourceRegistrySourceKind.composite) {
      return null;
    }
    return _mutate(
      () => capability.sourceRegistryDeleteComposite(
        expectedGeneration: registryGeneration,
        sourceId: selected.single.id,
      ),
      success: (_) => '自建合集已删除',
    );
  }

  Future<SourceRegistryImportResult?> importRules(String sourcePath) async {
    final capability = core is SourceRegistryRulesCore
        ? core as SourceRegistryRulesCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryImportRules(
        expectedGeneration: registryGeneration,
        sourcePath: sourcePath,
      ),
      success: (result) => '已导入 ${result.added} 个来源',
    );
  }

  Future<SourceRegistryImportResult?> fetchImportRules(String rulesUrl) async {
    final capability = core is SourceRegistryRulesCore
        ? core as SourceRegistryRulesCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryFetchImportRules(
        expectedGeneration: registryGeneration,
        rulesUrl: rulesUrl,
      ),
      success: (result) => '已导入 ${result.added} 个来源',
    );
  }

  Future<SourceRegistryExportResult?> exportSelected(
    String destination, {
    bool includeCredentials = false,
  }) async {
    final capability = core is SourceRegistryRulesCore
        ? core as SourceRegistryRulesCore
        : null;
    if (capability == null) return null;
    final ids = selectedSources
        .where((source) => !source.builtIn)
        .map((source) => source.id)
        .toList(growable: false);
    return _mutate(
      () => capability.sourceRegistryExportRules(
        expectedGeneration: registryGeneration,
        destinationPath: destination,
        sourceIds: ids,
        includeCredentials: includeCredentials,
        credentialConfirmation: includeCredentials
            ? 'export-source-access-codes'
            : '',
      ),
      success: (result) => includeCredentials
          ? '已导出 ${result.count} 个来源（包含访问码）'
          : '已安全导出 ${result.count} 个来源（不含访问码）',
      preserveSelection: true,
    );
  }

  Future<SourceRegistryMutation?> restoreBackup() async {
    final capability = core is SourceRegistryRestoreCore
        ? core as SourceRegistryRestoreCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryRestoreBackup(registryGeneration),
      success: (_) => '已恢复上次备份',
    );
  }

  Future<SourceRegistryMutation?> restoreOfficial() async {
    final capability = core is SourceRegistryRestoreCore
        ? core as SourceRegistryRestoreCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryRestoreOfficial(registryGeneration),
      success: (_) => '已恢复官方来源',
    );
  }

  Future<SourceRegistryMutation?> reset() async {
    final capability = core is SourceRegistryRestoreCore
        ? core as SourceRegistryRestoreCore
        : null;
    if (capability == null) return null;
    return _mutate(
      () => capability.sourceRegistryReset(registryGeneration),
      success: (_) => '已重置全部来源设置',
    );
  }

  Future<T?> _mutate<T extends SourceRegistryMutation>(
    Future<T> Function() task, {
    required String Function(T) success,
    bool preserveSelection = false,
  }) async {
    if (isMutating || _disposed) return null;
    isMutating = true;
    errorMessage = '';
    actionMessage = '';
    notifyListeners();
    try {
      final result = await task();
      final successMessage = success(result);
      if (!preserveSelection) selectedIds = const {};
      await refresh();
      actionMessage = successMessage;
      return result;
    } on Object catch (error) {
      errorMessage = _safeError(error, '来源操作失败');
      return null;
    } finally {
      isMutating = false;
      notifyListeners();
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  String _safeError(Object error, String fallback) => switch (error) {
    LibraryCoreFailure(:final message) when message.trim().isNotEmpty =>
      message,
    _ => fallback,
  };

  @override
  void dispose() {
    _disposed = true;
    _queryTimer?.cancel();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}
