import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../public_library/public_library_core.dart';
import '../public_library/public_library_models.dart';
import '../../shared/app_motion.dart';

enum LanzouSettingsAction {
  manageSources,
  importSources,
  exportSources,
  retestSources,
  resetSources,
  searchBehavior,
  downloadBehavior,
}

class LanzouSettingsCapabilities {
  const LanzouSettingsCapabilities({
    this.manageSources = false,
    this.importSources = false,
    this.exportSources = false,
    this.retestSources = false,
    this.resetSources = false,
    this.searchBehavior = false,
    this.downloadBehavior = false,
  });

  final bool manageSources;
  final bool importSources;
  final bool exportSources;
  final bool retestSources;
  final bool resetSources;
  final bool searchBehavior;
  final bool downloadBehavior;

  bool supports(LanzouSettingsAction action) => switch (action) {
    LanzouSettingsAction.manageSources => manageSources,
    LanzouSettingsAction.importSources => importSources,
    LanzouSettingsAction.exportSources => exportSources,
    LanzouSettingsAction.retestSources => retestSources,
    LanzouSettingsAction.resetSources => resetSources,
    LanzouSettingsAction.searchBehavior => searchBehavior,
    LanzouSettingsAction.downloadBehavior => downloadBehavior,
  };
}

typedef LanzouSettingsTask = Future<void> Function();

class LanzouSettingsActions {
  const LanzouSettingsActions({
    this.manageSources,
    this.importSources,
    this.exportSources,
    this.retestSources,
    this.resetSources,
    this.openSearchBehavior,
    this.openDownloadBehavior,
  });

  final LanzouSettingsTask? manageSources;
  final LanzouSettingsTask? importSources;
  final LanzouSettingsTask? exportSources;
  final LanzouSettingsTask? retestSources;
  final LanzouSettingsTask? resetSources;
  final LanzouSettingsTask? openSearchBehavior;
  final LanzouSettingsTask? openDownloadBehavior;

  LanzouSettingsTask? taskFor(LanzouSettingsAction action) => switch (action) {
    LanzouSettingsAction.manageSources => manageSources,
    LanzouSettingsAction.importSources => importSources,
    LanzouSettingsAction.exportSources => exportSources,
    LanzouSettingsAction.retestSources => retestSources,
    LanzouSettingsAction.resetSources => resetSources,
    LanzouSettingsAction.searchBehavior => openSearchBehavior,
    LanzouSettingsAction.downloadBehavior => openDownloadBehavior,
  };
}

/// Bridges only capabilities already proven and implemented by the Rust
/// catalog adapter. A row cannot be enabled without an executable callback.
class LanzouSettingsController extends ChangeNotifier {
  LanzouSettingsController({
    required this.catalog,
    required this.capabilities,
    required this.actions,
  }) {
    for (final action in LanzouSettingsAction.values) {
      if (capabilities.supports(action) && actions.taskFor(action) == null) {
        throw ArgumentError(
          'Lanzou capability ${action.name} requires a real action',
        );
      }
    }
  }

  final PublicLibraryCatalogCore catalog;
  final LanzouSettingsCapabilities capabilities;
  final LanzouSettingsActions actions;

  PublicLibraryCatalogSummary? summary;
  bool isLoading = false;
  LanzouSettingsAction? busyAction;
  String errorMessage = '';
  bool _initialized = false;
  bool _disposed = false;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    await reload();
  }

  Future<void> reload() async {
    if (_disposed || isLoading) return;
    isLoading = true;
    errorMessage = '';
    notifyListeners();
    try {
      summary = await catalog.catalogSummary();
    } on Object {
      errorMessage = '无法读取蓝奏来源状态';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> run(LanzouSettingsAction action) async {
    final task = actions.taskFor(action);
    if (!capabilities.supports(action) || task == null || busyAction != null) {
      return;
    }
    busyAction = action;
    errorMessage = '';
    notifyListeners();
    try {
      await task();
      if (_changesCatalog(action)) await _reloadAfterAction();
    } on Object {
      errorMessage = '${_actionLabel(action)}失败，请稍后重试';
    } finally {
      busyAction = null;
      notifyListeners();
    }
  }

  Future<void> _reloadAfterAction() async {
    try {
      summary = await catalog.catalogSummary();
    } on Object {
      errorMessage = '操作已完成，但来源统计刷新失败';
    }
  }

  bool _changesCatalog(LanzouSettingsAction action) => switch (action) {
    LanzouSettingsAction.importSources ||
    LanzouSettingsAction.retestSources ||
    LanzouSettingsAction.resetSources => true,
    _ => false,
  };

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}

class LanzouSettingsPage extends StatefulWidget {
  const LanzouSettingsPage({
    required this.controller,
    this.embedded = false,
    this.disposeController = false,
    this.appearanceContentBuilder,
    this.behaviorContentBuilder,
    this.accountContentBuilder,
    super.key,
  });

  final LanzouSettingsController controller;
  final bool embedded;
  final bool disposeController;
  final WidgetBuilder? appearanceContentBuilder;
  final WidgetBuilder? behaviorContentBuilder;
  final WidgetBuilder? accountContentBuilder;

  @override
  State<LanzouSettingsPage> createState() => _LanzouSettingsPageState();
}

enum _LanzouSettingsPane { overview, appearance, behavior, account }

class _LanzouSettingsPageState extends State<LanzouSettingsPage> {
  _LanzouSettingsPane _selectedPane = _LanzouSettingsPane.overview;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(LanzouSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      unawaited(widget.controller.initialize());
    }
  }

  @override
  void dispose() {
    if (widget.disposeController) widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = SafeArea(
      top: false,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.f5): () =>
              unawaited(widget.controller.reload()),
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.maybePop(context),
        },
        child: FocusTraversalGroup(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final accountBuilder = widget.accountContentBuilder;
              final appearanceBuilder = widget.appearanceContentBuilder;
              final behaviorBuilder = widget.behaviorContentBuilder;
              final wide =
                  constraints.maxWidth >= 960 &&
                  (accountBuilder != null ||
                      appearanceBuilder != null ||
                      behaviorBuilder != null);
              if (!wide) {
                return _LanzouSettingsContent(
                  controller: widget.controller,
                  onOpenAppearance: appearanceBuilder == null
                      ? null
                      : _openAppearance,
                  onOpenBehavior: behaviorBuilder == null
                      ? null
                      : _openBehavior,
                  onOpenAccount: accountBuilder == null ? null : _openAccount,
                );
              }
              return Row(
                key: const Key('lanzou-settings-wide-master-detail'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 360,
                    child: _LanzouSettingsContent(
                      controller: widget.controller,
                      appearanceSelected:
                          _selectedPane == _LanzouSettingsPane.appearance,
                      behaviorSelected:
                          _selectedPane == _LanzouSettingsPane.behavior,
                      accountSelected:
                          _selectedPane == _LanzouSettingsPane.account,
                      onOpenOverview: () => setState(
                        () => _selectedPane = _LanzouSettingsPane.overview,
                      ),
                      onOpenAppearance: appearanceBuilder == null
                          ? null
                          : () async => setState(
                              () => _selectedPane =
                                  _LanzouSettingsPane.appearance,
                            ),
                      onOpenBehavior: behaviorBuilder == null
                          ? null
                          : () async => setState(
                              () =>
                                  _selectedPane = _LanzouSettingsPane.behavior,
                            ),
                      onOpenAccount: accountBuilder == null
                          ? null
                          : () async => setState(
                              () => _selectedPane = _LanzouSettingsPane.account,
                            ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: AppMotionSwitcher(
                      alignment: Alignment.topLeft,
                      child: _selectedPane == _LanzouSettingsPane.account
                          ? accountBuilder == null
                                ? const SizedBox.shrink()
                                : KeyedSubtree(
                                    key: const ValueKey('account-pane'),
                                    child: accountBuilder(context),
                                  )
                          : _selectedPane == _LanzouSettingsPane.appearance
                          ? appearanceBuilder == null
                                ? const SizedBox.shrink()
                                : KeyedSubtree(
                                    key: const ValueKey('appearance-pane'),
                                    child: appearanceBuilder(context),
                                  )
                          : _selectedPane == _LanzouSettingsPane.behavior
                          ? behaviorBuilder == null
                                ? const SizedBox.shrink()
                                : KeyedSubtree(
                                    key: const ValueKey('behavior-pane'),
                                    child: behaviorBuilder(context),
                                  )
                          : _LanzouOverviewDetail(
                              key: const ValueKey('overview-pane'),
                              controller: widget.controller,
                            ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (widget.embedded) {
      return Material(
        key: const Key('lanzou-settings-embedded'),
        child: content,
      );
    }
    return Scaffold(
      key: const Key('lanzou-settings-page'),
      appBar: AppBar(
        title: const Text('蓝奏'),
        actions: [
          ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) => IconButton(
              tooltip: '刷新来源状态',
              onPressed:
                  widget.controller.isLoading ||
                      widget.controller.busyAction != null
                  ? null
                  : () => unawaited(widget.controller.reload()),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
        ],
      ),
      body: content,
    );
  }

  Future<void> _openAccount() async {
    final builder = widget.accountContentBuilder;
    if (builder == null) return;
    await _openDetail('账号与会员', builder);
  }

  Future<void> _openAppearance() async {
    final builder = widget.appearanceContentBuilder;
    if (builder == null) return;
    await _openDetail('外观', builder);
  }

  Future<void> _openBehavior() async {
    final builder = widget.behaviorContentBuilder;
    if (builder == null) return;
    await _openDetail('链接与搜索', builder);
  }

  Future<void> _openDetail(String title, WidgetBuilder builder) {
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: AppMotion.mediumFor(context),
        reverseTransitionDuration: AppMotion.fastFor(context),
        pageBuilder: (context, animation, secondaryAnimation) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(top: false, child: builder(context)),
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            AppMotion.transition(
              AppMotionTransition.fadeThrough,
              child,
              animation,
            ),
      ),
    );
  }
}

class _LanzouSettingsContent extends StatelessWidget {
  const _LanzouSettingsContent({
    required this.controller,
    required this.onOpenAppearance,
    required this.onOpenBehavior,
    required this.onOpenAccount,
    this.onOpenOverview,
    this.appearanceSelected = false,
    this.behaviorSelected = false,
    this.accountSelected = false,
  });

  final LanzouSettingsController controller;
  final Future<void> Function()? onOpenAppearance;
  final Future<void> Function()? onOpenBehavior;
  final Future<void> Function()? onOpenAccount;
  final VoidCallback? onOpenOverview;
  final bool appearanceSelected;
  final bool behaviorSelected;
  final bool accountSelected;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scrollbar(
      child: ListView(
        key: const Key('lanzou-settings-list'),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionHeader('来源'),
                  _SourceSummary(
                    controller: controller,
                    selected:
                        onOpenOverview != null &&
                        !appearanceSelected &&
                        !behaviorSelected &&
                        !accountSelected,
                    onTap: onOpenOverview,
                  ),
                  if (controller.capabilities.manageSources) ...[
                    const Divider(),
                    _ActionTile(
                      controller: controller,
                      action: LanzouSettingsAction.manageSources,
                      icon: Icons.source_outlined,
                      title: '来源管理',
                      subtitle: '查看与管理已加载的真实来源',
                    ),
                  ],
                  if (controller.capabilities.importSources) ...[
                    const Divider(),
                    _ActionTile(
                      controller: controller,
                      action: LanzouSettingsAction.importSources,
                      icon: Icons.file_download_outlined,
                      title: '导入来源',
                      subtitle: '选择支持的来源文件并由 Rust 校验',
                    ),
                  ],
                  if (controller.capabilities.exportSources) ...[
                    const Divider(),
                    _ActionTile(
                      controller: controller,
                      action: LanzouSettingsAction.exportSources,
                      icon: Icons.file_upload_outlined,
                      title: '导出来源',
                      subtitle: '导出当前可分享的来源配置',
                    ),
                  ],
                  if (controller.capabilities.retestSources) ...[
                    const Divider(),
                    _ActionTile(
                      controller: controller,
                      action: LanzouSettingsAction.retestSources,
                      icon: Icons.fact_check_outlined,
                      title: '重新测试来源',
                      subtitle: '重新验证连通性与可搜索能力',
                    ),
                  ],
                  if (controller.capabilities.resetSources) ...[
                    const Divider(),
                    _ActionTile(
                      controller: controller,
                      action: LanzouSettingsAction.resetSources,
                      icon: Icons.restore_rounded,
                      title: '恢复默认来源',
                      subtitle: '移除自定义变更并恢复内置目录',
                      destructive: true,
                      onTap: () => _confirmReset(context),
                    ),
                  ],
                  if (onOpenAppearance != null) ...[
                    const Divider(),
                    const _SectionHeader('应用'),
                    ListTile(
                      key: const Key('lanzou-appearance-settings'),
                      selected: appearanceSelected,
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('外观'),
                      subtitle: const Text('主题与减少动效'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => unawaited(onOpenAppearance!()),
                    ),
                  ],
                  if (onOpenBehavior != null) ...[
                    const Divider(),
                    ListTile(
                      key: const Key('lanzou-behavior-settings'),
                      selected: behaviorSelected,
                      leading: const Icon(Icons.tune_rounded),
                      title: const Text('链接与搜索'),
                      subtitle: const Text('链接打开方式、来源链接与结果显示速度'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => unawaited(onOpenBehavior!()),
                    ),
                  ],
                  if (onOpenAccount != null) ...[
                    const Divider(),
                    const _SectionHeader('账号'),
                    ListTile(
                      key: const Key('lanzou-account-settings'),
                      selected: accountSelected,
                      leading: const Icon(Icons.account_circle_outlined),
                      title: const Text('账号与会员'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => unawaited(onOpenAccount!()),
                    ),
                  ],
                  if (controller.capabilities.searchBehavior ||
                      controller.capabilities.downloadBehavior) ...[
                    const Divider(),
                    const _SectionHeader('行为'),
                    if (controller.capabilities.searchBehavior)
                      _ActionTile(
                        controller: controller,
                        action: LanzouSettingsAction.searchBehavior,
                        icon: Icons.manage_search_outlined,
                        title: '搜索行为',
                        subtitle: '并发、目录范围与递归搜索',
                      ),
                    if (controller.capabilities.searchBehavior &&
                        controller.capabilities.downloadBehavior)
                      const Divider(),
                    if (controller.capabilities.downloadBehavior)
                      _ActionTile(
                        controller: controller,
                        action: LanzouSettingsAction.downloadBehavior,
                        icon: Icons.download_outlined,
                        title: '下载行为',
                        subtitle: '保存位置、直链预解析与任务行为',
                      ),
                  ],
                  AppMotionAnimatedSize(
                    child: controller.errorMessage.isEmpty
                        ? const SizedBox.shrink()
                        : Semantics(
                            liveRegion: true,
                            child: Column(
                              children: [
                                const Divider(),
                                ListTile(
                                  key: const Key('lanzou-settings-error'),
                                  leading: Icon(
                                    Icons.error_outline_rounded,
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                  title: Text(
                                    controller.errorMessage,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                  trailing: IconButton(
                                    tooltip: '重试',
                                    onPressed: controller.isLoading
                                        ? null
                                        : () => unawaited(controller.reload()),
                                    icon: const Icon(Icons.refresh_rounded),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.restore_rounded),
        title: const Text('恢复默认来源？'),
        content: const Text('自定义来源与合集变更将被移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-reset-lanzou-sources'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.run(LanzouSettingsAction.resetSources);
    }
  }
}

class _SourceSummary extends StatelessWidget {
  const _SourceSummary({
    required this.controller,
    this.selected = false,
    this.onTap,
  });

  final LanzouSettingsController controller;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final summary = controller.summary;
    return ListTile(
      key: const Key('lanzou-source-summary'),
      selected: selected,
      leading: const Icon(Icons.cloud_queue_outlined),
      title: const Text('当前来源'),
      subtitle: Semantics(
        liveRegion: true,
        child: AppMotionSwitcher(
          transition: AppMotionTransition.fade,
          alignment: Alignment.centerLeft,
          child: controller.isLoading && summary == null
              ? const Text('正在读取', key: ValueKey('loading'))
              : summary == null
              ? const Text('暂无来源统计', key: ValueKey('unavailable'))
              : Text(
                  '${summary.officialCount} 个官方来源 · '
                  '${summary.compositeCount} 个合集',
                  key: ValueKey(summary.revision),
                ),
        ),
      ),
      trailing: controller.isLoading
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: onTap,
    );
  }
}

class _LanzouOverviewDetail extends StatelessWidget {
  const _LanzouOverviewDetail({required this.controller, super.key});

  final LanzouSettingsController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final summary = controller.summary;
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: AppMotionSwitcher(
                child: controller.isLoading && summary == null
                    ? const _OverviewLoading(key: ValueKey('overview-loading'))
                    : summary == null
                    ? _OverviewError(
                        key: const ValueKey('overview-error'),
                        message: controller.errorMessage.isEmpty
                            ? '无法读取蓝奏来源状态'
                            : controller.errorMessage,
                        retry: controller.reload,
                      )
                    : _OverviewData(
                        key: ValueKey(summary.revision),
                        summary: summary,
                        refreshing: controller.isLoading,
                        refresh: controller.reload,
                      ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _OverviewLoading extends StatelessWidget {
  const _OverviewLoading({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      liveRegion: true,
      label: '正在读取来源概览',
      child: const CircularProgressIndicator(),
    ),
  );
}

class _OverviewError extends StatelessWidget {
  const _OverviewError({required this.message, required this.retry, super.key});

  final String message;
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.cloud_off_outlined,
          size: 42,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          onPressed: () => unawaited(retry()),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      ],
    ),
  );
}

class _OverviewData extends StatelessWidget {
  const _OverviewData({
    required this.summary,
    required this.refreshing,
    required this.refresh,
    super.key,
  });

  final PublicLibraryCatalogSummary summary;
  final bool refreshing;
  final Future<void> Function() refresh;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              '来源概览',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          IconButton(
            tooltip: '刷新来源状态',
            onPressed: refreshing ? null : () => unawaited(refresh()),
            icon: refreshing
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      const SizedBox(height: 20),
      ListTile(
        leading: const Icon(Icons.cloud_outlined),
        title: const Text('官方来源'),
        trailing: Text('${summary.officialCount}'),
      ),
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.folder_copy_outlined),
        title: const Text('软件合集'),
        trailing: Text('${summary.compositeCount}'),
      ),
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.account_tree_outlined),
        title: const Text('目录节点'),
        trailing: Text('${summary.nodeCount}'),
      ),
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.manage_search_outlined),
        title: const Text('可搜索来源'),
        trailing: Text('${summary.searchableCount}'),
      ),
    ],
  );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.controller,
    required this.action,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.destructive = false,
    this.onTap,
  });

  final LanzouSettingsController controller;
  final LanzouSettingsAction action;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool destructive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final busy = controller.busyAction == action;
    final blocked = controller.busyAction != null;
    final color = destructive ? Theme.of(context).colorScheme.error : null;
    return Semantics(
      button: true,
      child: ListTile(
        key: Key('lanzou-settings-${action.name}'),
        enabled: !blocked,
        leading: Icon(icon, color: color),
        title: Text(
          title,
          style: color == null ? null : TextStyle(color: color),
        ),
        subtitle: Text(subtitle),
        trailing: busy
            ? const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right_rounded),
        onTap: blocked
            ? null
            : onTap ?? () => unawaited(controller.run(action)),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

String _actionLabel(LanzouSettingsAction action) => switch (action) {
  LanzouSettingsAction.manageSources => '来源管理',
  LanzouSettingsAction.importSources => '导入来源',
  LanzouSettingsAction.exportSources => '导出来源',
  LanzouSettingsAction.retestSources => '重新测试来源',
  LanzouSettingsAction.resetSources => '恢复默认来源',
  LanzouSettingsAction.searchBehavior => '打开搜索行为设置',
  LanzouSettingsAction.downloadBehavior => '打开下载行为设置',
};
