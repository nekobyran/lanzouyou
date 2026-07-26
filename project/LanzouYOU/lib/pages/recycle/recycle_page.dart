import 'package:flutter/material.dart';

import '../../controllers/recycle_controller.dart';
import '../../models/cloud_item.dart';
import '../../shared/app_motion.dart';

class RecyclePage extends StatefulWidget {
  const RecyclePage({required this.controller, super.key});

  final RecycleController controller;

  @override
  State<RecyclePage> createState() => _RecyclePageState();
}

class _RecyclePageState extends State<RecyclePage> {
  RecycleController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    if (controller.status == RecycleStatus.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.load());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: AppMotionSwitcher(
            transition: AppMotionTransition.fade,
            child: controller.selectionMode
                ? _selectionAppBar()
                : AppBar(
                    key: const ValueKey('recycle-default-app-bar'),
                    title: const Text('回收站'),
                    actions: [
                      IconButton(
                        tooltip: '刷新回收站',
                        onPressed: controller.operationRunning
                            ? null
                            : () => controller.load(refresh: true),
                        icon: const Icon(Icons.refresh),
                      ),
                      IconButton(
                        key: const Key('empty-recycle-button'),
                        tooltip: '清空回收站',
                        onPressed:
                            controller.items.isEmpty ||
                                controller.operationRunning
                            ? null
                            : _confirmEmpty,
                        icon: const Icon(Icons.delete_sweep_outlined),
                      ),
                    ],
                  ),
          ),
        ),
        body: Column(
          children: [
            AppMotionAnimatedSize(
              child: controller.operationRunning
                  ? Semantics(
                      key: const ValueKey('recycle-operation-progress'),
                      label: '正在处理回收站',
                      liveRegion: true,
                      child: const LinearProgressIndicator(),
                    )
                  : const SizedBox.shrink(
                      key: ValueKey('recycle-operation-idle'),
                    ),
            ),
            Expanded(child: AppMotionSwitcher(child: _body())),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    return AppBar(
      key: const ValueKey('recycle-selection-app-bar'),
      leading: IconButton(
        tooltip: '取消选择',
        onPressed: controller.clearSelection,
        icon: const Icon(Icons.close),
      ),
      title: Text('已选择 ${controller.selectedIds.length} 项'),
      actions: [
        IconButton(
          tooltip: '全选',
          onPressed: controller.selectAll,
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: '恢复所选项目到根目录',
          onPressed: controller.operationRunning
              ? null
              : () => _restore(controller.selectedItems),
          icon: const Icon(Icons.restore),
        ),
        IconButton(
          tooltip: '永久删除所选项目',
          onPressed: controller.operationRunning
              ? null
              : () => _confirmPurge(controller.selectedItems),
          icon: const Icon(Icons.delete_forever_outlined),
        ),
      ],
    );
  }

  Widget _body() {
    return switch (controller.status) {
      RecycleStatus.idle || RecycleStatus.loading => const _RecycleState(
        key: ValueKey('recycle-loading'),
        icon: Icons.recycling,
        title: '正在读取回收站',
        loading: true,
      ),
      RecycleStatus.empty => const _RecycleState(
        key: ValueKey('recycle-empty'),
        icon: Icons.delete_outline,
        title: '回收站是空的',
      ),
      RecycleStatus.error => _RecycleState(
        key: const ValueKey('recycle-error'),
        icon: Icons.error_outline,
        title: '无法读取回收站',
        message: controller.errorMessage,
        actionLabel: '重试',
        onAction: controller.load,
      ),
      RecycleStatus.content => RefreshIndicator(
        key: const ValueKey('recycle-content'),
        onRefresh: () => controller.load(refresh: true),
        child: ListView.separated(
          itemCount: controller.items.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
          itemBuilder: (context, index) {
            final item = controller.items[index];
            final selected = controller.selectedIds.contains(item.id);
            return AppMotionListItem(
              key: ValueKey('recycle-motion-${item.id}'),
              child: AppMotionSelection(
                selected: selected,
                borderRadius: BorderRadius.zero,
                child: Semantics(
                  selected: selected,
                  button: true,
                  label: '回收站中的${item.isFolder ? '文件夹' : '文件'} ${item.name}',
                  child: ListTile(
                    key: ValueKey('recycle-item-${item.id}'),
                    selected: selected,
                    minTileHeight: 64,
                    leading: controller.selectionMode
                        ? Checkbox(
                            value: selected,
                            onChanged: (_) => controller.toggleSelection(item),
                          )
                        : Icon(
                            item.isFolder
                                ? Icons.folder_outlined
                                : Icons.insert_drive_file_outlined,
                          ),
                    title: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: item.modifiedAt == null
                        ? null
                        : Text('删除时间 ${item.modifiedAt}'),
                    onTap: () {
                      if (controller.selectionMode) {
                        controller.toggleSelection(item);
                      } else {
                        _showActions(item);
                      }
                    },
                    onLongPress: () => controller.toggleSelection(item),
                    trailing: PopupMenuButton<_RecycleAction>(
                      tooltip: '回收站操作',
                      onSelected: (action) {
                        if (action == _RecycleAction.restore) {
                          _restore([item]);
                        } else {
                          _confirmPurge([item]);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: _RecycleAction.restore,
                          child: ListTile(
                            leading: Icon(Icons.restore),
                            title: Text('恢复'),
                          ),
                        ),
                        PopupMenuItem(
                          value: _RecycleAction.purge,
                          child: ListTile(
                            leading: Icon(Icons.delete_forever_outlined),
                            title: Text('永久删除'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    };
  }

  Future<void> _showActions(CloudItem item) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('恢复到根目录'),
              onTap: () {
                Navigator.pop(sheetContext);
                _restore([item]);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                '永久删除',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _confirmPurge([item]);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restore(Iterable<CloudItem> values) async {
    final items = values.toList(growable: false);
    final error = await controller.restore(items);
    if (mounted) _message(error ?? '已恢复 ${items.length} 项到根目录');
  }

  Future<void> _confirmPurge(Iterable<CloudItem> values) async {
    final items = values.toList(growable: false);
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('永久删除？'),
        content: Text('${items.length} 个项目将无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await controller.purge(items);
    if (mounted) _message(error ?? '已永久删除 ${items.length} 项');
  }

  Future<void> _confirmEmpty() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('清空回收站？'),
        content: const Text('回收站中的所有项目都将永久删除，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await controller.empty();
    if (mounted) _message(error ?? '回收站已清空');
  }

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _RecycleAction { restore, purge }

class _RecycleState extends StatelessWidget {
  const _RecycleState({
    required this.icon,
    required this.title,
    this.message,
    this.loading = false,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? message;
  final bool loading;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const CircularProgressIndicator()
              else
                Icon(
                  icon,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(message!, textAlign: TextAlign.center),
              ],
              if (actionLabel != null) ...[
                const SizedBox(height: 20),
                FilledButton.tonal(
                  onPressed: onAction,
                  child: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
