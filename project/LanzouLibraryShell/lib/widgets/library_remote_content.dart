import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../repositories/library_remote_content_repository.dart';

class LibraryRemoteImage extends StatefulWidget {
  const LibraryRemoteImage({
    super.key,
    required this.url,
    required this.repository,
    required this.semanticLabel,
    this.fit = BoxFit.cover,
  });

  final String url;
  final LibraryRemoteContentRepository repository;
  final String semanticLabel;
  final BoxFit fit;

  @override
  State<LibraryRemoteImage> createState() => _LibraryRemoteImageState();
}

class _LibraryRemoteImageState extends State<LibraryRemoteImage> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LibraryRemoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.repository != widget.repository) {
      _load();
    }
  }

  void _load({bool refresh = false}) {
    _future = widget.repository.loadImage(widget.url, refresh: refresh);
  }

  void _retry() {
    setState(() => _load(refresh: true));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _RemoteImageLoading(url: widget.url);
        }
        final bytes = snapshot.data;
        if (snapshot.hasError || bytes == null) {
          return _RemoteImageError(url: widget.url, onRetry: _retry);
        }
        return Image.memory(
          bytes,
          fit: widget.fit,
          semanticLabel: widget.semanticLabel,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) =>
              _RemoteImageError(url: widget.url, onRetry: _retry),
        );
      },
    );
  }
}

class LibraryRemoteImageIcon extends StatefulWidget {
  const LibraryRemoteImageIcon({
    super.key,
    required this.url,
    required this.repository,
    required this.semanticLabel,
    this.size = 28,
  });

  final String url;
  final LibraryRemoteContentRepository repository;
  final String semanticLabel;
  final double size;

  @override
  State<LibraryRemoteImageIcon> createState() => _LibraryRemoteImageIconState();
}

class _LibraryRemoteImageIconState extends State<LibraryRemoteImageIcon> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LibraryRemoteImageIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.repository != widget.repository) {
      _load();
    }
  }

  void _load({bool refresh = false}) {
    _future = widget.repository.loadImage(widget.url, refresh: refresh);
  }

  void _retry() {
    setState(() => _load(refresh: true));
  }

  @override
  Widget build(BuildContext context) {
    final pixelSize = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 192);
    return SizedBox.square(
      dimension: widget.size,
      child: FutureBuilder<Uint8List>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Center(
              child: SizedBox.square(
                key: ValueKey('remote-icon-loading-${widget.url}'),
                dimension: widget.size * 0.58,
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          final bytes = snapshot.data;
          if (snapshot.hasError || bytes == null) {
            return _iconError();
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(widget.size * 0.2),
            child: Image.memory(
              bytes,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              cacheWidth: pixelSize,
              cacheHeight: pixelSize,
              semanticLabel: widget.semanticLabel,
              errorBuilder: (_, _, _) => _iconError(),
            ),
          );
        },
      ),
    );
  }

  Widget _iconError() => IconButton(
    key: ValueKey('remote-icon-error-${widget.url}'),
    tooltip: '重新加载${widget.semanticLabel}',
    padding: EdgeInsets.zero,
    constraints: BoxConstraints.tightFor(
      width: widget.size,
      height: widget.size,
    ),
    onPressed: _retry,
    icon: const Icon(Icons.refresh_rounded),
  );
}

class LibraryRemoteAnnouncement extends StatefulWidget {
  const LibraryRemoteAnnouncement({
    super.key,
    required this.url,
    required this.repository,
    required this.onOpenUrl,
  });

  final String url;
  final LibraryRemoteContentRepository repository;
  final VoidCallback onOpenUrl;

  @override
  State<LibraryRemoteAnnouncement> createState() =>
      _LibraryRemoteAnnouncementState();
}

class _LibraryRemoteAnnouncementState extends State<LibraryRemoteAnnouncement> {
  late Future<String> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LibraryRemoteAnnouncement oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.repository != widget.repository) {
      _load();
    }
  }

  void _load({bool refresh = false}) {
    _future = widget.repository.loadText(widget.url, refresh: refresh);
  }

  void _retry() {
    setState(() => _load(refresh: true));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const Key('home-remote-announcement'),
      color: colors.secondaryContainer.withValues(alpha: 0.48),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.campaign_outlined,
                  color: colors.onSecondaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '公告',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: widget.onOpenUrl,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('打开原链接'),
                ),
              ],
            ),
            FutureBuilder<String>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(
                      child: SizedBox.square(
                        key: Key('announcement-loading'),
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return _AnnouncementError(onRetry: _retry);
                }
                final text = snapshot.data ?? '';
                return Padding(
                  padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
                  child: SelectionArea(
                    child: Text(
                      text.isEmpty ? '暂无公告内容' : text,
                      key: const Key('announcement-body'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSecondaryContainer,
                        height: 1.5,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoteImageLoading extends StatelessWidget {
  const _RemoteImageLoading({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Center(
        child: SizedBox.square(
          key: ValueKey('remote-image-loading-$url'),
          dimension: 28,
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _RemoteImageError extends StatelessWidget {
  const _RemoteImageError({required this.url, required this.onRetry});

  final String url;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: ValueKey('remote-image-error-$url'),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_outlined,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnnouncementError extends StatelessWidget {
  const _AnnouncementError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('announcement-error'),
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: colors.error),
          const SizedBox(width: 8),
          const Expanded(child: Text('公告加载失败，请稍后重试')),
          TextButton.icon(
            key: const Key('announcement-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
