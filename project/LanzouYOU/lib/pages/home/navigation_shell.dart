import 'package:flutter/material.dart';
import 'package:lanzou_library_shell/library_preview.dart';

import '../../controllers/app_controller.dart';
import '../../controllers/transfer_controller.dart';
import '../../controllers/recycle_controller.dart';
import '../../shared/app_motion.dart';
import '../files/files_page.dart';
import '../library_builder/library_workspace_page.dart';
import '../public_library/public_library.dart';
import '../recycle/recycle_page.dart';
import '../settings/settings_page.dart';
import '../transfers/transfers_page.dart';

enum _ShellDestination {
  files(Icons.folder_outlined, Icons.folder, '文件'),
  recycle(Icons.delete_outline, Icons.delete, '回收站'),
  transfers(Icons.swap_vert_outlined, Icons.swap_vert, '传输'),
  library(Icons.apps_outlined, Icons.apps, '软件库'),
  settings(Icons.settings_outlined, Icons.settings, '设置');

  const _ShellDestination(this.icon, this.selectedIcon, this.label);

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  NavigationDestination get compactDestination => NavigationDestination(
    icon: Icon(icon),
    selectedIcon: Icon(selectedIcon),
    label: label,
  );

  NavigationRailDestination get railDestination => NavigationRailDestination(
    icon: Icon(icon),
    selectedIcon: Icon(selectedIcon),
    label: Text(label),
  );
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
  _ShellDestination _destination = _ShellDestination.files;
  late final RecycleController _recycleController;
  PublicLibraryController? _publicLibraryController;
  late final List<_ShellDestination> _destinations;
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _recycleController = RecycleController(
      cloudService: widget.appController.cloudService,
      onSessionExpired: widget.appController.expireSession,
    );
    final publicLibraryCore = widget.publicLibraryCore;
    _publicLibraryController = publicLibraryCore == null
        ? null
        : PublicLibraryController(core: publicLibraryCore);
    _destinations = <_ShellDestination>[
      _ShellDestination.files,
      _ShellDestination.recycle,
      _ShellDestination.transfers,
      if (_publicLibraryController != null) _ShellDestination.library,
      _ShellDestination.settings,
    ];
    _pages = <Widget>[
      FilesPage(
        key: const ValueKey('files'),
        appController: widget.appController,
        transferController: widget.transferController,
        onShowTransfers: () =>
            _selectDestinationValue(_ShellDestination.transfers),
      ),
      RecyclePage(
        key: const ValueKey('recycle'),
        controller: _recycleController,
      ),
      TransfersPage(
        key: const ValueKey('transfers'),
        controller: widget.transferController,
      ),
      if (_publicLibraryController != null)
        LibraryWorkspacePage(
          key: const ValueKey('public-library'),
          cloudService: widget.appController.cloudService,
          publicLibraryController: _publicLibraryController!,
        ),
      SettingsPage(
        key: const ValueKey('settings'),
        controller: widget.appController,
        publicLibraryCore: widget.publicLibraryCore,
        sourceRegistryCore: widget.sourceRegistryCore,
      ),
    ];
  }

  void _selectDestination(int value) {
    final destination = _destinations[value];
    _selectDestinationValue(destination);
  }

  void _selectDestinationValue(_ShellDestination destination) {
    if (destination == _destination) return;
    setState(() => _destination = destination);
  }

  @override
  void dispose() {
    _recycleController.dispose();
    _publicLibraryController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = AppMotionPageStack(
      index: _destinations.indexOf(_destination),
      children: _pages,
    );

    return FocusTraversalGroup(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 768;
          if (!wide) {
            return Scaffold(
              body: page,
              bottomNavigationBar: NavigationBar(
                key: const Key('compact-navigation'),
                selectedIndex: _destinations.indexOf(_destination),
                onDestinationSelected: _selectDestination,
                destinations: _destinations
                    .map((destination) => destination.compactDestination)
                    .toList(growable: false),
              ),
            );
          }
          final extended = constraints.maxWidth >= 1200;
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  key: const Key('wide-navigation'),
                  selectedIndex: _destinations.indexOf(_destination),
                  extended: extended,
                  labelType: extended
                      ? NavigationRailLabelType.none
                      : NavigationRailLabelType.all,
                  onDestinationSelected: _selectDestination,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Icon(
                      Icons.cloud_outlined,
                      color: Theme.of(context).colorScheme.primary,
                      semanticLabel: 'LanzouYOU',
                    ),
                  ),
                  destinations: _destinations
                      .map((destination) => destination.railDestination)
                      .toList(growable: false),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: page),
              ],
            ),
          );
        },
      ),
    );
  }
}
