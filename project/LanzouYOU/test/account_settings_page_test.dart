import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/controllers/app_controller.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/pages/settings/account_settings_page.dart';
import 'package:lanzouyou/services/cloud_service.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'membership entry opens a native page before any external launch',
    (tester) async {
      await _resetAccountHarness(tester);
      Uri? launched;
      final controller = await _signedInController();
      addTearDown(controller.dispose);

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

      await tester.tap(find.byKey(const Key('account-destination-membership')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('membership-recharge-detail')),
        findsOneWidget,
      );
      expect(find.byType(RadioListTile<String>), findsNWidgets(3));
      expect(
        find.byKey(const Key('official-portal-confirmation')),
        findsNothing,
      );
      expect(launched, isNull);
    },
  );

  testWidgets('membership plan selection and confirmation precede launch', (
    tester,
  ) async {
    Uri? launched;
    final controller = await _signedInController();
    addTearDown(controller.dispose);
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

    await tester.tap(find.byKey(const Key('account-destination-membership')));
    await tester.pumpAndSettle();
    final continueButton = find.byKey(
      const Key('continue-membership-purchase'),
    );
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

    await tester.tap(find.byKey(const Key('membership-plan-monthly')));
    await tester.pumpAndSettle();
    final membershipScrollable = find
        .descendant(
          of: find.byKey(const Key('membership-recharge-detail')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      continueButton,
      220,
      scrollable: membershipScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(continueButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('official-portal-confirmation')),
      findsOneWidget,
    );
    expect(find.text('前往蓝奏云官方会员页面？'), findsOneWidget);
    expect(find.textContaining('不会自动购买'), findsOneWidget);
    expect(launched, isNull);

    await tester.tap(find.byKey(const Key('confirm-official-portal')));
    await tester.pumpAndSettle();
    expect(launched?.host, 'pc.woozooo.com');
    expect(launched?.queryParameters['action'], 'huiyuan');
  });

  testWidgets('personalization page exposes all 11 native read-only items', (
    tester,
  ) async {
    final controller = await _signedInController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: AccountSettingsPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('account-destination-personalization')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('personalization-settings-detail')),
      findsOneWidget,
    );
    expect(find.text('个性化项目（11 项）'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);

    await tester.drag(
      find.byKey(const Key('personalization-settings-detail')),
      const Offset(0, -760),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('personalization-directLinkDomain')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('personalization-detail-directLinkDomain')),
      findsOneWidget,
    );
    expect(find.text('应用内只读'), findsOneWidget);
    expect(find.text('当前值未知'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('master list restores every official personal-center entry', (
    tester,
  ) async {
    final controller = await _signedInController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: AccountSettingsPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    const entryIds = <String>[
      'permissions',
      'balance',
      'fileUpgrade',
      'downloadCashout',
      'cashoutRecords',
      'invite',
      'password',
      'phone',
      'closeAccount',
    ];
    for (final id in entryIds) {
      final destination = find.byKey(Key('account-destination-entry-$id'));
      for (
        var attempt = 0;
        attempt < 12 && destination.evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(
          find.byKey(const Key('account-center-master-list')),
          const Offset(0, -240),
        );
        await tester.pumpAndSettle();
      }
      expect(destination, findsOneWidget);
    }
    expect(
      find.byKey(const Key('account-destination-entry-closeAccount')),
      findsOneWidget,
    );
  });

  for (final stateCase in <({MembershipState state, String expected, Key key})>[
    (
      state: MembershipState.vip,
      expected: '黄金 VIP',
      key: const Key('membership-state-vip'),
    ),
    (
      state: MembershipState.free,
      expected: '免费用户',
      key: const Key('membership-state-free'),
    ),
    (
      state: MembershipState.unknown,
      expected: '会员状态未知',
      key: const Key('membership-state-unknown'),
    ),
  ]) {
    testWidgets('renders real ${stateCase.state.name} membership state', (
      tester,
    ) async {
      final controller = await _signedInController(state: stateCase.state);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: AccountSettingsPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(stateCase.key), findsOneWidget);
      expect(find.text(stateCase.expected), findsOneWidget);
      if (stateCase.state == MembershipState.vip) {
        expect(find.text('有效期至 2027-08-31'), findsOneWidget);
      }
      if (stateCase.state == MembershipState.unknown) {
        expect(find.text('官方未返回会员标识'), findsOneWidget);
      }
    });
  }

  testWidgets(
    'narrow high-scale master pushes a scrollable native detail without overflow',
    (tester) async {
      await _resetAccountHarness(tester);
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

      expect(find.byKey(const Key('account-wide-master-detail')), findsNothing);
      await tester.drag(
        find.byKey(const Key('account-center-master-list')),
        const Offset(0, -460),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-destination-membership')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('membership-recharge-detail')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide layout keeps master list and replaces full detail pane', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final controller = await _signedInController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: AccountSettingsPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account-wide-master-detail')), findsOneWidget);
    expect(find.byKey(const Key('account-overview-detail')), findsOneWidget);
    await tester.tap(find.byKey(const Key('account-destination-membership')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-center-master-list')), findsOneWidget);
    expect(find.byKey(const Key('membership-recharge-detail')), findsOneWidget);
    expect(find.byKey(const Key('account-overview-detail')), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
  });

  testWidgets('capability load error has retry', (tester) async {
    await _resetAccountHarness(tester);
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

    cloud.accountCapabilitiesFailure = null;
    await tester.tap(find.byKey(const Key('retry-account-capabilities')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-center-master-list')), findsOneWidget);
  });

  testWidgets('real balance entry shows payment warning before launch', (
    tester,
  ) async {
    Uri? launched;
    final controller = await _signedInController();
    addTearDown(controller.dispose);
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
    final destination = find.byKey(
      const Key('account-destination-entry-balance'),
    );
    await tester.drag(
      find.byKey(const Key('account-center-master-list')),
      const Offset(0, -360),
    );
    await tester.pumpAndSettle();
    await tester.tap(destination);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-account-entry-balance')));
    await tester.pumpAndSettle();

    expect(find.textContaining('这是付款或资金相关操作'), findsOneWidget);
    expect(
      find.byKey(const Key('official-portal-confirmation')),
      findsOneWidget,
    );
    expect(launched, isNull);
  });

  testWidgets('untrusted external URL is blocked before confirmation', (
    tester,
  ) async {
    Uri? launched;
    final capabilities = _capabilities().copyWithEntries(<AccountEntry>[
      AccountEntry(
        id: 'permissions',
        title: '我的权限',
        description: '查看真实权限',
        portalUrl: Uri.parse(
          'https://pc.woozooo.com/not-official?item=profile&action=mypower',
        ),
        available: true,
        requiresOfficialConfirmation: true,
        dangerous: false,
      ),
    ]);
    final controller = await _signedInController(capabilities: capabilities);
    addTearDown(controller.dispose);
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
    await tester.drag(
      find.byKey(const Key('account-center-master-list')),
      const Offset(0, -360),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('account-destination-entry-permissions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-account-entry-permissions')));
    await tester.pumpAndSettle();

    expect(find.text('已阻止非蓝奏云官方页面'), findsOneWidget);
    expect(find.byKey(const Key('official-portal-confirmation')), findsNothing);
    expect(launched, isNull);
  });
}

Future<void> _resetAccountHarness(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 20));
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

Future<AppController> _signedInController({
  MembershipState state = MembershipState.vip,
  AccountCapabilities? capabilities,
}) async {
  final cloud = FakeCloudService()
    ..accountCapabilitiesResult =
        capabilities ?? _capabilities(membershipState: state);
  final controller = AppController(
    cloudService: cloud,
    sessionStore: MemorySessionStore(),
    settingsStore: MemoryAppSettingsStore(),
  );
  await controller.login('test-account', 'test-password');
  return controller;
}

AccountCapabilities _capabilities({
  MembershipState membershipState = MembershipState.vip,
}) {
  final accountPortal = Uri.parse(
    'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower',
  );
  final membershipPortal = Uri.parse(
    'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
  );
  return AccountCapabilities(
    authenticated: true,
    userId: 'member-user',
    accountPortalUrl: accountPortal,
    membershipPortalUrl: membershipPortal,
    personalizationPortalUrl: membershipPortal,
    membershipProfile: MembershipProfile(
      state: membershipState,
      displayName: 'member-user',
      level: membershipState == MembershipState.vip ? '黄金 VIP' : null,
      expiresAt: membershipState == MembershipState.vip
          ? DateTime.utc(2027, 8, 31)
          : null,
      reason: membershipState == MembershipState.unknown
          ? '官方未返回会员标识'
          : '官方账号页已验证',
    ),
    entries: <AccountEntry>[
      _entry('permissions', '我的权限', accountPortal),
      _entry(
        'balance',
        '财务充值',
        Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=goods',
        ),
      ),
      _entry(
        'fileUpgrade',
        '文件升级',
        Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=buygoods',
        ),
      ),
      _entry(
        'downloadCashout',
        '下载提现',
        Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=exchange',
        ),
      ),
      _entry(
        'cashoutRecords',
        '提现记录',
        Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=orders',
        ),
      ),
      _entry(
        'invite',
        '邀请注册',
        Uri.parse('https://pc.woozooo.com/mydisk.php?item=buddy&action=invite'),
      ),
      _entry(
        'password',
        '密码修改',
        Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=password',
        ),
      ),
      _entry('phone', '手机号', accountPortal),
      _entry('closeAccount', '注销账户', accountPortal, dangerous: true),
    ],
    facts: const <AccountFact>[
      AccountFact(
        id: 'max_file_size',
        label: '单个文件大小',
        value: '100 MB',
        known: true,
      ),
      AccountFact(id: 'storage', label: '云存储统计', value: null, known: false),
    ],
    plans: const <MembershipPlan>[
      MembershipPlan(
        id: 'monthly',
        label: '包月',
        detail: '会员增值服务与会员个性化权益',
        priceLabel: '官方价格',
        available: true,
      ),
      MembershipPlan(
        id: 'yearly',
        label: '包年',
        detail: '按年续费或升级会员',
        priceLabel: '官方价格',
        available: true,
      ),
      MembershipPlan(
        id: 'downloadPack',
        label: '下载包',
        detail: '独立下载流量权益',
        priceLabel: '官方价格',
        available: true,
      ),
    ],
    personalization: _personalizationSettings(),
    acceptsPaymentData: false,
  );
}

AccountEntry _entry(
  String id,
  String title,
  Uri uri, {
  bool dangerous = false,
}) {
  return AccountEntry(
    id: id,
    title: title,
    description: '$title的真实状态与官方操作入口',
    portalUrl: uri,
    available: true,
    requiresOfficialConfirmation: true,
    dangerous: dangerous,
  );
}

List<PersonalizationSetting> _personalizationSettings() {
  const definitions = <(String, String)>[
    ('adFreeDownloads', '免广告下载'),
    ('uploadTimeVisibility', '上传时间隐藏/显示'),
    ('subfolders', '子文件夹'),
    ('search', '搜索'),
    ('defaultFilePassword', '新文件密码默认开关'),
    ('avatarUpload', '头像上传'),
    ('downloadPageTemplate', '下载页模板'),
    ('publisherNickname', '发布者昵称'),
    ('dailyDownloadReport', '日下载报表'),
    ('fileRetention', '文件保存时间'),
    ('directLinkDomain', '直链域名绑定'),
  ];
  return <PersonalizationSetting>[
    for (final definition in definitions)
      PersonalizationSetting(
        id: definition.$1,
        title: definition.$2,
        description: '${definition.$2}的官方会员个性化设置',
        available: true,
        enabled: definition.$1 == 'adFreeDownloads' ? true : null,
        value: definition.$1 == 'publisherNickname' ? '已设置' : null,
        writable: false,
        reason: '未验证应用内写入端点',
      ),
  ];
}

extension on AccountCapabilities {
  AccountCapabilities copyWithEntries(List<AccountEntry> value) {
    return AccountCapabilities(
      authenticated: authenticated,
      userId: userId,
      accountPortalUrl: accountPortalUrl,
      membershipPortalUrl: membershipPortalUrl,
      personalizationPortalUrl: personalizationPortalUrl,
      membershipProfile: membershipProfile,
      entries: value,
      facts: facts,
      plans: plans,
      personalization: personalization,
      acceptsPaymentData: acceptsPaymentData,
    );
  }
}
