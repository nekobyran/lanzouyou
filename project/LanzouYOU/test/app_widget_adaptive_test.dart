import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/app/lanzou_you_app.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('wide rail selects the real software library destination', (
    tester,
  ) async {
    await _setSurface(tester, const Size(1100, 800));
    await tester.pumpWidget(
      LanzouYouApp(
        cloudService: FakeCloudService(),
        publicLibraryCore: FakePublicLibraryCatalogCore(),
        sessionStore: MemorySessionStore(cookie: 'restored-test-cookie'),
        settingsStore: MemoryAppSettingsStore(),
      ),
    );
    await tester.pumpAndSettle();

    final rail = find.byKey(const Key('wide-navigation'));
    final libraryDestination = find.descendant(
      of: rail,
      matching: find.text('软件库'),
    );
    expect(libraryDestination, findsOneWidget);

    await tester.tap(libraryDestination);
    await tester.pumpAndSettle();

    final navigationRail = tester.widget<NavigationRail>(rail);
    expect(navigationRail.destinations, hasLength(8));
    expect(navigationRail.selectedIndex, 6);
    expect(find.byKey(const Key('public-library-root')), findsOneWidget);
    expect(find.byKey(const Key('public-library-detail-pane')), findsOneWidget);
    expect(find.text('真实公开来源'), findsOneWidget);
  });

  testWidgets('navigation changes at 768 and extends at 1200 logical pixels', (
    tester,
  ) async {
    await _setSurface(tester, const Size(767, 800));
    await tester.pumpWidget(
      LanzouYouApp(
        cloudService: FakeCloudService(),
        publicLibraryCore: FakePublicLibraryCatalogCore(),
        sessionStore: MemorySessionStore(cookie: 'restored-test-cookie'),
        settingsStore: MemoryAppSettingsStore(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('compact-navigation')), findsOneWidget);

    tester.view.physicalSize = const Size(801, 800);
    await tester.pumpAndSettle();
    var rail = tester.widget<NavigationRail>(
      find.byKey(const Key('wide-navigation')),
    );
    expect(rail.extended, isFalse);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    rail = tester.widget<NavigationRail>(
      find.byKey(const Key('wide-navigation')),
    );
    expect(rail.extended, isTrue);
  });

  testWidgets('settings index remains a direct one-entry list at high scale', (
    tester,
  ) async {
    await _setSurface(tester, const Size(320, 640));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: LanzouYouApp(
          cloudService: FakeCloudService(),
          publicLibraryCore: FakePublicLibraryCatalogCore(),
          sessionStore: MemorySessionStore(cookie: 'restored-test-cookie'),
          settingsStore: MemoryAppSettingsStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _tapCompactDestination(tester, '设置');

    expect(find.byKey(const Key('settings-list')), findsOneWidget);
    expect(find.byKey(const Key('lanzou-settings-entry')), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.byKey(const Key('theme-mode-selector')), findsNothing);
    expect(find.byKey(const Key('library-builder-entry')), findsNothing);
    expect(tester.takeException(), isNull);
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
