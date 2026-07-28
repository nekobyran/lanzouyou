import 'package:flutter/material.dart';

import '../config/library_config.dart';
import '../pages/library/library_page.dart';
import '../repositories/library_remote_content_repository.dart';
import '../services/download_coordinator.dart';
import '../services/library_core.dart';
import '../services/link_opener.dart';
import '../services/rust_library_core.dart';
import '../shared/app_theme.dart';

class LibraryShellApp extends StatelessWidget {
  factory LibraryShellApp.production({
    Key? key,
    required LibraryConfig config,
  }) {
    final core = RustLibraryCore.production();
    return LibraryShellApp._(
      key: key,
      config: config,
      core: core,
      linkOpener: const UrlLauncherLinkOpener(),
      remoteContent: CachedLibraryRemoteContentRepository.production(
        core: core,
      ),
      downloads: config.features.download
          ? DownloadCoordinator.production(core: core)
          : null,
    );
  }

  factory LibraryShellApp.testHarness({
    Key? key,
    required LibraryConfig config,
    required LibraryCore core,
    required LinkOpener linkOpener,
    LibraryRemoteContentRepository remoteContent =
        const UnavailableLibraryRemoteContentRepository(),
    DownloadCoordinator? downloads,
  }) {
    if (config.features.download && downloads == null) {
      throw ArgumentError.value(downloads, 'downloads', '启用下载功能时必须注入真实或测试下载服务');
    }
    return LibraryShellApp._(
      key: key,
      config: config,
      core: core,
      linkOpener: linkOpener,
      remoteContent: remoteContent,
      downloads: downloads,
    );
  }

  const LibraryShellApp._({
    super.key,
    required this.config,
    required this.core,
    required this.linkOpener,
    required this.remoteContent,
    required this.downloads,
  });

  final LibraryConfig config;
  final LibraryCore core;
  final LinkOpener linkOpener;
  final LibraryRemoteContentRepository remoteContent;
  final DownloadCoordinator? downloads;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: config.identity.displayName,
      theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
      darkTheme: buildLibraryTheme(config.branding.seedColor, Brightness.dark),
      themeMode: config.branding.themeMode.material,
      home: LibraryPage(
        config: config,
        core: core,
        linkOpener: linkOpener,
        remoteContent: remoteContent,
        downloads: downloads,
      ),
    );
  }
}

class LibraryConfigErrorApp extends StatelessWidget {
  const LibraryConfigErrorApp({super.key, required this.error});

  final LibraryConfigException error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildLibraryTheme(const Color(0xFF2563EB), Brightness.light),
      darkTheme: buildLibraryTheme(const Color(0xFF2563EB), Brightness.dark),
      home: Scaffold(
        appBar: AppBar(
          title: Text(
            error.kind == LibraryConfigErrorKind.unconfiguredTemplate
                ? '软件库尚未生成'
                : '软件库配置错误',
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    error.kind == LibraryConfigErrorKind.unconfiguredTemplate
                        ? Icons.inventory_2_outlined
                        : Icons.data_object_outlined,
                    size: 48,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    error.message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
