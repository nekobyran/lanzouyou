import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/controllers/app_controller.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/pages/settings/account_settings_page.dart';
import 'package:lanzouyou/services/cloud_service.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'shows only real official account capabilities without fake toggles',
    (tester) async {
      final controller = await _signedInController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: AccountSettingsPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('account-capabilities-content')),
        findsOneWidget,
      );
      expect(find.text('文件大小与云空间统计'), findsOneWidget);
      expect(find.text('会员购买与续费'), findsOneWidget);
      expect(find.text('发布者昵称'), findsOneWidget);
      expect(find.byKey(const Key('open-membership-portal')), findsOneWidget);
      expect(
        find.byKey(const Key('open-personalization-portal')),
        findsOneWidget,
      );
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.textContaining('应用不会读取或提交付款信息'), findsOneWidget);
    },
  );

  testWidgets(
    'official membership action requires confirmation and external launch',
    (tester) async {
      final controller = await _signedInController();
      addTearDown(controller.dispose);
      Uri? launched;
      await tester.pumpWidget(
        MaterialApp(
          home: AccountSettingsPage(
            controller: controller,
            launchOfficialUrl: (uri) async {
              launched = uri;
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('open-membership-portal')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('official-portal-confirmation')),
        findsOneWidget,
      );
      expect(find.text('前往蓝奏云官方会员页面？'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('official-portal-confirmation')),
          matching: find.textContaining('付款确认只在蓝奏云官方页面完成'),
        ),
        findsOneWidget,
      );
      expect(launched, isNull);

      await tester.tap(find.byKey(const Key('confirm-official-portal')));
      await tester.pumpAndSettle();
      expect(launched?.scheme, 'https');
      expect(launched?.host, 'pc.woozooo.com');
      expect(launched?.queryParameters['action'], 'huiyuan');
    },
  );

  testWidgets('capability load error has a real retry path', (tester) async {
    final cloud = FakeCloudService()
      ..accountCapabilitiesFailure = const CloudFailure(
        'temporary_failure',
        '账号能力暂时不可用',
        retriable: true,
      );
    final controller = AppController(
      cloudService: cloud,
      sessionStore: MemorySessionStore(),
      settingsStore: MemoryAppSettingsStore(),
    );
    addTearDown(controller.dispose);
    await controller.login('test-account', 'test-password');

    await tester.pumpWidget(
      MaterialApp(home: AccountSettingsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-capabilities-error')), findsOneWidget);
    expect(find.text('账号能力暂时不可用'), findsOneWidget);

    cloud.accountCapabilitiesFailure = null;
    await tester.tap(find.byKey(const Key('retry-account-capabilities')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('account-capabilities-content')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('account-capabilities-error')), findsNothing);
  });

  testWidgets('official portal launch failure stays recoverable', (
    tester,
  ) async {
    final controller = await _signedInController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AccountSettingsPage(
          controller: controller,
          launchOfficialUrl: (_) => throw StateError('platform unavailable'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-account-portal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-official-portal')));
    await tester.pumpAndSettle();

    expect(find.text('无法打开蓝奏云官方页面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow high-scale account page remains scrollable without overflow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final controller = await _signedInController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: AccountSettingsPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('account-capabilities-content')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byKey(const Key('account-capabilities-content')),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      expect(find.text('付款安全'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<AppController> _signedInController() async {
  final cloud = FakeCloudService()
    ..accountCapabilitiesResult = AccountCapabilities(
      authenticated: true,
      userId: 'member-user',
      accountPortalUrl: Uri.parse(
        'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower',
      ),
      accountFeatures: const <String>['文件大小与云空间统计', '上传格式权限'],
      membership: RemoteCapability(
        state: 'available',
        portalUrl: Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
        ),
        reason: '由蓝奏云官方页面管理',
        readable: false,
        writable: false,
        features: const <String>['会员购买与续费', '下载流量包'],
      ),
      personalization: RemoteCapability(
        state: 'available',
        portalUrl: Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
        ),
        reason: '由蓝奏云官方页面管理',
        readable: false,
        writable: false,
        features: const <String>['发布者昵称', '文件头像', '下载页模板'],
      ),
      acceptsPaymentData: false,
    );
  final controller = AppController(
    cloudService: cloud,
    sessionStore: MemorySessionStore(),
    settingsStore: MemoryAppSettingsStore(),
  );
  await controller.login('test-account', 'test-password');
  return controller;
}
