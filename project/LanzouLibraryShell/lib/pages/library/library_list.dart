import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../controllers/library_controller.dart';
import '../../models/library_item.dart';
import '../../shared/app_motion.dart';
import 'library_item_icon.dart';

class LibraryDirectoryList extends StatefulWidget {
  const LibraryDirectoryList({
    super.key,
    required this.controller,
    required this.onTapItem,
    this.onTapSource,
    this.appearingKeys = const <String>{},
    this.compactGrid = false,
    this.initialScrollOffset = 0,
    this.onScrollOffsetChanged,
  });

  final LibraryController controller;
  final ValueChanged<LibraryItem> onTapItem;
  final ValueChanged<LibraryItem>? onTapSource;
  final Set<String> appearingKeys;
  final bool compactGrid;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollOffsetChanged;

  @override
  State<LibraryDirectoryList> createState() => _LibraryDirectoryListState();
}

class _LibraryDirectoryListState extends State<LibraryDirectoryList> {
  final LinkedHashSet<String> _pendingAnimations = LinkedHashSet();
  final LinkedHashSet<String> _consumedAnimations = LinkedHashSet();
  late final ScrollController _scrollController;
  String _autoRequestedPage = '';

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    );
    _scrollController.addListener(_handleScroll);
    _queueAnimations(widget.appearingKeys);
    _scheduleViewportCheck();
  }

  @override
  void didUpdateWidget(covariant LibraryDirectoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.appearingKeys, widget.appearingKeys)) {
      _queueAnimations(widget.appearingKeys);
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      _autoRequestedPage = '';
    }
    _scheduleViewportCheck();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _scheduleViewportCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadNextPage();
    });
  }

  void _handleScroll() {
    widget.onScrollOffsetChanged?.call(_scrollController.position.pixels);
    _maybeLoadNextPage();
  }

  void _maybeLoadNextPage() {
    if (!_scrollController.hasClients ||
        widget.controller.isSearching ||
        widget.controller.isLoadingMore ||
        widget.controller.loadMoreError.isNotEmpty) {
      return;
    }
    final folder = widget.controller.folder;
    if (folder == null || !folder.hasMore) return;
    final position = _scrollController.position;
    final threshold = (position.viewportDimension * 0.75).clamp(
      320.0,
      double.infinity,
    );
    if (position.extentAfter > threshold) return;
    final pageKey =
        '${folder.sourceId}\u0000${folder.url}\u0000'
        '${folder.folderId}\u0000${folder.page + 1}';
    if (_autoRequestedPage == pageKey) return;
    _autoRequestedPage = pageKey;
    unawaited(widget.controller.loadMore());
  }

  void _queueAnimations(Iterable<String> keys) {
    for (final key in keys) {
      if (!_consumedAnimations.contains(key)) _pendingAnimations.add(key);
    }
    while (_pendingAnimations.length > _maxPendingInsertAnimations) {
      _pendingAnimations.remove(_pendingAnimations.first);
    }
  }

  bool _consumeAnimation(String key) {
    if (!_pendingAnimations.remove(key)) return false;
    _consumedAnimations.add(key);
    while (_consumedAnimations.length > _maxRememberedInsertAnimations) {
      _consumedAnimations.remove(_consumedAnimations.first);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.controller.items;
    final hasMore = widget.controller.folder?.hasMore == true;
    final useCompactGrid =
        widget.compactGrid &&
        MediaQuery.sizeOf(context).width >= 360 &&
        MediaQuery.textScalerOf(context).scale(1) < 1.35;
    return Scrollbar(
      controller: _scrollController,
      child: CustomScrollView(
        key: const Key('directory-scroll-view'),
        controller: _scrollController,
        slivers: [
          if (useCompactGrid)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              sliver: SliverGrid.builder(
                key: const Key('compact-directory-grid'),
                itemCount: items.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisExtent: widget.controller.isSearching ? 154 : 122,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return _ListInsertMotion(
                    animate: _consumeAnimation(item.stableKey),
                    child: LibraryCompactGridTile(
                      key: ValueKey('compact-library-item-${item.stableKey}'),
                      item: item,
                      selected:
                          widget.controller.selectedItem?.stableKey ==
                          item.stableKey,
                      loadAsset: widget.controller.loadAsset,
                      sourceTitle: _sourceTitle(widget.controller, item),
                      onOpenSource: _sourceAction(item),
                      onTap: () => widget.onTapItem(item),
                    ),
                  );
                },
              ),
            )
          else
            SliverList.builder(
              key: widget.compactGrid
                  ? const Key('compact-directory-list')
                  : const Key('wide-directory-list'),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return _ListInsertMotion(
                  animate: _consumeAnimation(item.stableKey),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LibraryDirectoryRow(
                        key: ValueKey('library-item-${item.stableKey}'),
                        item: item,
                        selected:
                            widget.controller.selectedItem?.stableKey ==
                            item.stableKey,
                        showDescription:
                            widget.controller.config.features.showDescription,
                        loadAsset: widget.controller.loadAsset,
                        sourceTitle: _sourceTitle(widget.controller, item),
                        onOpenSource: _sourceAction(item),
                        onTap: () => widget.onTapItem(item),
                      ),
                      const Divider(indent: 76),
                    ],
                  ),
                );
              },
            ),
          if (hasMore)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Center(
                  child: widget.controller.loadMoreError.isEmpty
                      ? OutlinedButton.icon(
                          key: const Key('load-more-fallback'),
                          onPressed: widget.controller.isLoadingMore
                              ? null
                              : widget.controller.loadMore,
                          icon: const Icon(Icons.expand_more_rounded),
                          label: const Text('加载更多'),
                        )
                      : Semantics(
                          liveRegion: true,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.controller.loadMoreError,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                key: const Key('retry-load-more'),
                                onPressed: widget.controller.loadMore,
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('重试下一页'),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }

  VoidCallback? _sourceAction(LibraryItem item) {
    if (!widget.controller.isSearching ||
        widget.controller.config.sourceById(item.sourceId) == null ||
        widget.onTapSource == null) {
      return null;
    }
    return () => widget.onTapSource!(item);
  }

  String _sourceTitle(LibraryController controller, LibraryItem item) {
    if (!controller.isSearching) return '';
    final configured = controller.config.sourceById(item.sourceId)?.title;
    if (configured != null && configured.trim().isNotEmpty) return configured;
    if (item.source.trim().isNotEmpty) return item.source.trim();
    return item.sourceId;
  }
}

const _maxPendingInsertAnimations = 16;
const _maxRememberedInsertAnimations = 128;

class LibraryCompactGridTile extends StatefulWidget {
  const LibraryCompactGridTile({
    super.key,
    required this.item,
    required this.selected,
    required this.loadAsset,
    required this.onTap,
    this.sourceTitle = '',
    this.onOpenSource,
  });

  final LibraryItem item;
  final bool selected;
  final Future<Uint8List?> Function(String url) loadAsset;
  final VoidCallback onTap;
  final String sourceTitle;
  final VoidCallback? onOpenSource;

  @override
  State<LibraryCompactGridTile> createState() => _LibraryCompactGridTileState();
}

class _LibraryCompactGridTileState extends State<LibraryCompactGridTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final stateColor = widget.selected
        ? colors.secondaryContainer
        : _focused
        ? colors.secondaryContainer.withValues(alpha: 0.62)
        : _hovered
        ? colors.onSurface.withValues(alpha: 0.06)
        : Colors.transparent;
    final metadata = <String>[
      if (widget.item.size.isNotEmpty) widget.item.size,
      if (widget.item.time.isNotEmpty) widget.item.time,
    ];
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.item.isFolder
          ? '${widget.item.title}，文件夹'
          : widget.item.title,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: AnimatedContainer(
          duration: AppMotion.duration(context, AppMotion.fast),
          curve: AppMotion.enterCurve,
          color: stateColor,
          constraints: const BoxConstraints(minHeight: 96),
          child: InkWell(
            onTap: widget.onTap,
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LibraryItemIcon(
                          item: widget.item,
                          loadAsset: widget.loadAsset,
                          size: 52,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.item.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  color: widget.selected
                                      ? colors.onSecondaryContainer
                                      : colors.onSurface,
                                  fontWeight: widget.selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.sourceTitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    LibraryItemSourceAction(
                      item: widget.item,
                      title: widget.sourceTitle,
                      onTap: widget.onOpenSource,
                      compact: true,
                    ),
                  ],
                  if (metadata.isNotEmpty)
                    Text(
                      metadata.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: widget.selected
                            ? colors.onSecondaryContainer
                            : colors.onSurfaceVariant,
                      ),
                    )
                  else if (widget.item.isFolder)
                    Text(
                      '文件夹',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LibraryDirectoryRow extends StatefulWidget {
  const LibraryDirectoryRow({
    super.key,
    required this.item,
    required this.selected,
    required this.showDescription,
    required this.loadAsset,
    required this.onTap,
    this.sourceTitle = '',
    this.onOpenSource,
  });

  final LibraryItem item;
  final bool selected;
  final bool showDescription;
  final Future<Uint8List?> Function(String url) loadAsset;
  final VoidCallback onTap;
  final String sourceTitle;
  final VoidCallback? onOpenSource;

  @override
  State<LibraryDirectoryRow> createState() => _LibraryDirectoryRowState();
}

class _LibraryDirectoryRowState extends State<LibraryDirectoryRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final stateColor = widget.selected
        ? colors.secondaryContainer
        : _focused
        ? colors.secondaryContainer.withValues(alpha: 0.62)
        : _hovered
        ? colors.onSurface.withValues(alpha: 0.06)
        : Colors.transparent;
    final metadata = <String>[
      if (widget.item.size.isNotEmpty) widget.item.size,
      if (widget.item.time.isNotEmpty) widget.item.time,
      if (widget.showDescription && widget.item.description.isNotEmpty)
        widget.item.description,
    ];
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.item.isFolder
          ? '${widget.item.title}，文件夹'
          : widget.item.title,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: AnimatedContainer(
          duration: AppMotion.duration(context, AppMotion.fast),
          curve: AppMotion.enterCurve,
          color: stateColor,
          constraints: const BoxConstraints(minHeight: 64),
          child: InkWell(
            onTap: widget.onTap,
            canRequestFocus: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Row(
                children: [
                  LibraryItemIcon(
                    item: widget.item,
                    loadAsset: widget.loadAsset,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: widget.selected
                                    ? colors.onSecondaryContainer
                                    : colors.onSurface,
                                fontWeight: widget.selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                        ),
                        if (metadata.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            metadata.join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: widget.selected
                                      ? colors.onSecondaryContainer
                                      : colors.onSurfaceVariant,
                                ),
                          ),
                        ],
                        if (widget.sourceTitle.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: LibraryItemSourceAction(
                              item: widget.item,
                              title: widget.sourceTitle,
                              onTap: widget.onOpenSource,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    widget.item.isFolder
                        ? Icons.chevron_right_rounded
                        : widget.selected
                        ? Icons.info_rounded
                        : Icons.info_outline_rounded,
                    color: widget.selected
                        ? colors.onSecondaryContainer
                        : colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Search provenance is a separate action from opening a result. It remains
/// visually highlighted even when the referenced source is no longer in the
/// current configuration; only a source with a stable, resolvable sourceId is
/// exposed as a button.
class LibraryItemSourceAction extends StatelessWidget {
  const LibraryItemSourceAction({
    super.key,
    required this.item,
    required this.title,
    required this.onTap,
    this.compact = false,
  });

  final LibraryItem item;
  final String title;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 3 : 4,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.source_rounded,
            size: compact ? 13 : 15,
            color: colors.onPrimaryContainer,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  (compact
                          ? Theme.of(context).textTheme.labelSmall
                          : Theme.of(context).textTheme.labelMedium)
                      ?.copyWith(
                        color: colors.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 3),
            Icon(
              Icons.arrow_forward_rounded,
              size: compact ? 13 : 15,
              color: colors.onPrimaryContainer,
            ),
          ],
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      enabled: onTap != null,
      label: onTap == null ? '来源 $title，不可打开' : '来源 $title，打开来源',
      child: Material(
        key: Key('search-result-source-${item.sourceId}'),
        color: colors.primaryContainer,
        textStyle: TextStyle(color: colors.onPrimaryContainer),
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? content
            : InkWell(
                onTap: onTap,
                canRequestFocus: true,
                mouseCursor: SystemMouseCursors.click,
                child: content,
              ),
      ),
    );
  }
}

class _ListInsertMotion extends StatelessWidget {
  const _ListInsertMotion({required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!animate || !AppMotion.isEnabled(context)) return child;
    return TweenAnimationBuilder<double>(
      duration: AppMotion.standard,
      curve: AppMotion.enterCurve,
      tween: Tween(begin: 0, end: 1),
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: child,
        ),
      ),
    );
  }
}
