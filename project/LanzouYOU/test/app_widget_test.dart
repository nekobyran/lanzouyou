import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/app/lanzou_you_app.dart';
import 'package:lanzouyou/controllers/app_controller.dart';
import 'package:lanzouyou/controllers/transfer_controller.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/pages/files/files_page.dart';
import 'package:lanzouyou/services/app_settings_store.dart';
import 'package:lanzouyou/services/cloud_service.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('login leads to the compact adaptive file shell', (tester) async {
    await _setSurface(tester, const Size(390, 844));
    final cloud = FakeCloudService()
      ..folders['-1'] = const <CloudItem>[
        CloudItem(id: '1', name: '资料', isFolder: true),
        CloudItem(id: '2', name: '示例.zip', isFolder: false, size: '12 MB'),
      ];

    await tester.pumpWidget(
      LanzouYouApp(
        cloudService: cloud,
        publicLibraryCore: FakePublicLibraryCatalogCore(),
        sessionStore: MemorySessionStore(),
        settingsStore: MemoryAppSettingsStore(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-button')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('account-field')),
      'test-account',
    );
    await tester.enterText(
      find.byKey(const Key('password-field')),
      'test-password',
    );
    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('compact-navigation')), findsOneWidget);
    final navigation = tester.widget<NavigationBar>(
      find.byKey(const Key('compact-navigation')),
    );
    expect(navigation.destinations, hasLength(5));
    final libraryNavigation =
        navigation.destinations[3] as NavigationDestination;
    expect(libraryNavigation.label, '软件库');
    expect((libraryNavigation.icon as Icon).icon, Icons.apps_outlined);
    expect(
      find.descendant(
        of: find.byKey(const Key('compact-navigation')),
        matching: find.text('软件库'),
      ),
      findsOneWidget,
    );
    expect(find.text('示例.zip'), findsOneWidget);

    await tester.tap(find.byKey(const Key('upload-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auto-icon-switch')), findsOneWidget);
    expect(find.text('自动获取并压缩为文件图标（<100KB）'), findsOneWidget);
    expect(
      find.byKey(const Key('one-click-apk-upload-action')),
      findsOneWidget,
    );
    expect(find.text('选择 APK，一键上传并设置图标'), findsOneWidget);
    final compatibilitySwitch = tester.widget<SwitchListTile>(
      find.byKey(const Key('force-compat-wrap-switch')),
    );
    expect(compatibilitySwitch.value, isFalse);
  });

  testWidgets('public software library is available without account login', (
    tester,
  ) async {
    await _setSurface(tester, const Size(390, 844));
    final publicCore = FakePublicLibraryCatalogCore();
    await tester.pumpWidget(
      LanzouYouApp(
        cloudService: FakeCloudService(),
        publicLibraryCore: publicCore,
        sessionStore: MemorySessionStore(),
        settingsStore: MemoryAppSettingsStore(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('browse-public-library')), findsOneWidget);
    await tester.tap(find.byKey(const Key('browse-public-library')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('public-library-root')), findsOneWidget);
    expect(find.text('597 个官方来源'), findsOneWidget);
    expect(find.text('真实公开来源'), findsOneWidget);
    expect(publicCore.calls.any((call) => call['op'] == 'page'), isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-button')), findsOneWidget);
  });

  testWidgets('test graph without public core hides the library destination', (
    tester,
  ) async {
    await _setSurface(tester, const Size(390, 844));
    await tester.pumpWidget(
      LanzouYouApp(
        cloudService: FakeCloudService(),
        sessionStore: MemorySessionStore(cookie: 'restored-test-cookie'),
        settingsStore: MemoryAppSettingsStore(),
      ),
    );
    await tester.pumpAndSettle();

    final navigation = tester.widget<NavigationBar>(
      find.byKey(const Key('compact-navigation')),
    );
    expect(navigation.destinations, hasLength(4));
    expect(
      navigation.destinations.cast<NavigationDestination>().map(
        (destination) => destination.label,
      ),
      isNot(contains('软件库')),
    );
    expect(find.text('当前安装包未包含公共软件库核心'), findsNothing);
  });

  testWidgets(
    'description dialog loads remote text and cancelling performs no write',
    (tester) async {
      await _setSurface(tester, const Size(390, 844));
      final cloud = FakeCloudService()
        ..folders['-1'] = const <CloudItem>[
          CloudItem(
            id: 'apk-1',
            name: '应用.apk',
            isFolder: false,
            description: '列表缓存的旧简介',
          ),
        ]
        ..shareDescriptions['apk-1'] = '蓝奏云当前简介'
        ..shareInfoDelay = const Duration(milliseconds: 50);

      await tester.pumpWidget(
        LanzouYouApp(
          cloudService: cloud,
          publicLibraryCore: FakePublicLibraryCatalogCore(),
          sessionStore: MemorySessionStore(cookie: 'restored-test-cookie'),
          settingsStore: MemoryAppSettingsStore(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('replace-package-menu-item')),
        findsOneWidget,
      );
      await tester.tap(find.text('编辑简介'));
      await tester.pump();
      expect(find.byKey(const Key('description-loading')), findsOneWidget);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const Key('remote-description-field')),
      );
      expect(field.controller?.text, '蓝奏云当前简介');
      expect(field.controller?.text, isNot('列表缓存的旧简介'));

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        cloud.calls.where((call) => call.startsWith('set_description:')),
        isEmpty,
      );

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑简介'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('remote-description-field')),
        '保存后的新简介',
      );
      await tester.tap(find.byKey(const Key('save-remote-description')));
      await tester.pumpAndSettle();
      expect(cloud.calls, contains('set_description:apk-1:保存后的新简介'));
      expect(
        cloud.calls.where((call) => call == 'list:-1:1').length,
        greaterThanOrEqualTo(2),
      );
    },
  );

  testWidgets('description load failure can retry without writing', (
    tester,
  ) async {
    await _setSurface(tester, const Size(1100, 800));
    final cloud = FakeCloudService()
      ..folders['-1'] = const <CloudItem>[
        CloudItem(id: 'apk-2', name: '重试.apk', isFolder: false),
      ]
      ..shareDescriptions['apk-2'] = '重试后读取的简介'
      ..getDescriptionFailure = const CloudFailure(
        'temporary_failure',
        '暂时无法读取简介',
        retriable: true,
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
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑简介'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('description-load-error')), findsOneWidget);
    expect(find.text('暂时无法读取简介'), findsOneWidget);
    expect(find.byKey(const Key('save-remote-description')), findsOneWidget);

    cloud.getDescriptionFailure = null;
    await tester.tap(find.byKey(const Key('retry-description-load')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const Key('remote-description-field')),
    );
    expect(field.controller?.text, '重试后读取的简介');
    expect(
      cloud.calls.where((call) => call.startsWith('set_description:')),
      isEmpty,
    );
  });

  testWidgets('APK menu runs the core safe replacement confirmation', (
    tester,
  ) async {
    await _setSurface(tester, const Size(390, 844));
    const oldFile = CloudItem(
      id: 'replace-apk',
      name: '保留标题.apk',
      isFolder: false,
      description: '列表缓存简介',
      hasCustomIcon: true,
    );
    final cloud = FakeCloudService()
      ..folders['-1'] = const <CloudItem>[oldFile]
      ..shareDescriptions[oldFile.id] = '蓝奏云远端简介';
    final appController = AppController(
      cloudService: cloud,
      sessionStore: MemorySessionStore(),
      settingsStore: MemoryAppSettingsStore(),
    );
    final transferController = TransferController(cloud);
    addTearDown(appController.dispose);
    addTearDown(transferController.dispose);
    await appController.login('test-account', 'test-password');

    await tester.pumpWidget(
      MaterialApp(
        home: FilesPage(
          appController: appController,
          transferController: transferController,
          onShowTransfers: () {},
          pickReplacementApk: () async => r'D:\packages\new-version.apk',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('安全换包'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('package-replace-confirmation')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('package-replace-confirmation')),
        matching: find.text('保留标题.apk'),
      ),
      findsOneWidget,
    );
    expect(find.text('蓝奏云远端简介'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('replace-auto-icon-switch')),
          )
          .value,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('confirm-package-replace')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已安全换包'), findsOneWidget);
    expect(cloud.replacements, hasLength(1));
    expect(cloud.replacements.single['oldFileId'], oldFile.id);
    expect(cloud.uploads, isEmpty);
    expect(cloud.calls.where((call) => call.startsWith('delete:')), isEmpty);
  });

  testWidgets(
    'compact software library opens the real Rust catalog and keeps state',
    (tester) async {
      await _setSurface(tester, const Size(390, 844));
      final semantics = tester.ensureSemantics();
      final publicCore = FakePublicLibraryCatalogCore();
      await tester.pumpWidget(
        LanzouYouApp(
          cloudService: FakeCloudService(),
          publicLibraryCore: publicCore,
          sessionStore: MemorySessionStore(cookie: 'restored-test-cookie'),
          settingsStore: MemoryAppSettingsStore(),
        ),
      );
      await tester.pumpAndSettle();

      final navigation = find.byKey(const Key('compact-navigation'));
      final libraryDestination = find.descendant(
        of: navigation,
        matching: find.text('软件库'),
      );
      expect(libraryDestination, findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('软件库')), findsOneWidget);
      semantics.dispose();

      await tester.tap(libraryDestination);
      await tester.pumpAndSettle();

      expect(tester.widget<NavigationBar>(navigation).selectedIndex, 3);
      expect(find.byKey(const Key('public-library-root')), findsOneWidget);
      expect(find.text('597 个官方来源'), findsOneWidget);
      expect(find.text('真实公开来源'), findsOneWidget);

      await tester.tap(find.text('真实公开来源'));
      await tester.pumpAndSettle();
      expect(find.text('真实单软件.apk'), findsOneWidget);
      expect(
        publicCore.calls.where((call) => call['op'] == 'browse'),
        hasLength(1),
      );

      await tester.tap(
        find.descendant(of: navigation, matching: find.text('文件')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('public-library-root')), findsNothing);

      await tester.tap(libraryDestination);
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationBar>(navigation).selectedIndex, 3);
      expect(find.text('真实单软件.apk'), findsOneWidget);
    },
  );

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
    expect(find.text('蓝奏账号会话'), findsOneWidget);
    expect(find.byKey(const Key('logout-tile')), findsOneWidget);
    expect(find.text('Rust 文件核心'), findsNothing);
    expect(find.textContaining('系统安全存储'), findsNothing);
    expect(find.text('自定义图标'), findsNothing);
  });

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
    expect(navigationRail.destinations, hasLength(5));
    expect(navigationRail.selectedIndex, 3);
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

    tester.view.physicalSize = const Size(768, 800);
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

    final navigation = find.byKey(const Key('compact-navigation'));
    await tester.tap(
      find.descendant(of: navigation, matching: find.text('设置')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-list')), findsOneWidget);
    expect(find.byKey(const Key('lanzou-settings-entry')), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.byKey(const Key('theme-mode-selector')), findsNothing);
    expect(find.byKey(const Key('library-builder-entry')), findsNothing);
    expect(tester.takeException(), isNull);
  });

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

    final navigation = find.byKey(const Key('compact-navigation'));
    await tester.tap(
      find.descendant(of: navigation, matching: find.text('设置')),
    );
    await tester.pumpAndSettle();
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
  });
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}
