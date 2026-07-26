import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/settings_preview.dart' as settings_preview;

void main() {
  test('production Dart graph cannot import tool or test harnesses', () {
    final lib = Directory('lib');
    final directives = RegExp(
      r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
      multiLine: true,
    );
    final violations = <String>[];

    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final match in directives.allMatches(source)) {
        final uri = match.group(1)!.replaceAll('\\', '/');
        if (uri.startsWith('../tool/') ||
            uri.startsWith('../test/') ||
            uri.contains('/tool/') ||
            uri.contains('/test/')) {
          violations.add('${entity.path}:$uri');
        }
      }
    }

    expect(violations, isEmpty);
    expect(
      File('lib/main.dart').readAsStringSync(),
      isNot(contains('preview')),
    );
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('LanzouYouApp.production()'),
    );
    final appSource = File('lib/app/lanzou_you_app.dart').readAsStringSync();
    expect(appSource, contains('factory LanzouYouApp.production'));
    expect(appSource, contains('RustPublicLibraryCatalogCore'));
    expect(appSource, contains('cloudService.dispatchRaw'));
  });

  test('settings preview is debug-only and uses isolated memory harnesses', () {
    final source = File('tool/settings_preview.dart').readAsStringSync();

    expect(source, contains('if (kReleaseMode)'));
    expect(source, contains('LanzouYouApp('));
    expect(source, contains('implements AppSettingsStore'));
    expect(source, contains('implements SessionStore'));
    expect(source, contains('implements CloudService'));
    expect(source, contains('userId: null'));
    expect(source, isNot(contains('RustCloudService')));
    expect(source, isNot(contains('SecureSessionStore')));
    expect(source, isNot(contains('FileAppSettingsStore')));
    expect(source, isNot(contains('test-password')));
    expect(source, isNot(contains(RegExp(r'Bearer\s|Cookie:|token='))));
    final urls = RegExp(r'https://[^\s]+').allMatches(source);
    expect(urls, isNotEmpty);
    expect(
      urls.every(
        (match) => match.group(0)!.startsWith('https://pc.woozooo.com/'),
      ),
      isTrue,
    );
  });

  testWidgets('settings preview selects its label on compact and wide shells', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    settings_preview.main();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('compact-navigation'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const Key('lanzou-settings-page')), findsOneWidget);
    expect(find.text('597 个官方来源 · 9 个合集'), findsOneWidget);
    expect(find.byKey(const Key('lanzou-appearance-settings')), findsOneWidget);
    expect(find.byKey(const Key('lanzou-account-settings')), findsOneWidget);
    expect(find.byKey(const Key('theme-mode-selector')), findsNothing);
    expect(find.byKey(const Key('reduce-motion-switch')), findsNothing);
    expect(find.textContaining('用户 ID'), findsNothing);

    await tester.tap(find.byKey(const Key('lanzou-account-settings')));
    await tester.pumpAndSettle();
    expect(find.text('蓝奏账号会话'), findsOneWidget);
    expect(find.byKey(const Key('logout-tile')), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(1100, 800));
    settings_preview.main();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('wide-navigation'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('lanzou-settings-wide-master-detail')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('lanzou-appearance-settings')), findsOneWidget);
    expect(find.text('来源概览'), findsWidgets);
    expect(find.byKey(const Key('theme-mode-selector')), findsNothing);
    expect(find.byKey(const Key('reduce-motion-switch')), findsNothing);
    expect(find.textContaining('用户 ID'), findsNothing);
  });
}
