import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lanzou_library_shell/library_preview.dart';

import '../../controllers/app_controller.dart';
import '../../controllers/recycle_controller.dart';
import '../../controllers/transfer_controller.dart';
import '../../models/transfer_entry.dart';
import '../../shared/app_motion.dart';
import '../../shared/widgets/adaptive_navigation_bar.dart';
import '../files/files_page.dart';
import '../library_builder/library_workspace_page.dart';
import '../login/login_page.dart';
import '../public_library/public_library.dart';
import '../recycle/recycle_page.dart';
import '../settings/settings_page.dart';
import '../transfers/transfers_page.dart';

enum _PrimaryDestination {
  files,
  search,
  list,
  downloads,
  recycle,
  transfers,
  library,
  settings,
}

class NavigationShell extends StatefulWidget {
  const NavigationShell({
    required this.appController,
    required this.transferController,
    this.publicLibraryCore,
    this.sourceRegistryCore,
    super.key,
  });

  final AppController appController;
  final TransferController transferController;
  final PublicLibraryCatalogCore? publicLibraryCore;
  final SourceRegistryCore? sourceRegistryCore;

  @override
  State<NavigationShell> createState() => _NavigationShellState();
}

class _NavigationShellState extends State<NavigationShell> {
  _PrimaryDestination _selected = _PrimaryDestination.files;
  late final RecycleController _recycleController;
  PublicLibraryController? _searchController;
  PublicLibraryController? _listController;
  PublicLibraryController? _libraryController;
  String? _lastAccountId;

  AppController get app => widget.appController;

  @override
  void initState() {
    super.initState();
    _lastAccountId = app.activeAccountId;
    _recycleController = RecycleController(
      cloudService: app.cloudService,
      onSessionExpired: app.expireSession,
    );
    final core = widget.publicLibraryCore;
    if (core != null) {
      _searchController = PublicLibraryController(
        core: core,
        searchViewRatePerSecond: app.searchViewCreationRate,
      );
      _listController = PublicLibraryController(
        core: core,
        searchViewRatePerSecond: app.searchViewCreationRate,
      );
      _libraryController = PublicLibraryController(
        core: core,
        searchViewRatePerSecond: app.searchViewCreationRate,
      );
    }
    app.addListener(_handleAppState);
  }

  @override
  void dispose() {
    app.removeListener(_handleAppState);
    _recycleController.dispose();
    _searchController?.dispose();
    _listController?.dispose();
    _libraryController?.dispose();
    super.dispose();
  }

  void _handleAppState() {
    final nextAccountId = app.activeAccountId;
    if (nextAccountId == _lastAccountId) return;
    _lastAccountId = nextAccountId;
    _recycleController.reset();
  }

  List<_DestinationSpec> _specs() {
    final publicAvailable = widget.publicLibraryCore != null;
    return <_DestinationSpec>[
      const _DestinationSpec(
        id: _PrimaryDestination.files,
        label: '文件',
        icon: Icons.cloud_outlined,
        selectedIcon: Icons.cloud,
      ),
      if (publicAvailable)
        const _DestinationSpec(
          id: _PrimaryDestination.search,
          label: '搜索',
          icon: Icons.search_outlined,
          selectedIcon: Icons.search_rounded,
        ),
      if (publicAvailable)
        const _DestinationSpec(
          id: _PrimaryDestination.list,
          label: '列表',
          icon: Icons.view_list_outlined,
          selectedIcon: Icons.view_list_rounded,
        ),
      const _DestinationSpec(
        id: _PrimaryDestination.downloads,
        label: '下载',
        icon: Icons.download_outlined,
        selectedIcon: Icons.download_rounded,
      ),
      const _DestinationSpec(
        id: _PrimaryDestination.recycle,
        label: '回收站',
        icon: Icons.delete_outline,
        selectedIcon: Icons.delete_rounded,
      ),
      const _DestinationSpec(
        id: _PrimaryDestination.transfers,
        label: '传输',
        icon: Icons.swap_vert_outlined,
        selectedIcon: Icons.swap_vert_rounded,
      ),
      if (publicAvailable)
        const _DestinationSpec(
          id: _PrimaryDestination.library,
          label: '软件库',
          icon: Icons.apps_outlined,
          selectedIcon: Icons.apps_rounded,
        ),
      const _DestinationSpec(
        id: _PrimaryDestination.settings,
        label: '设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings_rounded,
      ),
    ];
  }

  void _select(_PrimaryDestination destination) {
    if (_selected == destination) return;
    setState(() => _selected = destination);
    if (destination == _PrimaryDestination.recycle &&
        app.isSignedIn &&
        _recycleController.status == RecycleStatus.idle) {
      unawaited(_recycleController.load());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final specs = _specs();
        var selectedIndex = specs.indexWhere((spec) => spec.id == _selected);
        if (selectedIndex < 0) {
          _selected = _PrimaryDestination.files;
          selectedIndex = 0;
        }
        final pages = [
          for (final spec in specs)
            _LazyDestination(
              key: ValueKey('destination-${spec.id.name}'),
              active: spec.id == _selected,
              builder: () => _pageFor(spec.id),
            ),
        ];
        return AppAdaptiveNavigationBar(
          applicationIcon: const Icon(Icons.cloud_outlined),
          applicationName: 'LanzouYOU',
          onLandscapeSearch: widget.publicLibraryCore == null
              ? null
              : () => _select(_PrimaryDestination.search),
          selectedIndex: selectedIndex,
          onDestinationSelected: (index) => _select(specs[index].id),
          destinations: [
            for (final spec in specs)
              AppNavigationDestination(
                label: spec.label,
                icon: spec.icon,
                selectedIcon: spec.selectedIcon,
              ),
          ],
          body: AppMotionPageStack(index: selectedIndex, children: pages),
        );
      },
    );
  }

  Widget _pageFor(_PrimaryDestination destination) {
    return switch (destination) {
      _PrimaryDestination.files => FilesPage(
        appController: app,
        transferController: widget.transferController,
        onShowTransfers: () => _select(_PrimaryDestination.transfers),
      ),
      _PrimaryDestination.search => PublicLibraryPage(
        controller: _searchController!,
        disposeController: false,
        autofocusSearch: true,
      ),
      _PrimaryDestination.list => PublicLibraryPage(
        controller: _listController!,
        disposeController: false,
      ),
      _PrimaryDestination.downloads => TransfersPage(
        controller: widget.transferController,
        kindFilter: TransferKind.download,
        title: '下载',
      ),
      _PrimaryDestination.recycle =>
        app.isSignedIn
            ? RecyclePage(controller: _recycleController)
            : _PrivateLoginRequired(
                controller: app,
                title: '登录后查看回收站',
                message: '回收站属于私人云盘数据；搜索、列表和公共软件库仍可免登录使用。',
              ),
      _PrimaryDestination.transfers => TransfersPage(
        controller: widget.transferController,
      ),
      _PrimaryDestination.library => LibraryWorkspacePage(
        cloudService: app.cloudService,
        publicLibraryController: _libraryController!,
      ),
      _PrimaryDestination.settings => SettingsPage(
        controller: app,
        publicLibraryCore: widget.publicLibraryCore,
        sourceRegistryCore: widget.sourceRegistryCore,
      ),
    };
  }
}

class _DestinationSpec {
  const _DestinationSpec({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final _PrimaryDestination id;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _LazyDestination extends StatefulWidget {
  const _LazyDestination({
    required this.active,
    required this.builder,
    super.key,
  });

  final bool active;
  final Widget Function() builder;

  @override
  State<_LazyDestination> createState() => _LazyDestinationState();
}

class _LazyDestinationState extends State<_LazyDestination> {
  late bool _activated = widget.active;

  @override
  void didUpdateWidget(_LazyDestination oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_activated && widget.active) _activated = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_activated) return const SizedBox.shrink();
    return widget.builder();
  }
}

class _PrivateLoginRequired extends StatelessWidget {
  const _PrivateLoginRequired({
    required this.controller,
    required this.title,
    required this.message,
  });

  final AppController controller;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('私人数据')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 52,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (context) => LoginPage(controller: controller),
                    ),
                  ),
                  icon: const Icon(Icons.login_rounded),
                  label: const Text('登录账号'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
