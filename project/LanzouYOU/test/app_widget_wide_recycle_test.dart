import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/app/lanzou_you_app.dart';

import 'package:lanzouyou/models/cloud_item.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('wide layout uses a rail and exposes recycle/session pages', (
    tester,
  ) async {
    await _setSurface(tester, const Size(1100, 800));
    final cloud = FakeCloudService()
      ..recycleItems.add(
        const CloudItem(
          id: '9',
          name: '待恢复.zip',
          isFolder: false,
          isRecycle: true,
        ),
      );
    await tester.pumpWidget(
      LanzouYouApp(
        cloudService: cloud,
        publicLibraryCore: FakePublicLibraryCatalogCore(),
        sessionStore: MemorySessionStore(cookie: 'restored-test-cookie'),
        settingsStore: MemoryAppSettingsStore(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wide-navigation')), findsOneWidget);
    expect(find.byKey(const Key('compact-navigation')), findsNothing);

    final rail = find.byKey(const Key('wide-navigation'));
    await tester.tap(find.descendant(of: rail, matching: find.text('回收站')));
    await tester.pumpAndSettle();
    expect(find.text('待恢复.zip'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recycle-item-9')));
    await tester.pumpAndSettle();
    expect(find.text('恢复到根目录'), findsOneWidget);
    await tester.tap(find.text('恢复到根目录'));
    await tester.pumpAndSettle();
    expect(find.text('已恢复 1 项到根目录'), findsOneWidget);

    await tester.tap(find.descendant(of: rail, matching: find.text('设置')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lanzou-settings-entry')), findsOneWidget);
    expect(find.byKey(const Key('theme-mode-selector')), findsNothing);
    expect(find.byKey(const Key('reduce-motion-switch')), findsNothing);
    expect(find.byKey(const Key('library-builder-entry')), findsNothing);
    expect(find.text('来源概览、外观与账号会员'), findsOneWidget);
    expect(find.textContaining('用户 ID test-user-id'), findsNothing);

    await tester.tap(find.byKey(const Key('lanzou-settings-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lanzou-settings-page')), findsOneWidget);
    expect(find.text('597 个官方来源 · 9 个合集'), findsOneWidget);
    await tester.tap(find.text('账号与会员'));
    await tester.pumpAndSettle();
    expect(find.text('个人中心'), findsOneWidget);
    expect(find.byKey(const Key('logout-tile')), findsOneWidget);
    expect(find.text('Rust 文件核心'), findsNothing);
    expect(find.textContaining('系统安全存储'), findsNothing);
    expect(find.text('自定义图标'), findsNothing);
  });
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
