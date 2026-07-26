import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../../models/source_registry.dart';
import '../../services/source_registry_core.dart';
import '../../shared/app_motion.dart';
import 'source_registry_controller.dart';
import 'source_registry_dialogs.dart';

typedef SourceRegistryOpenSource =
    Future<void> Function(SourceRegistrySource source);

/// Material 3 source manager backed exclusively by [SourceRegistryCore].
///
/// The list is lazy and paged in batches of 100. No link parsing, deduplication
/// or rules validation occurs in this widget tree.
class SourceManagerPage extends StatefulWidget {
  const SourceManagerPage({
    required this.core,
    this.embedded = false,
    this.showSourceLinks = false,
    this.pickImportPath,
    this.pickExportPath,
    this.onOpenSource,
    super.key,
  });

  final SourceRegistryCore core;
  final bool embedded;
  final bool showSourceLinks;
  final SourceRegistryPathPicker? pickImportPath;
  final SourceRegistryPathPicker? pickExportPath;
  final SourceRegistryOpenSource? onOpenSource;

  @override
  State<SourceManagerPage> createState() => _SourceManagerPageState();
}

class _SourceManagerPageState extends State<SourceManagerPage> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'source-search');
  final ScrollController _scroll = ScrollController();
  late final SourceRegistryController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SourceRegistryController(core: widget.core);
    _scroll.addListener(_loadNearEnd);
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _scroll.removeListener(_loadNearEnd);
    _scroll.dispose();
    _searchFocus.dispose();
    _search.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _loadNearEnd() {
    if (!_scroll.hasClients ||
        _scroll.position.extentAfter >
            (_scroll.position.viewportDimension * .75).clamp(320, 720)) {
      return;
    }
    unawaited(_controller.loadMore());
  }

  @override
  Widget build(BuildContext context) {
    final body = SafeArea(
      top: widget.embedded,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _searchFocus.requestFocus,
          const SingleActivator(LogicalKeyboardKey.keyA, control: true):
              _controller.selectAllVisible,
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_controller.selectionMode) {
              _controller.clearSelection();
            } else if (_searchFocus.hasFocus) {
              _searchFocus.unfocus();
            } else {
              Navigator.maybePop(context);
            }
          },
        },
        child: FocusTraversalGroup(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => Column(
              children: [
                _SearchCategoryControl(
                  controller: _controller,
                  textController: _search,
                  focusNode: _searchFocus,
                  onChooseCategory: _chooseCategory,
                ),
                _SourceActions(
                  controller: _controller,
                  showAddAction: widget.embedded,
                  canImportRules:
                      _controller.canManageRules &&
                      widget.pickImportPath != null,
                  canExportRules:
                      _controller.canManageRules &&
                      widget.pickExportPath != null,
                  onAdd: _addSource,
                  onCreateComposite: _createComposite,
                  onCreateCategory: _createCategory,
                  onManageCategories: _manageCategories,
                  onRawImport: _importRawSources,
                  onImportRulesFile: _importRulesFile,
                  onImportRulesUrl: _importRulesUrl,
                  onExport: _exportRules,
                  onRestoreBackup: _restoreBackup,
                  onRestoreOfficial: _restoreOfficial,
                  onReset: _reset,
                ),
                const Divider(height: 1),
                Expanded(child: _buildContent()),
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.embedded) return Material(child: body);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          leading: _controller.selectionMode
              ? IconButton(
                  tooltip: '退出多选',
                  onPressed: _controller.clearSelection,
                  icon: const Icon(Icons.close_rounded),
                )
              : null,
          title: Text(
            _controller.selectionMode
                ? '已选择 ${_controller.selectedIds.length} 项'
                : '来源管理',
          ),
          actions: _controller.selectionMode
              ? _selectionActions()
              : [
                  IconButton(
                    tooltip: '刷新来源',
                    onPressed: _controller.isMutating
                        ? null
                        : () => unawaited(_controller.refresh()),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
        ),
        body: body,
        floatingActionButton: _controller.selectionMode || !_controller.canAdd
            ? null
            : FloatingActionButton.extended(
                key: const Key('source-add-fab'),
                onPressed: _controller.isMutating ? null : _addSource,
                icon: const Icon(Icons.add_rounded),
                label: const Text('添加来源'),
              ),
      ),
    );
  }

  List<Widget> _selectionActions() => [
    if (_controller.canRetest && _controller.selectedRetestableIds.isNotEmpty)
      IconButton(
        tooltip: '重新测试',
        onPressed: _controller.isMutating
            ? null
            : () => unawaited(_runAndReport(_controller.retestSelected)),
        icon: const Icon(Icons.fact_check_outlined),
      ),
    MenuAnchor(
      menuChildren: _selectionMenuItems(),
      builder: (context, menu, child) => IconButton(
        key: const Key('source-selection-more'),
        tooltip: '更多所选操作',
        onPressed: _controller.isMutating
            ? null
            : menu.isOpen
            ? menu.close
            : menu.open,
        icon: const Icon(Icons.more_vert_rounded),
      ),
    ),
  ];

  List<Widget> _selectionMenuItems() {
    final selected = _controller.selectedSources;
    final oneEditable =
        _controller.canMutateSources &&
        selected.length == 1 &&
        !selected.single.builtIn;
    return [
      if (oneEditable)
        MenuItemButton(
          leadingIcon: const Icon(Icons.edit_outlined),
          onPressed: _editSelected,
          child: Text(
            selected.single.kind == SourceRegistrySourceKind.composite
                ? '编辑自建合集'
                : '编辑来源',
          ),
        ),
      if (_controller.canManageRules &&
          widget.pickExportPath != null &&
          selected.any((source) => !source.builtIn))
        MenuItemButton(
          leadingIcon: const Icon(Icons.file_upload_outlined),
          onPressed: _exportRules,
          child: const Text('导出所选'),
        ),
      if (_controller.canManageCategories)
        MenuItemButton(
          leadingIcon: const Icon(Icons.drive_file_move_outline),
          onPressed: _addSelectionToCategory,
          child: const Text('加入分类'),
        ),
      if (_controller.canMutateSources)
        MenuItemButton(
          leadingIcon: const Icon(Icons.delete_outline_rounded),
          onPressed: _deleteSelected,
          child: const Text('删除所选来源'),
        )
      else if (_controller.canManageComposites &&
          selected.length == 1 &&
          selected.single.kind == SourceRegistrySourceKind.composite &&
          !selected.single.builtIn)
        MenuItemButton(
          leadingIcon: const Icon(Icons.delete_outline_rounded),
          onPressed: _deleteComposite,
          child: const Text('删除自建合集'),
        ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.select_all_rounded),
        onPressed: _controller.selectAllVisible,
        child: const Text('全选已加载项目'),
      ),
    ];
  }

  Widget _buildContent() => AppMotionSwitcher(
    child: switch (_controller.status) {
      SourceRegistryStatus.loading => const _SourceLoading(
        key: ValueKey('source-loading'),
      ),
      SourceRegistryStatus.error => _SourceMessage(
        key: const ValueKey('source-error'),
        icon: Icons.cloud_off_outlined,
        title: '来源加载失败',
        message: _controller.errorMessage,
        action: _controller.refresh,
      ),
      SourceRegistryStatus.empty => _SourceMessage(
        key: const ValueKey('source-empty'),
        icon: Icons.folder_off_outlined,
        title: '没有匹配来源',
        message: _controller.query.isEmpty ? '当前分类为空' : '请尝试其他关键词',
        action: _controller.query.isEmpty ? null : _clearSearch,
      ),
      SourceRegistryStatus.data => _SourceList(
        key: const ValueKey('source-data'),
        controller: _controller,
        scrollController: _scroll,
        showSourceLinks: widget.showSourceLinks,
        onTap: _openSource,
      ),
    },
  );

  void _clearSearch() {
    _search.clear();
    _controller.updateQuery('');
  }

  Future<void> _chooseCategory() async {
    final value = await showSourceCategoryDialog(
      context,
      categories: _controller.categories,
      selectedId: _controller.categoryId,
    );
    if (value != null) await _controller.selectCategory(value);
  }

  Future<void> _addSource() async {
    if (!_controller.canAdd) return;
    final draft = await showSourceDraftDialog(
      context,
      categories: _controller.categories,
    );
    if (draft == null) return;
    await _runAndReport(() => _controller.addSources([draft]));
  }

  Future<void> _createComposite() async {
    if (!_controller.canManageComposites) return;
    final draft = await showCompositeDraftDialog(context);
    if (draft == null) return;
    await _runAndReport(() => _controller.upsertComposite(draft));
  }

  Future<void> _createCategory() async {
    if (!_controller.canManageCategories) return;
    final draft = await showCategoryDraftDialog(context);
    if (draft == null) return;
    await _runAndReport(() => _controller.upsertCategory(draft));
  }

  Future<void> _addSelectionToCategory() async {
    if (!_controller.canManageCategories) return;
    if (_controller.categories.isEmpty) {
      await _createCategory();
      return;
    }
    final id = await showSourceCategoryDialog(
      context,
      categories: _controller.categories,
      selectedId: 'all',
    );
    if (id == null || id == 'all') return;
    final category = _controller.categories.firstWhere((item) => item.id == id);
    final ids = <String>{...category.sourceIds, ..._controller.selectedIds};
    await _runAndReport(
      () => _controller.setCategoryMembers(
        category.id,
        ids.toList(growable: false),
      ),
    );
  }

  Future<void> _manageCategories() async {
    if (!_controller.canManageCategories) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  '管理分类',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                trailing: IconButton(
                  tooltip: '新建分类',
                  onPressed: () async {
                    Navigator.pop(sheetContext);
                    await _createCategory();
                  },
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
              ),
              const Divider(height: 1),
              if (_controller.categories.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('暂无分类'))
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _controller.categories.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final category = _controller.categories[index];
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(category.title),
                        subtitle: Text('${category.sourceIds.length} 个来源'),
                        trailing: MenuAnchor(
                          menuChildren: [
                            MenuItemButton(
                              leadingIcon: const Icon(Icons.edit_outlined),
                              onPressed: () async {
                                Navigator.pop(sheetContext);
                                final draft = await showCategoryDraftDialog(
                                  context,
                                  existing: category,
                                );
                                if (draft != null) {
                                  await _runAndReport(
                                    () => _controller.upsertCategory(draft),
                                  );
                                }
                              },
                              child: const Text('重命名'),
                            ),
                            MenuItemButton(
                              leadingIcon: const Icon(
                                Icons.delete_outline_rounded,
                              ),
                              onPressed: () async {
                                Navigator.pop(sheetContext);
                                final confirmed = await _confirm(
                                  '删除分类？',
                                  '来源不会被删除，只会移出该分类。',
                                  destructive: true,
                                );
                                if (confirmed) {
                                  await _runAndReport(
                                    () =>
                                        _controller.deleteCategory(category.id),
                                  );
                                }
                              },
                              child: const Text('删除'),
                            ),
                          ],
                          builder: (context, menu, _) => IconButton(
                            tooltip: '${category.title}操作',
                            onPressed: menu.isOpen ? menu.close : menu.open,
                            icon: const Icon(Icons.more_vert_rounded),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editSelected() async {
    if (!_controller.canMutateSources ||
        _controller.selectedSources.length != 1 ||
        _controller.selectedSources.single.builtIn) {
      return;
    }
    final draft = await showSourceUpdateDialog(
      context,
      _controller.selectedSources.single,
    );
    if (draft != null) {
      await _runAndReport(() => _controller.updateSource(draft));
    }
  }

  Future<void> _deleteSelected() async {
    if (!_controller.canMutateSources || _controller.selectedIds.isEmpty) {
      return;
    }
    final count = _controller.selectedIds.length.clamp(1, 256);
    final hasBuiltIn = _controller.selectedSources.any(
      (source) => source.builtIn,
    );
    final confirmed = await _confirm(
      '删除 $count 个来源？',
      hasBuiltIn ? '自定义来源会被删除，内置来源会被隐藏；可稍后恢复官方来源。' : '来源规则会从本机删除，不会删除蓝奏云文件。',
      destructive: true,
    );
    if (confirmed) await _runAndReport(_controller.deleteSelected);
  }

  Future<void> _deleteComposite() async {
    final confirmed = await _confirm(
      '删除自建合集？',
      '仅删除本地合集规则，不会删除蓝奏云文件。',
      destructive: true,
    );
    if (confirmed) await _runAndReport(_controller.deleteSelectedComposite);
  }

  Future<void> _reset() async {
    final confirmed = await _confirm(
      '重置全部来源设置？',
      '自定义来源、分类、合集和本地测试状态都会被移除。',
      destructive: true,
    );
    if (confirmed) await _runAndReport(_controller.reset);
  }

  Future<void> _restoreOfficial() async {
    final confirmed = await _confirm(
      '恢复官方来源？',
      '被隐藏的官方来源会重新显示；自定义来源、分类和合集会保留。',
    );
    if (confirmed) await _runAndReport(_controller.restoreOfficial);
  }

  Future<void> _restoreBackup() async {
    final confirmed = await _confirm('恢复上次备份？', '当前来源设置会替换为最近一次可用备份。');
    if (confirmed) await _runAndReport(_controller.restoreBackup);
  }

  Future<void> _exportRules() async {
    final picker = widget.pickExportPath;
    if (picker == null) return;
    final selectedCount = _controller.selectedSources
        .where((source) => !source.builtIn)
        .length;
    final includeCredentials = await _chooseExportMode(selectedCount);
    if (includeCredentials == null || !mounted) return;
    if (includeCredentials) {
      final confirmed = await _confirm(
        '确认导出访问码？',
        '导出文件会包含来源访问码。请只保存到可信位置，不要公开分享。',
        destructive: true,
      );
      if (!confirmed) return;
    }
    final destination = await picker();
    if (destination == null || destination.trim().isEmpty || !mounted) return;
    await _runAndReport(
      () => _controller.exportSelected(
        destination,
        includeCredentials: includeCredentials,
      ),
    );
  }

  Future<bool?> _chooseExportMode(int count) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('选择导出方式'),
      content: Text(count == 0 ? '将导出全部自定义来源。' : '将导出 $count 个所选来源。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        OutlinedButton(
          key: const Key('export-with-credentials'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('包含访问码'),
        ),
        FilledButton(
          key: const Key('export-without-credentials'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('安全导出'),
        ),
      ],
    ),
  );

  Future<void> _importRawSources() async {
    if (!_controller.canPreviewImport) return;
    final draft = await showSourceBatchImportDialog(
      context,
      categories: _controller.categories,
    );
    if (draft == null || draft.rawText.trim().isEmpty || !mounted) return;
    final preview = await _controller.previewRawImport(draft);
    if (!mounted) return;
    if (preview == null) {
      _showMessage(
        _controller.errorMessage.isEmpty ? '无法预览来源' : _controller.errorMessage,
        error: true,
      );
      return;
    }
    final confirmed = await showSourceImportPreviewDialog(context, preview);
    if (!confirmed) return;
    await _runAndReport(() => _controller.commitRawImport(preview));
  }

  Future<void> _importRulesFile() async {
    final picker = widget.pickImportPath;
    if (!_controller.canManageRules || picker == null) return;
    final path = await picker();
    if (path == null || path.trim().isEmpty) return;
    await _runAndReport(() => _controller.importRules(path));
  }

  Future<void> _importRulesUrl() async {
    if (!_controller.canManageRules) return;
    final url = await showSourceRulesUrlDialog(context);
    if (url == null || !mounted) return;
    await _runAndReport(() => _controller.fetchImportRules(url));
  }

  Future<void> _openSource(SourceRegistrySource source) async {
    final callback = widget.onOpenSource;
    if (callback != null) {
      await callback(source);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            ListTile(
              leading: Icon(_sourceIcon(source)),
              title: Text(source.title),
              subtitle: source.shareUrl.isEmpty ? null : Text(source.shareUrl),
            ),
            if (source.description.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.notes_rounded),
                title: const Text('简介'),
                subtitle: Text(source.description),
              ),
            if (source.shareUrl.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制链接'),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: source.shareUrl));
                  if (context.mounted) Navigator.pop(context);
                  _showMessage('链接已复制');
                },
              ),
            if (!source.builtIn && _controller.canMutateSources)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(
                  source.kind == SourceRegistrySourceKind.composite
                      ? '编辑自建合集'
                      : '编辑来源',
                ),
                onTap: () async {
                  Navigator.pop(context);
                  final draft = await showSourceUpdateDialog(
                    this.context,
                    source,
                  );
                  if (draft != null) {
                    await _runAndReport(() => _controller.updateSource(draft));
                  }
                },
              ),
            if (!source.builtIn && _controller.canMutateSources)
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  '删除来源',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  final confirmed = await _confirm(
                    '删除“${source.title}”？',
                    '只删除本机来源规则，不会删除蓝奏云文件。',
                    destructive: true,
                  );
                  if (confirmed) {
                    await _runAndReport(
                      () => _controller.deleteSources([source.id]),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _runAndReport(Future<Object?> Function() task) async {
    final result = await task();
    if (!mounted) return;
    if (result == null) {
      _showMessage(
        _controller.errorMessage.isEmpty ? '操作未完成' : _controller.errorMessage,
        error: true,
      );
    } else {
      _showMessage(
        _controller.actionMessage.isEmpty ? '操作已完成' : _controller.actionMessage,
      );
    }
  }

  Future<bool> _confirm(
    String title,
    String message, {
    bool destructive = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }
}

class _SearchCategoryControl extends StatelessWidget {
  const _SearchCategoryControl({
    required this.controller,
    required this.textController,
    required this.focusNode,
    required this.onChooseCategory,
  });

  final SourceRegistryController controller;
  final TextEditingController textController;
  final FocusNode focusNode;
  final VoidCallback onChooseCategory;

  @override
  Widget build(BuildContext context) {
    final category = controller.categoryId == 'all'
        ? '全部'
        : controller.categories
                  .where((item) => item.id == controller.categoryId)
                  .map((item) => item.title)
                  .firstOrNull ??
              '全部';
    final current = controller.filter;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('source-search-field'),
            controller: textController,
            focusNode: focusNode,
            onChanged: controller.updateQuery,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: '搜索来源',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: controller.query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: () {
                        textController.clear();
                        controller.updateQuery('');
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(28)),
                borderSide: BorderSide.none,
              ),
              enabledBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(28)),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                key: const Key('source-category-button'),
                avatar: const Icon(Icons.folder_outlined, size: 18),
                label: Text('分类：$category'),
                onPressed: onChooseCategory,
              ),
              _SourceFilterMenu<SourceRegistrySourceKind?>(
                key: const Key('source-kind-filter'),
                icon: Icons.layers_outlined,
                label: '类型：${_kindFilterLabel(current.kind)}',
                values: const [
                  null,
                  SourceRegistrySourceKind.official,
                  SourceRegistrySourceKind.composite,
                  SourceRegistrySourceKind.singleSoftware,
                ],
                valueLabel: _kindFilterLabel,
                selected: current.kind,
                onSelected: (value) =>
                    unawaited(controller.applyFilter(current.withKind(value))),
              ),
              _SourceFilterMenu<bool?>(
                icon: Icons.search_outlined,
                label: '搜索：${_booleanFilterLabel(current.searchable)}',
                values: const [null, true, false],
                valueLabel: _booleanFilterLabel,
                selected: current.searchable,
                onSelected: (value) => unawaited(
                  controller.applyFilter(current.withSearchable(value)),
                ),
              ),
              _SourceFilterMenu<bool?>(
                icon: Icons.account_tree_outlined,
                label: '子目录：${_booleanFilterLabel(current.childDirectory)}',
                values: const [null, true, false],
                valueLabel: _booleanFilterLabel,
                selected: current.childDirectory,
                onSelected: (value) => unawaited(
                  controller.applyFilter(current.withChildDirectory(value)),
                ),
              ),
              _SourceFilterMenu<bool?>(
                icon: Icons.inventory_2_outlined,
                label: '归属：${_builtInFilterLabel(current.builtIn)}',
                values: const [null, true, false],
                valueLabel: _builtInFilterLabel,
                selected: current.builtIn,
                onSelected: (value) => unawaited(
                  controller.applyFilter(current.withBuiltIn(value)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SourceFilterMenu<T> extends StatelessWidget {
  const _SourceFilterMenu({
    required this.icon,
    required this.label,
    required this.values,
    required this.valueLabel,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final IconData icon;
  final String label;
  final List<T> values;
  final String Function(T) valueLabel;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: values
        .map(
          (value) => MenuItemButton(
            leadingIcon: value == selected
                ? const Icon(Icons.check_rounded)
                : const SizedBox.square(dimension: 24),
            onPressed: () => onSelected(value),
            child: Text(valueLabel(value)),
          ),
        )
        .toList(growable: false),
    builder: (context, menu, _) => ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: menu.isOpen ? menu.close : menu.open,
    ),
  );
}

class _SourceActions extends StatelessWidget {
  const _SourceActions({
    required this.controller,
    required this.showAddAction,
    required this.canImportRules,
    required this.canExportRules,
    required this.onAdd,
    required this.onCreateComposite,
    required this.onCreateCategory,
    required this.onManageCategories,
    required this.onRawImport,
    required this.onImportRulesFile,
    required this.onImportRulesUrl,
    required this.onExport,
    required this.onRestoreBackup,
    required this.onRestoreOfficial,
    required this.onReset,
  });

  final SourceRegistryController controller;
  final bool showAddAction;
  final bool canImportRules;
  final bool canExportRules;
  final VoidCallback onAdd;
  final VoidCallback onCreateComposite;
  final VoidCallback onCreateCategory;
  final VoidCallback onManageCategories;
  final VoidCallback onRawImport;
  final VoidCallback onImportRulesFile;
  final VoidCallback onImportRulesUrl;
  final VoidCallback onExport;
  final VoidCallback onRestoreBackup;
  final VoidCallback onRestoreOfficial;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      if (showAddAction && controller.canAdd)
        MenuItemButton(
          leadingIcon: const Icon(Icons.add_link_rounded),
          onPressed: onAdd,
          child: const Text('添加来源'),
        ),
      if (controller.canManageComposites)
        MenuItemButton(
          leadingIcon: const Icon(Icons.folder_copy_outlined),
          onPressed: onCreateComposite,
          child: const Text('新建合集'),
        ),
      if (controller.canManageCategories)
        MenuItemButton(
          leadingIcon: const Icon(Icons.create_new_folder_outlined),
          onPressed: onCreateCategory,
          child: const Text('新建分类'),
        ),
      if (controller.canManageCategories && controller.categories.isNotEmpty)
        MenuItemButton(
          leadingIcon: const Icon(Icons.folder_open_outlined),
          onPressed: onManageCategories,
          child: const Text('管理分类'),
        ),
      if (controller.canPreviewImport)
        MenuItemButton(
          leadingIcon: const Icon(Icons.playlist_add_rounded),
          onPressed: onRawImport,
          child: const Text('粘贴导入来源'),
        ),
      if (canImportRules)
        MenuItemButton(
          leadingIcon: const Icon(Icons.file_download_outlined),
          onPressed: onImportRulesFile,
          child: const Text('从文件导入规则'),
        ),
      if (controller.canManageRules)
        MenuItemButton(
          leadingIcon: const Icon(Icons.language_rounded),
          onPressed: onImportRulesUrl,
          child: const Text('从网址导入规则'),
        ),
      if (canExportRules)
        MenuItemButton(
          leadingIcon: const Icon(Icons.file_upload_outlined),
          onPressed: onExport,
          child: const Text('导出规则'),
        ),
      if (controller.canRestore)
        MenuItemButton(
          leadingIcon: const Icon(Icons.settings_backup_restore_rounded),
          onPressed: onRestoreBackup,
          child: const Text('恢复上次备份'),
        ),
      if (controller.canRestore)
        MenuItemButton(
          leadingIcon: const Icon(Icons.restore_rounded),
          onPressed: onRestoreOfficial,
          child: const Text('恢复官方来源'),
        ),
      if (controller.canRestore)
        MenuItemButton(
          leadingIcon: const Icon(Icons.delete_sweep_outlined),
          onPressed: onReset,
          child: const Text('重置全部来源设置'),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              controller.total == 0 ? '来源' : '共 ${controller.total} 个来源',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          if (controller.isMutating)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (actions.isNotEmpty)
            MenuAnchor(
              key: const Key('source-actions-menu'),
              menuChildren: actions,
              builder: (context, menu, child) => IconButton(
                tooltip: '来源操作',
                onPressed: menu.isOpen ? menu.close : menu.open,
                icon: const Icon(Icons.more_vert_rounded),
              ),
            ),
        ],
      ),
    );
  }
}

class _SourceList extends StatelessWidget {
  const _SourceList({
    required this.controller,
    required this.scrollController,
    required this.showSourceLinks,
    required this.onTap,
    super.key,
  });

  final SourceRegistryController controller;
  final ScrollController scrollController;
  final bool showSourceLinks;
  final Future<void> Function(SourceRegistrySource) onTap;

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: scrollController,
    child: ListView.builder(
      key: const Key('source-registry-list'),
      controller: scrollController,
      scrollCacheExtent: const ScrollCacheExtent.pixels(480),
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: controller.sources.length + 1,
      itemBuilder: (context, index) {
        if (index == controller.sources.length) {
          return _SourceListFooter(controller: controller);
        }
        final source = controller.sources[index];
        final selected = controller.selectedIds.contains(source.id);
        return Column(
          key: ValueKey(source.id),
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              selected: selected,
              button: true,
              child: ListTile(
                key: Key('source-row-${source.id}'),
                selected: selected,
                leading: controller.selectionMode
                    ? Checkbox(
                        value: selected,
                        onChanged: (_) => controller.toggleSelection(source),
                      )
                    : Icon(_sourceIcon(source)),
                title: Text(
                  source.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _SourceTag(source.builtIn ? '内置' : '自定义'),
                        _SourceTag(_kindLabel(source.kind)),
                        if (source.searchable) const _SourceTag('可搜索'),
                        if (source.childDirectory) const _SourceTag('子目录'),
                        if (source.errorCode.isNotEmpty)
                          const _SourceTag('需检查', error: true),
                      ],
                    ),
                    if (showSourceLinks && source.shareUrl.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        source.shareUrl,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
                trailing: controller.selectionMode
                    ? null
                    : const Icon(Icons.chevron_right_rounded),
                onLongPress: () => controller.toggleSelection(source),
                onTap: controller.selectionMode
                    ? () => controller.toggleSelection(source)
                    : () => unawaited(onTap(source)),
              ),
            ),
            const Divider(height: 1, indent: 72),
          ],
        );
      },
    ),
  );
}

class _SourceTag extends StatelessWidget {
  const _SourceTag(this.label, {this.error = false});

  final String label;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: error
                ? colors.onErrorContainer
                : colors.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}

class _SourceListFooter extends StatelessWidget {
  const _SourceListFooter({required this.controller});

  final SourceRegistryController controller;

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: AppMotion.duration(context, AppMotion.fast),
    child: controller.isLoadingMore
        ? const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          )
        : controller.loadMoreErrorMessage.isNotEmpty
        ? ListTile(
            leading: Icon(
              Icons.error_outline_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(controller.loadMoreErrorMessage),
            trailing: TextButton(
              onPressed: () => unawaited(controller.loadMore()),
              child: const Text('重试'),
            ),
          )
        : const SizedBox(height: 24),
  );
}

class _SourceLoading extends StatelessWidget {
  const _SourceLoading({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      liveRegion: true,
      label: '正在读取来源',
      child: const CircularProgressIndicator(),
    ),
  );
}

class _SourceMessage extends StatelessWidget {
  const _SourceMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final FutureOr<void> Function()? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => action!(),
              child: const Text('重试'),
            ),
          ],
        ],
      ),
    ),
  );
}

IconData _sourceIcon(SourceRegistrySource source) => switch (source.kind) {
  SourceRegistrySourceKind.official =>
    source.childDirectory
        ? Icons.subdirectory_arrow_right_rounded
        : Icons.cloud_outlined,
  SourceRegistrySourceKind.composite => Icons.folder_copy_outlined,
  SourceRegistrySourceKind.singleSoftware => Icons.android_rounded,
};

String _kindLabel(SourceRegistrySourceKind kind) => switch (kind) {
  SourceRegistrySourceKind.official => '列表源',
  SourceRegistrySourceKind.composite => '合集',
  SourceRegistrySourceKind.singleSoftware => '单文件',
};

String _kindFilterLabel(SourceRegistrySourceKind? kind) => switch (kind) {
  null => '全部',
  final value => _kindLabel(value),
};

String _booleanFilterLabel(bool? value) => switch (value) {
  null => '全部',
  true => '是',
  false => '否',
};

String _builtInFilterLabel(bool? value) => switch (value) {
  null => '全部',
  true => '内置',
  false => '自定义',
};
