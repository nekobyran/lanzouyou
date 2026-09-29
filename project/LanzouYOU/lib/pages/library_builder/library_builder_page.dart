import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lanzou_library_shell/library_preview.dart' as shell;
import 'package:path_provider/path_provider.dart';

import '../../models/cloud_item.dart';
import '../../services/cloud_service.dart';
import '../../shared/app_motion.dart';
import 'library_cloud_content_page.dart';
import 'library_builder_service.dart';
import 'library_preview/library_preview_page.dart';
import 'library_recipe.dart';

class LibraryBuilderPage extends StatefulWidget {
  const LibraryBuilderPage({
    required Future<ShareInfo> shareInfo,
    this.initialRecipe,
    this.cloudService,
    this.buildService,
    this.projectStore,
    this.hostPlatform,
    this.previewCore,
    this.previewLinkOpener,
    super.key,
  }) : assert(
         (previewCore == null) == (previewLinkOpener == null),
         'previewCore 与 previewLinkOpener 必须同时提供',
       ),
       _seedShareInfo = shareInfo;

  const LibraryBuilderPage.newProject({
    this.initialRecipe,
    this.cloudService,
    this.buildService,
    this.projectStore,
    this.hostPlatform,
    this.previewCore,
    this.previewLinkOpener,
    super.key,
  }) : assert(
         (previewCore == null) == (previewLinkOpener == null),
         'previewCore 与 previewLinkOpener 必须同时提供',
       ),
       _seedShareInfo = null;

  final Future<ShareInfo>? _seedShareInfo;
  final LibraryBuildRecipe? initialRecipe;
  final CloudService? cloudService;
  final LibraryBuildService? buildService;
  final LibraryProjectStore? projectStore;
  final TargetPlatform? hostPlatform;

  @visibleForTesting
  final shell.LibraryCore? previewCore;

  @visibleForTesting
  final shell.LinkOpener? previewLinkOpener;

  @override
  State<LibraryBuilderPage> createState() => _LibraryBuilderPageState();
}

class _LibraryBuilderPageState extends State<LibraryBuilderPage> {
  LibraryBuildRecipe? _recipe;
  LibraryBuildResult? _lastResult;
  Object? _loadError;
  bool _busy = false;
  bool _cancelRequested = false;
  String? _temporaryIconPath;
  LibraryBuildCancellation? _activeBuildCancellation;
  late final LibraryBuildService _buildService;
  late final LibraryProjectStore _projectStore;

  final _displayName = TextEditingController();
  final _projectId = TextEditingController();
  final _applicationId = TextEditingController();
  final _versionName = TextEditingController();
  final _versionCode = TextEditingController();
  final _windowsExeName = TextEditingController();
  final _seedColor = TextEditingController();
  final _officialUrl = TextEditingController();
  final _publisher = TextEditingController();
  final _splashImage = TextEditingController();
  final _splashText = TextEditingController();
  final _carouselImages = TextEditingController();
  final _announcementUrl = TextEditingController();
  final _webPages = TextEditingController();

  TargetPlatform get _hostPlatform =>
      widget.hostPlatform ?? defaultTargetPlatform;

  @override
  void initState() {
    super.initState();
    _projectStore = widget.projectStore ?? const LocalLibraryProjectStore();
    _buildService = widget.buildService ?? LocalTemplateLibraryBuildService();
    if (widget._seedShareInfo == null) {
      final recipe = widget.initialRecipe ?? LibraryBuildRecipe.newProject();
      _setControllers(recipe);
      _recipe = recipe;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _activeBuildCancellation?.cancel();
    final temporaryIconPath = _temporaryIconPath;
    if (temporaryIconPath != null) {
      unawaited(_deleteFileQuietly(temporaryIconPath));
    }
    for (final controller in [
      _displayName,
      _projectId,
      _applicationId,
      _versionName,
      _versionCode,
      _windowsExeName,
      _seedColor,
      _officialUrl,
      _publisher,
      _splashImage,
      _splashText,
      _carouselImages,
      _announcementUrl,
      _webPages,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final shareInfo = widget._seedShareInfo;
    if (shareInfo == null) return;
    setState(() => _loadError = null);
    try {
      final info = await shareInfo;
      if (!info.isFolder) throw const FormatException('只能从文件夹生成软件库');
      final recipe = LibraryBuildRecipe.fromShareInfo(info);
      _setControllers(recipe);
      if (mounted) setState(() => _recipe = recipe);
    } on Object catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  void _setControllers(LibraryBuildRecipe recipe) {
    _displayName.text = recipe.identity.displayName;
    _projectId.text = recipe.identity.projectId;
    _applicationId.text = recipe.identity.applicationId;
    _versionName.text = recipe.identity.versionName;
    _versionCode.text = '${recipe.identity.versionCode}';
    _windowsExeName.text = recipe.identity.windowsExeName;
    _seedColor.text = recipe.branding.seedColor;
    _officialUrl.text = recipe.branding.officialUrl;
    _publisher.text = recipe.branding.publisher;
    _splashImage.text = recipe.home.splashImage;
    _splashText.text = recipe.home.splashText;
    _carouselImages.text = recipe.home.carouselImages.join('\n');
    _announcementUrl.text = recipe.home.announcementUrl;
    _webPages.text = recipe.home.webPages
        .map((page) => '${page.name}|${page.url}|${page.icon}')
        .join('\n');
  }

  void _syncTextRecipe() {
    final recipe = _recipe;
    if (recipe == null) return;
    final versionCode = int.tryParse(_versionCode.text.trim()) ?? 0;
    setState(() {
      _recipe = recipe.copyWith(
        identity: recipe.identity.copyWith(
          displayName: _displayName.text.trim(),
          projectId: _projectId.text.trim(),
          applicationId: _applicationId.text.trim(),
          versionName: _versionName.text.trim(),
          versionCode: versionCode,
          windowsExeName: _windowsExeName.text.trim(),
        ),
        branding: recipe.branding.copyWith(
          seedColor: _seedColor.text.trim(),
          officialUrl: _officialUrl.text.trim(),
          publisher: _publisher.text.trim(),
        ),
        home: recipe.home.copyWith(
          splashImage: _splashImage.text.trim(),
          splashText: _splashText.text.trim(),
          carouselImages: _nonEmptyLines(_carouselImages.text),
          announcementUrl: _announcementUrl.text.trim(),
          webPages: _parseWebPages(_webPages.text),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget._seedShareInfo == null ? '软件库' : '生成自定义软件库'),
      ),
      body: AppMotionSwitcher(
        key: const Key('library-builder-body-motion'),
        transition: AppMotionTransition.fadeThrough,
        child: _body(),
      ),
      bottomNavigationBar: _recipe == null ? null : _actions(),
    );
  }

  Widget _body() {
    if (_loadError != null) {
      return _BuilderState(
        key: const ValueKey('error'),
        icon: Icons.cloud_off_outlined,
        title: '无法读取文件夹分享信息',
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final recipe = _recipe;
    if (recipe == null) {
      return const _BuilderState(
        key: ValueKey('loading'),
        icon: Icons.pending_outlined,
        title: '正在准备软件库配置',
      );
    }
    return LayoutBuilder(
      key: const ValueKey('content'),
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        final editor = _RecipeEditor(
          recipe: recipe,
          controllers: _controllers,
          onTextChanged: _syncTextRecipe,
          onPickIcon: _pickIcon,
          onAddSource: _addSource,
          onChangeSource: _changeSource,
          onRemoveSource: _removeSource,
          onFeaturesChanged: (features) =>
              setState(() => _recipe = recipe.copyWith(features: features)),
          onHomeChanged: (home) =>
              setState(() => _recipe = recipe.copyWith(home: home)),
          onBuildChanged: (build) =>
              setState(() => _recipe = recipe.copyWith(build: build)),
          onOpenCloudContent:
              widget.cloudService != null &&
                  recipe.workspace.rootFolderId.trim().isNotEmpty
              ? _openCloudContent
              : null,
          lastResult: wide ? null : _lastResult,
        );
        if (!wide) {
          return SizedBox(
            key: const Key('library-builder-narrow'),
            width: double.infinity,
            child: editor,
          );
        }
        return Row(
          key: const Key('library-builder-wide'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 3, child: editor),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 360,
              child: _BuildSummary(recipe: recipe, lastResult: _lastResult),
            ),
          ],
        );
      },
    );
  }

  List<TextEditingController> get _controllers => [
    _displayName,
    _projectId,
    _applicationId,
    _versionName,
    _versionCode,
    _windowsExeName,
    _seedColor,
    _officialUrl,
    _publisher,
    _splashImage,
    _splashText,
    _carouselImages,
    _announcementUrl,
    _webPages,
  ];

  Widget _actions() {
    final previewable = isLibraryRecipePreviewable(_recipe!);
    return SafeArea(
      top: false,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final secondary = Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Tooltip(
                  message: previewable ? '打开真实解析列表预览' : '完善配置并添加至少一个有效来源后可预览',
                  child: FilledButton.tonalIcon(
                    key: const Key('library-preview-button'),
                    onPressed: _busy || !previewable ? null : _preview,
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('预览列表'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _export,
                  icon: const Icon(Icons.ios_share_outlined),
                  label: const Text('导出去密配置'),
                ),
              ],
            );
            final primary = FilledButton.icon(
              key: const Key('library-build-button'),
              onPressed: _busy || !_buildService.canBuild ? null : _build,
              icon: AppMotionSwitcher(
                transition: AppMotionTransition.fade,
                child: _busy
                    ? const SizedBox.square(
                        key: ValueKey('builder-progress'),
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.inventory_2_outlined,
                        key: ValueKey('builder-ready'),
                      ),
              ),
              label: Text(_busy ? '正在生成' : '一键生成'),
            );
            final cancel = _busy
                ? OutlinedButton.icon(
                    key: const Key('library-build-cancel-button'),
                    onPressed: _cancelRequested ? null : _cancelBuild,
                    icon: const Icon(Icons.cancel_outlined),
                    label: Text(_cancelRequested ? '正在取消' : '取消生成'),
                  )
                : null;
            final unavailable = !_buildService.canBuild
                ? Text(
                    _buildService.unavailableReason,
                    maxLines: 2,
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                : null;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: constraints.maxWidth < 560
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        secondary,
                        if (unavailable != null) ...[
                          const SizedBox(height: 8),
                          unavailable,
                        ],
                        const SizedBox(height: 8),
                        if (cancel == null)
                          primary
                        else
                          Row(
                            children: [
                              Expanded(child: cancel),
                              const SizedBox(width: 8),
                              Expanded(child: primary),
                            ],
                          ),
                      ],
                    )
                  : Row(
                      children: [
                        secondary,
                        const Spacer(),
                        if (unavailable != null) ...[
                          Flexible(child: unavailable),
                          const SizedBox(width: 12),
                        ],
                        if (cancel != null) ...[
                          cancel,
                          const SizedBox(width: 8),
                        ],
                        primary,
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _pickIcon() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择应用图标',
      type: FileType.image,
      withData: _hostPlatform == TargetPlatform.android,
    );
    final selected = result?.files.single;
    if (selected == null) return;
    var path = selected.path;
    if ((path == null || path.isEmpty) && selected.bytes != null) {
      final cache = await getTemporaryDirectory();
      final directory = Directory(
        '${cache.path}${Platform.pathSeparator}lanzouyou'
        '${Platform.pathSeparator}library-builder'
        '${Platform.pathSeparator}icon-input',
      );
      await directory.create(recursive: true);
      final extension =
          RegExp(r'^[a-zA-Z0-9]{2,5}$').hasMatch(selected.extension ?? '')
          ? selected.extension!.toLowerCase()
          : 'png';
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        'icon-${DateTime.now().microsecondsSinceEpoch}.$extension',
      );
      await file.writeAsBytes(selected.bytes!, flush: true);
      path = file.path;
      final previous = _temporaryIconPath;
      _temporaryIconPath = path;
      if (previous != null && previous != path) {
        unawaited(_deleteFileQuietly(previous));
      }
    }
    if (path == null || path.isEmpty) {
      _message('未能读取所选图标');
      return;
    }
    final recipe = _recipe!;
    setState(() {
      _recipe = recipe.copyWith(
        build: recipe.build.copyWith(iconSourcePath: path),
      );
    });
  }

  Future<void> _openCloudContent() async {
    final cloudService = widget.cloudService;
    if (cloudService == null) return;
    _syncTextRecipe();
    final recipe = _recipe;
    if (recipe == null || recipe.workspace.rootFolderId.trim().isEmpty) return;
    final controller = LibraryCloudContentController(
      cloudService: cloudService,
      initialRecipe: recipe,
      onRecipeChanged: (updated) async {
        await _projectStore.save(updated);
        if (!mounted) return;
        _setControllers(updated);
        setState(() => _recipe = updated);
      },
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LibraryCloudContentPage(controller: controller),
      ),
    );
  }

  Future<void> _addSource() async {
    final source = await showDialog<LibrarySourceRecipe>(
      context: context,
      builder: (context) =>
          _AddSourceDialog(sourceId: _nextSourceId(_recipe!.sources)),
    );
    if (source == null) return;
    final recipe = _recipe!;
    setState(() {
      _recipe = recipe.copyWith(sources: [...recipe.sources, source]);
    });
  }

  void _changeSource(int index, LibrarySourceRecipe value) {
    final recipe = _recipe!;
    final sources = [...recipe.sources]..[index] = value;
    setState(() => _recipe = recipe.copyWith(sources: sources));
  }

  void _removeSource(int index) {
    final recipe = _recipe!;
    final sources = [...recipe.sources]..removeAt(index);
    setState(() => _recipe = recipe.copyWith(sources: sources));
  }

  Future<void> _preview() async {
    if (_busy) return;
    _syncTextRecipe();
    final recipe = _recipe!;
    if (!isLibraryRecipePreviewable(recipe)) {
      _message('完善配置并添加至少一个有效来源后可预览');
      return;
    }
    final core = widget.previewCore;
    final page = core == null
        ? LibraryPreviewPage.production(recipe: recipe)
        : LibraryPreviewPage.testHarness(
            recipe: recipe,
            core: core,
            linkOpener: widget.previewLinkOpener!,
          );
    final reduced = AppMotion.isReduced(context);
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: '/library-preview'),
        transitionDuration: reduced ? Duration.zero : AppMotion.medium,
        reverseTransitionDuration: reduced ? Duration.zero : AppMotion.fast,
        pageBuilder: (_, _, _) => page,
        transitionsBuilder: (_, animation, _, child) => AppMotion.transition(
          AppMotionTransition.fadeThrough,
          child,
          animation,
        ),
      ),
    );
  }

  Future<void> _save() => _runGuarded(() async {
    final recipe = _validRecipe();
    if (recipe == null) return;
    await _projectStore.save(recipe);
    _message('配置已保存');
  });

  Future<void> _export() => _runGuarded(() async {
    final recipe = _validRecipe();
    if (recipe == null) return;
    final path = await _projectStore.export(recipe);
    if (path != null) _message('去密配置已导出，不包含访问码');
  });

  Future<void> _build() async {
    if (_busy) return;
    final cancellation = LibraryBuildCancellation();
    _activeBuildCancellation = cancellation;
    try {
      await _runGuarded(() async {
        final recipe = _validRecipe();
        if (recipe == null) return;
        await _projectStore.save(recipe);
        cancellation.throwIfCancelled();
        final result = await _buildService.build(
          recipe,
          cancellation: cancellation,
        );
        if (mounted) setState(() => _lastResult = result);
        _message(
          result.export?.isBundle == true
              ? '已导出一个完整包，内含 ${result.artifacts.length} 个软件库产物'
              : '已生成 ${result.artifacts.length} 个软件库产物',
        );
      });
    } finally {
      _activeBuildCancellation = null;
      _cancelRequested = false;
    }
  }

  void _cancelBuild() {
    final cancellation = _activeBuildCancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    if (!cancellation.cancel()) return;
    if (mounted) setState(() => _cancelRequested = true);
  }

  LibraryBuildRecipe? _validRecipe() {
    _syncTextRecipe();
    final recipe = _recipe!;
    final errors = recipe.validate();
    if (errors.isNotEmpty) {
      _message(errors.first);
      return null;
    }
    return recipe;
  }

  Future<void> _runGuarded(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } on LibraryBuildCancelled {
      _message('已取消');
    } on Object {
      _message('操作失败，请检查配置与内置模板');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

class _RecipeEditor extends StatelessWidget {
  const _RecipeEditor({
    required this.recipe,
    required this.controllers,
    required this.onTextChanged,
    required this.onPickIcon,
    required this.onAddSource,
    required this.onChangeSource,
    required this.onRemoveSource,
    required this.onFeaturesChanged,
    required this.onHomeChanged,
    required this.onBuildChanged,
    required this.onOpenCloudContent,
    required this.lastResult,
  });

  final LibraryBuildRecipe recipe;
  final List<TextEditingController> controllers;
  final VoidCallback onTextChanged;
  final VoidCallback onPickIcon;
  final VoidCallback onAddSource;
  final void Function(int, LibrarySourceRecipe) onChangeSource;
  final ValueChanged<int> onRemoveSource;
  final ValueChanged<LibraryFeatures> onFeaturesChanged;
  final ValueChanged<LibraryHomeContent> onHomeChanged;
  final ValueChanged<LibraryBuildOptions> onBuildChanged;
  final VoidCallback? onOpenCloudContent;
  final LibraryBuildResult? lastResult;

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          if (recipe.hasEmbeddedPasswords)
            MaterialBanner(
              leading: const Icon(Icons.warning_amber_outlined),
              content: const Text(
                '访问码会随这个软件库成品一起在成品中分发，不能视为秘密。管理账号、密码和 Cookie 不会写入成品。',
              ),
              actions: const [SizedBox.shrink()],
            ),
          if (onOpenCloudContent != null) ...[
            ListTile(
              key: const Key('library-cloud-content-entry'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('云内容'),
              subtitle: const Text('管理图库、远程文档、网页与 rjk 绑定状态'),
              trailing: const Icon(Icons.chevron_right),
              onTap: onOpenCloudContent,
            ),
            const Divider(height: 1),
          ],
          const _SectionTitle('应用身份'),
          _field(
            controllers[0],
            '应用名称',
            Icons.badge_outlined,
            fieldKey: const Key('library-display-name-field'),
          ),
          _field(controllers[1], '项目 ID', Icons.key_outlined),
          _field(controllers[2], '应用 ID', Icons.android_outlined),
          Row(
            children: [
              Expanded(
                child: _field(controllers[3], '版本号', Icons.tag_outlined),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(
                  controllers[4],
                  '版本码',
                  Icons.numbers_outlined,
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          _field(
            controllers[5],
            'Windows exe slug',
            Icons.desktop_windows_outlined,
          ),
          const _SectionTitle('品牌'),
          _field(controllers[6], '主题色 #RRGGBB', Icons.color_lens_outlined),
          _field(
            controllers[7],
            '官网 HTTPS 地址（可选）',
            Icons.public_outlined,
            keyboardType: TextInputType.url,
          ),
          _field(controllers[8], '发布者（可选）', Icons.person_outline),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.image_outlined),
            title: const Text('应用图标（可选）'),
            subtitle: Text(
              recipe.build.iconSourcePath.isEmpty
                  ? '使用模板默认图标'
                  : recipe.build.iconSourcePath,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: OutlinedButton(
              onPressed: onPickIcon,
              child: const Text('选择'),
            ),
          ),
          const Divider(height: 1),
          _SectionTitle(
            '软件库来源',
            action: recipe.sources.isEmpty ? null : onAddSource,
          ),
          if (recipe.sources.isEmpty)
            ListTile(
              key: const Key('library-empty-sources'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.library_add_outlined),
              title: const Text('尚未添加来源'),
              subtitle: const Text('添加至少一个蓝奏分享地址后才能保存或生成'),
              trailing: OutlinedButton.icon(
                onPressed: onAddSource,
                icon: const Icon(Icons.add),
                label: const Text('添加'),
              ),
            ),
          for (var index = 0; index < recipe.sources.length; index++) ...[
            AppMotionListItem(
              key: ValueKey('source-motion-${recipe.sources[index].sourceId}'),
              child: _SourceEditor(
                key: ValueKey(recipe.sources[index].sourceId),
                source: recipe.sources[index],
                passwordFieldKey: Key('library-source-password-$index'),
                onChanged: (value) => onChangeSource(index, value),
                onRemove: () => onRemoveSource(index),
              ),
            ),
            if (index < recipe.sources.length - 1) const Divider(height: 24),
          ],
          const _SectionTitle('功能'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.search_outlined),
            title: const Text('搜索'),
            value: recipe.features.search,
            onChanged: (value) =>
                onFeaturesChanged(recipe.features.copyWith(search: value)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.download_outlined),
            title: const Text('下载'),
            value: recipe.features.download,
            onChanged: (value) =>
                onFeaturesChanged(recipe.features.copyWith(download: value)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.notes_outlined),
            title: const Text('显示简介'),
            value: recipe.features.showDescription,
            onChanged: (value) => onFeaturesChanged(
              recipe.features.copyWith(showDescription: value),
            ),
          ),
          ExpansionTile(
            key: const Key('library-home-editor'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            leading: const Icon(Icons.home_outlined),
            title: const Text('主页内容'),
            children: [
              SwitchListTile(
                key: const Key('library-home-visible'),
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.visibility_outlined),
                title: const Text('显示主页'),
                value: recipe.home.visible,
                onChanged: (value) =>
                    onHomeChanged(recipe.home.copyWith(visible: value)),
              ),
              _field(
                controllers[9],
                '开始界面图片 HTTPS 地址（可选）',
                Icons.image_outlined,
                keyboardType: TextInputType.url,
              ),
              _field(
                controllers[10],
                '开始文本（可选）',
                Icons.notes_outlined,
                maxLines: 3,
              ),
              _field(
                controllers[11],
                '轮播图片（每行一个 HTTPS 地址）',
                Icons.view_carousel_outlined,
                maxLines: 4,
              ),
              _field(
                controllers[12],
                '远程公告 HTTPS 地址（可选）',
                Icons.campaign_outlined,
                keyboardType: TextInputType.url,
              ),
              _field(
                controllers[13],
                '网页页面（每行：名称|URL|图标 URL）',
                Icons.web_outlined,
                maxLines: 4,
              ),
            ],
          ),
          const _SectionTitle('生成目标'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: recipe.build.targets.contains(LibraryTarget.android),
            onChanged: (selected) => onBuildChanged(
              recipe.build.copyWith(
                targets: _toggleTarget(
                  recipe.build.targets,
                  LibraryTarget.android,
                  selected == true,
                ),
              ),
            ),
            secondary: const Icon(Icons.android_outlined),
            title: const Text('Android 64位安装包（APK）'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: recipe.build.targets.contains(LibraryTarget.windows),
            onChanged: (selected) => onBuildChanged(
              recipe.build.copyWith(
                targets: _toggleTarget(
                  recipe.build.targets,
                  LibraryTarget.windows,
                  selected == true,
                ),
              ),
            ),
            secondary: const Icon(Icons.desktop_windows_outlined),
            title: const Text('Windows x64 便携版（ZIP）'),
          ),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.verified_outlined),
            title: Text('固定使用 Release 模板'),
            subtitle: Text('使用内置模板在本机离线封装'),
          ),
          if (recipe.build.targets.contains(LibraryTarget.android))
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.verified_user_outlined),
              title: Text('Android 更新签名'),
              subtitle: Text(
                '本机 LanzouYOU 会为 APK 复用同一签名身份；'
                '卸载或清除 LanzouYOU 数据后身份会丢失，'
                '同包名旧版可能无法覆盖安装。',
              ),
            ),
          AppMotionSwitcher(
            transition: AppMotionTransition.fade,
            alignment: Alignment.centerLeft,
            child: lastResult == null
                ? const SizedBox.shrink(key: ValueKey('builder-no-artifacts'))
                : _ArtifactResults(
                    key: const ValueKey('builder-artifacts'),
                    result: lastResult!,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    Key? fieldKey,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: fieldKey,
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(prefixIcon: Icon(icon), labelText: label),
        onChanged: (_) => onTextChanged(),
      ),
    );
  }
}

List<String> _nonEmptyLines(String value) => value
    .split(RegExp(r'\r?\n'))
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .toList(growable: false);

List<LibraryWebPageRecipe> _parseWebPages(String value) => _nonEmptyLines(value)
    .map((line) {
      final parts = line.split('|').map((part) => part.trim()).toList();
      return LibraryWebPageRecipe(
        name: parts.isEmpty ? '' : parts[0],
        url: parts.length < 2 ? '' : parts[1],
        icon: parts.length < 3 ? '' : parts[2],
      );
    })
    .toList(growable: false);

class _SourceEditor extends StatefulWidget {
  const _SourceEditor({
    required this.source,
    required this.passwordFieldKey,
    required this.onChanged,
    required this.onRemove,
    super.key,
  });

  final LibrarySourceRecipe source;
  final Key passwordFieldKey;
  final ValueChanged<LibrarySourceRecipe> onChanged;
  final VoidCallback onRemove;

  @override
  State<_SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<_SourceEditor> {
  bool _obscurePassword = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.source.sourceId,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            IconButton(
              tooltip: '删除来源',
              onPressed: widget.onRemove,
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ],
        ),
        TextFormField(
          initialValue: widget.source.title,
          decoration: const InputDecoration(labelText: '来源标题'),
          onChanged: (value) =>
              widget.onChanged(widget.source.copyWith(title: value)),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: widget.source.shareUrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: '分享地址'),
          onChanged: (value) =>
              widget.onChanged(widget.source.copyWith(shareUrl: value)),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: widget.passwordFieldKey,
          initialValue: widget.source.password,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            labelText: '访问码（可选）',
            helperText: '访问码会嵌入成品，不是安全存储',
            suffixIcon: IconButton(
              key: const Key('library-source-password-visibility'),
              tooltip: _obscurePassword ? '显示访问码' : '隐藏访问码',
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          ),
          onChanged: (value) =>
              widget.onChanged(widget.source.copyWith(password: value)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('参与搜索'),
          value: widget.source.searchable,
          onChanged: (value) =>
              widget.onChanged(widget.source.copyWith(searchable: value)),
        ),
      ],
    );
  }
}

class _BuildSummary extends StatelessWidget {
  const _BuildSummary({required this.recipe, required this.lastResult});

  final LibraryBuildRecipe recipe;
  final LibraryBuildResult? lastResult;

  @override
  Widget build(BuildContext context) {
    final targets = recipe.build.targets
        .map(
          (value) =>
              value == LibraryTarget.android ? 'Android APK' : 'Windows ZIP',
        )
        .join(' + ');
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('生成摘要', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),
        CircleAvatar(
          radius: 34,
          child: Text(
            recipe.identity.displayName.isEmpty
                ? '?'
                : recipe.identity.displayName.characters.first,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          recipe.identity.displayName,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 24),
        _SummaryLine('应用 ID', recipe.identity.applicationId),
        _SummaryLine('版本', recipe.identity.versionName),
        _SummaryLine('来源', '${recipe.sources.length} 个'),
        _SummaryLine('目标', targets.isEmpty ? '未选择' : targets),
        const SizedBox(height: 16),
        Text(
          recipe.validate().isEmpty ? '配置可生成' : recipe.validate().first,
          style: TextStyle(
            color: recipe.validate().isEmpty
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
        ),
        if (lastResult != null) _ArtifactResults(result: lastResult!),
      ],
    );
  }
}

class _ArtifactResults extends StatelessWidget {
  const _ArtifactResults({required this.result, super.key});

  final LibraryBuildResult result;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Column(
        key: const Key('library-artifact-results'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('已生成'),
          if (result.export?.isBundle == true)
            const ListTile(
              key: Key('library-artifact-bundle'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.inventory_2_outlined),
              title: Text('Android + Windows 完整包'),
              subtitle: Text('一次导出，包内含以下两个产物与校验清单'),
            ),
          if (result.export?.isBundle == true)
            Text('包内产物', style: Theme.of(context).textTheme.labelLarge),
          for (final artifact in result.artifacts)
            AppMotionListItem(
              key: ValueKey(
                'artifact-motion-${artifact.platform}-${artifact.fileName}-${artifact.byteLength}',
              ),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  artifact.platform == 'android'
                      ? Icons.android_outlined
                      : Icons.folder_zip_outlined,
                ),
                title: Text(
                  artifact.platform == 'android'
                      ? 'Android APK 可安装'
                      : 'Windows ZIP 便携版',
                ),
                subtitle: Text(
                  artifact.platform == 'android'
                      ? '可安装到 Android 设备'
                      : '复制到 Windows 后解压运行',
                ),
                trailing: Text(_formatArtifactBytes(artifact.byteLength)),
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 64, child: Text(label)),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.action});

  final String title;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          if (action != null)
            TextButton.icon(
              onPressed: action,
              icon: const Icon(Icons.add),
              label: const Text('添加'),
            ),
        ],
      ),
    );
  }
}

class _BuilderState extends StatelessWidget {
  const _BuilderState({
    required this.icon,
    required this.title,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(title),
          if (onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog({required this.sourceId});

  final String sourceId;

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final title = TextEditingController();
  final url = TextEditingController();
  final password = TextEditingController();
  bool obscurePassword = true;

  @override
  void dispose() {
    title.dispose();
    url.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加软件库来源'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('library-add-source-title'),
              controller: title,
              decoration: const InputDecoration(labelText: '标题'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('library-add-source-url'),
              controller: url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: '蓝奏分享地址'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('library-add-source-password'),
              controller: password,
              obscureText: obscurePassword,
              decoration: InputDecoration(
                labelText: '访问码（可选）',
                suffixIcon: IconButton(
                  tooltip: obscurePassword ? '显示访问码' : '隐藏访问码',
                  onPressed: () =>
                      setState(() => obscurePassword = !obscurePassword),
                  icon: Icon(
                    obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            LibrarySourceRecipe(
              sourceId: widget.sourceId,
              title: title.text.trim(),
              shareUrl: url.text.trim(),
              password: password.text,
            ),
          ),
          child: const Text('添加'),
        ),
      ],
    );
  }
}

Set<LibraryTarget> _toggleTarget(
  Set<LibraryTarget> targets,
  LibraryTarget target,
  bool selected,
) {
  final result = {...targets};
  selected ? result.add(target) : result.remove(target);
  return result;
}

String _nextSourceId(List<LibrarySourceRecipe> sources) {
  var index = sources.length + 1;
  while (sources.any((source) => source.sourceId == 'source-$index')) {
    index++;
  }
  return 'source-$index';
}

String _formatArtifactBytes(int bytes) {
  const kib = 1024;
  const mib = kib * 1024;
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MiB';
  if (bytes >= kib) return '${(bytes / kib).toStringAsFixed(1)} KiB';
  return '$bytes B';
}

Future<void> _deleteFileQuietly(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Best-effort cleanup during page disposal.
  }
}
