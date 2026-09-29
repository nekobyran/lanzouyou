import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/transfer_controller.dart';
import '../../models/transfer_entry.dart';
import '../../shared/app_motion.dart';

class TransfersPage extends StatelessWidget {
  const TransfersPage({
    required this.controller,
    this.kindFilter,
    this.title = '传输',
    super.key,
  });

  final TransferController controller;
  final TransferKind? kindFilter;
  final String title;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final entries = kindFilter == null
            ? controller.entries
            : controller.entries
                  .where((entry) => entry.kind == kindFilter)
                  .toList(growable: false);
        return Scaffold(
          appBar: AppBar(
            title: Text(title),
            actions: [
              TextButton.icon(
                onPressed: entries.any(_isFinished)
                    ? () => controller.clearFinished(kind: kindFilter)
                    : null,
                icon: const Icon(Icons.clear_all),
                label: const Text('清除已完成'),
              ),
            ],
          ),
          body: AppMotionSwitcher(
            child: entries.isEmpty
                ? _TransferEmpty(
                    key: ValueKey(
                      kindFilter == TransferKind.download
                          ? 'empty-downloads'
                          : 'empty-transfers',
                    ),
                    title: kindFilter == TransferKind.download
                        ? '还没有下载任务'
                        : '还没有传输任务',
                  )
                : Scrollbar(
                    key: ValueKey(
                      kindFilter == TransferKind.download
                          ? 'download-list'
                          : 'transfer-list',
                    ),
                    child: ListView.separated(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return AppMotionListItem(
                          key: ValueKey('transfer-motion-${entry.id}'),
                          child: _TransferRow(
                            entry: entry,
                            onShowDetails: entry.directoryUploadResult == null
                                ? null
                                : () => _showDirectoryUploadDetails(
                                    context,
                                    entry,
                                  ),
                            onPause: controller.canPause(entry.id)
                                ? () => unawaited(controller.pause(entry.id))
                                : null,
                            onResume: controller.canResume(entry.id)
                                ? () => unawaited(controller.resume(entry.id))
                                : null,
                            onCancel:
                                entry.state == TransferState.queued ||
                                    entry.state == TransferState.running ||
                                    entry.state == TransferState.paused
                                ? () => unawaited(controller.cancel(entry.id))
                                : null,
                            onRetryIcon: entry.iconRetryAvailable
                                ? () => controller.retryIconBinding(entry.id)
                                : null,
                          ),
                        );
                      },
                    ),
                  ),
          ),
        );
      },
    );
  }

  bool _isFinished(TransferEntry entry) =>
      entry.state != TransferState.queued &&
      entry.state != TransferState.running &&
      entry.state != TransferState.paused &&
      entry.state != TransferState.cancelling;
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({
    required this.entry,
    this.onPause,
    this.onResume,
    this.onCancel,
    this.onRetryIcon,
    this.onShowDetails,
  });

  final TransferEntry entry;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;
  final VoidCallback? onRetryIcon;
  final VoidCallback? onShowDetails;

  @override
  Widget build(BuildContext context) {
    final visual = _visual(entry);
    final isActive =
        entry.state == TransferState.running ||
        entry.state == TransferState.paused ||
        entry.state == TransferState.cancelling;
    final byteProgress = isActive ? _byteProgress(entry) : null;
    return Semantics(
      label: [entry.name, visual.label, ?byteProgress].join('，'),
      liveRegion:
          entry.state == TransferState.cancelling ||
          entry.state == TransferState.cancelled ||
          entry.state == TransferState.succeeded ||
          entry.state == TransferState.succeededWithWarning ||
          entry.state == TransferState.failed,
      child: ListTile(
        onTap: onShowDetails,
        minTileHeight: 72,
        leading: AppMotionSwitcher(
          transition: AppMotionTransition.fade,
          child: Icon(
            visual.icon,
            key: ValueKey(entry.state),
            color: visual.color(context),
          ),
        ),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppMotionSwitcher(
              transition: AppMotionTransition.fade,
              alignment: Alignment.centerLeft,
              child: Text(
                entry.errorMessage ?? visual.label,
                key: ValueKey('${entry.state}:${entry.errorMessage}'),
              ),
            ),
            AppMotionAnimatedSize(
              alignment: Alignment.centerLeft,
              child: isActive
                  ? Padding(
                      key: const ValueKey('transfer-progress'),
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(
                            minHeight: 4,
                            value: entry.progress,
                            semanticsLabel: byteProgress,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            byteProgress!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(
                      key: ValueKey('transfer-progress-hidden'),
                    ),
            ),
          ],
        ),
        trailing: _trailingAction(),
      ),
    );
  }

  Widget? _trailingAction() {
    if (onRetryIcon != null) {
      return Semantics(
        label: '重试图标绑定，不会重新上传文件',
        button: true,
        child: IconButton.filledTonal(
          key: const Key('retry-icon-binding-action'),
          tooltip: '重试图标绑定',
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          onPressed: onRetryIcon,
          icon: const Icon(Icons.refresh),
        ),
      );
    }
    if (entry.state == TransferState.cancelling) {
      return Semantics(
        key: const ValueKey('cancelling-transfer-action'),
        label: '正在取消传输，请稍候',
        liveRegion: true,
        child: SizedBox.square(
          dimension: 48,
          child: Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ),
      );
    }
    final actions = <Widget>[];
    if (onPause != null) {
      actions.add(
        IconButton(
          key: const Key('pause-transfer-action'),
          tooltip: '暂停传输',
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          onPressed: onPause,
          icon: const Icon(Icons.pause_rounded),
        ),
      );
    }
    if (onResume != null) {
      actions.add(
        IconButton(
          key: const Key('resume-transfer-action'),
          tooltip: '继续传输',
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          onPressed: onResume,
          icon: const Icon(Icons.play_arrow_rounded),
        ),
      );
    }
    if (onCancel != null) {
      final tooltip = entry.state == TransferState.queued
          ? '取消排队'
          : switch (entry.kind) {
              TransferKind.upload => '取消上传',
              TransferKind.directoryUpload => '取消文件夹上传',
              TransferKind.download => '取消下载',
            };
      actions.add(
        IconButton(
          key: ValueKey('cancel-transfer-${entry.state}'),
          tooltip: tooltip,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          onPressed: onCancel,
          icon: const Icon(Icons.close),
        ),
      );
    }
    if (actions.isEmpty) return null;
    return Row(mainAxisSize: MainAxisSize.min, children: actions);
  }

  _TransferVisual _visual(TransferEntry entry) {
    return switch (entry.state) {
      TransferState.queued => const _TransferVisual(
        Icons.schedule,
        '等待传输，可取消',
        _neutral,
      ),
      TransferState.running => switch (entry.kind) {
        TransferKind.upload => const _TransferVisual(
          Icons.upload,
          '正在上传',
          _primary,
        ),
        TransferKind.directoryUpload => const _TransferVisual(
          Icons.drive_folder_upload_outlined,
          '正在上传文件夹',
          _primary,
        ),
        TransferKind.download => const _TransferVisual(
          Icons.download,
          '正在下载',
          _primary,
        ),
      },
      TransferState.paused => const _TransferVisual(
        Icons.pause_circle_outline,
        '已暂停，可继续或取消',
        _neutral,
      ),
      TransferState.cancelling => const _TransferVisual(
        Icons.cancel_outlined,
        '正在取消',
        _neutral,
      ),
      TransferState.cancelled => const _TransferVisual(
        Icons.cancel_outlined,
        '已取消',
        _neutral,
      ),
      TransferState.succeeded => _TransferVisual(
        Icons.check_circle_outline,
        entry.kind == TransferKind.directoryUpload ? '文件夹上传完成' : '传输成功',
        _primary,
      ),
      TransferState.succeededWithWarning => _TransferVisual(
        Icons.warning_amber_rounded,
        entry.kind == TransferKind.directoryUpload
            ? '文件夹已部分上传，点按查看失败明细'
            : '文件上传成功，但图标未设置',
        _warning,
      ),
      TransferState.failed => const _TransferVisual(
        Icons.error_outline,
        '传输失败',
        _error,
      ),
    };
  }
}

String _byteProgress(TransferEntry entry) {
  final transferred = _formatBytes(entry.bytesTransferred);
  final total = entry.totalBytes;
  final units =
      entry.kind == TransferKind.directoryUpload && entry.totalUnits > 0
      ? '已处理 ${entry.completedUnits}/${entry.totalUnits} 个文件 · '
      : '';
  if (total == null || total <= 0) return '$units已传输 $transferred';
  final percent = ((entry.progress ?? 0) * 100).round();
  return '$units$transferred / ${_formatBytes(total)}（$percent%）';
}

Future<void> _showDirectoryUploadDetails(
  BuildContext context,
  TransferEntry entry,
) async {
  final result = entry.directoryUploadResult;
  if (result == null) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(
        result.failures.isEmpty
            ? Icons.check_circle_outline
            : Icons.warning_amber_rounded,
      ),
      title: Text('「${result.rootName}」上传结果'),
      content: SizedBox(
        width: 560,
        height: result.failures.isEmpty
            ? null
            : (MediaQuery.sizeOf(context).height * 0.55).clamp(240.0, 520.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.summary),
            if (result.failures.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '未完成 ${result.failures.length} 项',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Scrollbar(
                  child: ListView.separated(
                    key: const Key('directory-upload-failure-list'),
                    itemCount: result.failures.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final failure = result.failures[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.error_outline),
                        title: Text(
                          failure.relativePath,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(failure.message),
                      );
                    },
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = <String>['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final digits = value >= 100 || value == value.roundToDouble() ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unitIndex]}';
}

class _TransferVisual {
  const _TransferVisual(this.icon, this.label, this.color);

  final IconData icon;
  final String label;
  final Color Function(BuildContext) color;
}

Color _primary(BuildContext context) => Theme.of(context).colorScheme.primary;
Color _error(BuildContext context) => Theme.of(context).colorScheme.error;
Color _warning(BuildContext context) => Colors.amber.shade800;
Color _neutral(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

class _TransferEmpty extends StatelessWidget {
  const _TransferEmpty({this.title = '还没有传输任务', super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(
        label: title,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.swap_vert,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
