import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/cloud_item.dart';
import '../../services/cloud_service.dart';
import '../public_library/public_library.dart';
import 'library_builder_page.dart';
import 'library_builder_service.dart';
import 'library_recipe.dart';

class LibraryWorkspacePage extends StatefulWidget {
  const LibraryWorkspacePage({
    required this.cloudService,
    required this.publicLibraryController,
    this.projectStore,
    super.key,
  });

  final CloudService cloudService;
  final PublicLibraryController publicLibraryController;
  final LibraryProjectCatalogStore? projectStore;

  @override
  State<LibraryWorkspacePage> createState() => _LibraryWorkspacePageState();
}

class _LibraryWorkspacePageState extends State<LibraryWorkspacePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final LibraryProjectCatalogStore _store;
  Future<List<LibraryBuildRecipe>>? _projects;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _store = widget.projectStore ?? const LocalLibraryProjectStore();
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _reload() => setState(() => _projects = _store.list());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('软件库'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.public_outlined), text: '公共库'),
            Tab(icon: Icon(Icons.workspaces_outlined), text: '我的工程'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          PublicLibraryPage(
            controller: widget.publicLibraryController,
            disposeController: false,
            showAppBar: false,
            safeBottom: false,
          ),
          _projectList(),
        ],
      ),
      floatingActionButton: AnimatedBuilder(
        animation: _tabs,
        builder: (context, _) => _tabs.index == 1
            ? FloatingActionButton.extended(
                key: const Key('create-library-project'),
                onPressed: _creating ? null : _createProject,
                icon: _creating
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(_creating ? '正在创建' : '新建工程'),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  Widget _projectList() {
    return FutureBuilder<List<LibraryBuildRecipe>>(
      future: _projects,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _ProjectState(
            icon: Icons.error_outline,
            message: '无法读取工程',
            action: _reload,
          );
        }
        final projects = snapshot.data ?? const <LibraryBuildRecipe>[];
        if (projects.isEmpty) {
          return _ProjectState(
            icon: Icons.workspaces_outline,
            message: '还没有软件库工程',
            action: _createProject,
          );
        }
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView.separated(
            key: const Key('library-project-list'),
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: projects.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final project = projects[index];
              return ListTile(
                key: ValueKey('library-project-${project.identity.projectId}'),
                leading: const Icon(Icons.apps_outlined),
                title: Text(project.identity.displayName),
                subtitle: Text(
                  '${project.identity.applicationId}  '
                  '${project.identity.versionName} (${project.identity.versionCode})',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(project),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _createProject() async {
    if (_creating) return;
    final name = await _askProjectName();
    if (name == null) return;
    setState(() => _creating = true);
    try {
      final existing = await _findFolder('-1', name);
      if (existing != null) {
        throw const CloudFailure('already_exists', '根目录已有同名文件夹，请换一个工程名');
      }
      await widget.cloudService.createFolder(
        '-1',
        name,
        description:
            'LanzouYOU 软件库工程；img*/txt* 单目录最多 50 项；rjk 为软件列表；url 为网页页面。',
      );
      final root = await _findFolder('-1', name);
      if (root == null) {
        throw const CloudFailure('create_unconfirmed', '云端未返回新工程目录');
      }
      for (final child in const ['img1', 'txt1', 'rjk', 'url']) {
        await widget.cloudService.createFolder(root.id, child);
      }
      final share = await widget.cloudService.shareInfo(root);
      final recipe = LibraryBuildRecipe.fromShareInfo(share);
      await _store.save(recipe);
      _reload();
      if (mounted) await _open(recipe);
    } on Object catch (error) {
      if (mounted) {
        final message = error is CloudFailure
            ? error.message
            : '创建工程失败，请检查账号与网络';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<CloudItem?> _findFolder(String parentId, String name) async {
    for (var page = 1; page <= 100; page++) {
      final result = await widget.cloudService.listFolder(
        parentId,
        page: page,
        pageSize: 50,
      );
      for (final item in result.items) {
        if (item.isFolder && item.name == name) {
          return item;
        }
      }
      if (!result.hasMore) return null;
    }
    throw const CloudFailure('too_many_pages', '目录页数超过安全上限');
  }

  Future<String?> _askProjectName() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建软件库工程'),
        content: TextField(
          key: const Key('library-project-name'),
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: '工程名'),
          textInputAction: TextInputAction.done,
          onSubmitted: (value) {
            final trimmed = value.trim();
            if (trimmed.isNotEmpty) Navigator.pop(context, trimmed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _open(LibraryBuildRecipe recipe) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => LibraryBuilderPage.newProject(initialRecipe: recipe),
      ),
    );
    _reload();
  }
}

class _ProjectState extends StatelessWidget {
  const _ProjectState({
    required this.icon,
    required this.message,
    required this.action,
  });

  final IconData icon;
  final String message;
  final VoidCallback action;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 44, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(message),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: action,
          icon: const Icon(Icons.add),
          label: const Text('新建工程'),
        ),
      ],
    ),
  );
}
