import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lanzou_library_shell/library_preview.dart';

import '../controllers/app_controller.dart';
import '../controllers/transfer_controller.dart';
import '../pages/home/navigation_shell.dart';
import '../pages/public_library/public_library_core.dart';
import '../services/app_settings_store.dart';
import '../services/cloud_service.dart';
import '../services/rust_cloud_service.dart';
import '../services/rust_public_library_catalog_core.dart';
import '../services/rust_source_registry_core.dart';
import '../services/public_library_storage.dart';
import '../services/session_store.dart';
import '../shared/app_motion.dart';
import '../shared/app_theme.dart';
import '../shared/windows_app_shell.dart';

class LanzouYouApp extends StatefulWidget {
  const LanzouYouApp({
    required this.cloudService,
    required this.sessionStore,
    required this.settingsStore,
    this.publicLibraryCore,
    this.sourceRegistryCore,
    super.key,
  });

  /// Formal app graph: managed cloud operations and the public catalog share
  /// one persistent Rust JSON transport and therefore one native runtime.
  factory LanzouYouApp.production({Key? key}) {
    final cloudService = RustCloudService();
    final storageRoot = PublicLibraryStorageRoot();
    return LanzouYouApp(
      key: key,
      cloudService: cloudService,
      publicLibraryCore: RustPublicLibraryCatalogCore.production(
        cloudService.dispatchRaw,
        storageRootProvider: storageRoot.resolve,
      ),
      sourceRegistryCore: RustSourceRegistryCore.production(
        cloudService.dispatchRaw,
        storageRootProvider: storageRoot.resolve,
      ),
      sessionStore: const SecureSessionStore(),
      settingsStore: FileAppSettingsStore(),
    );
  }

  final CloudService cloudService;
  final SessionStore sessionStore;
  final AppSettingsStore settingsStore;
  final PublicLibraryCatalogCore? publicLibraryCore;
  final SourceRegistryCore? sourceRegistryCore;

  @override
  State<LanzouYouApp> createState() => _LanzouYouAppState();
}

class _LanzouYouAppState extends State<LanzouYouApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final AppController _appController;
  late final TransferController _transferController;

  @override
  void initState() {
    super.initState();
    _appController = AppController(
      cloudService: widget.cloudService,
      sessionStore: widget.sessionStore,
      settingsStore: widget.settingsStore,
    );
    _transferController = TransferController(widget.cloudService);
    _appController.initialize();
  }

  @override
  void dispose() {
    _appController.dispose();
    _transferController.dispose();
    final cloudService = widget.cloudService;
    if (cloudService case CloudServiceLifecycle lifecycle) {
      unawaited(lifecycle.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _appController,
      builder: (context, _) => MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'LanzouYOU',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _appController.themeMode,
        builder: (context, child) {
          final media = MediaQuery.of(context);
          final reduceMotion =
              media.disableAnimations || _appController.reduceMotion;
          final content = MediaQuery(
            data: media.copyWith(disableAnimations: reduceMotion),
            child: child ?? const SizedBox.shrink(),
          );
          return AppMotionScope(
            reduceMotion: _appController.reduceMotion,
            child: AppWindowsShell(
              navigatorKey: _navigatorKey,
              title: 'LanzouYOU',
              titleIcon: Icons.cloud_outlined,
              closeTopTransientLayer: () => false,
              child: content,
            ),
          );
        },
        home: AppMotionSwitcher(
          child: _appController.sessionStatus == SessionStatus.restoring
              ? const _RestoringPage(key: ValueKey('restoring'))
              : NavigationShell(
                  key: const ValueKey('shell'),
                  appController: _appController,
                  transferController: _transferController,
                  publicLibraryCore: widget.publicLibraryCore,
                  sourceRegistryCore: widget.sourceRegistryCore,
                ),
        ),
      ),
    );
  }
}

class _RestoringPage extends StatelessWidget {
  const _RestoringPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Semantics(
          label: '正在恢复登录状态',
          liveRegion: true,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在恢复登录状态'),
            ],
          ),
        ),
      ),
    );
  }
}
