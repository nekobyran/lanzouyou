import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../controllers/app_controller.dart';
import '../../controllers/transfer_controller.dart';
import '../../models/cloud_item.dart';
import '../../models/transfer_entry.dart';
import '../../services/cloud_service.dart';
import '../../services/icon_source_locator.dart';
import '../../shared/app_motion.dart';
import '../library_builder/library_builder_page.dart';
import 'folder_upload/folder_upload_launcher.dart';
import 'folder_upload/upload_options_dialog.dart';

enum _ItemAction {
  share,
  generateLibrary,
  rename,
  move,
  copy,
  password,
  description,
  customIcon,
  replacePackage,
  download,
  delete,
}

class FilesPage extends StatefulWidget {
  const FilesPage({
    required this.appController,
    required this.transferController,
    required this.onShowTransfers,
    this.pickReplacementApk,
    this.pickUploadDirectory,
    super.key,
  });

  final AppController appController;
  final TransferController transferController;
  final VoidCallback onShowTransfers;
  final Future<String?> Function()? pickReplacementApk;
  final DirectoryPathPicker? pickUploadDirectory;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  final _searchController = TextEditingController();
  final _pageFocusNode = FocusNode();
  final _iconSourceLocator = const IconSourceLocator();

  @override
  void dispose() {
    _searchController.dispose();
    _pageFocusNode.dispose();
    super.dispose();
  }

  AppController get app => widget.appController;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, widget.transferController]),
      builder: (context, _) {
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyR, control: true): () =>
                app.loadCurrentFolder(refresh: true),
            const SingleActivator(LogicalKeyboardKey.escape):
                app.clearSelection,
            const SingleActivator(LogicalKeyboardKey.delete): _deleteSelection,
          },
          child: Focus(
            autofocus: true,
            focusNode: _pageFocusNode,
            child: PopScope(
              canPop: app.crumbs.length <= 1,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) app.goBackFolder();
              },
              child: Scaffold(
                appBar: _buildAppBar(context),
                body: Column(
                  children: [
                    _Breadcrumbs(controller: app),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: SearchBar(
                        key: const Key('file-search'),
                        controller: _searchController,
                        hintText: '搜索当前目录',
                        leading: const Icon(Icons.search),
                        trailing: [
                          AppMotionSwitcher(
                            transition: AppMotionTransition.fade,
                            child: _searchController.text.isNotEmpty
                                ? IconButton(
                                    key: const ValueKey('clear-search'),
                                    tooltip: '清除搜索',
                                    onPressed: () {
                                      _searchController.clear();
                                      app.setSearch('');
                                      setState(() {});
                                    },
                                    icon: const Icon(Icons.close),
                                  )
                                : const SizedBox.square(
                                    key: ValueKey('no-clear-search'),
                                    dimension: 48,
                                  ),
                          ),
                        ],
                        onChanged: (value) {
                          app.setSearch(value);
                          setState(() {});
                        },
                      ),
                    ),
                    AppMotionAnimatedSize(
                      child: app.fileOperationRunning
                          ? const LinearProgressIndicator(
                              key: Key('file-operation-progress'),
                            )
                          : const SizedBox.shrink(
                              key: Key('file-operation-idle'),
                            ),
                    ),
                    Expanded(child: _buildBody(context)),
                  ],
                ),
                floatingActionButton: FloatingActionButton.extended(
                  key: const Key('upload-button'),
                  onPressed: app.fileOperationRunning ? null : _showUploadMenu,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('上传'),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final appBar = app.selectionMode
        ? AppBar(
            key: const ValueKey('file-selection-app-bar'),
            leading: IconButton(
              tooltip: '取消选择',
              onPressed: app.clearSelection,
              icon: const Icon(Icons.close),
            ),
            title: Text('已选择 ${app.selectedIds.length} 项'),
            actions: [
              IconButton(
                tooltip: '全选当前结果',
                onPressed: app.selectAllVisible,
                icon: const Icon(Icons.select_all),
              ),
              IconButton(
                tooltip: '移动所选项目',
                onPressed: app.fileOperationRunning ? null : _moveSelection,
                icon: const Icon(Icons.drive_file_move_outline),
              ),
              IconButton(
                tooltip: '移到回收站',
                onPressed: app.fileOperationRunning ? null : _deleteSelection,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          )
        : AppBar(
            key: const ValueKey('file-default-app-bar'),
            leading: app.crumbs.length > 1
                ? IconButton(
                    tooltip: '返回上一级',
                    onPressed: app.goBackFolder,
                    icon: const Icon(Icons.arrow_back),
                  )
                : null,
            title: Text(app.currentFolderName),
            actions: [
              if (widget.transferController.hasRunning)
                IconButton(
                  tooltip: '查看正在进行的传输',
                  onPressed: widget.onShowTransfers,
                  icon: const Badge(child: Icon(Icons.swap_vert)),
                ),
              IconButton(
                tooltip: '刷新',
                onPressed: () => app.loadCurrentFolder(refresh: true),
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                key: const Key('create-folder-button'),
                tooltip: '新建文件夹',
                onPressed: app.fileOperationRunning ? null : _createFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            ],
          );
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: AppMotionSwitcher(
        transition: AppMotionTransition.fade,
        child: appBar,
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final child = switch (app.fileStatus) {
      FileLoadStatus.idle || FileLoadStatus.loading => const _StateMessage(
        key: ValueKey('loading'),
        icon: Icons.cloud_sync_outlined,
        title: '正在读取文件',
        loading: true,
      ),
      FileLoadStatus.empty => _StateMessage(
        key: const ValueKey('empty'),
        icon: Icons.folder_open,
        title: '这个目录是空的',
        actionLabel: '上传文件',
        onAction: _showUploadMenu,
      ),
      FileLoadStatus.error => _StateMessage(
        key: const ValueKey('error'),
        icon: Icons.cloud_off_outlined,
        title: '无法读取文件',
        message: app.fileError,
        actionLabel: '重试',
        onAction: app.loadCurrentFolder,
      ),
      FileLoadStatus.content =>
        app.visibleItems.isEmpty
            ? const _StateMessage(
                key: ValueKey('no-results'),
                icon: Icons.search_off,
                title: '没有匹配的文件',
              )
            : _FileList(
                key: const ValueKey('content'),
                controller: app,
                onTap: _tapItem,
                onLongPress: app.toggleSelection,
                onAction: _handleItemAction,
              ),
    };
    return AppMotionSwitcher(child: child);
  }

  Future<void> _tapItem(CloudItem item) async {
    if (app.selectionMode) {
      app.toggleSelection(item);
    } else if (item.isFolder) {
      _searchController.clear();
      await app.openFolder(item);
    } else {
      await _showFileDetails(item);
    }
  }

  Future<void> _handleItemAction(CloudItem item, _ItemAction action) async {
    switch (action) {
      case _ItemAction.share:
        await _showShare(item);
      case _ItemAction.generateLibrary:
        await _openLibraryBuilder(item);
      case _ItemAction.rename:
        await _renameItem(item);
      case _ItemAction.move:
        await _moveItems([item]);
      case _ItemAction.copy:
        await _copyItem(item);
      case _ItemAction.password:
        await _setPassword(item);
      case _ItemAction.description:
        await _describeItem(item);
      case _ItemAction.customIcon:
        await _pickCustomIcon(item);
      case _ItemAction.replacePackage:
        await _replaceApk(item);
      case _ItemAction.download:
        await _pickDownload(item);
      case _ItemAction.delete:
        await _deleteItems([item]);
    }
  }

  Future<void> _showUploadMenu() async {
    final choice = await showDialog<UploadOptionsChoice>(
      context: context,
      builder: (context) => const UploadOptionsDialog(),
    );
    if (!mounted || choice == null) return;

    if (choice.kind == UploadPickerKind.directory) {
      final launch = await FolderUploadLauncher.pickAndEnqueue(
        transferController: widget.transferController,
        cloudFolderId: app.currentFolderId,
        compatibilityWrap: choice.compatibilityWrap,
        autoApkIcons: choice.autoIcon,
        onFolderChanged: () => app.loadCurrentFolder(refresh: true),
        picker: widget.pickUploadDirectory,
      );
      if (!mounted || launch.cancelled) return;
      if (!launch.enqueued) {
        _showMessage(launch.message ?? '无法读取该目录，请选择可访问目录');
        return;
      }
      _showMessage('文件夹已加入传输队列，将保留目录层级');
      widget.onShowTransfers();
      return;
    }

    final result = await FilePicker.pickFiles(
      dialogTitle: choice.kind == UploadPickerKind.apk
          ? '选择一个 APK'
          : '选择要上传的文件',
      allowMultiple: choice.kind != UploadPickerKind.apk,
      type: choice.kind == UploadPickerKind.apk
          ? FileType.custom
          : FileType.any,
      allowedExtensions: choice.kind == UploadPickerKind.apk
          ? const <String>['apk']
          : null,
    );
    if (!mounted || result == null) return;
    final paths = result.paths.whereType<String>().toList(growable: false);
    if (paths.isEmpty) {
      _showMessage('没有可读取的本地文件');
      return;
    }
    if (choice.kind == UploadPickerKind.apk &&
        (paths.length != 1 || !paths.single.toLowerCase().endsWith('.apk'))) {
      _showMessage('请选择一个有效的 APK 文件');
      return;
    }

    final requests = <UploadRequest>[];
    var overrideCount = 0;
    for (final path in paths) {
      final sidecar = choice.autoIcon
          ? await _iconSourceLocator.findSidecar(path)
          : null;
      if (sidecar != null) overrideCount++;
      requests.add(
        UploadRequest(
          path: path,
          compatibilityWrap: choice.compatibilityWrap,
          kind: 'file',
          autoFileIcon: choice.autoIcon,
          iconSourcePath: sidecar ?? path,
        ),
      );
    }
    if (!mounted) return;
    widget.transferController.enqueueUploadRequests(
      folderId: app.currentFolderId,
      requests: requests,
      onFolderChanged: () => app.loadCurrentFolder(refresh: true),
    );
    if (choice.autoIcon) {
      _showMessage(
        overrideCount == 0
            ? '已加入 ${paths.length} 个文件，将自动提取并设置图标'
            : '已加入 ${paths.length} 个文件，其中 $overrideCount 个使用同名图片覆盖图标',
      );
    }
    widget.onShowTransfers();
  }

  Future<void> _pickCustomIcon(CloudItem item) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '选择自定义图标',
      type: FileType.custom,
      allowedExtensions: [
        'png',
        'jpg',
        'jpeg',
        'gif',
        'bmp',
        'apk',
        if (Platform.isWindows) 'exe',
      ],
    );
    final path = result == null || result.files.isEmpty
        ? null
        : result.files.first.path;
    if (!mounted || path == null) return;
    final error = await app.setItemIcon(item, path);
    if (mounted) _showMessage(error ?? '“${item.name}”的文件图标已更新');
  }

  Future<void> _replaceApk(CloudItem item) async {
    if (item.isFolder || !item.name.toLowerCase().endsWith('.apk')) return;
    final picker = widget.pickReplacementApk;
    final path = picker != null
        ? await picker()
        : (await FilePicker.pickFiles(
            dialogTitle: '选择新的 APK',
            type: FileType.custom,
            allowedExtensions: const <String>['apk'],
          ))?.files.firstOrNull?.path;
    if (!mounted || path == null) return;
    if (!path.toLowerCase().endsWith('.apk')) {
      _showMessage('请选择有效的 APK 文件');
      return;
    }
    final succeeded = await showDialog<bool>(
      context: context,
      builder: (context) =>
          _ReplacePackageDialog(appController: app, item: item, path: path),
    );
    if (mounted && succeeded == true) {
      _showMessage('“${item.name}”已安全换包，标题与简介保持不变');
    }
  }

  Future<void> _pickDownload(CloudItem item) async {
    final directory = await FilePicker.getDirectoryPath(dialogTitle: '选择保存目录');
    if (!mounted || directory == null) return;
    widget.transferController.enqueueDownload(
      item: item,
      destination: directory,
    );
    widget.onShowTransfers();
  }

  Future<void> _createFolder() async {
    final result = await _showTextDialog(
      title: '新建文件夹',
      label: '文件夹名称',
      secondaryLabel: '简介（可选）',
    );
    if (result == null) return;
    final error = await app.createFolder(result.$1, result.$2 ?? '');
    if (mounted) _showMessage(error ?? '文件夹已创建');
  }

  Future<void> _renameItem(CloudItem item) async {
    final result = await _showTextDialog(
      title: '重命名',
      label: '新名称',
      initialValue: item.name,
    );
    if (result == null) return;
    final error = await app.renameItem(item, result.$1);
    if (mounted) _showMessage(error ?? '名称已更新');
  }

  Future<void> _moveSelection() async {
    if (app.selectedIds.isEmpty) return;
    await _moveItems(
      app.items.where((item) => app.selectedIds.contains(item.id)),
    );
  }

  Future<void> _moveItems(Iterable<CloudItem> values) async {
    final items = values.toList(growable: false);
    if (items.isEmpty) return;
    final targetId = await _pickTarget(
      title: items.length == 1
          ? '移动“${items.first.name}”'
          : '移动 ${items.length} 项',
      excludedIds: <String>{
        app.currentFolderId,
        ...items.where((item) => item.isFolder).map((item) => item.id),
      },
    );
    if (targetId == null) return;
    final error = await app.moveItems(items, targetId);
    if (mounted) _showMessage(error ?? '已移动 ${items.length} 项');
  }

  Future<void> _copyItem(CloudItem item) async {
    final targetId = await _pickTarget(
      title: '复制“${item.name}”',
      excludedIds: item.isFolder ? [item.id] : const <String>[],
    );
    if (targetId == null) return;
    try {
      final root = await getTemporaryDirectory();
      final copyDirectory = Directory(
        _joinPath(root.path, const ['lanzouyou', 'cache', 'copy']),
      );
      await copyDirectory.create(recursive: true);
      final error = await app.copyItem(item, targetId, copyDirectory.path);
      if (mounted) _showMessage(error ?? '“${item.name}”已复制');
    } on Object {
      if (mounted) _showMessage('无法准备复制所需的临时目录');
    }
  }

  Future<String?> _pickTarget({
    required String title,
    required Iterable<String> excludedIds,
  }) {
    return showDialog<String>(
      context: context,
      builder: (context) => _TargetPickerDialog(
        title: title,
        targets: app.loadMoveTargets(),
        excludedIds: excludedIds.toSet(),
      ),
    );
  }

  Future<void> _setPassword(CloudItem item) async {
    final password = await showDialog<String>(
      context: context,
      builder: (context) => _PasswordDialog(item: item),
    );
    if (password == null) return;
    final error = await app.setItemPassword(item, password);
    if (mounted) {
      _showMessage(error ?? (password.isEmpty ? '提取码已关闭' : '提取码已更新'));
    }
  }

  Future<void> _showShare(CloudItem item) async {
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _ShareDialog(item: item, shareInfo: app.loadShareInfo(item)),
    );
  }

  Future<void> _openLibraryBuilder(CloudItem item) async {
    if (!item.isFolder) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) =>
            LibraryBuilderPage(shareInfo: app.loadShareInfo(item)),
      ),
    );
  }

  Future<void> _describeItem(CloudItem item) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _DescriptionEditorDialog(
        itemName: item.name,
        loadDescription: () => app.loadItemDescription(item),
        saveDescription: (description) => app.describeItem(item, description),
      ),
    );
    if (mounted && saved == true) _showMessage('简介已更新');
  }

  Future<void> _deleteSelection() async {
    if (app.selectedIds.isEmpty) return;
    await _deleteItems(
      app.items.where((item) => app.selectedIds.contains(item.id)),
    );
  }

  Future<void> _deleteItems(Iterable<CloudItem> values) async {
    final items = values.toList(growable: false);
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const Text('移到回收站？'),
        content: Text(
          items.length == 1
              ? '“${items.first.name}”将移到回收站。'
              : '${items.length} 个项目将移到回收站。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移到回收站'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await app.deleteItems(items);
    if (mounted) _showMessage(error ?? '已移到回收站');
  }

  Future<(String, String?)?> _showTextDialog({
    required String title,
    required String label,
    String initialValue = '',
    String? secondaryLabel,
    bool allowEmpty = false,
    int maxLines = 1,
  }) async {
    final primary = TextEditingController(text: initialValue);
    final secondary = secondaryLabel == null ? null : TextEditingController();
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<(String, String?)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  autofocus: true,
                  controller: primary,
                  maxLines: maxLines,
                  maxLength: maxLines > 1 ? 4000 : 255,
                  decoration: InputDecoration(labelText: label),
                  validator: (value) =>
                      !allowEmpty && (value?.trim().isEmpty ?? true)
                      ? '请输入$label'
                      : null,
                ),
                if (secondary != null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: secondary,
                    maxLines: 3,
                    maxLength: 4000,
                    decoration: InputDecoration(labelText: secondaryLabel),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(context, (
                  primary.text.trim(),
                  secondary?.text.trim(),
                ));
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    primary.dispose();
    secondary?.dispose();
    return result;
  }

  Future<void> _showFileDetails(CloudItem item) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(item.name, style: Theme.of(context).textTheme.titleLarge),
              if (item.size != null) ...[
                const SizedBox(height: 8),
                Text('大小：${item.size}'),
              ],
              if (item.modifiedAt != null) Text('修改时间：${item.modifiedAt}'),
              if ((item.description ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(item.description!),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _pickDownload(item);
                },
                icon: const Icon(Icons.download),
                label: const Text('下载'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _DescriptionEditorDialog extends StatefulWidget {
  const _DescriptionEditorDialog({
    required this.itemName,
    required this.loadDescription,
    required this.saveDescription,
  });

  final String itemName;
  final Future<String> Function() loadDescription;
  final Future<String?> Function(String description) saveDescription;

  @override
  State<_DescriptionEditorDialog> createState() =>
      _DescriptionEditorDialogState();
}

class _DescriptionEditorDialogState extends State<_DescriptionEditorDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _saveError;
  int _loadSerial = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _loadSerial++;
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final serial = ++_loadSerial;
    setState(() {
      _loading = true;
      _loadError = null;
      _saveError = null;
    });
    try {
      final description = await widget.loadDescription();
      if (!mounted || serial != _loadSerial) return;
      _controller.text = description;
      setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    } on CloudFailure catch (error) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _loading = false;
        _loadError = error.message;
      });
    } on Object {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _loading = false;
        _loadError = '无法读取蓝奏云当前简介，请重试';
      });
    }
  }

  Future<void> _save() async {
    if (_loading || _saving || _loadError != null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final error = await widget.saveDescription(_controller.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _saving = false;
      _saveError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.notes_outlined),
        title: const Text('编辑简介'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, minWidth: 280),
          child: AppMotionSwitcher(
            transition: AppMotionTransition.fade,
            child: _buildContent(context),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('save-remote-description'),
            onPressed: _loading || _saving || _loadError != null ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_loading) {
      return Semantics(
        key: const Key('description-loading'),
        liveRegion: true,
        label: '正在读取蓝奏云当前简介',
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Column(
            key: ValueKey('description-loading-content'),
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在读取蓝奏云当前简介'),
            ],
          ),
        ),
      );
    }
    final loadError = _loadError;
    if (loadError != null) {
      return Semantics(
        key: const Key('description-load-error'),
        liveRegion: true,
        label: '简介读取失败，$loadError',
        child: Column(
          key: const ValueKey('description-error-content'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(loadError, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('retry-description-load'),
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return Column(
      key: const ValueKey('description-editor-content'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.itemName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('remote-description-field'),
          controller: _controller,
          focusNode: _focusNode,
          enabled: !_saving,
          minLines: 3,
          maxLines: 5,
          maxLength: 4000,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(labelText: '简介', errorText: _saveError),
        ),
      ],
    );
  }
}

class _ReplacePackageDialog extends StatefulWidget {
  const _ReplacePackageDialog({
    required this.appController,
    required this.item,
    required this.path,
  });

  final AppController appController;
  final CloudItem item;
  final String path;

  @override
  State<_ReplacePackageDialog> createState() => _ReplacePackageDialogState();
}

class _ReplacePackageDialogState extends State<_ReplacePackageDialog> {
  ManagedDescription? _metadata;
  PackageReplaceFailure? _failure;
  String? _loadError;
  bool _loading = true;
  bool _running = false;
  bool _autoIcon = true;
  int _loadSerial = 0;

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  @override
  void dispose() {
    _loadSerial++;
    super.dispose();
  }

  Future<void> _loadMetadata() async {
    final serial = ++_loadSerial;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final metadata = await widget.appController.loadManagedDescription(
        widget.item,
      );
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _metadata = metadata;
        _loading = false;
      });
    } on CloudFailure catch (error) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _loading = false;
        _loadError = error.message;
      });
    } on Object {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _loading = false;
        _loadError = '无法读取蓝奏云当前标题与简介，请重试';
      });
    }
  }

  Future<void> _start() async {
    if (_running || _metadata == null) return;
    setState(() {
      _running = true;
      _failure = null;
    });
    final outcome = await widget.appController.replacePackage(
      widget.item,
      widget.path,
      autoFileIcon: _autoIcon,
    );
    if (!mounted) return;
    if (outcome.succeeded) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _running = false;
      _failure = outcome.failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.appController,
      builder: (context, _) => PopScope(
        canPop: !_running,
        child: AlertDialog(
          scrollable: true,
          icon: const Icon(Icons.sync_alt_outlined),
          title: const Text('安全换包'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, minWidth: 280),
            child: AppMotionSwitcher(
              transition: AppMotionTransition.fade,
              child: _buildContent(context),
            ),
          ),
          actions: _buildActions(),
        ),
      ),
    );
  }

  List<Widget> _buildActions() {
    if (_running) return const <Widget>[];
    if (_failure != null) {
      return <Widget>[
        FilledButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('关闭'),
        ),
      ];
    }
    if (_loading || _loadError != null) {
      return <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
      ];
    }
    return <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        key: const Key('confirm-package-replace'),
        onPressed: _start,
        icon: const Icon(Icons.sync),
        label: const Text('开始换包'),
      ),
    ];
  }

  Widget _buildContent(BuildContext context) {
    if (_running) {
      return Semantics(
        key: const Key('package-replace-running'),
        liveRegion: true,
        label: widget.appController.packageReplaceMessage ?? '正在安全换包，请稍候',
        child: Padding(
          key: const ValueKey('package-replace-running-content'),
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                widget.appController.packageReplaceMessage ?? '正在安全换包，请稍候',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '核心确认新文件信息后才会删除旧文件',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final failure = _failure;
    if (failure != null) return _buildFailure(context, failure);
    if (_loading) {
      return Semantics(
        key: const Key('package-replace-loading'),
        liveRegion: true,
        label: '正在读取蓝奏云当前标题与简介',
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在读取蓝奏云当前标题与简介'),
            ],
          ),
        ),
      );
    }
    final loadError = _loadError;
    if (loadError != null) {
      return Semantics(
        liveRegion: true,
        label: '换包信息读取失败，$loadError',
        child: Column(
          key: const ValueKey('package-replace-load-error'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(loadError, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _loadMetadata,
              icon: const Icon(Icons.refresh),
              label: const Text('重试读取'),
            ),
          ],
        ),
      );
    }
    final metadata = _metadata!;
    final description = metadata.description.trim();
    return Column(
      key: const ValueKey('package-replace-confirmation'),
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.title),
          title: const Text('保留云端标题'),
          subtitle: Text(metadata.name),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.notes_outlined),
          title: const Text('保留云端简介'),
          subtitle: Text(
            description.isEmpty ? '当前为空简介' : description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.android_outlined),
          title: const Text('新的 APK'),
          subtitle: Text(_localFileName(widget.path)),
        ),
        const Divider(height: 1),
        SwitchListTile(
          key: const Key('replace-auto-icon-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('从新 APK 提取并设置图标（<100KB）'),
          subtitle: const Text('启用后，图标绑定成功才会提交换包'),
          value: _autoIcon,
          onChanged: (value) => setState(() => _autoIcon = value),
        ),
      ],
    );
  }

  Widget _buildFailure(BuildContext context, PackageReplaceFailure failure) {
    final retention = switch (failure.oldRetained) {
      true => '旧文件仍保留，可继续使用',
      false => '核心报告旧文件未保留，请立即刷新核对',
      null => '核心未确认旧文件状态，请立即刷新核对',
    };
    final cleanup = failure.cleanupRequired
        ? failure.newFileId == null
              ? '蓝奏云中可能留有未完成的新文件，需要手动核对清理'
              : '需要核对清理未完成的新文件：${failure.newFileId}'
        : null;
    return Semantics(
      key: const Key('package-replace-failure'),
      liveRegion: true,
      label:
          '换包失败，${failure.message}，$retention${cleanup == null ? '' : '，$cleanup'}',
      child: Column(
        key: const ValueKey('package-replace-failure-content'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          Text(failure.message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              failure.oldRetained == true
                  ? Icons.verified_outlined
                  : Icons.warning_amber_outlined,
            ),
            title: Text(retention),
          ),
          if (cleanup != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cleaning_services_outlined),
              title: Text(cleanup),
            ),
        ],
      ),
    );
  }
}

class _TargetPickerDialog extends StatefulWidget {
  const _TargetPickerDialog({
    required this.title,
    required this.targets,
    required this.excludedIds,
  });

  final String title;
  final Future<List<CloudItem>> targets;
  final Set<String> excludedIds;

  @override
  State<_TargetPickerDialog> createState() => _TargetPickerDialogState();
}

class _TargetPickerDialogState extends State<_TargetPickerDialog> {
  final _searchController = TextEditingController();
  String _query = '';
  String? _selectedId;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height * 0.55)
        .clamp(280.0, 500.0)
        .toDouble();
    return AlertDialog(
      icon: const Icon(Icons.drive_file_move_outline),
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: height,
        child: FutureBuilder<List<CloudItem>>(
          future: widget.targets,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Center(
                child: Semantics(
                  label: '正在读取目标目录',
                  liveRegion: true,
                  child: const CircularProgressIndicator(),
                ),
              );
            }
            if (snapshot.hasError) {
              final error = snapshot.error;
              return _DialogError(
                message: error is CloudFailure ? error.message : '无法读取目标目录',
              );
            }
            final targets = _targets(snapshot.data ?? const <CloudItem>[]);
            return Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: '搜索目录',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close),
                          ),
                  ),
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: targets.isEmpty
                      ? const Center(child: Text('没有可用的目标目录'))
                      : Scrollbar(
                          child: ListView.separated(
                            itemCount: targets.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1, indent: 56),
                            itemBuilder: (context, index) {
                              final target = targets[index];
                              final selected = target.id == _selectedId;
                              return Semantics(
                                selected: selected,
                                button: true,
                                label: '目标目录 ${target.path ?? target.name}',
                                child: ListTile(
                                  selected: selected,
                                  leading: Icon(
                                    selected
                                        ? Icons.check_circle
                                        : target.id == '-1'
                                        ? Icons.cloud_outlined
                                        : Icons.folder_outlined,
                                  ),
                                  title: Text(target.name),
                                  subtitle: target.path == null
                                      ? null
                                      : Text(
                                          target.path!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                  onTap: () =>
                                      setState(() => _selectedId = target.id),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selectedId == null
              ? null
              : () => Navigator.pop(context, _selectedId),
          child: const Text('确定'),
        ),
      ],
    );
  }

  List<CloudItem> _targets(List<CloudItem> values) {
    final all = <CloudItem>[
      if (!values.any((item) => item.id == '-1'))
        const CloudItem(id: '-1', name: '全部文件', isFolder: true, path: '/'),
      ...values,
    ];
    return all
        .where((item) {
          if (!item.isFolder || widget.excludedIds.contains(item.id)) {
            return false;
          }
          if (_query.isEmpty) {
            return true;
          }
          return item.name.toLowerCase().contains(_query) ||
              (item.path ?? '').toLowerCase().contains(_query);
        })
        .toList(growable: false)
      ..sort((first, second) {
        if (first.id == '-1') {
          return -1;
        }
        if (second.id == '-1') {
          return 1;
        }
        return (first.path ?? first.name).compareTo(second.path ?? second.name);
      });
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.item});

  final CloudItem item;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscure = false;

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maximum = widget.item.isFolder ? 12 : 6;
    return AlertDialog(
      icon: const Icon(Icons.password_outlined),
      title: const Text('设置提取码'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Form(
          key: _formKey,
          child: TextFormField(
            key: const Key('password-dialog-field'),
            controller: _controller,
            autofocus: true,
            obscureText: _obscure,
            maxLength: maximum,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: '提取码（留空关闭）',
              helperText: widget.item.isFolder ? '文件夹最多 12 位' : '文件需要 2–6 位',
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示提取码' : '隐藏提取码',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
            validator: (value) {
              final length = value?.trim().characters.length ?? 0;
              if (length == 0) return null;
              if (!widget.item.isFolder && (length < 2 || length > 6)) {
                return '文件提取码需要 2–6 位';
              }
              if (widget.item.isFolder && length > 12) return '文件夹提取码最多 12 位';
              return null;
            },
            onFieldSubmitted: (_) => _submit(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.pop(context, _controller.text.trim());
    }
  }
}

class _ShareDialog extends StatelessWidget {
  const _ShareDialog({required this.item, required this.shareInfo});

  final CloudItem item;
  final Future<ShareInfo> shareInfo;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.share_outlined),
      title: Text('分享 · ${item.name}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: FutureBuilder<ShareInfo>(
          future: shareInfo,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return SizedBox(
                height: 160,
                child: Center(
                  child: Semantics(
                    label: '正在获取分享信息',
                    liveRegion: true,
                    child: const CircularProgressIndicator(),
                  ),
                ),
              );
            }
            if (snapshot.hasError || !snapshot.hasData) {
              final error = snapshot.error;
              return _DialogError(
                message: error is CloudFailure ? error.message : '无法获取分享信息',
              );
            }
            final info = snapshot.requireData;
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CopyValue(
                    label: '分享链接',
                    value: info.shareUrl,
                    unavailableText: '暂无分享链接',
                  ),
                  const SizedBox(height: 12),
                  _CopyValue(
                    label: '提取码',
                    value: info.password,
                    unavailableText: '未设置提取码',
                  ),
                  if (!info.isFolder) ...[
                    const SizedBox(height: 12),
                    _CopyValue(
                      label: '临时直链',
                      value: info.directUrl ?? '',
                      unavailableText: '未取得临时直链',
                    ),
                  ],
                  if (info.description.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('简介', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 4),
                    SelectableText(info.description),
                  ],
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _CopyValue extends StatelessWidget {
  const _CopyValue({
    required this.label,
    required this.value,
    required this.unavailableText,
  });

  final String label;
  final String value;
  final String unavailableText;

  @override
  Widget build(BuildContext context) {
    final available = value.isNotEmpty;
    return Semantics(
      label: available ? '$label $value' : '$label $unavailableText',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                SelectableText(available ? value : unavailableText),
              ],
            ),
          ),
          IconButton(
            tooltip: '复制$label',
            onPressed: available
                ? () async {
                    await Clipboard.setData(ClipboardData(text: value));
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('$label已复制')));
                    }
                  }
                : null,
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
    );
  }
}

class _DialogError extends StatelessWidget {
  const _DialogError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        itemCount: controller.crumbs.length,
        separatorBuilder: (_, _) => const Icon(Icons.chevron_right, size: 18),
        itemBuilder: (context, index) {
          final crumb = controller.crumbs[index];
          final current = index == controller.crumbs.length - 1;
          return TextButton.icon(
            onPressed: current ? null : () => controller.openCrumb(index),
            icon: Icon(
              index == 0 ? Icons.home_outlined : Icons.folder_outlined,
            ),
            label: Text(crumb.name),
          );
        },
      ),
    );
  }
}

String _joinPath(String root, List<String> parts) {
  return <String>[
    root.replaceFirst(RegExp(r'[/\\]+$'), ''),
    ...parts,
  ].join(Platform.pathSeparator);
}

String _localFileName(String path) => path.split(RegExp(r'[/\\]')).last;

class _FileList extends StatelessWidget {
  const _FileList({
    required this.controller,
    required this.onTap,
    required this.onLongPress,
    required this.onAction,
    super.key,
  });

  final AppController controller;
  final ValueChanged<CloudItem> onTap;
  final ValueChanged<CloudItem> onLongPress;
  final void Function(CloudItem, _ItemAction) onAction;

  @override
  Widget build(BuildContext context) {
    final items = controller.visibleItems;
    return Scrollbar(
      child: RefreshIndicator(
        onRefresh: () => controller.loadCurrentFolder(refresh: true),
        child: ListView.separated(
          key: const Key('file-list'),
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: items.length + (controller.hasMore ? 1 : 0),
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
          itemBuilder: (context, index) {
            if (index == items.length) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: OutlinedButton.icon(
                    onPressed: controller.loadingMore
                        ? null
                        : controller.loadMore,
                    icon: controller.loadingMore
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.expand_more),
                    label: Text(controller.loadingMore ? '正在加载' : '加载更多'),
                  ),
                ),
              );
            }
            final item = items[index];
            final selected = controller.selectedIds.contains(item.id);
            return AppMotionListItem(
              key: ValueKey('file-motion-${item.id}'),
              child: AppMotionSelection(
                selected: selected,
                borderRadius: BorderRadius.zero,
                child: Semantics(
                  selected: selected,
                  button: true,
                  label: '${item.isFolder ? '文件夹' : '文件'} ${item.name}',
                  child: ListTile(
                    key: ValueKey('cloud-item-${item.id}'),
                    selected: selected,
                    minTileHeight: 64,
                    leading: controller.selectionMode
                        ? Checkbox(
                            value: selected,
                            onChanged: (_) => controller.toggleSelection(item),
                          )
                        : _CloudItemIcon(item: item),
                    title: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: _subtitle(item),
                    onTap: () => onTap(item),
                    onLongPress: () => onLongPress(item),
                    trailing: PopupMenuButton<_ItemAction>(
                      tooltip: '更多操作',
                      onSelected: (action) => onAction(item, action),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: _ItemAction.share,
                          child: ListTile(
                            leading: Icon(Icons.share_outlined),
                            title: Text('分享信息'),
                          ),
                        ),
                        if (item.isFolder)
                          const PopupMenuItem(
                            value: _ItemAction.generateLibrary,
                            child: ListTile(
                              leading: Icon(Icons.library_add_outlined),
                              title: Text('生成软件库'),
                            ),
                          ),
                        const PopupMenuItem(
                          value: _ItemAction.rename,
                          child: ListTile(
                            leading: Icon(Icons.edit_outlined),
                            title: Text('重命名'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: _ItemAction.move,
                          child: ListTile(
                            leading: Icon(Icons.drive_file_move_outline),
                            title: Text('移动'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: _ItemAction.copy,
                          child: ListTile(
                            leading: Icon(Icons.copy_outlined),
                            title: Text('复制'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: _ItemAction.password,
                          child: ListTile(
                            leading: Icon(Icons.password_outlined),
                            title: Text('设置提取码'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: _ItemAction.description,
                          child: ListTile(
                            leading: Icon(Icons.notes_outlined),
                            title: Text('编辑简介'),
                          ),
                        ),
                        if (!item.isFolder)
                          const PopupMenuItem(
                            value: _ItemAction.customIcon,
                            child: ListTile(
                              leading: Icon(Icons.image_outlined),
                              title: Text('设置自定义图标'),
                            ),
                          ),
                        if (!item.isFolder &&
                            item.name.toLowerCase().endsWith('.apk'))
                          const PopupMenuItem(
                            value: _ItemAction.replacePackage,
                            child: ListTile(
                              key: Key('replace-package-menu-item'),
                              leading: Icon(Icons.sync_alt_outlined),
                              title: Text('安全换包'),
                              subtitle: Text('保留云端标题与简介'),
                            ),
                          ),
                        if (!item.isFolder)
                          const PopupMenuItem(
                            value: _ItemAction.download,
                            child: ListTile(
                              leading: Icon(Icons.download_outlined),
                              title: Text('下载'),
                            ),
                          ),
                        const PopupMenuItem(
                          value: _ItemAction.delete,
                          child: ListTile(
                            leading: Icon(Icons.delete_outline),
                            title: Text('移到回收站'),
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
    );
  }

  Widget? _subtitle(CloudItem item) {
    final parts = <String>[
      if (item.size != null) item.size!,
      if (item.modifiedAt != null) item.modifiedAt!,
      if (item.hasPassword) '有提取码',
      if (item.hasCustomIcon) '自定义图标',
    ];
    return parts.isEmpty
        ? null
        : Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}

class _CloudItemIcon extends StatelessWidget {
  const _CloudItemIcon({required this.item});

  final CloudItem item;

  @override
  Widget build(BuildContext context) {
    if (item.isFolder) {
      return Icon(Icons.folder, color: Theme.of(context).colorScheme.primary);
    }
    final iconUrl = item.iconUrl;
    if (iconUrl == null || iconUrl.isEmpty) return _fallback(context);
    return Semantics(
      image: true,
      label: '${item.name}的自定义文件图标',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox.square(
          dimension: 40,
          child: Image.network(
            iconUrl,
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (context, _, _) => _fallback(context),
          ),
        ),
      ),
    );
  }

  Widget _fallback(BuildContext context) {
    return Icon(Icons.insert_drive_file, color: Colors.amber.shade700);
  }
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({
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
