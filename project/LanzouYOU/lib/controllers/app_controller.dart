import 'dart:io';

import 'package:flutter/material.dart';

import '../models/cloud_item.dart';
import '../services/app_settings_store.dart';
import '../services/cloud_service.dart';
import '../services/session_store.dart';

enum SessionStatus { restoring, signedOut, authenticating, signedIn }

enum FileLoadStatus { idle, loading, content, empty, error }

enum PackageReplaceStage { idle, preparingIcon, replacing }

class PackageReplaceFailure {
  const PackageReplaceFailure({
    required this.message,
    required this.stage,
    required this.oldRetained,
    required this.cleanupRequired,
    this.newFileId,
  });

  final String message;
  final String? stage;
  final bool? oldRetained;
  final bool cleanupRequired;
  final String? newFileId;
}

class PackageReplaceOutcome {
  const PackageReplaceOutcome.success(this.result) : failure = null;

  const PackageReplaceOutcome.failure(this.failure) : result = null;

  final ReplaceFileResult? result;
  final PackageReplaceFailure? failure;

  bool get succeeded => result != null;
}

class AppController extends ChangeNotifier {
  AppController({
    required this.cloudService,
    required this.sessionStore,
    required this.settingsStore,
  });

  final CloudService cloudService;
  final SessionStore sessionStore;
  final AppSettingsStore settingsStore;

  SessionStatus sessionStatus = SessionStatus.restoring;
  FileLoadStatus fileStatus = FileLoadStatus.idle;
  ThemeMode themeMode = ThemeMode.system;
  bool reduceMotion = false;
  LanzouLinkOpenPreference linkOpenPreference = LanzouLinkOpenPreference.ask;
  bool showSourceLinks = false;
  int searchViewCreationRate = 100;
  String? settingsSaveError;
  String? sessionError;
  String? fileError;
  bool fileOperationRunning = false;
  bool loadingMore = false;
  bool hasMore = false;
  bool sessionInfoLoading = false;
  bool accountCapabilitiesLoading = false;
  PackageReplaceStage packageReplaceStage = PackageReplaceStage.idle;
  String? packageReplaceMessage;
  SessionInfo? currentSession;
  String? sessionInfoError;
  AccountCapabilities? currentAccountCapabilities;
  String? accountCapabilitiesError;
  int _page = 1;
  int _requestSerial = 0;
  int _accountCapabilitiesSerial = 0;
  int _settingsRevision = 0;
  Future<void> _settingsWriteTail = Future<void>.value();
  String searchQuery = '';

  final List<FolderCrumb> crumbs = <FolderCrumb>[
    const FolderCrumb('-1', '全部文件'),
  ];
  final List<CloudItem> _items = <CloudItem>[];
  final Set<String> selectedIds = <String>{};

  String get currentFolderId => crumbs.last.id;
  String get currentFolderName => crumbs.last.name;
  bool get selectionMode => selectedIds.isNotEmpty;
  List<CloudItem> get items => List.unmodifiable(_items);
  List<CloudItem> get visibleItems {
    final query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) return items;
    return _items
        .where((item) => item.name.toLowerCase().contains(query))
        .toList(growable: false);
  }

  Future<void> initialize() async {
    sessionStatus = SessionStatus.restoring;
    sessionError = null;
    notifyListeners();
    final settings = await settingsStore.read();
    themeMode = settings.themeMode;
    reduceMotion = settings.reduceMotion;
    linkOpenPreference = settings.linkOpenPreference;
    showSourceLinks = settings.showSourceLinks;
    searchViewCreationRate = settings.searchViewCreationRate;
    settingsSaveError = null;
    notifyListeners();
    try {
      final cookie = await sessionStore.readCookie();
      if (cookie == null || cookie.trim().isEmpty) {
        sessionStatus = SessionStatus.signedOut;
        notifyListeners();
        return;
      }
      await cloudService.restoreSession(cookie);
      sessionStatus = SessionStatus.signedIn;
      notifyListeners();
      await refreshSessionInfo();
      if (sessionStatus != SessionStatus.signedIn) return;
      await refreshAccountCapabilities();
      if (sessionStatus != SessionStatus.signedIn) return;
      await loadCurrentFolder();
    } on CloudFailure catch (error) {
      await sessionStore.clear();
      sessionStatus = SessionStatus.signedOut;
      sessionError = error.message;
      notifyListeners();
    } on Object {
      sessionStatus = SessionStatus.signedOut;
      sessionError = '无法读取受保护的登录状态';
      notifyListeners();
    }
  }

  Future<bool> login(String account, String password) async {
    if (account.trim().isEmpty || password.isEmpty) {
      sessionError = '请输入账号和密码';
      notifyListeners();
      return false;
    }
    sessionStatus = SessionStatus.authenticating;
    sessionError = null;
    notifyListeners();
    try {
      final result = await cloudService.login(account.trim(), password);
      await sessionStore.writeCookie(result.cookie);
      sessionStatus = SessionStatus.signedIn;
      notifyListeners();
      await refreshSessionInfo();
      if (sessionStatus != SessionStatus.signedIn) return false;
      await refreshAccountCapabilities();
      if (sessionStatus != SessionStatus.signedIn) return false;
      await loadCurrentFolder();
      return sessionStatus == SessionStatus.signedIn;
    } on CloudFailure catch (error) {
      sessionStatus = SessionStatus.signedOut;
      sessionError = error.message;
      notifyListeners();
      return false;
    } on Object {
      sessionStatus = SessionStatus.signedOut;
      sessionError = '无法保存受保护的登录状态';
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    try {
      await cloudService.logout();
    } on Object {
      // Local session removal is authoritative even if the remote logout fails.
    }
    await sessionStore.clear();
    _requestSerial++;
    _accountCapabilitiesSerial++;
    sessionStatus = SessionStatus.signedOut;
    fileStatus = FileLoadStatus.idle;
    sessionError = null;
    currentSession = null;
    sessionInfoError = null;
    currentAccountCapabilities = null;
    accountCapabilitiesError = null;
    accountCapabilitiesLoading = false;
    fileError = null;
    _items.clear();
    crumbs
      ..clear()
      ..add(const FolderCrumb('-1', '全部文件'));
    searchQuery = '';
    clearSelection(notify: false);
    notifyListeners();
  }

  Future<void> loadCurrentFolder({bool refresh = false}) async {
    final serial = ++_requestSerial;
    if (!refresh || _items.isEmpty) {
      fileStatus = FileLoadStatus.loading;
    }
    fileError = null;
    _page = 1;
    hasMore = false;
    clearSelection(notify: false);
    notifyListeners();
    try {
      final result = await cloudService.listFolder(currentFolderId);
      if (serial != _requestSerial) return;
      _items
        ..clear()
        ..addAll(result.items);
      _page = result.page;
      hasMore = result.hasMore;
      fileStatus = _items.isEmpty
          ? FileLoadStatus.empty
          : FileLoadStatus.content;
      notifyListeners();
    } on CloudFailure catch (error) {
      if (serial != _requestSerial) return;
      if (error.isSessionExpired) {
        await _expireSession(error.message);
        return;
      }
      fileError = error.message;
      fileStatus = FileLoadStatus.error;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (!hasMore || loadingMore || fileStatus != FileLoadStatus.content) {
      return;
    }
    loadingMore = true;
    notifyListeners();
    try {
      final result = await cloudService.listFolder(
        currentFolderId,
        page: _page + 1,
      );
      _items.addAll(result.items);
      _page = result.page;
      hasMore = result.hasMore;
    } on CloudFailure catch (error) {
      fileError = error.message;
      if (error.isSessionExpired) await _expireSession(error.message);
    } finally {
      loadingMore = false;
      notifyListeners();
    }
  }

  Future<void> openFolder(CloudItem item) async {
    if (!item.isFolder) return;
    crumbs.add(FolderCrumb(item.id, item.name));
    searchQuery = '';
    await loadCurrentFolder();
  }

  Future<void> openCrumb(int index) async {
    if (index < 0 || index >= crumbs.length || index == crumbs.length - 1) {
      return;
    }
    crumbs.removeRange(index + 1, crumbs.length);
    searchQuery = '';
    await loadCurrentFolder();
  }

  Future<bool> goBackFolder() async {
    if (crumbs.length <= 1) return false;
    crumbs.removeLast();
    searchQuery = '';
    await loadCurrentFolder();
    return true;
  }

  void setSearch(String value) {
    if (searchQuery == value) return;
    searchQuery = value;
    notifyListeners();
  }

  void toggleSelection(CloudItem item) {
    if (!selectedIds.add(item.id)) selectedIds.remove(item.id);
    notifyListeners();
  }

  void selectAllVisible() {
    selectedIds.addAll(visibleItems.map((item) => item.id));
    notifyListeners();
  }

  void clearSelection({bool notify = true}) {
    if (selectedIds.isEmpty) return;
    selectedIds.clear();
    if (notify) notifyListeners();
  }

  Future<String?> createFolder(String name, String description) {
    return _mutate(
      () => cloudService.createFolder(
        currentFolderId,
        name.trim(),
        description: description.trim(),
      ),
    );
  }

  Future<String?> renameItem(CloudItem item, String name) {
    return _mutate(() => cloudService.rename(item, name.trim()));
  }

  Future<String?> moveItems(Iterable<CloudItem> items, String targetId) {
    return _mutate(() async {
      for (final item in items) {
        await cloudService.move(item, targetId);
      }
    });
  }

  Future<String?> copyItem(
    CloudItem item,
    String targetId,
    String tempDirectory,
  ) {
    return _mutate(() => cloudService.copy(item, targetId, tempDirectory));
  }

  Future<String?> setItemPassword(CloudItem item, String password) {
    return _mutate(() => cloudService.setPassword(item, password.trim()));
  }

  Future<String?> setItemIcon(CloudItem item, String sourcePath) {
    if (item.isFolder) return Future<String?>.value('文件夹不支持自定义文件图标');
    return _mutate(() async {
      PreparedIcon? prepared;
      try {
        prepared = await cloudService.prepareIcon(sourcePath);
        if (prepared.path.isEmpty || prepared.bytes >= 100000) {
          throw const CloudFailure('invalid_icon', '核心未能生成小于 100KB 的有效图标');
        }
        await cloudService.setIcon(item.id, prepared.path);
      } finally {
        final path = prepared?.path;
        if (path != null && !_sameLocalPath(path, sourcePath)) {
          try {
            final file = File(path);
            if (await file.exists()) await file.delete();
          } on Object {
            // Prepared icons are disposable cache files.
          }
        }
      }
    });
  }

  Future<String?> describeItem(CloudItem item, String description) {
    return _mutate(() => cloudService.setDescription(item, description.trim()));
  }

  Future<String?> deleteItems(Iterable<CloudItem> items) async {
    return _mutate(() async {
      for (final item in items) {
        await cloudService.delete(item);
      }
    });
  }

  Future<List<CloudItem>> loadMoveTargets() async {
    try {
      return await cloudService.moveTargets();
    } on CloudFailure catch (error) {
      if (error.isSessionExpired) await _expireSession(error.message);
      rethrow;
    }
  }

  Future<ShareInfo> loadShareInfo(CloudItem item) async {
    try {
      return await cloudService.shareInfo(item);
    } on CloudFailure catch (error) {
      if (error.isSessionExpired) await _expireSession(error.message);
      rethrow;
    }
  }

  Future<ManagedDescription> loadManagedDescription(CloudItem item) async {
    try {
      final metadata = await cloudService.getDescription(item);
      if (metadata.id != item.id || metadata.isFolder != item.isFolder) {
        throw const CloudFailure('invalid_response', '核心返回了不匹配的简介对象，已阻止覆盖错误项目');
      }
      return metadata;
    } on CloudFailure catch (error) {
      if (error.isSessionExpired) await _expireSession(error.message);
      rethrow;
    } on Object {
      throw const CloudFailure(
        'description_load_failed',
        '无法读取蓝奏云当前简介，请重试',
        retriable: true,
      );
    }
  }

  Future<String> loadItemDescription(CloudItem item) async {
    return (await loadManagedDescription(item)).description;
  }

  Future<PackageReplaceOutcome> replacePackage(
    CloudItem item,
    String path, {
    bool compatibilityWrap = false,
    bool autoFileIcon = true,
  }) async {
    if (item.isFolder) {
      return const PackageReplaceOutcome.failure(
        PackageReplaceFailure(
          message: '文件夹不能执行 APK 换包',
          stage: 'validation',
          oldRetained: true,
          cleanupRequired: false,
        ),
      );
    }
    if (!path.toLowerCase().endsWith('.apk')) {
      return const PackageReplaceOutcome.failure(
        PackageReplaceFailure(
          message: '请选择有效的 APK 文件',
          stage: 'validation',
          oldRetained: true,
          cleanupRequired: false,
        ),
      );
    }
    if (fileOperationRunning) {
      return const PackageReplaceOutcome.failure(
        PackageReplaceFailure(
          message: '已有文件操作正在进行',
          stage: 'busy',
          oldRetained: true,
          cleanupRequired: false,
        ),
      );
    }

    final folderId = currentFolderId;
    PreparedIcon? prepared;
    fileOperationRunning = true;
    packageReplaceStage = autoFileIcon
        ? PackageReplaceStage.preparingIcon
        : PackageReplaceStage.replacing;
    packageReplaceMessage = autoFileIcon ? '正在提取并压缩新 APK 图标' : '正在安全换包并恢复云端信息';
    notifyListeners();
    try {
      if (autoFileIcon) {
        prepared = await cloudService.prepareIcon(path);
        if (prepared.path.isEmpty || prepared.bytes >= 100000) {
          throw const CloudFailure(
            'invalid_icon',
            '换包尚未开始：核心未能生成小于 100KB 的有效图标',
          );
        }
        packageReplaceStage = PackageReplaceStage.replacing;
        packageReplaceMessage = '正在上传新 APK，并恢复原标题与简介';
        notifyListeners();
      }
      final result = await cloudService.replaceFile(
        oldFile: item,
        folderId: folderId,
        path: path,
        compatibilityWrap: compatibilityWrap,
        iconPath: prepared?.path,
      );
      if (result.oldFileId != item.id ||
          result.folderId != folderId ||
          !result.descriptionPreserved ||
          !result.oldDeleted ||
          result.cleanupRequired ||
          (autoFileIcon && !result.iconApplied)) {
        throw const CloudFailure(
          'invalid_replace_result',
          '核心未能确认标题、简介、图标与旧文件的安全换包结果',
        );
      }
      await loadCurrentFolder(refresh: true);
      return PackageReplaceOutcome.success(result);
    } on CloudFailure catch (error) {
      if (error.isSessionExpired) {
        await _expireSession(error.message);
      } else if (sessionStatus == SessionStatus.signedIn) {
        await loadCurrentFolder(refresh: true);
      }
      return PackageReplaceOutcome.failure(_replaceFailure(error));
    } on Object {
      if (sessionStatus == SessionStatus.signedIn) {
        await loadCurrentFolder(refresh: true);
      }
      return const PackageReplaceOutcome.failure(
        PackageReplaceFailure(
          message: '换包失败，核心未确认远端状态',
          stage: null,
          oldRetained: null,
          cleanupRequired: false,
        ),
      );
    } finally {
      final preparedPath = prepared?.path;
      if (preparedPath != null && !_sameLocalPath(preparedPath, path)) {
        try {
          final file = File(preparedPath);
          if (await file.exists()) await file.delete();
        } on Object {
          // Prepared icons are disposable cache files.
        }
      }
      fileOperationRunning = false;
      packageReplaceStage = PackageReplaceStage.idle;
      packageReplaceMessage = null;
      notifyListeners();
    }
  }

  Future<void> refreshSessionInfo() async {
    if (sessionStatus != SessionStatus.signedIn || sessionInfoLoading) return;
    sessionInfoLoading = true;
    sessionInfoError = null;
    notifyListeners();
    try {
      currentSession = await cloudService.sessionInfo();
      if (currentSession?.authenticated != true) {
        await _expireSession('登录状态已失效，请重新登录');
      }
    } on CloudFailure catch (error) {
      if (error.isSessionExpired) {
        await _expireSession(error.message);
      } else {
        sessionInfoError = error.message;
      }
    } on Object {
      sessionInfoError = '无法读取会话信息';
    } finally {
      sessionInfoLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshAccountCapabilities() async {
    if (sessionStatus != SessionStatus.signedIn || accountCapabilitiesLoading) {
      return;
    }
    final serial = ++_accountCapabilitiesSerial;
    accountCapabilitiesLoading = true;
    accountCapabilitiesError = null;
    notifyListeners();
    try {
      final capabilities = await cloudService.accountCapabilities();
      if (serial != _accountCapabilitiesSerial ||
          sessionStatus != SessionStatus.signedIn) {
        return;
      }
      if (!capabilities.authenticated) {
        await _expireSession('登录状态已失效，请重新登录');
        return;
      }
      currentAccountCapabilities = capabilities;
    } on CloudFailure catch (error) {
      if (serial != _accountCapabilitiesSerial) return;
      if (error.isSessionExpired) {
        await _expireSession(error.message);
      } else {
        currentAccountCapabilities = null;
        accountCapabilitiesError = error.message;
      }
    } on Object {
      if (serial != _accountCapabilitiesSerial) return;
      currentAccountCapabilities = null;
      accountCapabilitiesError = '无法读取蓝奏账号能力';
    } finally {
      if (serial == _accountCapabilitiesSerial) {
        accountCapabilitiesLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> expireSession(String message) => _expireSession(message);

  PackageReplaceFailure _replaceFailure(CloudFailure error) {
    final details = error.details;
    final detailStage = details['stage'];
    final detailOldRetained = details['oldRetained'];
    final detailCleanupRequired = details['cleanupRequired'];
    final detailNewFileId = details['newFileId'];
    final beforeReplace =
        packageReplaceStage == PackageReplaceStage.preparingIcon;
    return PackageReplaceFailure(
      message: error.message,
      stage: detailStage is String && detailStage.isNotEmpty
          ? detailStage
          : beforeReplace
          ? 'prepare_icon'
          : null,
      oldRetained: detailOldRetained is bool
          ? detailOldRetained
          : beforeReplace
          ? true
          : null,
      cleanupRequired: detailCleanupRequired is bool && detailCleanupRequired,
      newFileId:
          detailNewFileId is String &&
              RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(detailNewFileId)
          ? detailNewFileId
          : null,
    );
  }

  Future<String?> _mutate(Future<void> Function() operation) async {
    if (fileOperationRunning) return '已有操作正在进行';
    fileOperationRunning = true;
    notifyListeners();
    try {
      await operation();
      await loadCurrentFolder(refresh: true);
      return null;
    } on CloudFailure catch (error) {
      if (error.isSessionExpired) {
        await _expireSession(error.message);
      } else {
        await loadCurrentFolder(refresh: true);
      }
      return error.message;
    } on Object {
      if (sessionStatus == SessionStatus.signedIn) {
        await loadCurrentFolder(refresh: true);
      }
      return '操作失败，请稍后重试';
    } finally {
      fileOperationRunning = false;
      notifyListeners();
    }
  }

  Future<void> _expireSession(String message) async {
    await sessionStore.clear();
    _accountCapabilitiesSerial++;
    sessionStatus = SessionStatus.signedOut;
    sessionError = message;
    currentSession = null;
    sessionInfoError = null;
    currentAccountCapabilities = null;
    accountCapabilitiesError = null;
    accountCapabilitiesLoading = false;
    _items.clear();
    crumbs
      ..clear()
      ..add(const FolderCrumb('-1', '全部文件'));
    searchQuery = '';
    fileStatus = FileLoadStatus.idle;
    clearSelection(notify: false);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode value) {
    if (themeMode == value) return Future<void>.value();
    themeMode = value;
    notifyListeners();
    return _persistSettings();
  }

  Future<void> setReduceMotion(bool value) {
    if (reduceMotion == value) return Future<void>.value();
    reduceMotion = value;
    notifyListeners();
    return _persistSettings();
  }

  Future<void> setLinkOpenPreference(LanzouLinkOpenPreference value) {
    if (linkOpenPreference == value) return Future<void>.value();
    linkOpenPreference = value;
    notifyListeners();
    return _persistSettings();
  }

  Future<void> setShowSourceLinks(bool value) {
    if (showSourceLinks == value) return Future<void>.value();
    showSourceLinks = value;
    notifyListeners();
    return _persistSettings();
  }

  Future<void> setSearchViewCreationRate(int value) {
    final bounded = value.clamp(1, 500);
    if (searchViewCreationRate == bounded) return Future<void>.value();
    searchViewCreationRate = bounded;
    notifyListeners();
    return _persistSettings();
  }

  Future<void> _persistSettings() {
    final revision = ++_settingsRevision;
    final settings = AppSettings(
      themeMode: themeMode,
      reduceMotion: reduceMotion,
      linkOpenPreference: linkOpenPreference,
      showSourceLinks: showSourceLinks,
      searchViewCreationRate: searchViewCreationRate,
    );
    _settingsWriteTail = _settingsWriteTail.then((_) async {
      try {
        await settingsStore.write(settings);
        if (revision == _settingsRevision && settingsSaveError != null) {
          settingsSaveError = null;
          notifyListeners();
        }
      } on Object {
        if (revision == _settingsRevision) {
          settingsSaveError = '设置未能保存，请重试';
          notifyListeners();
        }
      }
    });
    return _settingsWriteTail;
  }
}

bool _sameLocalPath(String first, String second) {
  if (Platform.isWindows) return first.toLowerCase() == second.toLowerCase();
  return first == second;
}
