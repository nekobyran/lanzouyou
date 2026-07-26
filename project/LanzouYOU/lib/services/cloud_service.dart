import '../models/cloud_item.dart';
import '../models/directory_upload.dart';

class CloudFailure implements Exception {
  const CloudFailure(
    this.code,
    this.message, {
    this.retriable = false,
    this.details = const <String, Object?>{},
  });

  final String code;
  final String message;
  final bool retriable;
  final Map<String, Object?> details;

  bool get isSessionExpired =>
      code == 'session_expired' || code == 'unauthenticated';

  @override
  String toString() => message;
}

class LoginResult {
  const LoginResult({required this.cookie});

  final String cookie;
}

class CloudOperationStatus {
  const CloudOperationStatus({
    required this.operationId,
    required this.kind,
    required this.state,
    required this.completedUnits,
    required this.totalUnits,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.itemsFound,
  });

  factory CloudOperationStatus.fromJson(Map<String, Object?> json) {
    return CloudOperationStatus(
      operationId: _requiredOperationId(json),
      kind: _requiredChoice(json, 'kind', const <String>{
        'upload',
        'directory_upload',
        'replace_file',
        'download',
        'library_search',
      }),
      state: _requiredChoice(json, 'state', const <String>{
        'running',
        'cancelling',
        'succeeded',
        'cancelled',
        'failed',
      }),
      completedUnits: _requiredInt(json, 'completedUnits'),
      totalUnits: _requiredInt(json, 'totalUnits'),
      bytesTransferred: _requiredInt(json, 'bytesTransferred'),
      totalBytes: _requiredInt(json, 'totalBytes'),
      itemsFound: _requiredInt(json, 'itemsFound'),
    );
  }

  final String operationId;
  final String kind;
  final String state;
  final int completedUnits;
  final int totalUnits;
  final int bytesTransferred;
  final int totalBytes;
  final int itemsFound;
}

abstract interface class CloudService {
  Future<LoginResult> login(String account, String password);

  Future<void> restoreSession(String cookie);

  Future<void> logout();

  Future<SessionInfo> sessionInfo();

  Future<CloudPage> listFolder(
    String folderId, {
    int page = 1,
    int pageSize = 200,
  });

  Future<List<CloudItem>> moveTargets();

  Future<void> createFolder(
    String parentId,
    String name, {
    String description = '',
  });

  Future<void> rename(CloudItem item, String name);

  Future<void> move(CloudItem item, String targetId);

  Future<void> copy(CloudItem item, String targetId, String tempDirectory);

  Future<void> delete(CloudItem item);

  Future<ShareInfo> shareInfo(CloudItem item);

  Future<ManagedDescription> getDescription(CloudItem item);

  Future<AccountCapabilities> accountCapabilities();

  Future<void> setPassword(CloudItem item, String password);

  Future<void> setDescription(CloudItem item, String description);

  Future<UploadResult> upload(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    String? operationId,
  });

  Future<DirectoryUploadResult> uploadDirectory(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    bool autoApkIcons = false,
    String? operationId,
  });

  Future<PreparedIcon> prepareIcon(String sourcePath, {String? outputPath});

  Future<void> setIcon(String fileId, String path);

  Future<ReplaceFileResult> replaceFile({
    required CloudItem oldFile,
    required String folderId,
    required String path,
    bool compatibilityWrap = false,
    String? iconPath,
    String? operationId,
  });

  Future<void> download(
    CloudItem item,
    String destination, {
    String? operationId,
  });

  Future<CloudOperationStatus> operationStatus(String operationId);

  Future<CloudOperationStatus> operationCancel(String operationId);

  Future<void> operationForget(String operationId);

  Future<List<CloudItem>> listRecycle();

  Future<void> restoreRecycle(CloudItem item);

  Future<void> purgeRecycle(CloudItem item);

  Future<void> emptyRecycle();
}

/// Optional lifecycle for services that own persistent native worker isolates.
abstract interface class CloudServiceLifecycle {
  Future<void> close();
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw CloudFailure('invalid_response', '核心返回的操作状态无效：$key');
}

String _requiredOperationId(Map<String, Object?> json) {
  final value = _requiredString(json, 'operationId');
  if (RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(value)) return value;
  throw const CloudFailure('invalid_response', '核心返回的操作状态无效：operationId');
}

String _requiredChoice(
  Map<String, Object?> json,
  String key,
  Set<String> choices,
) {
  final value = _requiredString(json, key);
  if (choices.contains(value)) return value;
  throw CloudFailure('invalid_response', '核心返回的操作状态无效：$key');
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int && value >= 0) return value;
  throw CloudFailure('invalid_response', '核心返回的操作状态无效：$key');
}
