import 'package:flutter/material.dart';

import '../../controllers/library_controller.dart';
import '../../models/library_item.dart';
import '../../shared/app_listenable_selector.dart';
import '../../shared/app_motion.dart';
import 'library_list.dart';
import 'library_source_header.dart';
import 'library_states.dart';

class LibraryContentPane extends StatefulWidget {
  const LibraryContentPane({
    super.key,
    required this.controller,
    required this.searchController,
    required this.searchFocusNode,
    required this.showPersistentDetails,
    required this.onShowTransientDetails,
    this.onOpenItemSource,
    this.compactGrid = false,
    this.showSourceHeader = true,
    this.restoreScrollForQuery,
    this.restoredScrollOffset = 0,
    this.onDirectoryScrollOffsetChanged,
    this.debugOnPaneBuild,
    this.debugOnSearchProgressBuild,
  });

  final LibraryController controller;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final bool showPersistentDetails;
  final ValueChanged<LibraryItem> onShowTransientDetails;
  final ValueChanged<LibraryItem>? onOpenItemSource;
  final bool compactGrid;
  final bool showSourceHeader;
  final String? restoreScrollForQuery;
  final double restoredScrollOffset;
  final ValueChanged<double>? onDirectoryScrollOffsetChanged;

  @visibleForTesting
  final VoidCallback? debugOnPaneBuild;

  @visibleForTesting
  final VoidCallback? debugOnSearchProgressBuild;

  @override
  State<LibraryContentPane> createState() => _LibraryContentPaneState();
}

class _LibraryContentPaneState extends State<LibraryContentPane> {
  List<String> _lastDataKeys = const [];

  @override
  Widget build(BuildContext context) {
    return AppListenableSelector<_ContentSnapshot>(
      listenable: widget.controller,
      selector: _snapshot,
      builder: (context, _, child) => _buildPane(),
    );
  }

  _ContentSnapshot _snapshot() {
    final controller = widget.controller;
    return (
      status: controller.status,
      selectedSource: controller.selectedSource,
      folder: controller.folder,
      items: controller.items,
      breadcrumbs: controller.breadcrumbs,
      query: controller.query,
      errorMessage: controller.errorMessage,
      searchWasCancelled: controller.searchWasCancelled,
      selectedItemKey: controller.selectedItem?.stableKey,
      isLoadingMore: controller.isLoadingMore,
      loadMoreError: controller.loadMoreError,
    );
  }

  Widget _buildPane() {
    assert(() {
      widget.debugOnPaneBuild?.call();
      return true;
    }());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LibraryBreadcrumbBar(controller: widget.controller),
        if (widget.showSourceHeader)
          LibrarySourceHeader(
            key: ValueKey(
              'source-header-${widget.controller.selectedSource?.sourceId}',
            ),
            controller: widget.controller,
            compact: widget.compactGrid,
          ),
        if (widget.controller.config.features.search)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: _SearchField(
              controller: widget.controller,
              textController: widget.searchController,
              focusNode: widget.searchFocusNode,
            ),
          ),
        const Divider(),
        Expanded(child: _buildState()),
      ],
    );
  }

  Widget _buildState() {
    final controller = widget.controller;
    late final String stateKey;
    late final Widget child;
    if (controller.isLoadingMore && controller.items.isNotEmpty) {
      stateKey = _dataStateKey(controller);
      child = _buildDirectory(loadingMore: true);
      return AppMotionEntrance(
        key: ValueKey('content-state-$stateKey'),
        duration: AppMotion.emphasized,
        child: child,
      );
    }
    switch (controller.status) {
      case LibraryContentStatus.loading:
        stateKey = controller.isSearching ? 'search-loading' : 'loading';
        child = controller.isSearching
            ? LibrarySearchLoadingState(
                controller: controller,
                debugOnBuild: widget.debugOnSearchProgressBuild,
              )
            : const LibraryLoadingState();
      case LibraryContentStatus.error:
        stateKey = 'error';
        child = LibraryErrorState(
          message: controller.errorMessage,
          onRetry: controller.retry,
        );
      case LibraryContentStatus.empty:
        stateKey = controller.isSearching
            ? controller.searchWasCancelled
                  ? 'search-cancelled'
                  : 'search-empty'
            : 'empty';
        child = _emptyState(controller);
      case LibraryContentStatus.data:
        stateKey = _dataStateKey(controller);
        child = _buildDirectory(loadingMore: false);
    }
    return AppMotionEntrance(
      key: ValueKey('content-state-$stateKey'),
      duration: AppMotion.emphasized,
      child: child,
    );
  }

  Widget _buildDirectory({required bool loadingMore}) {
    final controller = widget.controller;
    final restoreScroll =
        controller.isSearching &&
        controller.query == widget.restoreScrollForQuery;
    final currentKeys = controller.items
        .map((item) => item.stableKey)
        .toList(growable: false);
    final appended = _appendedKeys(_lastDataKeys, currentKeys);
    _lastDataKeys = currentKeys;
    return Stack(
      children: [
        Positioned.fill(
          child: LibraryDirectoryList(
            controller: controller,
            appearingKeys: appended,
            compactGrid: widget.compactGrid,
            onTapSource: widget.onOpenItemSource,
            initialScrollOffset: restoreScroll
                ? widget.restoredScrollOffset
                : 0,
            onScrollOffsetChanged: widget.onDirectoryScrollOffsetChanged,
            onTapItem: (item) {
              if (item.isFolder) {
                controller.openFolder(item);
              } else if (widget.showPersistentDetails) {
                controller.selectItem(item);
              } else {
                widget.onShowTransientDetails(item);
              }
            },
          ),
        ),
        if (loadingMore)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: RepaintBoundary(
              child: Semantics(
                liveRegion: true,
                label: '正在加载更多项目',
                child: AppMotion.isEnabled(context)
                    ? const LinearProgressIndicator(minHeight: 3)
                    : Container(
                        height: 3,
                        color: Theme.of(context).colorScheme.primary,
                      ),
              ),
            ),
          ),
      ],
    );
  }

  String _dataStateKey(LibraryController controller) {
    if (controller.isSearching) return 'data-search-${controller.query}';
    final sourceId = controller.selectedSource?.sourceId ?? 'none';
    final depth = controller.breadcrumbs.length;
    return 'data-source-$sourceId-depth-$depth';
  }

  LibraryEmptyState _emptyState(LibraryController controller) {
    if (controller.isSearching) {
      if (controller.searchWasCancelled) {
        return const LibraryEmptyState(
          icon: Icons.cancel_outlined,
          title: '搜索已取消',
          message: '未保留本次搜索结果',
        );
      }
      return const LibraryEmptyState(
        icon: Icons.search_off_rounded,
        title: '没有匹配结果',
      );
    }
    if (controller.config.sources.isEmpty) {
      return const LibraryEmptyState(
        icon: Icons.source_outlined,
        title: '尚未配置软件源',
      );
    }
    if (!controller.config.features.browse) {
      return const LibraryEmptyState(
        icon: Icons.folder_off_outlined,
        title: '目录浏览已关闭',
      );
    }
    return const LibraryEmptyState(
      icon: Icons.folder_open_rounded,
      title: '此目录没有文件',
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.textController,
    required this.focusNode,
  });

  final LibraryController controller;
  final TextEditingController textController;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: textController,
      builder: (context, value, _) => SearchBar(
        key: const Key('library-search-bar'),
        controller: textController,
        focusNode: focusNode,
        hintText: '搜索全部来源',
        leading: const Icon(Icons.search_rounded),
        trailing: [
          if (value.text.isNotEmpty)
            IconButton(
              tooltip: '清除搜索',
              onPressed: () {
                textController.clear();
                controller.search('');
              },
              icon: const Icon(Icons.close_rounded),
            ),
        ],
        textInputAction: TextInputAction.search,
        onSubmitted: controller.search,
      ),
    );
  }
}

class LibraryBreadcrumbBar extends StatelessWidget {
  const LibraryBreadcrumbBar({super.key, required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Semantics(
        container: true,
        label: controller.isSearching ? '搜索结果路径' : '当前目录路径',
        child: ListView(
          key: const Key('breadcrumb-list'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          scrollDirection: Axis.horizontal,
          children: [
            if (controller.isSearching)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  child: Row(
                    children: [
                      const Icon(Icons.manage_search_rounded, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '搜索结果',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ],
                  ),
                ),
              )
            else
              for (
                var index = 0;
                index < controller.breadcrumbs.length;
                index++
              ) ...[
                if (index > 0)
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                TextButton.icon(
                  onPressed: controller.status == LibraryContentStatus.loading
                      ? null
                      : () => controller.openBreadcrumb(index),
                  icon: index == 0
                      ? const Icon(Icons.home_outlined, size: 18)
                      : const SizedBox.shrink(),
                  label: Text(controller.breadcrumbs[index].title),
                ),
              ],
          ],
        ),
      ),
    );
  }
}

Set<String> _appendedKeys(List<String> previous, List<String> current) {
  if (previous.isEmpty || current.length <= previous.length) return const {};
  for (var index = 0; index < previous.length; index++) {
    if (previous[index] != current[index]) return const {};
  }
  // Large batches stay cheap; the first visible additions still explain that
  // the load-more action inserted rows rather than replacing the directory.
  return current.skip(previous.length).take(8).toSet();
}

typedef _ContentSnapshot = ({
  LibraryContentStatus status,
  Object? selectedSource,
  Object? folder,
  Object items,
  Object breadcrumbs,
  String query,
  String errorMessage,
  bool searchWasCancelled,
  String? selectedItemKey,
  bool isLoadingMore,
  String loadMoreError,
});
