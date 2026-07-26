import 'package:flutter/material.dart';

import 'config/library_config.dart';
import 'pages/library/library_page.dart';
import 'services/library_core.dart';
import 'services/link_opener.dart';
import 'services/rust_library_core.dart';
import 'shared/app_theme.dart';

export 'config/library_config.dart';
export 'models/library_item.dart';
export 'models/source_registry.dart';
export 'pages/sources/source_registry_controller.dart';
export 'pages/sources/source_registry_page.dart';
export 'services/library_core.dart';
export 'services/link_opener.dart';
export 'services/source_registry_core.dart';

/// Embeds the production software-library experience in an existing app.
///
/// Unlike [LibraryShellApp], this entry deliberately does not create another
/// MaterialApp or Navigator. The host owns routing while this widget reuses the
/// exact production [LibraryPage], controller and Rust core pipeline.
class EmbeddedLibraryPreview extends StatelessWidget {
  factory EmbeddedLibraryPreview.production({
    Key? key,
    required LibraryConfig config,
  }) {
    _requireSafePreviewConfig(config);
    return EmbeddedLibraryPreview._(
      key: key,
      config: config,
      core: RustLibraryCore.production(),
      linkOpener: const UrlLauncherLinkOpener(),
    );
  }

  factory EmbeddedLibraryPreview.testHarness({
    Key? key,
    required LibraryConfig config,
    required LibraryCore core,
    required LinkOpener linkOpener,
  }) {
    _requireSafePreviewConfig(config);
    return EmbeddedLibraryPreview._(
      key: key,
      config: config,
      core: core,
      linkOpener: linkOpener,
    );
  }

  const EmbeddedLibraryPreview._({
    super.key,
    required this.config,
    required this.core,
    required this.linkOpener,
  });

  final LibraryConfig config;
  final LibraryCore core;
  final LinkOpener linkOpener;

  @override
  Widget build(BuildContext context) {
    final brightness = switch (config.branding.themeMode) {
      LibraryThemeMode.system => MediaQuery.platformBrightnessOf(context),
      LibraryThemeMode.light => Brightness.light,
      LibraryThemeMode.dark => Brightness.dark,
    };
    final theme = buildLibraryTheme(config.branding.seedColor, brightness);
    return Theme(
      data: theme,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _PreviewModeBar(),
            Expanded(
              child: Builder(
                builder: (context) => MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: LibraryPage(
                    config: config,
                    core: core,
                    linkOpener: linkOpener,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewModeBar extends StatelessWidget {
  const _PreviewModeBar();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: '软件库列表预览，下载已停用',
      child: Material(
        color: colors.surfaceContainerHigh,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              IconButton(
                tooltip: '返回编辑',
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              const Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.visibility_outlined, size: 18),
                    SizedBox(width: 8),
                    Flexible(child: Text('预览模式 · 下载已停用')),
                  ],
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    );
  }
}

void _requireSafePreviewConfig(LibraryConfig config) {
  if (config.features.download) {
    throw ArgumentError.value(
      config.features.download,
      'config.features.download',
      '嵌入式预览必须停用下载',
    );
  }
}
