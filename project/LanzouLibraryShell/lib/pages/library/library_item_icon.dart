import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/library_item.dart';

class LibraryItemIcon extends StatefulWidget {
  const LibraryItemIcon({
    super.key,
    required this.item,
    required this.loadAsset,
    this.size = 40,
  });

  final LibraryItem item;
  final Future<Uint8List?> Function(String url) loadAsset;
  final double size;

  @override
  State<LibraryItemIcon> createState() => _LibraryItemIconState();
}

class _LibraryItemIconState extends State<LibraryItemIcon> {
  Future<Uint8List?>? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LibraryItemIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.iconUrl != widget.item.iconUrl ||
        oldWidget.item.isFolder != widget.item.isFolder) {
      _load();
    }
  }

  void _load() {
    final item = widget.item;
    if (item.isFolder) {
      _bytes = null;
      return;
    }
    final uri = Uri.tryParse(item.iconUrl);
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
    if (widget.item.isFolder) {
      return _fallback(context, folder: true);
    }
    final bytes = _bytes;
    if (bytes == null) return _fallback(context);
    final pixelSize = (widget.size * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, 192);
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.size * 0.22),
          child: FutureBuilder<Uint8List?>(
            future: bytes,
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (data == null) return _fallback(context);
              return Image.memory(
                data,
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                cacheWidth: pixelSize,
                cacheHeight: pixelSize,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _fallback(context),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _fallback(BuildContext context, {bool folder = false}) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: widget.size,
      child: Icon(
        folder ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
        size: widget.size * 0.68,
        color: folder ? colors.primary : colors.tertiary,
      ),
    );
  }
}
