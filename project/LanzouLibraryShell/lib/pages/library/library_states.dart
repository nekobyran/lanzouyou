import 'package:flutter/material.dart';

import '../../controllers/library_controller.dart';
import '../../shared/app_listenable_selector.dart';
import '../../shared/app_motion.dart';

class LibraryLoadingState extends StatelessWidget {
  const LibraryLoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    final reducedMotion = !AppMotion.isEnabled(context);
    return Center(
      child: Semantics(
        label: '正在加载软件目录',
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reducedMotion)
              const Icon(Icons.hourglass_top_rounded, size: 36)
            else
              const SizedBox.square(
                dimension: 36,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            const SizedBox(height: 16),
            const ExcludeSemantics(child: Text('正在加载软件目录')),
          ],
        ),
      ),
    );
  }
}

class LibrarySearchLoadingState extends StatelessWidget {
  const LibrarySearchLoadingState({
    super.key,
    required this.controller,
    this.debugOnBuild,
  });

  final LibraryController controller;

  @visibleForTesting
  final VoidCallback? debugOnBuild;

  @override
  Widget build(BuildContext context) {
    return AppListenableSelector<_SearchProgressSnapshot>(
      listenable: controller,
      selector: () => (
        operation: controller.searchOperation,
        cancelling: controller.isSearchCancelling,
        cancellationError: controller.searchCancellationError,
        canCancel: controller.canCancelSearch,
      ),
      builder: (context, _, child) {
        assert(() {
          debugOnBuild?.call();
          return true;
        }());
        return _buildProgress(context);
      },
    );
  }

  Widget _buildProgress(BuildContext context) {
    final operation = controller.searchOperation;
    final completed = operation?.completedUnits ?? 0;
    final total = operation?.totalUnits ?? 0;
    final items = operation?.itemsFound ?? 0;
    final cancelling = controller.isSearchCancelling;
    final label = cancelling
        ? '正在取消搜索'
        : total > 0
        ? '已完成 $completed/$total 个来源，找到 $items 项'
        : '正在搜索软件源';
    final reducedMotion = !AppMotion.isEnabled(context);
    return Center(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: label,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (operation?.fraction case final fraction?)
                  LinearProgressIndicator(value: fraction)
                else if (reducedMotion)
                  Icon(
                    cancelling
                        ? Icons.cancel_outlined
                        : Icons.manage_search_rounded,
                    size: 36,
                  )
                else
                  const LinearProgressIndicator(),
                const SizedBox(height: 18),
                ExcludeSemantics(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                if (controller.searchCancellationError.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    controller.searchCancellationError,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                FilledButton.tonalIcon(
                  onPressed:
                      controller.canCancelSearch &&
                          !controller.isSearchCancelling
                      ? controller.cancelSearch
                      : null,
                  icon: Icon(
                    cancelling
                        ? Icons.hourglass_top_rounded
                        : Icons.close_rounded,
                  ),
                  label: Text(cancelling ? '正在取消' : '取消搜索'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

typedef _SearchProgressSnapshot = ({
  Object? operation,
  bool cancelling,
  String cancellationError,
  bool canCancel,
});

class LibraryEmptyState extends StatelessWidget {
  const LibraryEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message = '',
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      container: true,
      label: message.isEmpty ? title : '$title，$message',
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
            ExcludeSemantics(
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 8),
              ExcludeSemantics(
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class LibraryErrorState extends StatelessWidget {
  const LibraryErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      container: true,
      liveRegion: true,
      label: '加载失败，$message',
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            ExcludeSemantics(
              child: Text(
                '加载失败',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            ExcludeSemantics(child: Text(message, textAlign: TextAlign.center)),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    ),
  );
}
