import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../controllers/library_controller.dart';
import '../../shared/app_motion.dart';
import 'library_share_dialog.dart';

class LibrarySourceHeader extends StatefulWidget {
  const LibrarySourceHeader({
    super.key,
    required this.controller,
    required this.compact,
  });

  final LibraryController controller;
  final bool compact;

  @override
  State<LibrarySourceHeader> createState() => _LibrarySourceHeaderState();
}

class _LibrarySourceHeaderState extends State<LibrarySourceHeader> {
  bool _descriptionExpanded = false;
  String _publisher = '';
  String _description = '';
  String _avatarUrl = '';

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.isSearching) {
      return Padding(
        padding: EdgeInsets.fromLTRB(20, widget.compact ? 12 : 16, 20, 4),
        child: Row(
          children: [
            Icon(
              Icons.manage_search_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '搜索结果',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Text(
              '${controller.items.length} 项',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    final source = controller.selectedSource;
    if (source == null) return const SizedBox.shrink();
    final folder = controller.folder;
    if (folder?.publisher.isNotEmpty == true) _publisher = folder!.publisher;
    if (folder?.description.isNotEmpty == true) {
      _description = folder!.description;
    }
    if (folder?.avatarUrl.isNotEmpty == true) _avatarUrl = folder!.avatarUrl;
    final publisher = _publisher;
    final description = _description;
    final canExpand = description.runes.length > 96;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, widget.compact ? 12 : 18, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _SourceAvatar(
                url: _avatarUrl,
                loadAsset: controller.loadAsset,
                size: widget.compact ? 56 : 48,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (publisher.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        '由 $publisher 发布',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                key: const Key('source-share-action'),
                tooltip: '分享',
                onPressed: () {
                  final current = controller.breadcrumbs.isEmpty
                      ? source.shareUrl
                      : controller.breadcrumbs.last.shareUrl;
                  final title = controller.breadcrumbs.isEmpty
                      ? source.title
                      : controller.breadcrumbs.last.title;
                  showLibraryShareDialog(
                    context: context,
                    title: title,
                    shareUrl: current,
                    password: source.password,
                  );
                },
                icon: const Icon(Icons.ios_share_rounded),
              ),
              IconButton(
                tooltip: '刷新当前目录',
                onPressed: controller.status == LibraryContentStatus.loading
                    ? null
                    : controller.refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 12),
            AnimatedSize(
              duration: AppMotion.duration(context, AppMotion.standard),
              curve: AppMotion.emphasizedCurve,
              alignment: Alignment.topCenter,
              child: Text(
                description,
                maxLines: _descriptionExpanded ? 8 : 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ),
            if (canExpand)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(
                    () => _descriptionExpanded = !_descriptionExpanded,
                  ),
                  icon: Icon(
                    _descriptionExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(_descriptionExpanded ? '收起简介' : '展开简介'),
                ),
              ),
          ],
          const SizedBox(height: 4),
          Text(
            '已显示 ${controller.items.length} 个项目',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SourceAvatar extends StatefulWidget {
  const _SourceAvatar({
    required this.url,
    required this.loadAsset,
    required this.size,
  });

  final String url;
  final Future<Uint8List?> Function(String url) loadAsset;
  final double size;

  @override
  State<_SourceAvatar> createState() => _SourceAvatarState();
}

class _SourceAvatarState extends State<_SourceAvatar> {
  Future<Uint8List?>? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _SourceAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  void _load() {
    final uri = Uri.tryParse(widget.url);
    _bytes =
        uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            !uri.hasPort
        ? widget.loadAsset(uri.toString())
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final fallback = Icon(
      Icons.folder_rounded,
      size: widget.size * 0.62,
      color: Theme.of(context).colorScheme.primary,
    );
    if (bytes == null) {
      return SizedBox.square(dimension: widget.size, child: fallback);
    }
    final pixelSize = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 192);
    return SizedBox.square(
      dimension: widget.size,
      child: ClipOval(
        child: FutureBuilder<Uint8List?>(
          future: bytes,
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data == null) return fallback;
            return Image.memory(
              data,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              cacheWidth: pixelSize,
              cacheHeight: pixelSize,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => fallback,
            );
          },
        ),
      ),
    );
  }
}
