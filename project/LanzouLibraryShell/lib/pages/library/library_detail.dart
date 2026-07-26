import 'package:flutter/material.dart';

import '../../controllers/library_controller.dart';
import '../../models/download_history.dart';
import '../../models/library_item.dart';
import '../../shared/app_listenable_selector.dart';
import '../../shared/app_motion.dart';
import 'library_item_icon.dart';
import 'library_share_dialog.dart';
import 'library_states.dart';

class LibraryDetailPane extends StatelessWidget {
  const LibraryDetailPane({
    super.key,
    required this.controller,
    required this.compact,
  });

  final LibraryController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AppListenableSelector<_DetailSnapshot>(
      listenable: controller,
      selector: () => (
        item: controller.selectedItem,
        detailError: controller.detailError,
        detailDescription: controller.detailDescription,
        descriptionError: controller.descriptionError,
        isDescriptionLoading: controller.isDescriptionLoading,
      ),
      builder: (context, _, child) => _buildPane(context),
    );
  }

  Widget _buildPane(BuildContext context) {
    final item = controller.selectedItem;
    final stateKey = item?.stableKey ?? 'no-selection';
    return Material(
      color: compact
          ? Theme.of(context).colorScheme.surfaceContainerLow
          : Theme.of(context).colorScheme.surfaceContainerLowest,
      child: AppMotionEntrance(
        key: ValueKey('detail-$stateKey'),
        duration: AppMotion.emphasized,
        offset: const Offset(0.025, 0),
        child: item == null
            ? const LibraryEmptyState(
                icon: Icons.touch_app_outlined,
                title: '未选择文件',
                message: '选择一个文件查看详情',
              )
            : _DetailContent(
                controller: controller,
                item: item,
                compact: compact,
              ),
      ),
    );
  }
}

typedef _DetailSnapshot = ({
  Object? item,
  String detailError,
  String detailDescription,
  String descriptionError,
  bool isDescriptionLoading,
});

class _DetailContent extends StatelessWidget {
  const _DetailContent({
    required this.controller,
    required this.item,
    required this.compact,
  });

  final LibraryController controller;
  final LibraryItem item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '${item.title}，文件详情',
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, compact ? 8 : 28, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LibraryItemIcon(
                    item: item,
                    size: 48,
                    loadAsset: controller.loadAsset,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          item.title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (item.source.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          SelectableText(
                            item.source,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('detail-share-action'),
                    tooltip: '分享',
                    onPressed: item.navigationUrl.isEmpty
                        ? null
                        : () {
                            final source = controller.config.sourceById(
                              item.sourceId,
                            );
                            showLibraryShareDialog(
                              context: context,
                              title: item.title,
                              shareUrl: item.navigationUrl,
                              password: source?.password ?? '',
                            );
                          },
                    icon: const Icon(Icons.ios_share_rounded),
                  ),
                  if (!compact)
                    IconButton(
                      tooltip: '关闭详情',
                      onPressed: controller.clearSelection,
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
              if (item.size.isNotEmpty || item.time.isNotEmpty) ...[
                const SizedBox(height: 24),
                Wrap(
                  spacing: 20,
                  runSpacing: 12,
                  children: [
                    if (item.size.isNotEmpty)
                      _Metadata(
                        icon: Icons.data_usage_rounded,
                        value: item.size,
                      ),
                    if (item.time.isNotEmpty)
                      _Metadata(icon: Icons.schedule_rounded, value: item.time),
                  ],
                ),
              ],
              if (controller.config.features.showDescription) ...[
                const SizedBox(height: 28),
                Text('文件简介', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                _DescriptionState(controller: controller),
              ],
              if (controller.detailError.isNotEmpty) ...[
                const SizedBox(height: 20),
                Semantics(
                  liveRegion: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline_rounded, color: colors.error),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          controller.detailError,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (controller.config.features.download) ...[
                const SizedBox(height: 28),
                _DownloadAction(controller: controller, item: item),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadAction extends StatelessWidget {
  const _DownloadAction({required this.controller, required this.item});

  final LibraryController controller;
  final LibraryItem item;

  @override
  Widget build(BuildContext context) {
    return AppListenableSelector<_DownloadActionSnapshot>(
      listenable: controller,
      selector: () => (
        active: controller.activeDownloadFor(item),
        history: controller.latestDownloadFor(item),
        available: controller.downloads != null,
      ),
      builder: (context, snapshot, child) => _buildAction(
        context,
        active: snapshot.active,
        history: snapshot.history,
        available: snapshot.available,
      ),
    );
  }

  Widget _buildAction(
    BuildContext context, {
    required DownloadSnapshot? active,
    required DownloadHistoryEntry? history,
    required bool available,
  }) {
    if (!available) {
      return _withStateMotion(
        'unavailable',
        FilledButton.icon(
          onPressed: null,
          icon: const Icon(Icons.warning_amber_rounded),
          label: const Text('下载服务不可用'),
        ),
      );
    }
    if (active case final task? when !task.state.isTerminal) {
      final status = _activeDownloadStatus(task);
      final total = task.totalBytes;
      final progress = total > 0
          ? (task.bytesTransferred / total).clamp(0.0, 1.0)
          : null;
      final reducedMotion = !AppMotion.isEnabled(context);
      return _withStateMotion(
        'active-${task.state.name}',
        Semantics(
          container: true,
          liveRegion: task.state != DownloadActivityState.downloading,
          label: '下载状态',
          value: status,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Row(
                  children: [
                    Icon(
                      task.state == DownloadActivityState.queued
                          ? Icons.schedule_rounded
                          : task.state == DownloadActivityState.resolving
                          ? Icons.link_rounded
                          : task.state == DownloadActivityState.cancelling
                          ? Icons.hourglass_top_rounded
                          : Icons.downloading_rounded,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(status)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (progress != null)
                LinearProgressIndicator(value: progress)
              else if (reducedMotion)
                Container(
                  height: 4,
                  color: Theme.of(context).colorScheme.primary,
                )
              else
                const LinearProgressIndicator(),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: task.state == DownloadActivityState.cancelling
                    ? null
                    : () => controller.cancelDownload(task),
                icon: Icon(
                  task.state == DownloadActivityState.cancelling
                      ? Icons.hourglass_top_rounded
                      : Icons.close_rounded,
                ),
                label: Text(
                  task.state == DownloadActivityState.cancelling
                      ? '正在取消'
                      : '取消下载',
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (history != null && history.status == DownloadHistoryStatus.succeeded) {
      return _withStateMotion(
        'succeeded',
        FilledButton.icon(
          onPressed: () => controller.openDownload(history),
          icon: const Icon(Icons.folder_open_rounded),
          label: const Text('打开文件'),
        ),
      );
    }
    if (history != null) {
      final interrupted =
          history.status == DownloadHistoryStatus.queued ||
          history.status == DownloadHistoryStatus.resolving ||
          history.status == DownloadHistoryStatus.downloading ||
          history.status == DownloadHistoryStatus.cancelling ||
          history.errorCode == 'interrupted';
      return _withStateMotion(
        'terminal-${history.status.name}',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                interrupted
                    ? '下载已中断'
                    : history.status == DownloadHistoryStatus.cancelled
                    ? '下载已取消'
                    : history.errorMessage.isEmpty
                    ? '下载失败'
                    : history.errorMessage,
                style: TextStyle(
                  color: history.status == DownloadHistoryStatus.failed
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => controller.retryDownload(history),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新下载'),
            ),
          ],
        ),
      );
    }
    return _withStateMotion(
      'idle',
      FilledButton.icon(
        onPressed: () => controller.downloadItem(item),
        icon: const Icon(Icons.download_rounded),
        label: const Text('下载'),
      ),
    );
  }

  Widget _withStateMotion(String state, Widget child) => AppMotionSwitcher(
    child: KeyedSubtree(key: ValueKey('download-action-$state'), child: child),
  );
}

typedef _DownloadActionSnapshot = ({
  DownloadSnapshot? active,
  DownloadHistoryEntry? history,
  bool available,
});

String _activeDownloadStatus(DownloadSnapshot task) => switch (task.state) {
  DownloadActivityState.queued => '等待下载',
  DownloadActivityState.resolving => '正在解析下载地址',
  DownloadActivityState.downloading =>
    task.totalBytes > 0
        ? '已下载 ${_formatDetailBytes(task.bytesTransferred)} / ${_formatDetailBytes(task.totalBytes)} · ${((task.bytesTransferred / task.totalBytes) * 100).clamp(0, 100).round()}%'
        : '已下载 ${_formatDetailBytes(task.bytesTransferred)}',
  DownloadActivityState.cancelling => '正在取消下载',
  DownloadActivityState.succeeded => '下载完成',
  DownloadActivityState.cancelled => '下载已取消',
  DownloadActivityState.failed =>
    task.safeError.isEmpty ? '下载失败' : task.safeError,
};

String _formatDetailBytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _DescriptionState extends StatelessWidget {
  const _DescriptionState({required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final state = controller.isDescriptionLoading
        ? 'loading'
        : controller.descriptionError.isNotEmpty
        ? 'error'
        : 'content';
    final child = switch (state) {
      'loading' => Semantics(
        label: '正在加载文件简介',
        liveRegion: true,
        child: Row(
          children: [
            _ProgressOrStatusIcon(reducedMotion: !AppMotion.isEnabled(context)),
            const SizedBox(width: 12),
            const ExcludeSemantics(child: Text('正在加载简介')),
          ],
        ),
      ),
      'error' => Semantics(
        liveRegion: true,
        child: Text(
          controller.descriptionError,
          style: TextStyle(color: colors.error),
        ),
      ),
      _ => SelectableText(
        controller.detailDescription.isEmpty
            ? '暂无简介'
            : controller.detailDescription,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
          height: 1.55,
        ),
      ),
    };
    return AppMotionEntrance(key: ValueKey('description-$state'), child: child);
  }
}

class _Metadata extends StatelessWidget {
  const _Metadata({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        icon,
        size: 18,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 8),
      Text(value),
    ],
  );
}

class _ProgressOrStatusIcon extends StatelessWidget {
  const _ProgressOrStatusIcon({required this.reducedMotion});

  final bool reducedMotion;

  @override
  Widget build(BuildContext context) => reducedMotion
      ? const SizedBox.square(
          dimension: 20,
          child: Icon(Icons.hourglass_top_rounded, size: 20),
        )
      : const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
}
