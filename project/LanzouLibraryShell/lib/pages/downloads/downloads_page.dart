import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/library_controller.dart';
import '../../models/download_history.dart';
import '../../services/download_coordinator.dart';
import '../../shared/app_listenable_selector.dart';
import '../../shared/app_motion.dart';
import '../library/library_states.dart';

enum _DownloadStateFilter { all, resolving, downloading, completed, failed }

/// Real, persisted download history. Progress comes only from the Rust-backed
/// coordinator; this page never estimates bytes or manufactures task states.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    required this.controller,
    required this.searchFocusNode,
    this.debugOnStructureBuild,
    this.debugOnRowBuild,
  });

  final LibraryController controller;
  final FocusNode searchFocusNode;

  @visibleForTesting
  final VoidCallback? debugOnStructureBuild;

  @visibleForTesting
  final ValueChanged<String>? debugOnRowBuild;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _knownRowKeys = <String>{};
  final Set<String> _pendingRowEntrances = <String>{};
  final Set<String> _selectedHistoryIds = <String>{};
  _DownloadStateFilter _stateFilter = _DownloadStateFilter.all;
  DownloadExtensionCategory _extensionFilter = DownloadExtensionCategory.all;
  String _localActionError = '';
  bool _hasObservedLoadedRows = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppListenableSelector<_DownloadsStructureSnapshot>(
      listenable: widget.controller,
      selector: _structureSnapshot,
      builder: (context, _, child) {
        assert(() {
          widget.debugOnStructureBuild?.call();
          return true;
        }());
        return ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) => _buildPage(value.text.trim()),
        );
      },
    );
  }

  _DownloadsStructureSnapshot _structureSnapshot() {
    final downloads = widget.controller.downloads;
    return (
      available: downloads != null,
      loading: downloads?.isLoading ?? false,
      loadError: downloads?.loadError ?? '',
      persistenceWarning: downloads?.persistenceWarning ?? '',
      actionError: widget.controller.downloadActionError,
      saveDirectory: downloads?.saveDirectory ?? '',
      activeKeys:
          downloads?.active
              .map(
                (entry) =>
                    '${entry.historyId}\u0001${entry.operationId}\u0001'
                    '${entry.state.name}\u0001${entry.fileName}',
              )
              .join('\u0002') ??
          '',
      historyKeys:
          downloads?.history
              .map(
                (entry) =>
                    '${entry.id}\u0001${entry.status.name}\u0001'
                    '${entry.suggestedFileName}',
              )
              .join('\u0002') ??
          '',
    );
  }

  Widget _buildPage(String query) {
    final downloads = widget.controller.downloads;
    if (downloads == null) {
      return const LibraryEmptyState(
        icon: Icons.warning_amber_rounded,
        title: '下载服务不可用',
        message: '请重新打开应用',
      );
    }

    final rowKeys = _visibleRowKeys(query);
    _trackRowEntrances(
      rowKeys,
      canPresent: !downloads.isLoading && downloads.loadError.isEmpty,
    );
    final visibleIds = rowKeys.map(_historyIdFromRowKey).toSet();
    _selectedHistoryIds.retainWhere(visibleIds.contains);
    final actionError = _localActionError.isNotEmpty
        ? _localActionError
        : widget.controller.downloadActionError;
    return SafeArea(
      top: false,
      child: Column(
        key: const Key('downloads-page'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DownloadsHeader(saveDirectory: downloads.saveDirectory),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: SearchBar(
              key: const Key('download-history-search'),
              controller: _searchController,
              focusNode: widget.searchFocusNode,
              hintText: '搜索下载记录',
              leading: const Icon(Icons.search_rounded),
              trailing: [
                if (_searchController.text.isNotEmpty)
                  IconButton(
                    tooltip: '清除搜索',
                    onPressed: _searchController.clear,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
          ),
          _DownloadFilters(
            stateFilter: _stateFilter,
            extensionFilter: _extensionFilter,
            onStateChanged: (value) => setState(() {
              _stateFilter = value;
              _clearSelection();
            }),
            onExtensionChanged: (value) => setState(() {
              _extensionFilter = value;
              _clearSelection();
            }),
          ),
          if (_selectedHistoryIds.isNotEmpty)
            _DownloadSelectionBar(
              selectedCount: _selectedHistoryIds.length,
              allVisibleSelected:
                  visibleIds.isNotEmpty &&
                  _selectedHistoryIds.containsAll(visibleIds),
              onToggleAll: () => setState(() {
                if (_selectedHistoryIds.containsAll(visibleIds)) {
                  _selectedHistoryIds.clear();
                } else {
                  _selectedHistoryIds.addAll(visibleIds);
                }
              }),
              onActions: _showSelectedActions,
              onClose: () => setState(_selectedHistoryIds.clear),
            ),
          if (actionError.isNotEmpty)
            _InlineDownloadError(message: actionError),
          if (downloads.persistenceWarning.isNotEmpty)
            _InlineDownloadWarning(message: downloads.persistenceWarning),
          const Divider(height: 1),
          Expanded(
            child: _DownloadBody(
              key: ValueKey(
                downloads.isLoading
                    ? 'loading'
                    : downloads.loadError.isNotEmpty
                    ? 'error'
                    : rowKeys.isEmpty
                    ? _hasActiveFilters || query.isNotEmpty
                          ? 'search-empty'
                          : 'empty'
                    : 'list',
              ),
              controller: widget.controller,
              rowKeys: rowKeys,
              query: query,
              hasActiveFilters: _hasActiveFilters,
              selectedHistoryIds: _selectedHistoryIds,
              consumeRowEntrance: _pendingRowEntrances.remove,
              onToggleSelection: _toggleSelection,
              onShowActions: _showRowActions,
              debugOnRowBuild: widget.debugOnRowBuild,
            ),
          ),
        ],
      ),
    );
  }

  List<String> _visibleRowKeys(String query) {
    final downloads = widget.controller.downloads!;
    final activeHistoryIds = downloads.active
        .map((entry) => entry.historyId)
        .toSet();
    final keys = <String>[
      for (final active in downloads.active) 'active:${active.historyId}',
      for (final entry in downloads.history)
        if (!activeHistoryIds.contains(entry.id)) 'history:${entry.id}',
    ];
    final filtered = keys.where((key) {
      final row = _rowForKey(downloads, key);
      return _matchesStateFilter(row.entry, row.active) &&
          _matchesExtensionFilter(row.entry, row.active);
    });
    if (query.isEmpty) return filtered.toList(growable: false);
    final normalized = query.toLowerCase();
    return filtered
        .where((key) {
          final row = _rowForKey(downloads, key);
          return [
            row.entry?.displayName ?? '',
            row.entry?.suggestedFileName ?? '',
            row.active?.fileName ?? '',
          ].any((value) => value.toLowerCase().contains(normalized));
        })
        .toList(growable: false);
  }

  bool get _hasActiveFilters =>
      _stateFilter != _DownloadStateFilter.all ||
      _extensionFilter != DownloadExtensionCategory.all;

  bool _matchesStateFilter(
    DownloadHistoryEntry? entry,
    DownloadSnapshot? active,
  ) {
    final state = active?.state;
    final status = entry?.status;
    return switch (_stateFilter) {
      _DownloadStateFilter.all => true,
      _DownloadStateFilter.resolving =>
        state == DownloadActivityState.resolving ||
            (state == null && status == DownloadHistoryStatus.resolving),
      _DownloadStateFilter.downloading =>
        state == DownloadActivityState.queued ||
            state == DownloadActivityState.downloading ||
            state == DownloadActivityState.cancelling ||
            (state == null &&
                (status == DownloadHistoryStatus.queued ||
                    status == DownloadHistoryStatus.downloading ||
                    status == DownloadHistoryStatus.cancelling)),
      _DownloadStateFilter.completed =>
        state == DownloadActivityState.succeeded ||
            (state == null && status == DownloadHistoryStatus.succeeded),
      _DownloadStateFilter.failed =>
        state == DownloadActivityState.failed ||
            state == DownloadActivityState.cancelled ||
            (state == null &&
                (status == DownloadHistoryStatus.failed ||
                    status == DownloadHistoryStatus.cancelled)),
    };
  }

  bool _matchesExtensionFilter(
    DownloadHistoryEntry? entry,
    DownloadSnapshot? active,
  ) {
    if (_extensionFilter == DownloadExtensionCategory.all) return true;
    final activeName = active?.fileName.trim() ?? '';
    final historyName = entry?.suggestedFileName.trim() ?? '';
    final displayName = entry?.displayName.trim() ?? '';
    final fileName = activeName.isNotEmpty
        ? activeName
        : historyName.isNotEmpty
        ? historyName
        : displayName;
    return classifyDownloadExtension(fileName) == _extensionFilter;
  }

  void _clearSelection() => _selectedHistoryIds.clear();

  void _toggleSelection(String historyId) {
    setState(() {
      if (!_selectedHistoryIds.add(historyId)) {
        _selectedHistoryIds.remove(historyId);
      }
    });
  }

  List<DownloadHistoryEntry> _selectedEntries() {
    final downloads = widget.controller.downloads!;
    return downloads.history
        .where((entry) => _selectedHistoryIds.contains(entry.id))
        .toList(growable: false);
  }

  List<DownloadSnapshot> _selectedActivities() {
    final downloads = widget.controller.downloads!;
    return downloads.active
        .where(
          (task) =>
              _selectedHistoryIds.contains(task.historyId) &&
              !task.state.isTerminal,
        )
        .toList(growable: false);
  }

  Future<void> _showSelectedActions() async {
    final entries = _selectedEntries();
    final activities = _selectedActivities();
    if (entries.isEmpty && activities.isEmpty) return;
    final activeIds = activities.map((task) => task.historyId).toSet();
    final retryable = entries
        .where(
          (entry) =>
              !activeIds.contains(entry.id) &&
              entry.status != DownloadHistoryStatus.succeeded,
        )
        .toList(growable: false);
    final completed = entries
        .where(
          (entry) =>
              !activeIds.contains(entry.id) &&
              entry.status == DownloadHistoryStatus.succeeded,
        )
        .toList(growable: false);
    final removable = entries
        .where((entry) => !activeIds.contains(entry.id))
        .toList(growable: false);
    final actions = <_DownloadDialogAction>[
      const _DownloadDialogAction(
        action: _DownloadAction.pauseUnsupported,
        icon: Icons.pause_circle_outline_rounded,
        title: '暂停/继续',
        subtitle: '当前下载核心不支持断点续传，不会伪装成暂停',
        enabled: false,
      ),
      if (activities.isNotEmpty)
        _DownloadDialogAction(
          action: _DownloadAction.cancel,
          icon: Icons.close_rounded,
          title: '取消所选下载',
          subtitle: '${activities.length} 个未完成任务',
        ),
      if (retryable.isNotEmpty)
        _DownloadDialogAction(
          action: _DownloadAction.retry,
          icon: Icons.refresh_rounded,
          title: '重新下载失败项目',
          subtitle: '${retryable.length} 个项目将重新解析并从头下载',
        ),
      if (completed.length == 1)
        _DownloadDialogAction(
          action: _DownloadAction.open,
          icon: _isInstallAction(completed.single)
              ? Icons.install_mobile_rounded
              : Icons.open_in_new_rounded,
          title: _isInstallAction(completed.single) ? '安装' : '打开文件',
        ),
      if (entries.isNotEmpty)
        const _DownloadDialogAction(
          action: _DownloadAction.copyLinks,
          icon: Icons.copy_rounded,
          title: '复制所选原链接',
        ),
      if (removable.isNotEmpty)
        _DownloadDialogAction(
          action: _DownloadAction.deleteHistory,
          icon: Icons.delete_outline_rounded,
          title: '仅删除所选记录',
          subtitle: '保留已经下载的本地文件',
          destructive: true,
        ),
      if (completed.isNotEmpty)
        _DownloadDialogAction(
          action: _DownloadAction.deleteFileAndHistory,
          icon: Icons.delete_forever_outlined,
          title: '删除所选本地文件和记录',
          subtitle: '${completed.length} 个已完成项目',
          destructive: true,
        ),
    ];
    final action = await _chooseAction(title: '所选下载操作', actions: actions);
    if (!mounted || action == null) return;
    await _performAction(
      action,
      entries: entries,
      activities: activities,
      selection: true,
    );
  }

  Future<void> _showRowActions(
    DownloadHistoryEntry? entry,
    DownloadSnapshot? active,
  ) async {
    if (entry == null && active == null) return;
    final actions = <_DownloadDialogAction>[
      if (active != null && !active.state.isTerminal) ...[
        const _DownloadDialogAction(
          action: _DownloadAction.pauseUnsupported,
          icon: Icons.pause_circle_outline_rounded,
          title: '暂停/继续',
          subtitle: '当前下载核心不支持断点续传，不会伪装成暂停',
          enabled: false,
        ),
        const _DownloadDialogAction(
          action: _DownloadAction.cancel,
          icon: Icons.close_rounded,
          title: '取消下载',
        ),
      ],
      if (entry != null &&
          active == null &&
          entry.status == DownloadHistoryStatus.succeeded)
        _DownloadDialogAction(
          action: _DownloadAction.open,
          icon: _isInstallAction(entry)
              ? Icons.install_mobile_rounded
              : Icons.open_in_new_rounded,
          title: _isInstallAction(entry) ? '安装' : '打开文件',
        ),
      if (entry != null &&
          active == null &&
          entry.status != DownloadHistoryStatus.succeeded)
        const _DownloadDialogAction(
          action: _DownloadAction.retry,
          icon: Icons.refresh_rounded,
          title: '重新下载',
          subtitle: '重新解析并从头下载',
        ),
      if (entry != null)
        const _DownloadDialogAction(
          action: _DownloadAction.copyLinks,
          icon: Icons.copy_rounded,
          title: '复制原链接',
        ),
      if (entry != null && active == null)
        const _DownloadDialogAction(
          action: _DownloadAction.deleteHistory,
          icon: Icons.delete_outline_rounded,
          title: '仅删除记录',
          subtitle: '保留已经下载的本地文件',
          destructive: true,
        ),
      if (entry != null &&
          active == null &&
          entry.status == DownloadHistoryStatus.succeeded)
        const _DownloadDialogAction(
          action: _DownloadAction.deleteFileAndHistory,
          icon: Icons.delete_forever_outlined,
          title: '删除本地文件和记录',
          destructive: true,
        ),
    ];
    final action = await _chooseAction(
      title: entry?.displayName ?? active?.fileName ?? '下载任务',
      actions: actions,
    );
    if (!mounted || action == null) return;
    await _performAction(
      action,
      entries: entry == null ? const [] : [entry],
      activities: active == null ? const [] : [active],
      selection: false,
    );
  }

  Future<void> _performAction(
    _DownloadAction action, {
    required List<DownloadHistoryEntry> entries,
    required List<DownloadSnapshot> activities,
    required bool selection,
  }) async {
    final activeIds = activities.map((task) => task.historyId).toSet();
    final retryable = entries
        .where(
          (entry) =>
              !activeIds.contains(entry.id) &&
              entry.status != DownloadHistoryStatus.succeeded,
        )
        .toList(growable: false);
    final completed = entries
        .where(
          (entry) =>
              !activeIds.contains(entry.id) &&
              entry.status == DownloadHistoryStatus.succeeded,
        )
        .toList(growable: false);
    switch (action) {
      case _DownloadAction.pauseUnsupported:
        return;
      case _DownloadAction.cancel:
        if (activities.isEmpty) return;
        final confirmed = await _confirmAction(
          title: selection ? '取消 ${activities.length} 个下载？' : '取消这个下载？',
          message: '已传输的临时内容不会作为已完成文件保留。之后仍可重新下载。',
          confirmLabel: '取消下载',
        );
        if (!confirmed) return;
        for (final task in activities) {
          await widget.controller.cancelDownload(task);
        }
      case _DownloadAction.retry:
        for (final entry in retryable) {
          await widget.controller.retryDownload(entry);
        }
      case _DownloadAction.open:
        if (completed.length == 1) {
          await widget.controller.openDownload(completed.single);
        }
      case _DownloadAction.copyLinks:
        final links = entries
            .map((entry) => entry.shareUrl.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .join('\n');
        if (links.isEmpty) return;
        await Clipboard.setData(ClipboardData(text: links));
        if (mounted) _showNotice('已复制 ${entries.length} 个原链接');
      case _DownloadAction.deleteHistory:
        final removable = entries
            .where((entry) => !activeIds.contains(entry.id))
            .toList(growable: false);
        if (removable.isEmpty) return;
        final confirmed = await _confirmAction(
          title: selection ? '删除 ${removable.length} 条记录？' : '删除下载记录？',
          message: '只删除应用内记录，本地文件会保留。',
          confirmLabel: '删除记录',
        );
        if (!confirmed) return;
        for (final entry in removable) {
          await widget.controller.deleteDownloadHistory(entry);
        }
      case _DownloadAction.deleteFileAndHistory:
        if (completed.isEmpty) return;
        final confirmed = await _confirmAction(
          title: selection ? '删除 ${completed.length} 个本地文件？' : '删除本地文件？',
          message: '文件和对应下载记录都会删除，此操作无法撤销。',
          confirmLabel: '删除文件',
        );
        if (!confirmed) return;
        var failures = 0;
        for (final entry in completed) {
          try {
            await widget.controller.downloads!.deleteFileAndHistory(entry);
          } on Object catch (error) {
            failures++;
            _localActionError = _safeActionError(error);
          }
        }
        if (mounted && failures > 0) setState(() {});
    }
    if (mounted && selection) setState(_selectedHistoryIds.clear);
  }

  bool _isInstallAction(DownloadHistoryEntry entry) =>
      Theme.of(context).platform == TargetPlatform.android &&
      classifyDownloadExtension(entry.suggestedFileName) ==
          DownloadExtensionCategory.installationPackage;

  Future<_DownloadAction?> _chooseAction({
    required String title,
    required List<_DownloadDialogAction> actions,
  }) => showGeneralDialog<_DownloadAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭下载操作',
    barrierColor: Colors.black54,
    transitionDuration: AppMotion.duration(context, AppMotion.fast),
    pageBuilder: (context, _, _) =>
        _DownloadActionDialog(title: title, actions: actions),
    transitionBuilder: _dialogTransition,
  );

  Future<bool> _confirmAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async =>
      await showGeneralDialog<bool>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '取消',
        barrierColor: Colors.black54,
        transitionDuration: AppMotion.duration(context, AppMotion.fast),
        pageBuilder: (context, _, _) => _DownloadConfirmationDialog(
          title: title,
          message: message,
          confirmLabel: confirmLabel,
        ),
        transitionBuilder: _dialogTransition,
      ) ??
      false;

  Widget _dialogTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (!AppMotion.isEnabled(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: AppMotion.enterCurve,
      reverseCurve: AppMotion.exitCurve,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
        child: child,
      ),
    );
  }

  void _showNotice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _safeActionError(Object error) => switch (error) {
    DownloadCoordinatorFailure() => error.message,
    _ => '下载操作失败，请稍后重试',
  };

  void _trackRowEntrances(List<String> rowKeys, {required bool canPresent}) {
    if (!canPresent) return;
    if (!_hasObservedLoadedRows) {
      _knownRowKeys.addAll(rowKeys);
      _hasObservedLoadedRows = true;
      return;
    }
    for (final rowKey in rowKeys) {
      if (_knownRowKeys.add(rowKey)) {
        _pendingRowEntrances.add(rowKey);
      }
    }
  }
}

typedef _DownloadsStructureSnapshot = ({
  bool available,
  bool loading,
  String loadError,
  String persistenceWarning,
  String actionError,
  String saveDirectory,
  String activeKeys,
  String historyKeys,
});

class _DownloadFilters extends StatelessWidget {
  const _DownloadFilters({
    required this.stateFilter,
    required this.extensionFilter,
    required this.onStateChanged,
    required this.onExtensionChanged,
  });

  final _DownloadStateFilter stateFilter;
  final DownloadExtensionCategory extensionFilter;
  final ValueChanged<_DownloadStateFilter> onStateChanged;
  final ValueChanged<DownloadExtensionCategory> onExtensionChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            label: '下载状态筛选',
            child: SingleChildScrollView(
              key: const Key('download-state-filters'),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final value in _DownloadStateFilter.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: FilterChip(
                        label: Text(_stateFilterLabel(value)),
                        selected: value == stateFilter,
                        onSelected: (_) => onStateChanged(value),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Semantics(
            container: true,
            label: '文件类型筛选',
            child: SingleChildScrollView(
              key: const Key('download-extension-filters'),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final value in DownloadExtensionCategory.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: FilterChip(
                        label: Text(_extensionFilterLabel(value)),
                        selected: value == extensionFilter,
                        onSelected: (_) => onExtensionChanged(value),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadSelectionBar extends StatelessWidget {
  const _DownloadSelectionBar({
    required this.selectedCount,
    required this.allVisibleSelected,
    required this.onToggleAll,
    required this.onActions,
    required this.onClose,
  });

  final int selectedCount;
  final bool allVisibleSelected;
  final VoidCallback onToggleAll;
  final VoidCallback onActions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                '已选 $selectedCount',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: colors.onSecondaryContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: onToggleAll,
              child: Text(allVisibleSelected ? '取消全选' : '全选'),
            ),
            IconButton(
              tooltip: '所选下载操作',
              onPressed: onActions,
              icon: const Icon(Icons.more_horiz_rounded),
            ),
            IconButton(
              tooltip: '退出选择',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

enum _DownloadAction {
  pauseUnsupported,
  cancel,
  retry,
  open,
  copyLinks,
  deleteHistory,
  deleteFileAndHistory,
}

class _DownloadDialogAction {
  const _DownloadDialogAction({
    required this.action,
    required this.icon,
    required this.title,
    this.subtitle = '',
    this.enabled = true,
    this.destructive = false,
  });

  final _DownloadAction action;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final bool destructive;
}

class _DownloadActionDialog extends StatelessWidget {
  const _DownloadActionDialog({required this.title, required this.actions});

  final String title;
  final List<_DownloadDialogAction> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: actions.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 56, endIndent: 16),
                itemBuilder: (context, index) {
                  final action = actions[index];
                  final foreground = action.destructive
                      ? colors.error
                      : action.enabled
                      ? colors.onSurface
                      : colors.onSurfaceVariant;
                  return ListTile(
                    enabled: action.enabled,
                    minTileHeight: 56,
                    leading: Icon(action.icon, color: foreground),
                    title: Text(
                      action.title,
                      style: TextStyle(color: foreground),
                    ),
                    subtitle: action.subtitle.isEmpty
                        ? null
                        : Text(action.subtitle),
                    onTap: action.enabled
                        ? () => Navigator.pop(context, action.action)
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadConfirmationDialog extends StatelessWidget {
  const _DownloadConfirmationDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              Text(message, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    height: 48,
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('返回'),
                    ),
                  ),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.error,
                        foregroundColor: colors.onError,
                      ),
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadsHeader extends StatelessWidget {
  const _DownloadsHeader({required this.saveDirectory});

  final String saveDirectory;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final path = saveDirectory.isEmpty
        ? '正在读取保存路径'
        : _privacySafeDisplayPath(saveDirectory);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final title = Text(
            '下载历史',
            style: Theme.of(context).textTheme.headlineMedium,
          );
          final pathView = Semantics(
            label: '保存路径，$path',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.download_done_rounded,
                  color: colors.primary,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '保存路径',
                        style: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(color: colors.primary),
                      ),
                      const SizedBox(height: 2),
                      Tooltip(
                        message: path,
                        child: SelectableText(
                          path,
                          maxLines: 2,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 16), pathView],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              title,
              const Spacer(),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: pathView,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _InlineDownloadError extends StatelessWidget {
  const _InlineDownloadError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      label: '下载操作失败，$message',
      child: ColoredBox(
        color: colors.errorContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineDownloadWarning extends StatelessWidget {
  const _InlineDownloadWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      label: '下载记录保存提醒，$message',
      child: ColoredBox(
        color: colors.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: colors.onTertiaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: colors.onTertiaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadBody extends StatelessWidget {
  const _DownloadBody({
    super.key,
    required this.controller,
    required this.rowKeys,
    required this.query,
    required this.hasActiveFilters,
    required this.selectedHistoryIds,
    required this.consumeRowEntrance,
    required this.onToggleSelection,
    required this.onShowActions,
    required this.debugOnRowBuild,
  });

  final LibraryController controller;
  final List<String> rowKeys;
  final String query;
  final bool hasActiveFilters;
  final Set<String> selectedHistoryIds;
  final bool Function(String rowKey) consumeRowEntrance;
  final ValueChanged<String> onToggleSelection;
  final void Function(DownloadHistoryEntry?, DownloadSnapshot?) onShowActions;
  final ValueChanged<String>? debugOnRowBuild;

  @override
  Widget build(BuildContext context) {
    final downloads = controller.downloads!;
    late final Widget child;
    if (downloads.isLoading) {
      child = const _DownloadLoadingState();
    } else if (downloads.loadError.isNotEmpty) {
      child = LibraryErrorState(
        message: downloads.loadError,
        onRetry: controller.reloadDownloads,
      );
    } else if (rowKeys.isEmpty) {
      child = LibraryEmptyState(
        icon: query.isEmpty && !hasActiveFilters
            ? Icons.download_for_offline_outlined
            : Icons.search_off_rounded,
        title: query.isEmpty && !hasActiveFilters ? '暂无下载记录' : '没有匹配记录',
      );
    } else {
      child = ListView.separated(
        key: const Key('download-history-list'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: rowKeys.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, indent: 76, endIndent: 20),
        itemBuilder: (context, index) {
          final rowKey = rowKeys[index];
          return _DownloadHistoryRow(
            key: ValueKey('download-row-$rowKey'),
            controller: controller,
            rowKey: rowKey,
            selectionMode: selectedHistoryIds.isNotEmpty,
            selected: selectedHistoryIds.contains(_historyIdFromRowKey(rowKey)),
            animateEntrance: consumeRowEntrance(rowKey),
            onToggleSelection: onToggleSelection,
            onShowActions: onShowActions,
            debugOnBuild: debugOnRowBuild,
          );
        },
      );
    }
    return AppMotionEntrance(
      key: ValueKey('download-body-${key.toString()}'),
      duration: AppMotion.emphasized,
      child: child,
    );
  }
}

class _DownloadLoadingState extends StatelessWidget {
  const _DownloadLoadingState();

  @override
  Widget build(BuildContext context) {
    final reducedMotion = !AppMotion.isEnabled(context);
    return Center(
      child: Semantics(
        liveRegion: true,
        label: '正在读取下载记录',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reducedMotion)
              const Icon(Icons.history_rounded, size: 40)
            else
              const SizedBox.square(
                dimension: 36,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            const SizedBox(height: 16),
            const ExcludeSemantics(child: Text('正在读取下载记录')),
          ],
        ),
      ),
    );
  }
}

class _DownloadHistoryRow extends StatelessWidget {
  const _DownloadHistoryRow({
    super.key,
    required this.controller,
    required this.rowKey,
    required this.selectionMode,
    required this.selected,
    required this.animateEntrance,
    required this.onToggleSelection,
    required this.onShowActions,
    this.debugOnBuild,
  });

  final LibraryController controller;
  final String rowKey;
  final bool selectionMode;
  final bool selected;
  final bool animateEntrance;
  final ValueChanged<String> onToggleSelection;
  final void Function(DownloadHistoryEntry?, DownloadSnapshot?) onShowActions;
  final ValueChanged<String>? debugOnBuild;

  @override
  Widget build(BuildContext context) {
    final row = AppListenableSelector<_DownloadRowSnapshot>(
      listenable: controller,
      selector: () => _rowSnapshot(controller.downloads!, rowKey),
      builder: (context, snapshot, child) {
        assert(() {
          debugOnBuild?.call(rowKey);
          return true;
        }());
        return _buildRow(context, snapshot);
      },
    );
    if (!animateEntrance) return row;
    return AppMotionEntrance(
      duration: AppMotion.fast,
      offset: const Offset(0, 0.02),
      child: row,
    );
  }

  Widget _buildRow(BuildContext context, _DownloadRowSnapshot snapshot) {
    final entry = snapshot.entry;
    final active = snapshot.active;
    if (entry == null && active == null) return const SizedBox.shrink();
    final title = (entry?.displayName ?? '').trim().isNotEmpty
        ? entry!.displayName
        : (active?.fileName ?? '').trim().isNotEmpty
        ? active!.fileName
        : '下载任务';
    final status = _statusText(entry: entry, active: active);
    final fileName = (active?.fileName ?? '').trim().isNotEmpty
        ? active!.fileName
        : entry?.suggestedFileName ?? '';
    final bytesTransferred =
        active?.bytesTransferred ?? entry?.bytesTransferred ?? 0;
    final totalBytes = active?.totalBytes ?? entry?.totalBytes ?? 0;
    final progress = totalBytes > 0
        ? (bytesTransferred / totalBytes).clamp(0.0, 1.0)
        : null;
    final showProgress = active != null && !active.state.isTerminal;
    final reducedMotion = !AppMotion.isEnabled(context);
    final time = entry == null ? '' : _formatTimestamp(entry.updatedAt);
    final stateKey = _rowStateKey(entry: entry, active: active);

    return Semantics(
      container: true,
      explicitChildNodes: true,
      selected: selected,
      label: '$title，$status',
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        minVerticalPadding: 12,
        leading: AppMotionSwitcher(
          child: Icon(
            _statusIcon(entry: entry, active: active),
            key: ValueKey('download-icon-$stateKey'),
            color: _statusColor(context, entry: entry, active: active),
          ),
        ),
        title: ExcludeSemantics(
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        subtitle: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (fileName.isNotEmpty && fileName != title)
                  Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                Text(
                  time.isEmpty ? status : '$status · $time',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (showProgress) ...[
                  const SizedBox(height: 8),
                  if (progress != null)
                    LinearProgressIndicator(value: progress, minHeight: 4)
                  else if (reducedMotion)
                    Container(
                      height: 4,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  else
                    const LinearProgressIndicator(minHeight: 4),
                ],
              ],
            ),
          ),
        ),
        selected: selected,
        onTap: selectionMode
            ? () => onToggleSelection(_historyIdFromRowKey(rowKey))
            : null,
        onLongPress: () => onToggleSelection(_historyIdFromRowKey(rowKey)),
        trailing: selectionMode
            ? Checkbox(
                value: selected,
                onChanged: (_) =>
                    onToggleSelection(_historyIdFromRowKey(rowKey)),
              )
            : AppMotionSwitcher(
                child: KeyedSubtree(
                  key: ValueKey('download-actions-$stateKey'),
                  child: _DownloadRowActions(
                    controller: controller,
                    entry: entry,
                    active: active,
                    onShowActions: onShowActions,
                  ),
                ),
              ),
      ),
    );
  }
}

class _DownloadRowActions extends StatelessWidget {
  const _DownloadRowActions({
    required this.controller,
    required this.entry,
    required this.active,
    required this.onShowActions,
  });

  final LibraryController controller;
  final DownloadHistoryEntry? entry;
  final DownloadSnapshot? active;
  final void Function(DownloadHistoryEntry?, DownloadSnapshot?) onShowActions;

  @override
  Widget build(BuildContext context) {
    if (active case final task? when !task.state.isTerminal) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: task.state == DownloadActivityState.cancelling
                ? '正在取消下载'
                : '取消下载',
            onPressed: task.state == DownloadActivityState.cancelling
                ? null
                : () => controller.cancelDownload(task),
            icon: Icon(
              task.state == DownloadActivityState.cancelling
                  ? Icons.hourglass_top_rounded
                  : Icons.close_rounded,
            ),
          ),
          IconButton(
            tooltip: '更多下载操作',
            onPressed: () => onShowActions(entry, task),
            icon: const Icon(Icons.more_vert_rounded),
          ),
        ],
      );
    }
    final history = entry;
    if (history == null) return const SizedBox.shrink();
    final canOpen = history.status == DownloadHistoryStatus.succeeded;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: canOpen ? '打开文件' : '重新下载',
          onPressed: canOpen
              ? () => controller.openDownload(history)
              : () => controller.retryDownload(history),
          icon: Icon(
            canOpen ? Icons.folder_open_rounded : Icons.refresh_rounded,
          ),
        ),
        IconButton(
          tooltip: '更多下载操作',
          onPressed: () => onShowActions(history, active),
          icon: const Icon(Icons.more_vert_rounded),
        ),
      ],
    );
  }
}

typedef _DownloadRowSnapshot = ({
  DownloadHistoryEntry? entry,
  DownloadSnapshot? active,
});

String _rowStateKey({
  required DownloadHistoryEntry? entry,
  required DownloadSnapshot? active,
}) {
  if (active case final task?) return 'active-${task.state.name}';
  final history = entry!;
  final interrupted = history.errorCode == 'interrupted' ? '-interrupted' : '';
  return 'history-${history.status.name}$interrupted';
}

_DownloadRowSnapshot _rowSnapshot(
  DownloadCoordinator downloads,
  String rowKey,
) {
  final row = _rowForKey(downloads, rowKey);
  return (entry: row.entry, active: row.active);
}

({DownloadHistoryEntry? entry, DownloadSnapshot? active}) _rowForKey(
  DownloadCoordinator downloads,
  String rowKey,
) {
  final separator = rowKey.indexOf(':');
  final id = separator < 0 ? rowKey : rowKey.substring(separator + 1);
  DownloadHistoryEntry? entry;
  DownloadSnapshot? active;
  for (final candidate in downloads.history) {
    if (candidate.id == id) {
      entry = candidate;
      break;
    }
  }
  for (final candidate in downloads.active) {
    if (candidate.historyId == id) {
      active = candidate;
      break;
    }
  }
  return (entry: entry, active: active);
}

String _statusText({
  required DownloadHistoryEntry? entry,
  required DownloadSnapshot? active,
}) {
  final bytes = active?.bytesTransferred ?? entry?.bytesTransferred ?? 0;
  final total = active?.totalBytes ?? entry?.totalBytes ?? 0;
  if (active case final task?) {
    return switch (task.state) {
      DownloadActivityState.queued => '等待下载',
      DownloadActivityState.resolving => '正在解析下载地址',
      DownloadActivityState.downloading =>
        total > 0
            ? _appendLiveTransferMetrics(
                '已下载 ${_formatBytes(bytes)} / ${_formatBytes(total)} · ${((bytes / total) * 100).clamp(0, 100).round()}%',
                task,
              )
            : '已下载 ${_formatBytes(bytes)}',
      DownloadActivityState.cancelling => '正在取消下载',
      DownloadActivityState.succeeded => '下载完成 · ${_formatBytes(bytes)}',
      DownloadActivityState.cancelled => '下载已取消',
      DownloadActivityState.failed =>
        task.safeError.isEmpty ? '下载失败' : '下载失败 · ${task.safeError}',
    };
  }
  final history = entry!;
  return switch (history.status) {
    DownloadHistoryStatus.queued ||
    DownloadHistoryStatus.resolving ||
    DownloadHistoryStatus.downloading ||
    DownloadHistoryStatus.cancelling => '下载已中断',
    DownloadHistoryStatus.succeeded =>
      '下载完成 · ${_formatBytes(history.bytesTransferred)}',
    DownloadHistoryStatus.cancelled => '下载已取消',
    DownloadHistoryStatus.failed =>
      history.errorCode == 'interrupted'
          ? '下载已中断'
          : history.errorMessage.isEmpty
          ? '下载失败'
          : '下载失败 · ${history.errorMessage}',
  };
}

IconData _statusIcon({
  required DownloadHistoryEntry? entry,
  required DownloadSnapshot? active,
}) {
  if (active case final task?) {
    return switch (task.state) {
      DownloadActivityState.queued => Icons.schedule_rounded,
      DownloadActivityState.resolving => Icons.link_rounded,
      DownloadActivityState.downloading => Icons.downloading_rounded,
      DownloadActivityState.cancelling => Icons.hourglass_top_rounded,
      DownloadActivityState.succeeded => Icons.check_circle_rounded,
      DownloadActivityState.cancelled => Icons.cancel_outlined,
      DownloadActivityState.failed => Icons.error_outline_rounded,
    };
  }
  return switch (entry!.status) {
    DownloadHistoryStatus.queued => Icons.schedule_rounded,
    DownloadHistoryStatus.resolving ||
    DownloadHistoryStatus.downloading => Icons.downloading_rounded,
    DownloadHistoryStatus.cancelling => Icons.hourglass_top_rounded,
    DownloadHistoryStatus.succeeded => Icons.check_circle_rounded,
    DownloadHistoryStatus.cancelled => Icons.cancel_outlined,
    DownloadHistoryStatus.failed =>
      entry.errorCode == 'interrupted'
          ? Icons.pause_circle_outline_rounded
          : Icons.error_outline_rounded,
  };
}

Color _statusColor(
  BuildContext context, {
  required DownloadHistoryEntry? entry,
  required DownloadSnapshot? active,
}) {
  final colors = Theme.of(context).colorScheme;
  final failed =
      active?.state == DownloadActivityState.failed ||
      entry?.status == DownloadHistoryStatus.failed;
  final cancelled =
      active?.state == DownloadActivityState.cancelled ||
      entry?.status == DownloadHistoryStatus.cancelled;
  if (failed) return colors.error;
  if (cancelled) return colors.onSurfaceVariant;
  return colors.primary;
}

String _formatBytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _formatTimestamp(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _appendLiveTransferMetrics(String base, DownloadSnapshot snapshot) {
  if (snapshot.bytesPerSecond <= 0) return base;
  final eta = snapshot.estimatedRemaining;
  final remaining = eta == null ? '' : ' · 剩余约 ${_formatDuration(eta)}';
  return '$base\n${_formatBytes(snapshot.bytesPerSecond)}/s$remaining';
}

String _formatDuration(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 60) return '$seconds 秒';
  final minutes = (seconds / 60).ceil();
  if (minutes < 60) return '$minutes 分钟';
  final hours = (minutes / 60).ceil();
  return '$hours 小时';
}

String _historyIdFromRowKey(String rowKey) {
  final separator = rowKey.indexOf(':');
  return separator < 0 ? rowKey : rowKey.substring(separator + 1);
}

String _stateFilterLabel(_DownloadStateFilter value) => switch (value) {
  _DownloadStateFilter.all => '全部',
  _DownloadStateFilter.resolving => '解析中',
  _DownloadStateFilter.downloading => '下载中',
  _DownloadStateFilter.completed => '下载完成',
  _DownloadStateFilter.failed => '下载失败',
};

String _extensionFilterLabel(DownloadExtensionCategory value) =>
    switch (value) {
      DownloadExtensionCategory.all => '全部',
      DownloadExtensionCategory.installationPackage => '安装包',
      DownloadExtensionCategory.application => '应用程序',
      DownloadExtensionCategory.archive => '压缩包',
      DownloadExtensionCategory.document => '文本',
      DownloadExtensionCategory.video => '视频',
      DownloadExtensionCategory.audio => '音乐',
      DownloadExtensionCategory.other => '其他',
    };

String _privacySafeDisplayPath(String value) {
  final path = value.trim();
  if (path.isEmpty) return path;
  final windowsHome = RegExp(
    r'^[A-Za-z]:[\\/]+Users[\\/]+[^\\/]+(?=[\\/]|$)',
    caseSensitive: false,
  );
  if (windowsHome.hasMatch(path)) {
    return path.replaceFirst(windowsHome, '~');
  }
  final unixHome = RegExp(r'^/(?:home|Users)/[^/]+(?=/|$)');
  if (unixHome.hasMatch(path)) {
    return path.replaceFirst(unixHome, '~');
  }
  return path;
}
