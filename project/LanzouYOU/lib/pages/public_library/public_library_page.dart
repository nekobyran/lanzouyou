import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lanzou_library_shell/library_preview.dart';

import '../../shared/app_motion.dart';
import 'public_library_controller.dart';
import 'public_library_models.dart';

typedef PublicLibraryUrlOpener = Future<void> Function(Uri url);

class PublicLibraryPage extends StatefulWidget {
  const PublicLibraryPage({
    required this.controller,
    this.disposeController = true,
    this.showAppBar = true,
    this.safeBottom = true,
    this.autofocusSearch = false,
    this.onOpenPublicUrl,
    super.key,
  });

  final PublicLibraryController controller;
  final bool disposeController;
  final bool showAppBar;
  final bool safeBottom;
  final bool autofocusSearch;
  final PublicLibraryUrlOpener? onOpenPublicUrl;

  @override
  State<PublicLibraryPage> createState() => _PublicLibraryPageState();
}

class _PublicLibraryPageState extends State<PublicLibraryPage> {
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode(debugLabel: 'public-library-search');

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.controller.query);
    widget.controller.addListener(_syncSearchText);
    unawaited(widget.controller.initialize());
    if (widget.autofocusSearch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(PublicLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_syncSearchText);
    widget.controller.addListener(_syncSearchText);
    _searchController.text = widget.controller.query;
    unawaited(widget.controller.initialize());
  }

  void _syncSearchText() {
    final query = widget.controller.query;
    if (_searchController.text != query) _searchController.text = query;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncSearchText);
    if (widget.disposeController) widget.controller.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          _searchFocus.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.f5): () {
          unawaited(widget.controller.refresh());
        },
        const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
      },
      child: FocusTraversalGroup(
        child: _PublicLibraryBody(
          controller: widget.controller,
          searchController: _searchController,
          searchFocus: _searchFocus,
          onOpenNode: _openNode,
          onOpenItem: _openItem,
          onOpenPublicUrl: widget.onOpenPublicUrl,
        ),
      ),
    );
    final body = SafeArea(
      key: const Key('public-library-safe-area'),
      top: !widget.showAppBar,
      bottom: widget.safeBottom,
      child: KeyedSubtree(
        key: const Key('public-library-root'),
        child: shortcuts,
      ),
    );
    if (!widget.showAppBar) return Material(child: body);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('软件库'),
          leading: widget.controller.canGoBack
              ? IconButton(
                  tooltip: '返回上一级',
                  onPressed: () => unawaited(widget.controller.goBack()),
                  icon: const Icon(Icons.arrow_back_rounded),
                )
              : null,
          actions: [
            IconButton(
              tooltip: '刷新当前列表',
              onPressed:
                  widget.controller.status == PublicLibraryContentStatus.loading
                  ? null
                  : () => unawaited(widget.controller.refresh()),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: body,
      ),
    );
  }

  void _handleEscape() {
    if (_searchFocus.hasFocus) {
      _searchFocus.unfocus();
      return;
    }
    if (widget.controller.selectedNode != null ||
        widget.controller.selectedItem != null) {
      widget.controller.clearSelection();
      return;
    }
    if (widget.controller.canGoBack) {
      unawaited(widget.controller.goBack());
      return;
    }
    Navigator.maybePop(context);
  }

  Future<void> _openNode(PublicLibraryCatalogNode node, bool wide) async {
    if (node.isSoftware || (!node.opensCatalog && !node.opensRemoteFolder)) {
      unawaited(widget.controller.selectNode(node));
      if (!wide) await _showCompactDetails();
      return;
    }
    await widget.controller.openNode(node);
  }

  Future<void> _openItem(LibraryItem item, bool wide) async {
    if (item.isFolder) {
      await widget.controller.openItem(item);
      return;
    }
    unawaited(widget.controller.selectItem(item));
    if (!wide) await _showCompactDetails();
  }

  Future<void> _showCompactDetails() async {
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.82,
            ),
            child: _PublicLibraryDetail(
              key: const Key('public-library-detail-sheet'),
              controller: widget.controller,
              compact: true,
              onOpenPublicUrl: widget.onOpenPublicUrl,
            ),
          ),
        ),
      );
    } finally {
      if (mounted) widget.controller.clearSelection();
    }
  }
}

class _PublicLibraryBody extends StatelessWidget {
  const _PublicLibraryBody({
    required this.controller,
    required this.searchController,
    required this.searchFocus,
    required this.onOpenNode,
    required this.onOpenItem,
    required this.onOpenPublicUrl,
  });

  final PublicLibraryController controller;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final Future<void> Function(PublicLibraryCatalogNode, bool) onOpenNode;
  final Future<void> Function(LibraryItem, bool) onOpenItem;
  final PublicLibraryUrlOpener? onOpenPublicUrl;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        final list = _PublicLibraryListRegion(
          controller: controller,
          searchController: searchController,
          searchFocus: searchFocus,
          wide: wide,
          onOpenNode: onOpenNode,
          onOpenItem: onOpenItem,
          onOpenPublicUrl: onOpenPublicUrl,
        );
        if (!wide) return list;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 5, child: list),
            const VerticalDivider(width: 1),
            Expanded(
              flex: 3,
              child: _PublicLibraryDetail(
                key: const Key('public-library-detail-pane'),
                controller: controller,
                compact: false,
                onOpenPublicUrl: onOpenPublicUrl,
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _PublicLibraryListRegion extends StatelessWidget {
  const _PublicLibraryListRegion({
    required this.controller,
    required this.searchController,
    required this.searchFocus,
    required this.wide,
    required this.onOpenNode,
    required this.onOpenItem,
    required this.onOpenPublicUrl,
  });

  final PublicLibraryController controller;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final bool wide;
  final Future<void> Function(PublicLibraryCatalogNode, bool) onOpenNode;
  final Future<void> Function(LibraryItem, bool) onOpenItem;
  final PublicLibraryUrlOpener? onOpenPublicUrl;

  @override
  Widget build(BuildContext context) {
    final horizontal = wide ? 28.0 : 16.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(horizontal, 16, horizontal, 8),
          child: _SearchControls(
            controller: controller,
            textController: searchController,
            focusNode: searchFocus,
          ),
        ),
        if (controller.contentKind == PublicLibraryContentKind.catalog)
          _CatalogSummary(controller: controller, horizontal: horizontal),
        if (controller.contentKind == PublicLibraryContentKind.folder)
          _FolderContextHeader(
            folder: controller.folder,
            horizontal: horizontal,
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 8),
          child: Row(
            children: [
              if (controller.canGoBack)
                IconButton(
                  tooltip: '返回上一级',
                  onPressed: () => unawaited(controller.goBack()),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    controller.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              if (controller.total > 0)
                Text(
                  '${controller.total} 项',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: AppMotionSwitcher(
            alignment: Alignment.topCenter,
            child: _buildState(context),
          ),
        ),
      ],
    );
  }

  Widget _buildState(BuildContext context) => switch (controller.status) {
    PublicLibraryContentStatus.loading => _LoadingState(
      key: const ValueKey('loading'),
      controller: controller,
    ),
    PublicLibraryContentStatus.error => _MessageState(
      key: const ValueKey('error'),
      icon: Icons.cloud_off_outlined,
      title: '加载失败',
      message: controller.errorMessage,
      actionLabel: '重试',
      onAction: controller.retry,
    ),
    PublicLibraryContentStatus.empty => _MessageState(
      key: ValueKey('empty-${controller.searchWasCancelled}'),
      icon: controller.searchWasCancelled
          ? Icons.cancel_outlined
          : Icons.folder_off_outlined,
      title: controller.searchWasCancelled ? '已取消搜索' : '暂无内容',
      message: controller.searchWasCancelled
          ? '未保留未完成的搜索结果'
          : controller.query.trim().isEmpty
          ? '当前目录没有可显示的项目'
          : '没有找到匹配项目',
      actionLabel: controller.query.trim().isEmpty ? null : '清除搜索',
      onAction: controller.query.trim().isEmpty ? null : controller.clearSearch,
    ),
    PublicLibraryContentStatus.data => _LazyCatalogList(
      key: const ValueKey('data'),
      controller: controller,
      wide: wide,
      onOpenNode: onOpenNode,
      onOpenItem: onOpenItem,
      onOpenPublicUrl: onOpenPublicUrl,
    ),
  };
}

class _SearchControls extends StatelessWidget {
  const _SearchControls({
    required this.controller,
    required this.textController,
    required this.focusNode,
  });

  final PublicLibraryController controller;
  final TextEditingController textController;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SearchBar(
        key: const Key('public-library-search-field'),
        controller: textController,
        focusNode: focusNode,
        hintText: controller.searchMode == PublicLibrarySearchMode.software
            ? '搜索全部软件'
            : '筛选当前来源',
        leading: const Icon(Icons.search_rounded),
        onChanged: controller.updateQuery,
        onSubmitted: (_) => unawaited(controller.submitSearch()),
        trailing: [
          if (controller.query.isNotEmpty)
            IconButton(
              tooltip: '清除搜索',
              onPressed: () => unawaited(controller.clearSearch()),
              icon: const Icon(Icons.close_rounded),
            ),
          IconButton(
            tooltip: controller.searchMode == PublicLibrarySearchMode.software
                ? '搜索软件'
                : '筛选来源',
            onPressed: controller.status == PublicLibraryContentStatus.loading
                ? null
                : () => unawaited(controller.submitSearch()),
            icon: const Icon(Icons.arrow_forward_rounded),
          ),
        ],
      ),
      const SizedBox(height: 8),
      SingleChildScrollView(
        key: const Key('public-library-search-mode-scroll'),
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<PublicLibrarySearchMode>(
          key: const Key('public-library-search-mode'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: PublicLibrarySearchMode.software,
              icon: Icon(Icons.apps_outlined),
              label: Text('软件'),
            ),
            ButtonSegment(
              value: PublicLibrarySearchMode.sources,
              icon: Icon(Icons.source_outlined),
              label: Text('来源'),
            ),
          ],
          selected: {controller.searchMode},
          onSelectionChanged:
              controller.status == PublicLibraryContentStatus.loading
              ? null
              : (values) => controller.setSearchMode(values.first),
        ),
      ),
    ],
  );
}

class _CatalogSummary extends StatelessWidget {
  const _CatalogSummary({required this.controller, required this.horizontal});

  final PublicLibraryController controller;
  final double horizontal;

  @override
  Widget build(BuildContext context) {
    final summary = controller.summary;
    if (controller.summaryLoading && summary == null) {
      return const SizedBox(height: 36);
    }
    if (summary == null) {
      return Semantics(
        liveRegion: true,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontal),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  controller.summaryError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              TextButton.icon(
                key: const Key('retry-public-library-summary'),
                onPressed: controller.summaryLoading
                    ? null
                    : () => unawaited(controller.retrySummary()),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Semantics(
      container: true,
      label:
          '${summary.officialCount} 个官方来源，${summary.compositeCount} 个合集，'
          '${summary.nodeCount} 个节点，${summary.searchableCount} 个可搜索',
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: 4),
        child: Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            Text('${summary.officialCount} 个官方来源', style: style),
            Text('${summary.compositeCount} 个合集', style: style),
            Text('${summary.nodeCount} 个节点', style: style),
          ],
        ),
      ),
    );
  }
}

class _FolderContextHeader extends StatelessWidget {
  const _FolderContextHeader({required this.folder, required this.horizontal});

  final LibraryFolder? folder;
  final double horizontal;

  @override
  Widget build(BuildContext context) {
    final value = folder;
    if (value == null ||
        (value.publisher.trim().isEmpty && value.description.trim().isEmpty)) {
      return const SizedBox.shrink();
    }
    return Padding(
      key: const Key('public-library-folder-context'),
      padding: EdgeInsets.fromLTRB(horizontal, 4, horizontal, 8),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (value.publisher.trim().isNotEmpty)
              Text(
                value.publisher.trim(),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            if (value.publisher.trim().isNotEmpty &&
                value.description.trim().isNotEmpty)
              const SizedBox(height: 4),
            if (value.description.trim().isNotEmpty)
              Text(
                value.description.trim(),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
          ],
        ),
      ),
    );
  }
}

class _LazyCatalogList extends StatelessWidget {
  const _LazyCatalogList({
    super.key,
    required this.controller,
    required this.wide,
    required this.onOpenNode,
    required this.onOpenItem,
    required this.onOpenPublicUrl,
  });

  final PublicLibraryController controller;
  final bool wide;
  final Future<void> Function(PublicLibraryCatalogNode, bool) onOpenNode;
  final Future<void> Function(LibraryItem, bool) onOpenItem;
  final PublicLibraryUrlOpener? onOpenPublicUrl;

  @override
  Widget build(BuildContext context) {
    final itemCount = controller.contentKind == PublicLibraryContentKind.catalog
        ? controller.nodes.length
        : controller.items.length;
    final footerCount = controller.hasMore || controller.isLoadingMore ? 1 : 0;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 480 && controller.hasMore) {
          unawaited(controller.loadMore());
        }
        return false;
      },
      child: Scrollbar(
        child: CustomScrollView(
          key: const Key('public-library-lazy-list'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverList.builder(
              itemCount: itemCount + footerCount,
              itemBuilder: (context, index) {
                if (index == itemCount) {
                  return _LoadMoreFooter(controller: controller);
                }
                if (controller.contentKind ==
                    PublicLibraryContentKind.catalog) {
                  final node = controller.nodes[index];
                  return _NodeRow(
                    node: node,
                    selected: controller.selectedNode?.id == node.id,
                    onTap: () => onOpenNode(node, wide),
                    onOpenPublicUrl: onOpenPublicUrl,
                  );
                }
                final item = controller.items[index];
                return _ItemRow(
                  item: item,
                  selected:
                      controller.selectedItem?.stableKey == item.stableKey,
                  onTap: () => onOpenItem(item, wide),
                  onOpenSource:
                      controller.contentKind ==
                              PublicLibraryContentKind.searchResults &&
                          item.sourceId.trim().isNotEmpty
                      ? () => unawaited(controller.openItemSource(item))
                      : null,
                );
              },
            ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
          ],
        ),
      ),
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.selected,
    required this.onTap,
    required this.onOpenPublicUrl,
  });

  final PublicLibraryCatalogNode node;
  final bool selected;
  final VoidCallback onTap;
  final PublicLibraryUrlOpener? onOpenPublicUrl;

  @override
  Widget build(BuildContext context) {
    final subtitle = <String>[
      if (node.sourceLabel.isNotEmpty) node.sourceLabel,
      if (node.size.isNotEmpty) node.size,
      if (node.errorCode.isNotEmpty) '状态：${node.errorCode}',
    ].join(' · ');
    final publicUrl = Uri.tryParse(
      node.shareUrl.isNotEmpty ? node.shareUrl : node.originUrl,
    );
    return Column(
      key: const Key('public-library-node-row'),
      mainAxisSize: MainAxisSize.min,
      children: [
        AppMotionSelection(
          selected: selected,
          borderRadius: BorderRadius.zero,
          child: Material(
            type: MaterialType.transparency,
            child: Semantics(
              button: true,
              label: '${node.title}，${_nodeKindLabel(node.kind)}',
              child: ListTile(
                selected: selected,
                leading: Icon(_nodeIcon(node.kind)),
                title: Text(
                  node.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: subtitle.isEmpty
                    ? null
                    : Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onOpenPublicUrl != null &&
                        publicUrl != null &&
                        publicUrl.hasScheme)
                      IconButton(
                        tooltip: '在浏览器打开来源',
                        onPressed: () => unawaited(onOpenPublicUrl!(publicUrl)),
                        icon: const Icon(Icons.open_in_new_rounded),
                      ),
                    Icon(
                      node.isSoftware
                          ? Icons.info_outline_rounded
                          : Icons.chevron_right_rounded,
                    ),
                  ],
                ),
                onTap: onTap,
              ),
            ),
          ),
        ),
        const Divider(indent: 20, endIndent: 20),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onOpenSource,
  });

  final LibraryItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onOpenSource;

  @override
  Widget build(BuildContext context) {
    final metadata = <String>[
      if (item.size.isNotEmpty) item.size,
      if (item.time.isNotEmpty) item.time,
    ].join(' · ');
    return Column(
      key: const Key('public-library-item-row'),
      mainAxisSize: MainAxisSize.min,
      children: [
        AppMotionSelection(
          selected: selected,
          borderRadius: BorderRadius.zero,
          child: Material(
            type: MaterialType.transparency,
            child: Semantics(
              button: true,
              label: '${item.title}，${item.isFolder ? '文件夹' : '软件'}',
              child: ListTile(
                selected: selected,
                leading: Icon(
                  item.isFolder
                      ? Icons.folder_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: item.source.isEmpty && metadata.isEmpty
                    ? null
                    : Wrap(
                        spacing: 8,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (item.source.isNotEmpty)
                            onOpenSource == null
                                ? Text(item.source)
                                : TextButton.icon(
                                    key: Key(
                                      'public-library-source-${item.sourceId}',
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      minimumSize: const Size(48, 48),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                    ),
                                    onPressed: onOpenSource,
                                    icon: const Icon(
                                      Icons.source_outlined,
                                      size: 18,
                                    ),
                                    label: Text(
                                      item.source,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                          if (metadata.isNotEmpty) Text(metadata),
                        ],
                      ),
                trailing: Icon(
                  item.isFolder
                      ? Icons.chevron_right_rounded
                      : Icons.info_outline_rounded,
                ),
                onTap: onTap,
              ),
            ),
          ),
        ),
        const Divider(indent: 20, endIndent: 20),
      ],
    );
  }
}

class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter({required this.controller});

  final PublicLibraryController controller;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: controller.isLoadingMore,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: controller.isLoadingMore
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : controller.errorMessage.isNotEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    controller.errorMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => unawaited(controller.loadMore()),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试加载'),
                  ),
                ],
              )
            : TextButton.icon(
                onPressed: () => unawaited(controller.loadMore()),
                icon: const Icon(Icons.expand_more_rounded),
                label: const Text('加载更多'),
              ),
      ),
    ),
  );
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({super.key, required this.controller});

  final PublicLibraryController controller;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: controller.isSearchCancelling ? '正在取消搜索' : '正在加载',
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              controller.isSearchCancelling
                  ? '正在取消搜索'
                  : controller.contentKind ==
                        PublicLibraryContentKind.searchResults
                  ? '正在搜索真实软件'
                  : '正在加载真实来源',
            ),
            if (controller.canCancelSearch ||
                controller.isSearchCancelling) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const Key('public-library-cancel-search'),
                onPressed: controller.canCancelSearch
                    ? () => unawaited(controller.cancelSearch())
                    : null,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('取消搜索'),
              ),
            ],
            if (controller.searchCancellationError.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                controller.searchCancellationError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: '$title，$message',
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton.tonal(
                onPressed: () => unawaited(onAction!()),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _PublicLibraryDetail extends StatelessWidget {
  const _PublicLibraryDetail({
    super.key,
    required this.controller,
    required this.compact,
    required this.onOpenPublicUrl,
  });

  final PublicLibraryController controller;
  final bool compact;
  final PublicLibraryUrlOpener? onOpenPublicUrl;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final node = controller.selectedNode;
      final item = controller.selectedItem;
      if (node == null && item == null) {
        return const _MessageState(
          icon: Icons.touch_app_outlined,
          title: '未选择项目',
          message: '选择软件查看真实详情',
        );
      }
      final title = node?.title ?? item!.title;
      final source = node?.sourceLabel ?? item!.source;
      final size = node?.size ?? item!.size;
      final time = node?.time ?? item!.time;
      final rawUrl = node == null
          ? item!.navigationUrl
          : node.shareUrl.isNotEmpty
          ? node.shareUrl
          : node.originUrl;
      final url = Uri.tryParse(rawUrl);
      return Material(
        color: compact
            ? Theme.of(context).colorScheme.surfaceContainerLow
            : Theme.of(context).colorScheme.surfaceContainerLowest,
        child: Semantics(
          container: true,
          label: '$title，软件详情',
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(24, compact ? 4 : 28, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        node?.isSoftware == false || item?.isFolder == true
                            ? Icons.folder_outlined
                            : Icons.apps_rounded,
                        size: 42,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectionArea(
                              child: Text(
                                title,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            if (source.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                source,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (!compact)
                        IconButton(
                          tooltip: '关闭详情',
                          onPressed: controller.clearSelection,
                          icon: const Icon(Icons.close_rounded),
                        ),
                    ],
                  ),
                  if (size.isNotEmpty || time.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 18,
                      runSpacing: 8,
                      children: [
                        if (size.isNotEmpty)
                          _DetailMetadata(
                            icon: Icons.data_usage_rounded,
                            label: size,
                          ),
                        if (time.isNotEmpty)
                          _DetailMetadata(
                            icon: Icons.schedule_rounded,
                            label: time,
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text('软件简介', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  AppMotionSwitcher(
                    alignment: Alignment.topLeft,
                    child: controller.isDescriptionLoading
                        ? Semantics(
                            key: const ValueKey('description-loading'),
                            liveRegion: true,
                            child: const Row(
                              children: [
                                SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text('正在读取详情'),
                              ],
                            ),
                          )
                        : controller.descriptionError.isNotEmpty
                        ? Semantics(
                            key: const ValueKey('description-error'),
                            liveRegion: true,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  controller.descriptionError,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextButton.icon(
                                  onPressed: () =>
                                      unawaited(controller.retryDescription()),
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('重试'),
                                ),
                              ],
                            ),
                          )
                        : SelectableText(
                            controller.description.trim().isEmpty
                                ? '暂无简介'
                                : controller.description,
                            key: const ValueKey('description-content'),
                          ),
                  ),
                  if (onOpenPublicUrl != null &&
                      url != null &&
                      url.hasScheme) ...[
                    const SizedBox(height: 28),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(onOpenPublicUrl!(url)),
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('在浏览器打开来源'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _DetailMetadata extends StatelessWidget {
  const _DetailMetadata({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(label)],
  );
}

IconData _nodeIcon(PublicLibraryNodeKind kind) => switch (kind) {
  PublicLibraryNodeKind.remoteSource => Icons.cloud_outlined,
  PublicLibraryNodeKind.composite => Icons.folder_copy_outlined,
  PublicLibraryNodeKind.folder => Icons.folder_outlined,
  PublicLibraryNodeKind.singleSoftware => Icons.apps_outlined,
  PublicLibraryNodeKind.file => Icons.insert_drive_file_outlined,
};

String _nodeKindLabel(PublicLibraryNodeKind kind) => switch (kind) {
  PublicLibraryNodeKind.remoteSource => '远程来源',
  PublicLibraryNodeKind.composite => '软件合集',
  PublicLibraryNodeKind.folder => '文件夹',
  PublicLibraryNodeKind.singleSoftware => '单软件',
  PublicLibraryNodeKind.file => '文件',
};
