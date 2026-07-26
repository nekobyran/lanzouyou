import 'package:flutter/material.dart';

import '../../config/library_config.dart';
import '../../controllers/library_controller.dart';
import '../../shared/app_listenable_selector.dart';
import '../../shared/app_motion.dart';

class LibraryBrandLogo extends StatelessWidget {
  const LibraryBrandLogo({super.key, required this.config, required this.size});

  final LibraryConfig config;
  final double size;

  @override
  Widget build(BuildContext context) {
    final logoAsset = config.branding.logoAsset;
    return SizedBox.square(
      dimension: size,
      child: logoAsset.isEmpty
          ? Icon(Icons.apps_rounded, size: size)
          : ClipRRect(
              borderRadius: BorderRadius.circular(size * 0.25),
              child: Image.asset(
                logoAsset,
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .ceil(),
                cacheHeight: (size * MediaQuery.devicePixelRatioOf(context))
                    .ceil(),
                errorBuilder: (_, _, _) => Icon(Icons.apps_rounded, size: size),
              ),
            ),
    );
  }
}

class LibrarySourceRail extends StatefulWidget {
  const LibrarySourceRail({
    super.key,
    required this.controller,
    required this.extended,
    required this.downloadsEnabled,
    required this.downloadsSelected,
    required this.onSourceSelected,
    required this.onDownloadsSelected,
  });

  final LibraryController controller;
  final bool extended;
  final bool downloadsEnabled;
  final bool downloadsSelected;
  final ValueChanged<LibrarySource> onSourceSelected;
  final VoidCallback onDownloadsSelected;

  @override
  State<LibrarySourceRail> createState() => _LibrarySourceRailState();
}

class _LibrarySourceRailState extends State<LibrarySourceRail> {
  static const _extendedWidth = 280.0;
  static const _compactWidth = 88.0;
  static const _extendedItemExtent = 56.0;
  static const _compactItemExtent = 64.0;

  final ScrollController _scrollController = ScrollController();
  String? _lastVisibleSourceId;
  String? _pendingVisibleSourceId;

  @override
  void didUpdateWidget(covariant LibrarySourceRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.extended != widget.extended) {
      _lastVisibleSourceId = null;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.controller.config;
    return AppListenableSelector<String?>(
      listenable: widget.controller,
      selector: () => widget.controller.selectedSource?.sourceId,
      builder: (context, selectedSourceId, child) {
        _ensureSelectedSourceVisible(context, selectedSourceId);
        final colors = Theme.of(context).colorScheme;
        final background = colors.surfaceContainerLow;
        final sourceExtent = _sourceExtent(context);
        final paneWidth = _paneWidth(context);
        return AnimatedContainer(
          key: const Key('wide-source-pane'),
          duration: AppMotion.duration(context, AppMotion.standard),
          curve: AppMotion.emphasizedCurve,
          width: paneWidth,
          color: background,
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Tooltip(
                    message: config.identity.displayName,
                    child: LibraryBrandLogo(config: config, size: 40),
                  ),
                ),
                Expanded(
                  child: Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: widget.extended,
                    child: ListView.builder(
                      key: const Key('wide-source-list'),
                      controller: _scrollController,
                      itemExtent: sourceExtent,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: config.sources.length,
                      itemBuilder: (context, index) {
                        final source = config.sources[index];
                        return _sourceDestination(
                          context,
                          source,
                          selected:
                              source.sourceId == selectedSourceId &&
                              !widget.downloadsSelected,
                        );
                      },
                    ),
                  ),
                ),
                if (widget.extended && config.branding.publisher.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        config.branding.publisher,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                if (widget.downloadsEnabled) ...[
                  const Divider(height: 1),
                  _downloadDestination(context),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        );
      },
      child: null,
    );
  }

  Widget _sourceDestination(
    BuildContext context,
    LibrarySource source, {
    required bool selected,
  }) {
    final label = source.recommended ? '${source.title} · 推荐' : source.title;
    if (widget.extended) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: ListTile(
          key: Key('wide-source-${source.sourceId}'),
          minTileHeight: 52,
          dense: true,
          selected: selected,
          selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
          leading: Icon(_sourceIcon(source, selected: selected)),
          title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => widget.onSourceSelected(source),
        ),
      );
    }
    return Center(
      child: IconButton(
        key: Key('wide-source-${source.sourceId}'),
        tooltip: label,
        isSelected: selected,
        icon: Icon(_sourceIcon(source, selected: false)),
        selectedIcon: Icon(_sourceIcon(source, selected: true)),
        onPressed: () => widget.onSourceSelected(source),
      ),
    );
  }

  Widget _downloadDestination(BuildContext context) {
    if (widget.extended) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: ListTile(
          key: const Key('wide-download-destination'),
          minTileHeight: 52,
          dense: true,
          selected: widget.downloadsSelected,
          selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
          leading: Icon(
            widget.downloadsSelected
                ? Icons.download_rounded
                : Icons.download_outlined,
          ),
          title: const Text('下载'),
          onTap: widget.onDownloadsSelected,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: IconButton(
        key: const Key('wide-download-destination'),
        tooltip: '下载',
        isSelected: widget.downloadsSelected,
        icon: const Icon(Icons.download_outlined),
        selectedIcon: const Icon(Icons.download_rounded),
        onPressed: widget.onDownloadsSelected,
      ),
    );
  }

  void _ensureSelectedSourceVisible(
    BuildContext context,
    String? selectedSourceId,
  ) {
    if (selectedSourceId == null ||
        selectedSourceId == _lastVisibleSourceId ||
        selectedSourceId == _pendingVisibleSourceId ||
        widget.downloadsSelected) {
      return;
    }
    final index = widget.controller.config.sources.indexWhere(
      (source) => source.sourceId == selectedSourceId,
    );
    if (index < 0) return;
    _pendingVisibleSourceId = selectedSourceId;
    final motionEnabled = AppMotion.isEnabled(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingVisibleSourceId != selectedSourceId) return;
      _pendingVisibleSourceId = null;
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      final extent = _sourceExtent(context);
      final target =
          (index * extent - (position.viewportDimension - extent) / 2)
              .clamp(0.0, position.maxScrollExtent)
              .toDouble();
      _lastVisibleSourceId = selectedSourceId;
      if (motionEnabled) {
        _scrollController.animateTo(
          target,
          duration: AppMotion.standard,
          curve: AppMotion.emphasizedCurve,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  double _sourceExtent(BuildContext context) {
    if (!widget.extended) return _compactItemExtent;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.0);
    return (32 + 24 * scale).clamp(_extendedItemExtent, 104).toDouble();
  }

  double _paneWidth(BuildContext context) {
    if (!widget.extended) return _compactWidth;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.0);
    return (_extendedWidth + (scale - 1) * 48).clamp(280, 360).toDouble();
  }
}

IconData _sourceIcon(LibrarySource source, {required bool selected}) {
  if (source.recommended) {
    return selected ? Icons.star_rounded : Icons.star_outline_rounded;
  }
  return selected ? Icons.folder_rounded : Icons.folder_outlined;
}
