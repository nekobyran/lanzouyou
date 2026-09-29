import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/app/lanzou_you_app.dart';

import 'package:lanzouyou/services/app_settings_store.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('Lanzou appearance detail persists theme and reduced motion', (
    tester,
  ) async {
    await _setSurface(tester, const Size(390, 844));
    final settings = MemoryAppSettingsStore();
    await tester.pumpWidget(
      LanzouYouApp(
        cloudService: FakeCloudService(),
        publicLibraryCore: FakePublicLibraryCatalogCore(),
        sessionStore: MemorySessionStore(cookie: 'restored-test-cookie'),
        settingsStore: settings,
      ),
    );
    await tester.pumpAndSettle();

    await _tapCompactDestination(tester, '设置');
    await tester.tap(find.byKey(const Key('lanzou-settings-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lanzou-appearance-settings')), findsOneWidget);

    await tester.tap(find.byKey(const Key('lanzou-appearance-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reduce-motion-switch')));
    await tester.pumpAndSettle();

    expect(
      settings.settings,
      const AppSettings(themeMode: ThemeMode.dark, reduceMotion: true),
    );
    expect(
      Theme.of(
        tester.element(find.byKey(const Key('appearance-settings-list'))),
      ).brightness,
      Brightness.dark,
    );
    expect(
      MediaQuery.of(
        tester.element(find.byKey(const Key('appearance-settings-list'))),
      ).disableAnimations,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });
}


Future<void> _tapCompactDestination(WidgetTester tester, String label) async {
  final navigation = find.byKey(const Key('compact-navigation'));
  final direct = find.descendant(of: navigation, matching: find.text(label));
  if (direct.evaluate().isNotEmpty) {
    await tester.tap(direct);
    await tester.pumpAndSettle();
    return;
  }
  await tester.tap(find.descendant(of: navigation, matching: find.text('更多')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 20));
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}
