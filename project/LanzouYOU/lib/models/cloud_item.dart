class CloudItem {
  const CloudItem({
    required this.id,
    required this.name,
    required this.isFolder,
    this.size,
    this.modifiedAt,
    this.description,
    this.hasPassword = false,
    this.downloads,
    this.path,
    this.hasCustomIcon = false,
    this.iconUrl,
    this.isRecycle = false,
  });

  factory CloudItem.fromJson(Map<String, Object?> json) {
    return CloudItem(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      isFolder: json['isFolder'] == true,
      size: _optionalText(json['size']),
      modifiedAt: _optionalText(json['modifiedAt']),
      description: _optionalText(json['description']),
      hasPassword: json['hasPassword'] == true,
      downloads: (json['downloads'] as num?)?.toInt(),
      path: _optionalText(json['path']),
      hasCustomIcon: json['hasCustomIcon'] == true,
      iconUrl: _optionalText(json['iconUrl']),
      isRecycle: json['isRecycle'] == true,
    );
  }

  final String id;
  final String name;
  final bool isFolder;
  final String? size;
  final String? modifiedAt;
  final String? description;
  final bool hasPassword;
  final int? downloads;
  final String? path;
  final bool hasCustomIcon;
  final String? iconUrl;
  final bool isRecycle;
}

class CloudPage {
  const CloudPage({
    required this.items,
    required this.page,
    required this.hasMore,
  });

  factory CloudPage.fromJson(Map<String, Object?> json) {
    return CloudPage(
      items: cloudItemsFromJson(json['items']),
      page: (json['page'] as num?)?.toInt() ?? 1,
      hasMore: json['hasMore'] == true,
    );
  }

  final List<CloudItem> items;
  final int page;
  final bool hasMore;
}

class SessionInfo {
  const SessionInfo({required this.authenticated, this.userId});

  factory SessionInfo.fromJson(Map<String, Object?> json) {
    return SessionInfo(
      authenticated: json['authenticated'] == true,
      userId: _optionalText(json['userId']),
    );
  }

  final bool authenticated;
  final String? userId;
}

class ShareInfo {
  const ShareInfo({
    required this.id,
    required this.isFolder,
    required this.name,
    required this.shareUrl,
    required this.password,
    required this.description,
    this.directUrl,
  });

  factory ShareInfo.fromJson(Map<String, Object?> json) {
    return ShareInfo(
      id: '${json['id'] ?? ''}',
      isFolder: json['isFolder'] == true,
      name: '${json['name'] ?? ''}',
      shareUrl: '${json['shareUrl'] ?? ''}',
      password: '${json['password'] ?? ''}',
      description: '${json['description'] ?? ''}',
      directUrl: _optionalText(json['directUrl']),
    );
  }

  final String id;
  final bool isFolder;
  final String name;
  final String shareUrl;
  final String password;
  final String description;
  final String? directUrl;
}

class ManagedDescription {
  const ManagedDescription({
    required this.id,
    required this.isFolder,
    required this.name,
    required this.description,
  });

  factory ManagedDescription.fromJson(Map<String, Object?> json) {
    return ManagedDescription(
      id: _requiredText(json, 'id'),
      isFolder: json['isFolder'] == true,
      name: _presentText(json, 'name'),
      description: _presentText(json, 'description'),
    );
  }

  final String id;
  final bool isFolder;
  final String name;
  final String description;
}

class AccountCapabilities {
  const AccountCapabilities({
    required this.authenticated,
    required this.userId,
    required this.accountPortalUrl,
    required this.membership,
    required this.personalization,
    required this.acceptsPaymentData,
    this.accountFeatures = const <String>[],
  });

  factory AccountCapabilities.fromJson(Map<String, Object?> json) {
    final membership = _requiredMap(json, 'membership');
    final personalization = _requiredMap(json, 'personalization');
    return AccountCapabilities(
      authenticated: json['authenticated'] == true,
      userId: _optionalText(json['userId']),
      accountPortalUrl: _trustedWoozoooUrl(
        json['accountPortalUrl'],
        field: 'accountPortalUrl',
      )!,
      accountFeatures: _requiredStringList(json, 'accountFeatures'),
      membership: RemoteCapability(
        state: _requiredCapabilityState(membership),
        portalUrl: _trustedWoozoooUrl(
          membership['portalUrl'],
          field: 'membership.portalUrl',
          optional: true,
        ),
        reason: _presentText(membership, 'reason'),
        readable: membership['readable'] == true,
        writable: membership['writable'] == true,
        features: _requiredStringList(membership, 'features'),
      ),
      personalization: RemoteCapability(
        state: _requiredCapabilityState(personalization),
        portalUrl: _trustedWoozoooUrl(
          personalization['portalUrl'],
          field: 'personalization.portalUrl',
          optional: true,
        ),
        reason: _presentText(personalization, 'reason'),
        readable: personalization['readable'] == true,
        writable: personalization['writable'] == true,
        features: _requiredStringList(personalization, 'features'),
      ),
      acceptsPaymentData: json['acceptsPaymentData'] == true,
    );
  }

  final bool authenticated;
  final String? userId;
  final Uri accountPortalUrl;
  final RemoteCapability membership;
  final RemoteCapability personalization;
  final bool acceptsPaymentData;
  final List<String> accountFeatures;
}

class RemoteCapability {
  const RemoteCapability({
    required this.state,
    required this.portalUrl,
    required this.reason,
    required this.readable,
    required this.writable,
    this.features = const <String>[],
  });

  final String state;
  final Uri? portalUrl;
  final String reason;
  final bool readable;
  final bool writable;
  final List<String> features;

  bool get available => state == 'available';
}

class ReplaceFileResult {
  const ReplaceFileResult({
    required this.oldFileId,
    required this.newFileId,
    required this.folderId,
    required this.finalName,
    required this.uploadedName,
    required this.descriptionPreserved,
    required this.iconApplied,
    required this.oldDeleted,
    required this.cleanupRequired,
  });

  factory ReplaceFileResult.fromJson(Map<String, Object?> json) {
    if (json['replaced'] != true) {
      throw const FormatException('核心未确认换包成功');
    }
    return ReplaceFileResult(
      oldFileId: _requiredText(json, 'oldFileId'),
      newFileId: _requiredText(json, 'newFileId'),
      folderId: _requiredText(json, 'folderId'),
      finalName: _requiredText(json, 'finalName'),
      uploadedName: _requiredText(json, 'uploadedName'),
      descriptionPreserved: json['descriptionPreserved'] == true,
      iconApplied: json['iconApplied'] == true,
      oldDeleted: json['oldDeleted'] == true,
      cleanupRequired: json['cleanupRequired'] == true,
    );
  }

  final String oldFileId;
  final String newFileId;
  final String folderId;
  final String finalName;
  final String uploadedName;
  final bool descriptionPreserved;
  final bool iconApplied;
  final bool oldDeleted;
  final bool cleanupRequired;
}

class UploadResult {
  const UploadResult({
    required this.folderId,
    required this.originalName,
    required this.uploadedName,
    this.id,
  });

  factory UploadResult.fromJson(Map<String, Object?> json) {
    return UploadResult(
      id: _optionalText(json['id']),
      folderId: '${json['folderId'] ?? ''}',
      originalName: '${json['originalName'] ?? ''}',
      uploadedName: '${json['uploadedName'] ?? ''}',
    );
  }

  final String? id;
  final String folderId;
  final String originalName;
  final String uploadedName;
}

class PreparedIcon {
  const PreparedIcon({
    required this.path,
    required this.mediaType,
    required this.bytes,
    required this.width,
    required this.height,
    required this.sourceKind,
  });

  factory PreparedIcon.fromJson(Map<String, Object?> json) {
    return PreparedIcon(
      path: '${json['path'] ?? ''}',
      mediaType: '${json['mediaType'] ?? ''}',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      sourceKind: '${json['sourceKind'] ?? ''}',
    );
  }

  final String path;
  final String mediaType;
  final int bytes;
  final int width;
  final int height;
  final String sourceKind;
}

class FolderCrumb {
  const FolderCrumb(this.id, this.name);

  final String id;
  final String name;
}

List<CloudItem> cloudItemsFromJson(Object? value) {
  if (value is! List) return const <CloudItem>[];
  return value
      .whereType<Map>()
      .map((item) => CloudItem.fromJson(item.cast<String, Object?>()))
      .toList(growable: false);
}

String? _optionalText(Object? value) {
  if (value == null) return null;
  final text = '$value';
  return text.isEmpty ? null : text;
}

String _requiredText(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('核心响应缺少 $key');
}

String _presentText(Map<String, Object?> json, String key) {
  if (!json.containsKey(key) || json[key] is! String) {
    throw FormatException('核心响应缺少 $key');
  }
  return json[key]! as String;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is Map) return value.cast<String, Object?>();
  throw FormatException('核心响应缺少 $key');
}

List<String> _requiredStringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List ||
      value.length > 64 ||
      value.any(
        (item) => item is! String || item.isEmpty || item.length > 64,
      )) {
    throw FormatException('核心响应包含无效 $key');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

String _requiredCapabilityState(Map<String, Object?> json) {
  final value = json['state'];
  if (value == 'available' || value == 'unavailable') return value! as String;
  throw const FormatException('核心响应包含无效 capability state');
}

Uri? _trustedWoozoooUrl(
  Object? value, {
  required String field,
  bool optional = false,
}) {
  if (value == null && optional) return null;
  final uri = value is String ? Uri.tryParse(value) : null;
  final host = uri?.host.toLowerCase();
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      host == null ||
      (host != 'woozooo.com' && !host.endsWith('.woozooo.com'))) {
    throw FormatException('核心响应包含不受信任的 $field');
  }
  return uri;
}
