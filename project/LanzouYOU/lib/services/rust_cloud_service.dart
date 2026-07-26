import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:lanzou_library_shell/library_preview.dart';
import 'package:lanzou_library_shell/services/json_core_transport.dart';

import '../models/cloud_item.dart';
import '../models/directory_upload.dart';
import 'cloud_service.dart';

class RustCloudService implements CloudService, CloudServiceLifecycle {
  RustCloudService()
    : this.testHarness(PersistentIsolateJsonCoreTransport.production());

  @visibleForTesting
  RustCloudService.testHarness(this._transport);

  final JsonCoreTransport _transport;

  Future<Map<String, Object?>> dispatchRaw(Map<String, Object?> request) =>
      _request(request);

  Future<Map<String, Object?>> _request(Map<String, Object?> request) async {
    final String response;
    try {
      response = await _transport.dispatch(jsonEncode(request));
    } on LibraryCoreFailure catch (error) {
      throw CloudFailure(error.code, error.message, retriable: error.retriable);
    } on CloudFailure {
      rethrow;
    } on Object {
      throw const CloudFailure(
        'core_unavailable',
        'LanzouYOU 核心不可用，请安装包含原生核心的完整版本',
        retriable: true,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response);
    } on Object {
      throw const CloudFailure('invalid_response', '核心返回了无效数据');
    }
    if (decoded is! Map) {
      throw const CloudFailure('invalid_response', '核心返回了无效数据');
    }
    final envelope = decoded.cast<String, Object?>();
    if (envelope['ok'] != true) {
      final rawError = envelope['error'];
      final error = rawError is Map
          ? rawError.cast<String, Object?>()
          : const <String, Object?>{};
      throw CloudFailure(
        '${error['code'] ?? 'core_error'}',
        '${error['message'] ?? '核心操作失败'}',
        retriable: error['retriable'] == true,
        details: error['details'] is Map
            ? (error['details'] as Map).cast<String, Object?>()
            : const <String, Object?>{},
      );
    }
    final data = envelope['data'];
    return data is Map ? data.cast<String, Object?>() : <String, Object?>{};
  }

  @override
  Future<void> close() {
    final transport = _transport;
    return transport is ClosableJsonCoreTransport
        ? transport.close()
        : Future<void>.value();
  }

  @override
  Future<LoginResult> login(String account, String password) async {
    final data = await _request({
      'op': 'login',
      'account': account,
      'password': password,
    });
    final cookie = data['cookie'];
    if (cookie is! String || cookie.isEmpty) {
      throw const CloudFailure('invalid_response', '登录响应缺少会话信息');
    }
    return LoginResult(cookie: cookie);
  }

  @override
  Future<void> restoreSession(String cookie) async {
    await _request({'op': 'restore_session', 'cookie': cookie});
  }

  @override
  Future<void> logout() async {
    await _request({'op': 'logout'});
  }

  @override
  Future<SessionInfo> sessionInfo() async {
    return SessionInfo.fromJson(await _request({'op': 'session_info'}));
  }

  @override
  Future<CloudPage> listFolder(
    String folderId, {
    int page = 1,
    int pageSize = 200,
  }) async {
    return CloudPage.fromJson(
      await _request({
        'op': 'list',
        'folderId': folderId,
        'page': page,
        'pageSize': pageSize,
      }),
    );
  }

  @override
  Future<void> createFolder(
    String parentId,
    String name, {
    String description = '',
  }) async {
    await _request({
      'op': 'mkdir',
      'parentId': parentId,
      'name': name,
      'description': description,
    });
  }

  @override
  Future<List<CloudItem>> moveTargets() async {
    final data = await _request({'op': 'move_targets'});
    return cloudItemsFromJson(data['items']);
  }

  @override
  Future<void> rename(CloudItem item, String name) async {
    await _request({
      'op': 'rename',
      'id': item.id,
      'isFolder': item.isFolder,
      'name': name,
    });
  }

  @override
  Future<void> move(CloudItem item, String targetId) async {
    await _request({
      'op': 'move',
      'id': item.id,
      'isFolder': item.isFolder,
      'targetId': targetId,
    });
  }

  @override
  Future<void> copy(
    CloudItem item,
    String targetId,
    String tempDirectory,
  ) async {
    await _request({
      'op': 'copy',
      'id': item.id,
      'isFolder': item.isFolder,
      'name': item.name,
      'targetId': targetId,
      'tempDir': tempDirectory,
    });
  }

  @override
  Future<void> delete(CloudItem item) async {
    await _request({'op': 'delete', 'id': item.id, 'isFolder': item.isFolder});
  }

  @override
  Future<ShareInfo> shareInfo(CloudItem item) async {
    return ShareInfo.fromJson(
      await _request({
        'op': 'share_info',
        'id': item.id,
        'isFolder': item.isFolder,
      }),
    );
  }

  @override
  Future<ManagedDescription> getDescription(CloudItem item) async {
    return ManagedDescription.fromJson(
      await _request({
        'op': 'get_description',
        'id': item.id,
        'isFolder': item.isFolder,
      }),
    );
  }

  @override
  Future<AccountCapabilities> accountCapabilities() async {
    return AccountCapabilities.fromJson(
      await _request({'op': 'account_capabilities'}),
    );
  }

  @override
  Future<void> setPassword(CloudItem item, String password) async {
    await _request({
      'op': 'set_password',
      'id': item.id,
      'isFolder': item.isFolder,
      'password': password,
    });
  }

  @override
  Future<void> setDescription(CloudItem item, String description) async {
    await _request({
      'op': 'set_description',
      'id': item.id,
      'isFolder': item.isFolder,
      'description': description,
    });
  }

  @override
  Future<UploadResult> upload(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    String? operationId,
  }) async {
    return UploadResult.fromJson(
      await _request({
        'op': 'upload',
        'folderId': folderId,
        'path': path,
        'compatWrap': compatibilityWrap,
        'kind': kind,
        'operationId': ?operationId,
      }),
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
    return DirectoryUploadResult.fromJson(
      await _request({
        'op': 'upload_directory',
        'folderId': folderId,
        'path': path,
        'compatWrap': compatibilityWrap,
        'kind': kind,
        'autoApkIcons': autoApkIcons,
        'operationId': ?operationId,
      }),
    );
  }

  @override
  Future<PreparedIcon> prepareIcon(
    String sourcePath, {
    String? outputPath,
  }) async {
    return PreparedIcon.fromJson(
      await _request({
        'op': 'prepare_icon',
        'sourcePath': sourcePath,
        'outputPath': ?outputPath,
      }),
    );
  }

  @override
  Future<void> setIcon(String fileId, String path) async {
    await _request({'op': 'set_icon', 'fileId': fileId, 'path': path});
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
    if (oldFile.isFolder) {
      throw const CloudFailure('invalid_argument', '目录不能执行 APK 换包');
    }
    return ReplaceFileResult.fromJson(
      await _request({
        'op': 'replace_file',
        'oldFileId': oldFile.id,
        'folderId': folderId,
        'path': path,
        'compatWrap': compatibilityWrap,
        'iconPath': ?iconPath,
        'operationId': ?operationId,
      }),
    );
  }

  @override
  Future<void> download(
    CloudItem item,
    String destination, {
    String? operationId,
  }) async {
    await _request({
      'op': 'download',
      'id': item.id,
      'name': item.name,
      'destination': destination,
      'operationId': ?operationId,
    });
  }

  @override
  Future<CloudOperationStatus> operationStatus(String operationId) async {
    return CloudOperationStatus.fromJson(
      await _request({'op': 'operation_status', 'operationId': operationId}),
    );
  }

  @override
  Future<CloudOperationStatus> operationCancel(String operationId) async {
    return CloudOperationStatus.fromJson(
      await _request({'op': 'operation_cancel', 'operationId': operationId}),
    );
  }

  @override
  Future<void> operationForget(String operationId) async {
    await _request({'op': 'operation_forget', 'operationId': operationId});
  }

  @override
  Future<List<CloudItem>> listRecycle() async {
    final data = await _request({'op': 'recycle_list'});
    return cloudItemsFromJson(data['items']);
  }

  @override
  Future<void> restoreRecycle(CloudItem item) async {
    await _request({
      'op': 'recycle_restore',
      'id': item.id,
      'isFolder': item.isFolder,
    });
  }

  @override
  Future<void> purgeRecycle(CloudItem item) async {
    await _request({
      'op': 'recycle_purge',
      'id': item.id,
      'isFolder': item.isFolder,
    });
  }

  @override
  Future<void> emptyRecycle() async {
    await _request({'op': 'recycle_empty'});
  }
}
