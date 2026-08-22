import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lanzou_library_shell/library_preview.dart';
import 'package:lanzouyou/app/lanzou_you_app.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/models/directory_upload.dart';
import 'package:lanzouyou/pages/public_library/public_library.dart';
import 'package:lanzouyou/services/app_settings_store.dart';
import 'package:lanzouyou/services/cloud_service.dart';
import 'package:lanzouyou/services/session_store.dart';

void main() {
  if (kReleaseMode) {
    throw StateError('界面验收入口禁止用于正式发布');
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    LanzouYouApp(
      key: UniqueKey(),
      cloudService: _SettingsPreviewTestHarnessCloudService(),
      publicLibraryCore: _SettingsPreviewCatalogCore(),
      sessionStore: _SettingsPreviewTestHarnessSessionStore(),
      settingsStore: _SettingsPreviewTestHarnessSettingsStore(),
    ),
  );
  _scheduleSettingsDestination();
}

/// Waits for the real adaptive navigation shell to finish session restoration,
/// then invokes its public destination callback. This keeps the preview on the
/// production LanzouYouApp -> NavigationShell -> SettingsPage widget path.
void _scheduleSettingsDestination([int attempt = 0]) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final root = WidgetsBinding.instance.rootElement;
    if (root != null && _selectSettings(root)) {
      _scheduleLanzouSettings();
      return;
    }
    if (attempt >= 120) {
      throw StateError('设置页验收入口初始化超时');
    }
    _scheduleSettingsDestination(attempt + 1);
    WidgetsBinding.instance.scheduleFrame();
  });
}

void _scheduleLanzouSettings([int attempt = 0]) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final root = WidgetsBinding.instance.rootElement;
    if (root != null && _openLanzouSettings(root)) return;
    if (attempt >= 120) {
      throw StateError('蓝奏设置页验收入口初始化超时');
    }
    _scheduleLanzouSettings(attempt + 1);
    WidgetsBinding.instance.scheduleFrame();
  });
}

bool _openLanzouSettings(Element root) {
  VoidCallback? open;
  void visit(Element element) {
    if (open != null) return;
    final widget = element.widget;
    if (widget is ListTile &&
        widget.key == const Key('lanzou-settings-entry')) {
      open = widget.onTap;
      return;
    }
    element.visitChildren(visit);
  }

  visit(root);
  final action = open;
  if (action == null) return false;
  action();
  return true;
}

bool _selectSettings(Element root) {
  ValueChanged<int>? selectDestination;
  int? settingsIndex;

  void visit(Element element) {
    if (settingsIndex != null) return;
    final widget = element.widget;
    if (widget is NavigationRail) {
      final index = widget.destinations.indexWhere((destination) {
        final label = destination.label;
        return label is Text && label.data == '设置';
      });
      if (index >= 0) {
        selectDestination = widget.onDestinationSelected;
        settingsIndex = index;
      }
    } else if (widget is NavigationBar) {
      final index = widget.destinations.indexWhere(
        (destination) =>
            destination is NavigationDestination && destination.label == '设置',
      );
      if (index >= 0) {
        selectDestination = widget.onDestinationSelected;
        settingsIndex = index;
      }
    }
    if (settingsIndex == null) element.visitChildren(visit);
  }

  visit(root);
  final select = selectDestination;
  final index = settingsIndex;
  if (select == null || index == null) return false;
  select(index);
  return true;
}

class _SettingsPreviewTestHarnessSettingsStore implements AppSettingsStore {
  AppSettings _settings = const AppSettings(themeMode: ThemeMode.light);

  @override
  Future<AppSettings> read() async => _settings;

  @override
  Future<void> write(AppSettings settings) async {
    _settings = settings;
  }
}

class _SettingsPreviewTestHarnessSessionStore implements SessionStore {
  bool _available = true;

  @override
  Future<String?> readCookie() async =>
      _available ? identityHashCode(this).toRadixString(36) : null;

  @override
  Future<void> writeCookie(String cookie) async {
    _available = true;
  }

  @override
  Future<void> clear() async {
    _available = false;
  }
}

class _SettingsPreviewCatalogCore implements PublicLibraryCatalogCore {
  @override
  Future<PublicLibraryCatalogSummary> catalogSummary() async =>
      const PublicLibraryCatalogSummary(
        revision: 'preview-catalog',
        officialCount: 597,
        compositeCount: 9,
        nodeCount: 3370,
        searchableCount: 274,
      );

  @override
  Future<PublicLibraryCatalogPage> catalogPage({
    String parentId = '',
    String categoryId = 'all',
    String query = '',
    String cursor = '',
    int limit = 100,
  }) async => const PublicLibraryCatalogPage(
    revision: 'preview-catalog',
    total: 0,
    nextCursor: '',
    hasMore: false,
    nodes: <PublicLibraryCatalogNode>[],
  );

  @override
  Future<LibraryFolder> catalogBrowse({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
    int page = 1,
    bool refresh = false,
  }) async => const LibraryFolder(
    sourceId: 'preview-source',
    title: '预览来源',
    url: '',
    items: <LibraryItem>[],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SettingsPreviewTestHarnessCloudService implements CloudService {
  bool _authenticated = true;

  Never _unsupported() => throw UnsupportedError('视觉验收入口不执行云端文件操作');

  @override
  Future<void> restoreSession(String cookie) async {
    _authenticated = true;
  }

  @override
  Future<SessionInfo> sessionInfo() async =>
      SessionInfo(authenticated: _authenticated, userId: null);

  @override
  Future<CloudPage> listFolder(
    String folderId, {
    int page = 1,
    int pageSize = 200,
  }) async => CloudPage(items: const <CloudItem>[], page: page, hasMore: false);

  @override
  Future<void> logout() async {
    _authenticated = false;
  }

  @override
  Future<LoginResult> login(String account, String password) async =>
      _unsupported();

  @override
  Future<List<CloudItem>> moveTargets() async => _unsupported();

  @override
  Future<void> createFolder(
    String parentId,
    String name, {
    String description = '',
  }) async => _unsupported();

  @override
  Future<DirectoryUploadResult> uploadDirectory(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    bool autoApkIcons = false,
    String? operationId,
  }) async => _unsupported();

  @override
  Future<void> rename(CloudItem item, String name) async => _unsupported();

  @override
  Future<void> move(CloudItem item, String targetId) async => _unsupported();

  @override
  Future<void> copy(
    CloudItem item,
    String targetId,
    String tempDirectory,
  ) async => _unsupported();

  @override
  Future<void> delete(CloudItem item) async => _unsupported();

  @override
  Future<ShareInfo> shareInfo(CloudItem item) async => _unsupported();

  @override
  Future<ManagedDescription> getDescription(CloudItem item) async =>
      _unsupported();

  @override
  Future<AccountCapabilities> accountCapabilities() async =>
      AccountCapabilities(
        authenticated: _authenticated,
        userId: 'preview-vip-user',
        accountPortalUrl: Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower',
        ),
        membershipPortalUrl: Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
        ),
        personalizationPortalUrl: Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
        ),
        membershipProfile: MembershipProfile(
          state: MembershipState.vip,
          displayName: '会员个性化',
          level: 'VIP',
          expiresAt: DateTime(2027, 7, 30),
          reason: '已从蓝奏云官方个人页识别',
        ),
        entries: <AccountEntry>[
          AccountEntry(
            id: 'permissions',
            title: '我的权限',
            description: '查看账号权限与云存储状态',
            portalUrl: Uri.parse(
              'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower',
            ),
            available: true,
            requiresOfficialConfirmation: false,
            dangerous: false,
          ),
          AccountEntry(
            id: 'balance',
            title: '财务充值',
            description: '在蓝奏云官方页面查看余额与充值',
            portalUrl: Uri.parse(
              'https://pc.woozooo.com/mydisk.php?item=profile&action=goods',
            ),
            available: true,
            requiresOfficialConfirmation: true,
            dangerous: false,
          ),
          AccountEntry(
            id: 'fileUpgrade',
            title: '文件升级',
            description: '购买文件升级服务',
            portalUrl: Uri.parse(
              'https://pc.woozooo.com/mydisk.php?item=profile&action=buygoods',
            ),
            available: true,
            requiresOfficialConfirmation: true,
            dangerous: false,
          ),
          AccountEntry(
            id: 'downloadCashout',
            title: '下载提现',
            description: '申请下载收益提现',
            portalUrl: Uri.parse(
              'https://pc.woozooo.com/mydisk.php?item=profile&action=exchange',
            ),
            available: true,
            requiresOfficialConfirmation: true,
            dangerous: false,
          ),
          AccountEntry(
            id: 'cashoutRecords',
            title: '提现记录',
            description: '查看蓝奏云官方提现记录',
            portalUrl: Uri.parse(
              'https://pc.woozooo.com/mydisk.php?item=profile&action=orders',
            ),
            available: true,
            requiresOfficialConfirmation: false,
            dangerous: false,
          ),
          AccountEntry(
            id: 'invite',
            title: '邀请注册',
            description: '查看蓝奏云官方邀请注册入口',
            portalUrl: Uri.parse(
              'https://pc.woozooo.com/mydisk.php?item=buddy&action=invite',
            ),
            available: true,
            requiresOfficialConfirmation: false,
            dangerous: false,
          ),
          AccountEntry(
            id: 'password',
            title: '密码修改',
            description: '修改蓝奏云账号密码',
            portalUrl: Uri.parse(
              'https://pc.woozooo.com/mydisk.php?item=profile&action=password',
            ),
            available: true,
            requiresOfficialConfirmation: true,
            dangerous: false,
          ),
          AccountEntry(
            id: 'phone',
            title: '手机号',
            description: '管理蓝奏云账号绑定手机号',
            portalUrl: Uri.parse(
              'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower',
            ),
            available: true,
            requiresOfficialConfirmation: true,
            dangerous: false,
          ),
          AccountEntry(
            id: 'closeAccount',
            title: '注销账户',
            description: '在蓝奏云官方页面确认注销账户',
            portalUrl: Uri.parse(
              'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower',
            ),
            available: true,
            requiresOfficialConfirmation: true,
            dangerous: true,
          ),
        ],
        facts: const <AccountFact>[
          AccountFact(
            id: 'singleFileLimit',
            label: '单个文件大小',
            value: '100 MB',
            known: true,
          ),
          AccountFact(
            id: 'storageStatistics',
            label: '云存储统计',
            value: '2.4 GB / 10 GB',
            known: true,
          ),
          AccountFact(
            id: 'downloadWithoutLogin',
            label: '下载免登录',
            value: '已开启',
            known: true,
          ),
          AccountFact(
            id: 'downloadSpeed',
            label: '下载速度',
            value: '会员高速',
            known: true,
          ),
          AccountFact(
            id: 'downloadCount',
            label: '下载次数',
            value: '不限',
            known: true,
          ),
          AccountFact(
            id: 'downloadTraffic',
            label: '下载流量',
            value: '20 GB',
            known: true,
          ),
          AccountFact(
            id: 'storageCapacity',
            label: '存储空间',
            value: '10 GB',
            known: true,
          ),
          AccountFact(
            id: 'allowedUploadTypes',
            label: '允许上传类型',
            value: '会员类型',
            known: true,
          ),
        ],
        plans: const <MembershipPlan>[
          MembershipPlan(
            id: 'month1',
            label: '1个月',
            detail: '官方页面当前展示的会员时长',
            priceLabel: '以官方页面为准',
            available: true,
          ),
          MembershipPlan(
            id: 'month2',
            label: '2个月',
            detail: '官方页面当前展示的会员时长',
            priceLabel: '以官方页面为准',
            available: true,
          ),
          MembershipPlan(
            id: 'month6',
            label: '6个月',
            detail: '官方页面当前展示的会员时长',
            priceLabel: '以官方页面为准',
            available: true,
          ),
          MembershipPlan(
            id: 'year1',
            label: '1年',
            detail: '官方页面当前展示的会员时长',
            priceLabel: '以官方页面为准',
            available: true,
          ),
          MembershipPlan(
            id: 'monthly',
            label: '包月',
            detail: '按月开通或续费会员',
            priceLabel: '以官方页面为准',
            available: true,
          ),
          MembershipPlan(
            id: 'yearly',
            label: '包年',
            detail: '按年开通或续费会员',
            priceLabel: '以官方页面为准',
            available: true,
          ),
          MembershipPlan(
            id: 'downloadPack',
            label: '下载包',
            detail: '购买额外下载权益',
            priceLabel: '以官方页面为准',
            available: true,
          ),
        ],
        personalization: const <PersonalizationSetting>[
          PersonalizationSetting(
            id: 'adFreeDownloads',
            title: '免广告下载',
            description: '下载页面免广告',
            available: true,
            enabled: true,
            writable: false,
            reason: '修改需要蓝奏云官方确认',
          ),
          PersonalizationSetting(
            id: 'uploadTimeVisibility',
            title: '上传时间',
            description: '隐藏或显示文件上传时间',
            available: true,
            enabled: true,
            writable: false,
            reason: '修改需要蓝奏云官方确认',
          ),
          PersonalizationSetting(
            id: 'subfolders',
            title: '子文件夹',
            description: '启用分享页子文件夹',
            available: true,
            enabled: true,
            writable: false,
            reason: '修改需要蓝奏云官方确认',
          ),
          PersonalizationSetting(
            id: 'search',
            title: '搜索',
            description: '启用分享页搜索',
            available: true,
            enabled: true,
            writable: false,
            reason: '修改需要蓝奏云官方确认',
          ),
          PersonalizationSetting(
            id: 'defaultFilePassword',
            title: '新文件密码',
            description: '设置新文件默认密码开关',
            available: true,
            enabled: false,
            writable: false,
            reason: '修改需要蓝奏云官方确认',
          ),
          PersonalizationSetting(
            id: 'avatarUpload',
            title: '头像上传',
            description: '管理发布者头像',
            available: true,
            value: '已设置',
            writable: false,
            reason: '上传需要蓝奏云官方确认',
          ),
          PersonalizationSetting(
            id: 'downloadPageTemplate',
            title: '下载页模板',
            description: '选择文件下载页面模板',
            available: true,
            value: '默认模板',
            writable: false,
            reason: '修改需要蓝奏云官方确认',
          ),
          PersonalizationSetting(
            id: 'publisherNickname',
            title: '发布者昵称',
            description: '设置分享页面展示的发布者昵称',
            available: true,
            value: '会员个性化',
            writable: false,
            reason: '修改需要蓝奏云官方确认',
          ),
          PersonalizationSetting(
            id: 'dailyDownloadReport',
            title: '日下载报表',
            description: '查看每日下载报表',
            available: true,
            enabled: true,
            writable: false,
            reason: '修改需要蓝奏云官方确认',
          ),
          PersonalizationSetting(
            id: 'fileRetention',
            title: '文件保存时间',
            description: '查看会员文件保存期限',
            available: true,
            value: '会员期限',
            writable: false,
            reason: '修改需要蓝奏云官方确认',
          ),
          PersonalizationSetting(
            id: 'directLinkDomain',
            title: '直链域名绑定',
            description: '管理文件直链域名',
            available: true,
            value: '未绑定',
            writable: false,
            reason: '修改需要蓝奏云官方确认',
          ),
        ],
        acceptsPaymentData: false,
      );

  @override
  Future<void> setPassword(CloudItem item, String password) async =>
      _unsupported();

  @override
  Future<void> setDescription(CloudItem item, String description) async =>
      _unsupported();

  @override
  Future<UploadResult> upload(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    String? operationId,
  }) async => _unsupported();

  @override
  Future<PreparedIcon> prepareIcon(
    String sourcePath, {
    String? outputPath,
  }) async => _unsupported();

  @override
  Future<void> setIcon(String fileId, String path) async => _unsupported();

  @override
  Future<ReplaceFileResult> replaceFile({
    required CloudItem oldFile,
    required String folderId,
    required String path,
    bool compatibilityWrap = false,
    String? iconPath,
    String? operationId,
  }) async => _unsupported();

  @override
  Future<void> download(
    CloudItem item,
    String destination, {
    String? operationId,
  }) async => _unsupported();

  @override
  Future<CloudOperationStatus> operationStatus(String operationId) async =>
      _unsupported();

  @override
  Future<CloudOperationStatus> operationCancel(String operationId) async =>
      _unsupported();

  @override
  Future<void> operationForget(String operationId) async => _unsupported();

  @override
  Future<List<CloudItem>> listRecycle() async => const <CloudItem>[];

  @override
  Future<void> restoreRecycle(CloudItem item) async => _unsupported();

  @override
  Future<void> purgeRecycle(CloudItem item) async => _unsupported();

  @override
  Future<void> emptyRecycle() async => _unsupported();
}
