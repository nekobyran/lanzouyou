import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:lanzou_library_shell/library_preview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_version.dart';
import '../../controllers/app_controller.dart';
import '../../pages/public_library/public_library_core.dart';
import '../../services/app_settings_store.dart';
import '../../services/cloud_service.dart';
import '../../shared/app_motion.dart';
import 'account_settings_page.dart';
import 'lanzou_settings_page.dart';

/// Top-level settings index.
///
/// The current product has one settings family: Lanzou. Real child settings
/// live on the next route instead of mixing parent and child rows here.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    required this.controller,
    this.publicLibraryCore,
    this.sourceRegistryCore,
    super.key,
  });

  final AppController controller;
  final PublicLibraryCatalogCore? publicLibraryCore;
  final SourceRegistryCore? sourceRegistryCore;

  @override
  Widget build(BuildContext context) {
    final available = publicLibraryCore != null;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        top: false,
        child: Scrollbar(
          child: ListView(
            key: const Key('settings-list'),
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        key: const Key('lanzou-settings-entry'),
                        enabled: available,
                        leading: const Icon(Icons.cloud_queue_outlined),
                        title: const Text('蓝奏'),
                        subtitle: Text(
                          available ? '来源概览、外观与账号会员' : '当前运行环境未提供蓝奏公共核心',
                        ),
                        trailing: available
                            ? const Icon(Icons.chevron_right_rounded)
                            : null,
                        onTap: available
                            ? () => _openLanzouSettings(context)
                            : null,
                      ),
                      const Divider(height: 1),
                      _UpdateCheckTile(cloudService: controller.cloudService),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openLanzouSettings(BuildContext context) async {
    final core = publicLibraryCore;
    if (core == null) return;
    final settingsController = LanzouSettingsController(
      catalog: core,
      capabilities: LanzouSettingsCapabilities(
        manageSources: sourceRegistryCore != null,
      ),
      actions: LanzouSettingsActions(
        manageSources: sourceRegistryCore == null
            ? null
            : () => _openSourceManager(context),
      ),
    );
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: AppMotion.mediumFor(context),
        reverseTransitionDuration: AppMotion.fastFor(context),
        pageBuilder: (context, animation, secondaryAnimation) =>
            LanzouSettingsPage(
              controller: settingsController,
              disposeController: true,
              appearanceContentBuilder: (_) =>
                  _AppearanceSettingsContent(controller: controller),
              behaviorContentBuilder: (_) =>
                  _LibraryBehaviorSettingsContent(controller: controller),
              accountContentBuilder: (_) =>
                  _AccountSettingsWithLogout(controller: controller),
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

  Future<void> _openSourceManager(BuildContext context) async {
    final registry = sourceRegistryCore;
    if (registry == null) return;
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: AppMotion.mediumFor(context),
        reverseTransitionDuration: AppMotion.fastFor(context),
        pageBuilder: (context, animation, secondaryAnimation) =>
            SourceManagerPage(
              core: registry,
              showSourceLinks: controller.showSourceLinks,
              pickExportPath: () => file_picker.FilePicker.saveFile(
                dialogTitle: '导出 LanzouPlus 来源规则',
                fileName: 'lanzouplus-sources.json',
                type: file_picker.FileType.custom,
                allowedExtensions: const ['json'],
              ),
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

class _UpdateCheckTile extends StatefulWidget {
  const _UpdateCheckTile({required this.cloudService});

  final CloudService cloudService;

  @override
  State<_UpdateCheckTile> createState() => _UpdateCheckTileState();
}

class _UpdateCheckTileState extends State<_UpdateCheckTile> {
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    final provider = widget.cloudService is CloudAppUpdateProvider;
    return ListTile(
      key: const Key('app-update-entry'),
      enabled: provider && !_checking,
      leading: _checking
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.system_update_alt_rounded),
      title: const Text('关于与更新'),
      subtitle: Text(
        provider ? 'LanzouYOU $lanzouYouVersion · 检查正式版本更新' : '当前核心未提供更新检查',
      ),
      trailing: provider && !_checking
          ? const Icon(Icons.refresh_rounded)
          : null,
      onTap: provider && !_checking ? _check : null,
    );
  }

  Future<void> _check() async {
    final service = widget.cloudService;
    if (service is! CloudAppUpdateProvider) return;
    final provider = service as CloudAppUpdateProvider;
    setState(() => _checking = true);
    try {
      final locale = Localizations.localeOf(context);
      final country = locale.countryCode?.toUpperCase();
      final preferMirror =
          locale.languageCode.toLowerCase() == 'zh' ||
          const {'CN', 'HK', 'MO', 'TW', 'SG'}.contains(country);
      final info = await provider.appUpdateCheck(
        lanzouYouVersion,
        preferMirror: preferMirror,
      );
      if (!mounted) return;
      if (info == null) {
        _showMessage('当前已是最新正式版本');
        return;
      }
      await _showUpdate(info);
    } on CloudFailure catch (error) {
      if (mounted) _showMessage(error.message);
    } on Object {
      if (mounted) _showMessage('检查更新失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _showUpdate(AppUpdateInfo info) async {
    final download = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.system_update_alt_rounded),
        title: Text('发现 LanzouYOU ${info.version}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: SelectableText(
              info.body.trim().isEmpty ? '新的正式版本已发布。' : info.body.trim(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后'),
          ),
          FilledButton.icon(
            key: const Key('download-app-update'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.download_rounded),
            label: const Text('下载更新'),
          ),
        ],
      ),
    );
    if (download != true || !mounted) return;
    for (final value in info.downloadUrls) {
      final uri = Uri.tryParse(value);
      if (uri == null) continue;
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      } on Object {
        // Try the next Rust-validated release URL.
      }
    }
    if (mounted) _showMessage('无法打开更新下载地址');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _LibraryBehaviorSettingsContent extends StatelessWidget {
  const _LibraryBehaviorSettingsContent({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scrollbar(
      child: ListView(
        key: const Key('library-behavior-settings-list'),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionHeader('链接'),
                  const ListTile(
                    leading: Icon(Icons.link_rounded),
                    title: Text('蓝奏云链接打开方式'),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<LanzouLinkOpenPreference>(
                        key: const Key('link-open-preference'),
                        segments: const [
                          ButtonSegment(
                            value: LanzouLinkOpenPreference.ask,
                            icon: Icon(Icons.help_outline_rounded),
                            label: Text('每次询问'),
                          ),
                          ButtonSegment(
                            value: LanzouLinkOpenPreference.parse,
                            icon: Icon(Icons.view_list_outlined),
                            label: Text('列表解析'),
                          ),
                          ButtonSegment(
                            value: LanzouLinkOpenPreference.browser,
                            icon: Icon(Icons.open_in_browser_rounded),
                            label: Text('浏览器'),
                          ),
                        ],
                        selected: {controller.linkOpenPreference},
                        onSelectionChanged: (values) => unawaited(
                          controller.setLinkOpenPreference(values.first),
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    key: const Key('show-source-links-switch'),
                    secondary: const Icon(Icons.folder_outlined),
                    title: const Text('列表源展示链接'),
                    subtitle: const Text('在来源标题与标签之间显示完整链接'),
                    value: controller.showSourceLinks,
                    onChanged: (value) =>
                        unawaited(controller.setShowSourceLinks(value)),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.speed_rounded),
                    title: const Text('搜索视图创建上限'),
                    subtitle: const Text('仅限制界面显示速度，不限制 Rust 搜索、去重与计数'),
                    trailing: Text('${controller.searchViewCreationRate} 项/秒'),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Slider(
                      key: const Key('search-view-rate-slider'),
                      min: 25,
                      max: 500,
                      divisions: 19,
                      label: '${controller.searchViewCreationRate} 项/秒',
                      value: controller.searchViewCreationRate
                          .clamp(25, 500)
                          .toDouble(),
                      onChanged: (value) => unawaited(
                        controller.setSearchViewCreationRate(
                          (value / 25).round() * 25,
                        ),
                      ),
                    ),
                  ),
                  AppMotionAnimatedSize(
                    child: controller.settingsSaveError == null
                        ? const SizedBox.shrink()
                        : ListTile(
                            key: const Key('behavior-settings-save-error'),
                            leading: Icon(
                              Icons.sync_problem_outlined,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            title: Text(controller.settingsSaveError!),
                            textColor: Theme.of(context).colorScheme.error,
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
}

class _AppearanceSettingsContent extends StatelessWidget {
  const _AppearanceSettingsContent({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scrollbar(
      child: ListView(
        key: const Key('appearance-settings-list'),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionHeader('主题'),
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('主题'),
                    subtitle: Text(_themeLabel(controller.themeMode)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Semantics(
                      label: '主题选择',
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SegmentedButton<ThemeMode>(
                          key: const Key('theme-mode-selector'),
                          segments: const [
                            ButtonSegment(
                              value: ThemeMode.system,
                              icon: Icon(Icons.brightness_auto_outlined),
                              label: Text('跟随系统'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              icon: Icon(Icons.light_mode_outlined),
                              label: Text('浅色'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              icon: Icon(Icons.dark_mode_outlined),
                              label: Text('深色'),
                            ),
                          ],
                          selected: {controller.themeMode},
                          onSelectionChanged: (values) =>
                              unawaited(controller.setThemeMode(values.first)),
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    key: const Key('reduce-motion-switch'),
                    secondary: const Icon(Icons.motion_photos_off_outlined),
                    title: const Text('减少动效'),
                    subtitle: const Text('关闭页面、状态与列表的过渡动画'),
                    value: controller.reduceMotion,
                    onChanged: (value) =>
                        unawaited(controller.setReduceMotion(value)),
                  ),
                  AppMotionAnimatedSize(
                    child: controller.settingsSaveError == null
                        ? const SizedBox.shrink()
                        : Semantics(
                            liveRegion: true,
                            child: ListTile(
                              key: const Key('settings-save-error'),
                              leading: Icon(
                                Icons.sync_problem_outlined,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              title: Text(controller.settingsSaveError!),
                              textColor: Theme.of(context).colorScheme.error,
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
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(20, 24, 20, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

String _themeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => '跟随系统',
  ThemeMode.light => '浅色',
  ThemeMode.dark => '深色',
};

class _AccountSettingsWithLogout extends StatelessWidget {
  const _AccountSettingsWithLogout({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: AccountSettingsContent(controller: controller)),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: ListTile(
            key: const Key('logout-tile'),
            leading: Icon(
              Icons.logout,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              '退出登录',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => _confirmLogout(context),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const _LogoutDialog(),
    );
    if (confirmed != true) return;
    await controller.logout();
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

class _LogoutDialog extends StatelessWidget {
  const _LogoutDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.logout),
      title: const Text('退出登录？'),
      content: const Text('本机保存的会话将被清除。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('退出登录'),
        ),
      ],
    );
  }
}
