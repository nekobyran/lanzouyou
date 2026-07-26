import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/app_motion.dart';

enum _LibraryShareMethod { text, importableSource }

/// Presents two truthful share representations backed by the current item or
/// source contract. Both actions copy concrete data; no unavailable system
/// share target is simulated.
Future<void> showLibraryShareDialog({
  required BuildContext context,
  required String title,
  required String shareUrl,
  String password = '',
}) async {
  final normalizedUrl = shareUrl.trim();
  if (normalizedUrl.isEmpty) return;
  final method = await showDialog<_LibraryShareMethod>(
    context: context,
    useSafeArea: true,
    animationStyle: AnimationStyle(
      duration: AppMotion.duration(context, AppMotion.emphasized),
      reverseDuration: AppMotion.duration(context, AppMotion.standard),
      curve: AppMotion.emphasizedCurve,
      reverseCurve: AppMotion.exitCurve,
    ),
    builder: (context) => _LibraryShareDialog(title: title),
  );
  if (method == null || !context.mounted) return;

  final normalizedPassword = password.trim();
  final text = switch (method) {
    _LibraryShareMethod.text => [
      if (title.trim().isNotEmpty) title.trim(),
      normalizedUrl,
      if (normalizedPassword.isNotEmpty) '访问码：$normalizedPassword',
    ].join('\n'),
    _LibraryShareMethod.importableSource =>
      normalizedPassword.isEmpty
          ? normalizedUrl
          : '$normalizedUrl $normalizedPassword',
  };
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          method == _LibraryShareMethod.text ? '分享文本已复制' : '可导入来源已复制',
        ),
      ),
    );
}

class _LibraryShareDialog extends StatelessWidget {
  const _LibraryShareDialog({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      key: const Key('library-share-dialog'),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.ios_share_rounded, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '分享',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: Navigator.of(context).pop,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              if (title.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  title.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _ShareMethodTile(
                key: const Key('share-method-text'),
                icon: Icons.text_snippet_outlined,
                title: '分享文本',
                description: '复制名称、链接与访问码，适合发送给他人',
                onTap: () =>
                    Navigator.of(context).pop(_LibraryShareMethod.text),
              ),
              const SizedBox(height: 8),
              _ShareMethodTile(
                key: const Key('share-method-importable-source'),
                icon: Icons.playlist_add_rounded,
                title: '可导入软件库来源',
                description: '复制“链接 密码”，可直接粘贴到来源导入入口',
                onTap: () => Navigator.of(
                  context,
                ).pop(_LibraryShareMethod.importableSource),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShareMethodTile extends StatefulWidget {
  const _ShareMethodTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  State<_ShareMethodTile> createState() => _ShareMethodTileState();
}

class _ShareMethodTileState extends State<_ShareMethodTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = _focused
        ? colors.secondaryContainer
        : _hovered
        ? colors.onSurface.withValues(alpha: 0.06)
        : colors.surfaceContainerLow;
    return Semantics(
      button: true,
      label: '${widget.title}，${widget.description}',
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
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(20),
          ),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(widget.icon, color: colors.primary),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.description,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
