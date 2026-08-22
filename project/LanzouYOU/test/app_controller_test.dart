import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/controllers/app_controller.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/services/app_settings_store.dart';
import 'package:lanzouyou/services/cloud_service.dart';

import 'support/fakes.dart';

void main() {
  test(
    'login stores only the returned session and loads the root folder',
    () async {
      final cloud = FakeCloudService()
        ..folders['-1'] = const <CloudItem>[
          CloudItem(id: '1', name: '文档', isFolder: true),
        ];
      final store = MemorySessionStore();
      final controller = AppController(
        cloudService: cloud,
        sessionStore: store,
        settingsStore: MemoryAppSettingsStore(),
      );

      final succeeded = await controller.login('test-account', 'test-password');

      expect(succeeded, isTrue);
      expect(store.cookie, 'test-session-cookie');
      expect(controller.sessionStatus, SessionStatus.signedIn);
      expect(controller.currentSession?.userId, 'test-user-id');
      expect(controller.items.single.name, '文档');
      expect(
        cloud.calls,
        containsAllInOrder(<String>['login', 'session_info']),
      );
    },
  );

  test(
    'login loads real account, membership and personalization capabilities',
    () async {
      final cloud = FakeCloudService()
        ..accountCapabilitiesResult = buildVipAccountCapabilitiesFixture();
      final controller = AppController(
        cloudService: cloud,
        sessionStore: MemorySessionStore(),
        settingsStore: MemoryAppSettingsStore(),
      );

      expect(await controller.login('test-account', 'test-password'), isTrue);

      expect(cloud.calls, contains('account_capabilities'));
      expect(controller.accountCapabilitiesLoading, isFalse);
      expect(controller.accountCapabilitiesError, isNull);
      expect(controller.currentAccountCapabilities?.authenticated, isTrue);
      expect(
        controller.currentAccountCapabilities?.membershipProfile.state,
        MembershipState.vip,
      );
      expect(
        controller.currentAccountCapabilities?.membershipProfile.displayName,
        '会员个性化',
      );
      expect(
        controller.currentAccountCapabilities?.membershipProfile.expiresAt,
        DateTime(2027, 7, 30),
      );
      expect(controller.currentAccountCapabilities?.plans, hasLength(7));
      expect(
        controller.currentAccountCapabilities?.personalization.map(
          (setting) => setting.title,
        ),
        contains('头像上传'),
      );
      expect(
        controller.currentAccountCapabilities?.acceptsPaymentData,
        isFalse,
      );
    },
  );

  test('account capabilities expose recoverable errors and retry', () async {
    final cloud = FakeCloudService()
      ..accountCapabilitiesFailure = const CloudFailure(
        'temporary_failure',
        '暂时无法读取账号能力',
        retriable: true,
      );
    final controller = AppController(
      cloudService: cloud,
      sessionStore: MemorySessionStore(),
      settingsStore: MemoryAppSettingsStore(),
    );

    expect(await controller.login('test-account', 'test-password'), isTrue);
    expect(controller.accountCapabilitiesError, '暂时无法读取账号能力');
    expect(controller.currentAccountCapabilities, isNull);

    cloud.accountCapabilitiesFailure = null;
    await controller.refreshAccountCapabilities();

    expect(controller.accountCapabilitiesError, isNull);
    expect(controller.currentAccountCapabilities, isNotNull);
    expect(
      cloud.calls.where((call) => call == 'account_capabilities'),
      hasLength(2),
    );
  });

  test(
    'logout clears account capabilities without clearing app settings',
    () async {
      final controller = AppController(
        cloudService: FakeCloudService(),
        sessionStore: MemorySessionStore(),
        settingsStore: MemoryAppSettingsStore(),
      );
      await controller.login('test-account', 'test-password');
      expect(controller.currentAccountCapabilities, isNotNull);

      await controller.logout();

      expect(controller.currentAccountCapabilities, isNull);
      expect(controller.accountCapabilitiesError, isNull);
      expect(controller.accountCapabilitiesLoading, isFalse);
    },
  );

  test('file operations stay behind the CloudService abstraction', () async {
    final cloud = FakeCloudService();
    final controller = AppController(
      cloudService: cloud,
      sessionStore: MemorySessionStore(),
      settingsStore: MemoryAppSettingsStore(),
    );
    const item = CloudItem(id: '8', name: '文件.zip', isFolder: false);

    await controller.login('test-account', 'test-password');
    expect(await controller.moveItems(const [item], '20'), isNull);
    expect(await controller.setItemPassword(item, 'ab12'), isNull);
    expect(await controller.setItemIcon(item, 'test-icon.png'), isNull);
    final share = await controller.loadShareInfo(item);

    expect(cloud.calls, contains('move:8:20'));
    expect(cloud.calls, contains('set_password:8:ab12'));
    expect(cloud.calls, contains('set_icon:8:test-icon.png'));
    expect(share.shareUrl, contains('/8'));
  });

  test(
    'description editor reads the current remote value before writing',
    () async {
      final cloud = FakeCloudService()..shareDescriptions['8'] = '远端保留的简介';
      final controller = AppController(
        cloudService: cloud,
        sessionStore: MemorySessionStore(),
        settingsStore: MemoryAppSettingsStore(),
      );
      const staleItem = CloudItem(
        id: '8',
        name: '应用.apk',
        isFolder: false,
        description: '列表里的旧简介',
      );

      await controller.login('test-account', 'test-password');

      expect(await controller.loadItemDescription(staleItem), '远端保留的简介');
      expect(cloud.calls, contains('get_description:8'));
      expect(
        cloud.calls.where((call) => call.startsWith('set_description:')),
        isEmpty,
      );
    },
  );

  test('safe APK replacement delegates one atomic core transaction', () async {
    const oldFile = CloudItem(
      id: 'old-apk',
      name: '保留标题.apk',
      isFolder: false,
      description: '列表缓存简介',
      hasCustomIcon: true,
    );
    final cloud = FakeCloudService()
      ..folders['-1'] = const <CloudItem>[oldFile];
    final controller = AppController(
      cloudService: cloud,
      sessionStore: MemorySessionStore(),
      settingsStore: MemoryAppSettingsStore(),
    );
    await controller.login('test-account', 'test-password');

    final outcome = await controller.replacePackage(
      oldFile,
      r'D:\packages\new.apk',
    );

    expect(outcome.succeeded, isTrue);
    expect(outcome.result?.finalName, oldFile.name);
    expect(outcome.result?.descriptionPreserved, isTrue);
    expect(outcome.result?.iconApplied, isTrue);
    expect(cloud.replacements, hasLength(1));
    expect(cloud.replacements.single['oldFileId'], oldFile.id);
    expect(cloud.replacements.single['iconPath'], r'D:\packages\new.apk');
    expect(cloud.uploads, isEmpty);
    expect(
      cloud.calls.where((call) => call == 'delete:${oldFile.id}'),
      isEmpty,
    );
    expect(controller.fileOperationRunning, isFalse);
    expect(controller.packageReplaceStage, PackageReplaceStage.idle);
  });

  test('replacement failure exposes old-retained and cleanup facts', () async {
    const oldFile = CloudItem(id: 'old-apk', name: '保留标题.apk', isFolder: false);
    final cloud = FakeCloudService()
      ..folders['-1'] = const <CloudItem>[oldFile]
      ..replaceFileFailure = const CloudFailure(
        'replace_config_failed',
        '简介复核失败',
        retriable: false,
        details: <String, Object?>{
          'stage': 'verify_description',
          'newFileId': 'new-apk',
          'oldRetained': true,
          'cleanupRequired': true,
        },
      );
    final controller = AppController(
      cloudService: cloud,
      sessionStore: MemorySessionStore(),
      settingsStore: MemoryAppSettingsStore(),
    );
    await controller.login('test-account', 'test-password');

    final outcome = await controller.replacePackage(
      oldFile,
      r'D:\packages\broken.apk',
      autoFileIcon: false,
    );

    expect(outcome.succeeded, isFalse);
    expect(outcome.failure?.message, '简介复核失败');
    expect(outcome.failure?.stage, 'verify_description');
    expect(outcome.failure?.oldRetained, isTrue);
    expect(outcome.failure?.cleanupRequired, isTrue);
    expect(outcome.failure?.newFileId, 'new-apk');
    expect(cloud.folders['-1'], contains(oldFile));
    expect(cloud.calls.where((call) => call.startsWith('delete:')), isEmpty);
  });

  test('icon preparation failure prevents replacement from starting', () async {
    const oldFile = CloudItem(id: 'old-apk', name: '保留标题.apk', isFolder: false);
    final cloud = FakeCloudService()
      ..prepareIconFailure = const CloudFailure(
        'unsupported_icon',
        '无法提取 APK 图标',
      );
    final controller = AppController(
      cloudService: cloud,
      sessionStore: MemorySessionStore(),
      settingsStore: MemoryAppSettingsStore(),
    );
    await controller.login('test-account', 'test-password');

    final outcome = await controller.replacePackage(oldFile, 'broken.apk');

    expect(outcome.succeeded, isFalse);
    expect(outcome.failure?.oldRetained, isTrue);
    expect(outcome.failure?.stage, 'prepare_icon');
    expect(cloud.replacements, isEmpty);
    expect(cloud.uploads, isEmpty);
  });

  test('session expiration clears the protected local session', () async {
    final cloud = FakeCloudService();
    final store = MemorySessionStore(cookie: 'restored-test-cookie');
    final controller = AppController(
      cloudService: cloud,
      sessionStore: store,
      settingsStore: MemoryAppSettingsStore(),
    );
    await controller.initialize();
    cloud.listFailure = const CloudFailure('session_expired', '登录状态已失效');

    await controller.loadCurrentFolder(refresh: true);

    expect(controller.sessionStatus, SessionStatus.signedOut);
    expect(store.cookie, isNull);
    expect(controller.sessionError, '登录状态已失效');
  });

  test(
    'initialize restores durable settings before signed-out state',
    () async {
      final settings = MemoryAppSettingsStore(
        settings: const AppSettings(
          themeMode: ThemeMode.dark,
          reduceMotion: true,
        ),
      );
      final controller = AppController(
        cloudService: FakeCloudService(),
        sessionStore: MemorySessionStore(),
        settingsStore: settings,
      );

      await controller.initialize();

      expect(controller.themeMode, ThemeMode.dark);
      expect(controller.reduceMotion, isTrue);
      expect(controller.sessionStatus, SessionStatus.signedOut);
      expect(settings.readCount, 1);
    },
  );

  test(
    'theme and reduced motion update immediately and persist in order',
    () async {
      final settings = MemoryAppSettingsStore(
        writeDelay: const Duration(milliseconds: 5),
      );
      final controller = AppController(
        cloudService: FakeCloudService(),
        sessionStore: MemorySessionStore(),
        settingsStore: settings,
      );

      final first = controller.setThemeMode(ThemeMode.dark);
      final second = controller.setReduceMotion(true);
      final third = controller.setThemeMode(ThemeMode.light);

      expect(controller.themeMode, ThemeMode.light);
      expect(controller.reduceMotion, isTrue);
      await Future.wait(<Future<void>>[first, second, third]);
      expect(settings.writes, <AppSettings>[
        const AppSettings(themeMode: ThemeMode.dark),
        const AppSettings(themeMode: ThemeMode.dark, reduceMotion: true),
        const AppSettings(themeMode: ThemeMode.light, reduceMotion: true),
      ]);
      expect(
        settings.settings,
        const AppSettings(themeMode: ThemeMode.light, reduceMotion: true),
      );
    },
  );

  test(
    'latest write failure is visible and a later success clears it',
    () async {
      final settings = MemoryAppSettingsStore(failWrites: true);
      final controller = AppController(
        cloudService: FakeCloudService(),
        sessionStore: MemorySessionStore(),
        settingsStore: settings,
      );

      await controller.setThemeMode(ThemeMode.dark);

      expect(controller.themeMode, ThemeMode.dark);
      expect(controller.settingsSaveError, '设置未能保存，请重试');

      settings.failWrites = false;
      await controller.setReduceMotion(true);
      expect(controller.settingsSaveError, isNull);
      expect(
        settings.settings,
        const AppSettings(themeMode: ThemeMode.dark, reduceMotion: true),
      );
    },
  );

  test(
    'restart restores settings while logout only clears the session',
    () async {
      final settings = MemoryAppSettingsStore();
      final first = AppController(
        cloudService: FakeCloudService(),
        sessionStore: MemorySessionStore(cookie: 'test-cookie'),
        settingsStore: settings,
      );
      await first.setThemeMode(ThemeMode.dark);
      await first.setReduceMotion(true);
      await first.logout();

      final restarted = AppController(
        cloudService: FakeCloudService(),
        sessionStore: MemorySessionStore(),
        settingsStore: settings,
      );
      await restarted.initialize();

      expect(restarted.themeMode, ThemeMode.dark);
      expect(restarted.reduceMotion, isTrue);
      expect(restarted.sessionStatus, SessionStatus.signedOut);
    },
  );
}
