import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/app/library_shell_app.dart';
import 'package:lanzou_library_shell/config/library_config.dart';
import 'package:lanzou_library_shell/services/download_coordinator.dart';
import 'package:lanzou_library_shell/services/link_opener.dart';
import 'package:lanzou_library_shell/services/rust_library_core.dart';

void main() {
  test('production app always owns the Rust core and system URL launcher', () {
    final app = LibraryShellApp.production(config: _productionShapeConfig());

    expect(app.core, isA<RustLibraryCore>());
    expect(app.linkOpener, isA<UrlLauncherLinkOpener>());
    expect(app.downloads, isA<DownloadCoordinator>());
  });

  test(
    'production app does not create a hidden download runtime when disabled',
    () {
      final app = LibraryShellApp.production(
        config: _productionShapeConfig(download: false),
      );

      expect(app.core, isA<RustLibraryCore>());
      expect(app.downloads, isNull);
    },
  );

  test(
    'default main and maintainer template builds cannot reach UI harnesses',
    () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      final appSource = File(
        'lib/app/library_shell_app.dart',
      ).readAsStringSync();
      final templateBuildSource = File(
        '../../command/Build-LanzouLibraryTemplates.ps1',
      ).readAsStringSync();

      expect(mainSource, contains('LibraryConfigLoader.embeddedRuntime()'));
      expect(mainSource, contains('LibraryShellApp.production('));
      expect(mainSource, isNot(contains('testHarness')));
      expect(mainSource, isNot(contains('tool/')));
      expect(mainSource, isNot(contains('fixture')));
      expect(appSource, contains('RustLibraryCore.production()'));
      expect(appSource, contains('UrlLauncherLinkOpener()'));
      expect(templateBuildSource, isNot(contains('library_shell_preview')));
      expect(templateBuildSource, isNot(contains("'tool/")));
      expect(templateBuildSource, contains("'build', 'apk', '--release'"));
      expect(templateBuildSource, contains("'build', 'windows', '--release'"));
    },
  );

  test('maintainer runtime asset is data-free until repackage replaces it', () {
    final runtimeAsset = File('assets/runtime/library.json').readAsStringSync();

    expect(runtimeAsset, contains('"schemaVersion": 0'));
    expect(runtimeAsset, contains('"templateState": "requiresGeneration"'));
    expect(runtimeAsset, isNot(contains('identity')));
    expect(runtimeAsset, isNot(contains('sources')));
    expect(runtimeAsset, isNot(contains('http')));
    expect(runtimeAsset, isNot(contains('example')));
  });

  test(
    'Android manifest can hand downloaded APKs to the package installer',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();

      expect(manifest, contains('android.permission.REQUEST_INSTALL_PACKAGES'));
      expect(
        manifest,
        isNot(contains('android.permission.MANAGE_EXTERNAL_STORAGE')),
      );
    },
  );

  testWidgets('unconfigured template renders a generation-required state', (
    tester,
  ) async {
    await tester.pumpWidget(
      const LibraryConfigErrorApp(
        error: LibraryConfigException.unconfiguredTemplate(),
      ),
    );

    expect(find.text('软件库尚未生成'), findsOneWidget);
    expect(find.text('请通过 LanzouYOU 生成软件库后再打开'), findsOneWidget);
    expect(find.text('软件库配置错误'), findsNothing);
  });
}

LibraryConfig _productionShapeConfig({bool download = true}) =>
    LibraryConfig.fromJson({
      'schemaVersion': 1,
      'identity': {
        'projectId': 'runtime_contract',
        'displayName': '入口契约',
        'applicationId': 'cc.nkbr.runtimecontract',
        'versionName': '1.0.0',
        'versionCode': 1,
        'windowsExeName': 'runtime_contract',
      },
      'branding': {
        'seedColor': '#2563EB',
        'themeMode': 'system',
        'officialUrl': '',
        'publisher': '',
        'logoAsset': 'assets/runtime/logo.png',
      },
      'sources': [
        {
          'sourceId': 'runtime_source',
          'title': '正式数据源',
          'shareUrl': 'https://www.lanzouw.com/bruntime',
          'password': '',
          'searchable': true,
          'recommended': true,
        },
      ],
      'features': {
        'browse': true,
        'search': true,
        'download': download,
        'showDescription': true,
      },
    });
