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
        userId: null,
        accountPortalUrl: Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower',
        ),
        accountFeatures: const <String>['文件大小与云空间统计', '上传格式与下载限制', '账号安全与个人域名'],
        membership: RemoteCapability(
          state: 'available',
          portalUrl: Uri.parse(
            'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
          ),
          reason: '会员购买与续费由蓝奏云官方页面管理',
          readable: false,
          writable: false,
          features: const <String>['会员购买、续费与升级', '下载流量包', '广告与文件保留权益'],
        ),
        personalization: RemoteCapability(
          state: 'available',
          portalUrl: Uri.parse(
            'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
          ),
          reason: '个性化项目由蓝奏云官方页面管理',
          readable: false,
          writable: false,
          features: const <String>['发布者昵称与文件头像', '下载页模板与默认密码', '搜索、子文件夹与域名绑定'],
        ),
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
