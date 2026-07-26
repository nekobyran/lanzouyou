import 'dart:io';

import 'package:lanzou_library_shell/library_preview.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/models/directory_upload.dart';
import 'package:lanzouyou/pages/public_library/public_library.dart';
import 'package:lanzouyou/services/app_settings_store.dart';
import 'package:lanzouyou/services/cloud_service.dart';
import 'package:lanzouyou/services/session_store.dart';

class MemorySessionStore implements SessionStore {
  MemorySessionStore({this.cookie});

  String? cookie;
  int clearCount = 0;

  @override
  Future<void> clear() async {
    clearCount++;
    cookie = null;
  }

  @override
  Future<String?> readCookie() async => cookie;

  @override
  Future<void> writeCookie(String cookie) async {
    this.cookie = cookie;
  }
}

class MemoryAppSettingsStore implements AppSettingsStore {
  MemoryAppSettingsStore({
    this.settings = const AppSettings(),
    this.writeDelay = Duration.zero,
    this.failWrites = false,
  });

  AppSettings settings;
  Duration writeDelay;
  bool failWrites;
  int readCount = 0;
  final List<AppSettings> writes = <AppSettings>[];

  @override
  Future<AppSettings> read() async {
    readCount++;
    return settings;
  }

  @override
  Future<void> write(AppSettings settings) async {
    if (writeDelay != Duration.zero) await Future<void>.delayed(writeDelay);
    if (failWrites) throw const FileSystemException('test write failure');
    writes.add(settings);
    this.settings = settings;
  }
}

class FakePublicLibraryCatalogCore implements PublicLibraryCatalogCore {
  FakePublicLibraryCatalogCore({
    this.summary = const PublicLibraryCatalogSummary(
      revision: 'fixture-revision',
      officialCount: 597,
      compositeCount: 9,
      nodeCount: 3370,
      searchableCount: 274,
    ),
    List<PublicLibraryCatalogNode>? nodes,
  }) : nodes =
           nodes ??
           const <PublicLibraryCatalogNode>[
             PublicLibraryCatalogNode(
               id: 'source-fixture',
               parentId: '',
               kind: PublicLibraryNodeKind.remoteSource,
               sourceId: 'opaque-source-fixture',
               title: '真实公开来源',
               publisher: '来源发布者',
               description: '',
               iconUrl: '',
               size: '',
               time: '',
               searchable: true,
               childDirectory: false,
               originPath: 'fixture/source',
               originUrl: 'https://www.lanzouw.com/source-fixture',
               shareUrl: 'https://www.lanzouw.com/source-fixture',
               hasChildren: true,
             ),
           ];

  final PublicLibraryCatalogSummary summary;
  final List<PublicLibraryCatalogNode> nodes;
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  @override
  Future<PublicLibraryCatalogSummary> catalogSummary() async {
    calls.add(const {'op': 'summary'});
    return summary;
  }

  @override
  Future<PublicLibraryCatalogPage> catalogPage({
    String parentId = '',
    String categoryId = 'all',
    String query = '',
    String cursor = '',
    int limit = 100,
  }) async {
    calls.add({
      'op': 'page',
      'parentId': parentId,
      'categoryId': categoryId,
      'query': query,
      'cursor': cursor,
      'limit': limit,
    });
    final visible = query.isEmpty
        ? nodes
        : nodes
              .where((node) => node.title.contains(query))
              .toList(growable: false);
    return PublicLibraryCatalogPage(
      revision: summary.revision,
      total: visible.length,
      nextCursor: '',
      hasMore: false,
      nodes: visible,
    );
  }

  @override
  Future<LibraryFolder> catalogBrowse({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
    int page = 1,
    bool refresh = false,
  }) async {
    calls.add({'op': 'browse', 'nodeId': nodeId, 'page': page});
    return const LibraryFolder(
      sourceId: 'opaque-source-fixture',
      title: '真实公开来源',
      url: 'https://www.lanzouw.com/source-fixture',
      items: <LibraryItem>[
        LibraryItem(
          sourceId: 'opaque-source-fixture',
          title: '真实单软件.apk',
          url: 'https://www.lanzouw.com/software-fixture',
          shareUrl: 'https://www.lanzouw.com/software-fixture',
          isFolder: false,
        ),
      ],
    );
  }

  @override
  Future<LibrarySearchResult> catalogSearch({
    required String query,
    List<String> scopeIds = const [],
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) async {
    calls.add({'op': 'search', 'query': query});
    return const LibrarySearchResult();
  }

  @override
  Future<LibraryDescribeResult> catalogDescribe({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
  }) async => const LibraryDescribeResult(description: '真实公开软件简介');

  @override
  Future<LibraryResolveResult> catalogResolve({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
  }) async => const LibraryResolveResult(
    url: 'https://developer.mozilla.org/file.apk',
    fileName: 'file.apk',
  );

  @override
  Future<LibraryDownloadResult> catalogDownload({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
    required String destinationDirectory,
    String? operationId,
  }) async => LibraryDownloadResult(
    path: '$destinationDirectory/file.apk',
    fileName: 'file.apk',
    bytesWritten: 1,
  );

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) async =>
      LibraryOperationStatus(
        operationId: operationId,
        kind: 'library_search',
        state: LibraryOperationState.succeeded,
        completedUnits: 1,
        totalUnits: 1,
        bytesTransferred: 0,
        totalBytes: 0,
        itemsFound: 0,
      );

  @override
  Future<void> cancelOperation(String operationId) async {}

  @override
  Future<void> forgetOperation(String operationId) async {}
}

class FakeCloudService implements CloudService {
  final Map<String, List<CloudItem>> folders = <String, List<CloudItem>>{
    '-1': <CloudItem>[],
  };
  final List<CloudItem> recycleItems = <CloudItem>[];
  final List<String> calls = <String>[];
  final List<Map<String, Object?>> uploads = <Map<String, Object?>>[];
  final List<Map<String, Object?>> directoryUploads = <Map<String, Object?>>[];
  final List<Map<String, Object?>> replacements = <Map<String, Object?>>[];
  final Map<String, String> shareDescriptions = <String, String>{};

  CloudFailure? loginFailure;
  CloudFailure? restoreFailure;
  CloudFailure? listFailure;
  CloudFailure? shareInfoFailure;
  CloudFailure? getDescriptionFailure;
  CloudFailure? prepareIconFailure;
  CloudFailure? setIconFailure;
  CloudFailure? replaceFileFailure;
  CloudFailure? directoryUploadFailure;
  DirectoryUploadResult? directoryUploadResult;
  CloudFailure? accountCapabilitiesFailure;
  AccountCapabilities? accountCapabilitiesResult;
  Duration shareInfoDelay = Duration.zero;
  bool authenticated = true;
  bool omitUploadId = false;
  String userId = 'test-user-id';
  int _nextFolderId = 100;
  int _nextUploadId = 1000;

  @override
  Future<LoginResult> login(String account, String password) async {
    calls.add('login');
    if (loginFailure != null) throw loginFailure!;
    authenticated = true;
    return const LoginResult(cookie: 'test-session-cookie');
  }

  @override
  Future<void> restoreSession(String cookie) async {
    calls.add('restore_session');
    if (restoreFailure != null) throw restoreFailure!;
    authenticated = true;
  }

  @override
  Future<void> logout() async {
    calls.add('logout');
    authenticated = false;
  }

  @override
  Future<SessionInfo> sessionInfo() async {
    calls.add('session_info');
    return SessionInfo(authenticated: authenticated, userId: userId);
  }

  @override
  Future<CloudPage> listFolder(
    String folderId, {
    int page = 1,
    int pageSize = 200,
  }) async {
    calls.add('list:$folderId:$page');
    if (listFailure != null) throw listFailure!;
    return CloudPage(
      items: List<CloudItem>.of(folders[folderId] ?? const <CloudItem>[]),
      page: page,
      hasMore: false,
    );
  }

  @override
  Future<List<CloudItem>> moveTargets() async {
    calls.add('move_targets');
    return const <CloudItem>[
      CloudItem(id: '-1', name: '全部文件', isFolder: true, path: '/'),
      CloudItem(id: '20', name: '目标目录', isFolder: true, path: '/目标目录'),
    ];
  }

  @override
  Future<void> createFolder(
    String parentId,
    String name, {
    String description = '',
  }) async {
    calls.add('mkdir:$parentId:$name');
    folders
        .putIfAbsent(parentId, () => <CloudItem>[])
        .add(
          CloudItem(
            id: '${_nextFolderId++}',
            name: name,
            isFolder: true,
            description: description,
          ),
        );
  }

  @override
  Future<void> rename(CloudItem item, String name) async {
    calls.add('rename:${item.id}:$name');
  }

  @override
  Future<void> move(CloudItem item, String targetId) async {
    calls.add('move:${item.id}:$targetId');
  }

  @override
  Future<void> copy(
    CloudItem item,
    String targetId,
    String tempDirectory,
  ) async {
    calls.add('copy:${item.id}:$targetId');
  }

  @override
  Future<void> delete(CloudItem item) async {
    calls.add('delete:${item.id}');
    recycleItems.add(
      CloudItem(
        id: item.id,
        name: item.name,
        isFolder: item.isFolder,
        isRecycle: true,
      ),
    );
  }

  @override
  Future<ShareInfo> shareInfo(CloudItem item) async {
    calls.add('share_info:${item.id}');
    if (shareInfoDelay != Duration.zero) {
      await Future<void>.delayed(shareInfoDelay);
    }
    if (shareInfoFailure != null) throw shareInfoFailure!;
    return ShareInfo(
      id: item.id,
      isFolder: item.isFolder,
      name: item.name,
      shareUrl: 'https://example.invalid/share/${item.id}',
      password: 'ab12',
      description: shareDescriptions[item.id] ?? item.description ?? '',
      directUrl: item.isFolder
          ? null
          : 'https://example.invalid/download/${item.id}',
    );
  }

  @override
  Future<ManagedDescription> getDescription(CloudItem item) async {
    calls.add('get_description:${item.id}');
    if (shareInfoDelay != Duration.zero) {
      await Future<void>.delayed(shareInfoDelay);
    }
    if (getDescriptionFailure != null) throw getDescriptionFailure!;
    return ManagedDescription(
      id: item.id,
      isFolder: item.isFolder,
      name: item.name,
      description: shareDescriptions[item.id] ?? item.description ?? '',
    );
  }

  @override
  Future<AccountCapabilities> accountCapabilities() async {
    calls.add('account_capabilities');
    if (accountCapabilitiesFailure != null) {
      throw accountCapabilitiesFailure!;
    }
    final configured = accountCapabilitiesResult;
    if (configured != null) return configured;
    return AccountCapabilities(
      authenticated: authenticated,
      userId: userId,
      accountPortalUrl: Uri.parse(
        'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower',
      ),
      accountFeatures: const <String>['文件大小与云空间统计', '上传格式与下载限制'],
      membership: RemoteCapability(
        state: 'available',
        portalUrl: Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
        ),
        reason: '会员购买由蓝奏云官方页面管理',
        readable: false,
        writable: false,
        features: const <String>['会员购买与续费', '下载流量包'],
      ),
      personalization: RemoteCapability(
        state: 'available',
        portalUrl: Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
        ),
        reason: '个性化项目由蓝奏云官方页面管理',
        readable: false,
        writable: false,
        features: const <String>['发布者昵称', '文件头像', '下载页模板'],
      ),
      acceptsPaymentData: false,
    );
  }

  @override
  Future<void> setPassword(CloudItem item, String password) async {
    calls.add('set_password:${item.id}:$password');
  }

  @override
  Future<void> setDescription(CloudItem item, String description) async {
    calls.add('set_description:${item.id}:$description');
  }

  @override
  Future<UploadResult> upload(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    String? operationId,
  }) async {
    calls.add('upload:$folderId');
    uploads.add(<String, Object?>{
      'folderId': folderId,
      'path': path,
      'compatibilityWrap': compatibilityWrap,
      'kind': kind,
      'operationId': operationId,
    });
    return UploadResult(
      id: omitUploadId ? null : '${_nextUploadId++}',
      folderId: folderId,
      originalName: _fileName(path),
      uploadedName: _fileName(path),
    );
  }

  @override
  Future<DirectoryUploadResult> uploadDirectory(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    bool autoApkIcons = false,
    String? operationId,
  }) async {
    calls.add('upload_directory:$folderId');
    directoryUploads.add(<String, Object?>{
      'folderId': folderId,
      'path': path,
      'compatibilityWrap': compatibilityWrap,
      'kind': kind,
      'autoApkIcons': autoApkIcons,
      'operationId': operationId,
    });
    if (directoryUploadFailure != null) throw directoryUploadFailure!;
    return directoryUploadResult ??
        DirectoryUploadResult.fromJson(<String, Object?>{
          'state': 'succeeded',
          'atomic': false,
          'rootName': _fileName(path),
          'remoteRootId': '${_nextFolderId++}',
          'partialRemoteRetained': true,
          'totalDirectories': 1,
          'createdDirectories': 1,
          'totalFiles': 0,
          'processedFiles': 0,
          'uploadedFiles': 0,
          'totalBytes': 0,
          'uploadedBytes': 0,
          'autoApkIcons': autoApkIcons,
          'iconBoundFiles': 0,
          'failures': <Object?>[],
        });
  }

  @override
  Future<PreparedIcon> prepareIcon(
    String sourcePath, {
    String? outputPath,
  }) async {
    calls.add('prepare_icon:$sourcePath');
    if (prepareIconFailure != null) throw prepareIconFailure!;
    return PreparedIcon(
      path: outputPath ?? sourcePath,
      mediaType: 'image/png',
      bytes: 50000,
      width: 128,
      height: 128,
      sourceKind: 'image',
    );
  }

  @override
  Future<void> setIcon(String fileId, String path) async {
    calls.add('set_icon:$fileId:$path');
    if (setIconFailure != null) throw setIconFailure!;
  }

  @override
  Future<ReplaceFileResult> replaceFile({
    required CloudItem oldFile,
    required String folderId,
    required String path,
    bool compatibilityWrap = false,
    String? iconPath,
    String? operationId,
  }) async {
    calls.add('replace_file:${oldFile.id}:$folderId');
    replacements.add(<String, Object?>{
      'oldFileId': oldFile.id,
      'folderId': folderId,
      'path': path,
      'compatibilityWrap': compatibilityWrap,
      'iconPath': iconPath,
      'operationId': operationId,
    });
    if (replaceFileFailure != null) throw replaceFileFailure!;
    return ReplaceFileResult(
      oldFileId: oldFile.id,
      newFileId: 'replacement-${_nextUploadId++}',
      folderId: folderId,
      finalName: oldFile.name,
      uploadedName: _fileName(path),
      descriptionPreserved: true,
      iconApplied: iconPath != null,
      oldDeleted: true,
      cleanupRequired: false,
    );
  }

  @override
  Future<void> download(
    CloudItem item,
    String destination, {
    String? operationId,
  }) async {
    calls.add('download:${item.id}:$destination');
  }

  @override
  Future<CloudOperationStatus> operationStatus(String operationId) async {
    calls.add('operation_status:$operationId');
    return CloudOperationStatus(
      operationId: operationId,
      kind: 'upload',
      state: 'succeeded',
      completedUnits: 0,
      totalUnits: 0,
      bytesTransferred: 0,
      totalBytes: 0,
      itemsFound: 0,
    );
  }

  @override
  Future<CloudOperationStatus> operationCancel(String operationId) async {
    calls.add('operation_cancel:$operationId');
    return CloudOperationStatus(
      operationId: operationId,
      kind: 'upload',
      state: 'cancelling',
      completedUnits: 0,
      totalUnits: 0,
      bytesTransferred: 0,
      totalBytes: 0,
      itemsFound: 0,
    );
  }

  @override
  Future<void> operationForget(String operationId) async {
    calls.add('operation_forget:$operationId');
  }

  @override
  Future<List<CloudItem>> listRecycle() async {
    calls.add('recycle_list');
    return List<CloudItem>.of(recycleItems);
  }

  @override
  Future<void> restoreRecycle(CloudItem item) async {
    calls.add('recycle_restore:${item.id}');
    recycleItems.removeWhere((candidate) => candidate.id == item.id);
  }

  @override
  Future<void> purgeRecycle(CloudItem item) async {
    calls.add('recycle_purge:${item.id}');
    recycleItems.removeWhere((candidate) => candidate.id == item.id);
  }

  @override
  Future<void> emptyRecycle() async {
    calls.add('recycle_empty');
    recycleItems.clear();
  }
}

String _fileName(String path) => path.split(RegExp(r'[/\\]')).last;
