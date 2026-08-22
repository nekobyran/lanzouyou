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

enum MembershipState { vip, free, unknown }

class MembershipProfile {
  const MembershipProfile({
    required this.state,
    required this.displayName,
    required this.reason,
    this.level,
    this.expiresAt,
  });

  factory MembershipProfile.fromJson(Map<String, Object?> json) {
    return MembershipProfile(
      state: _requiredMembershipState(json['state']),
      displayName: _requiredBoundedText(json, 'displayName', maxLength: 160),
      level: _optionalBoundedText(json, 'level', maxLength: 160),
      expiresAt: _optionalDate(json, 'expiresAt'),
      reason: _presentBoundedText(json, 'reason', maxLength: 512),
    );
  }

  final MembershipState state;
  final String displayName;
  final String? level;
  final DateTime? expiresAt;
  final String reason;
}

class AccountEntry {
  const AccountEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.portalUrl,
    required this.available,
    required this.requiresOfficialConfirmation,
    required this.dangerous,
  });

  factory AccountEntry.fromJson(Map<String, Object?> json) {
    final id = _requiredBoundedText(json, 'id', maxLength: 64);
    return AccountEntry(
      id: id,
      title: _requiredBoundedText(json, 'title', maxLength: 128),
      description: _presentBoundedText(json, 'description', maxLength: 512),
      portalUrl: _trustedAccountEntryUrl(json['portalUrl'], id: id),
      available: _requiredBool(json, 'available'),
      requiresOfficialConfirmation: _requiredBool(
        json,
        'requiresOfficialConfirmation',
      ),
      dangerous: _requiredBool(json, 'dangerous'),
    );
  }

  final String id;
  final String title;
  final String description;
  final Uri portalUrl;
  final bool available;
  final bool requiresOfficialConfirmation;
  final bool dangerous;
}

class AccountFact {
  const AccountFact({
    required this.id,
    required this.label,
    required this.known,
    this.value,
  });

  factory AccountFact.fromJson(Map<String, Object?> json) {
    return AccountFact(
      id: _requiredBoundedText(json, 'id', maxLength: 64),
      label: _requiredBoundedText(json, 'label', maxLength: 128),
      value: _optionalBoundedText(json, 'value', maxLength: 160),
      known: _requiredBool(json, 'known'),
    );
  }

  final String id;
  final String label;
  final String? value;
  final bool known;
}

class MembershipPlan {
  const MembershipPlan({
    required this.id,
    required this.label,
    required this.detail,
    required this.available,
    this.priceLabel,
  });

  factory MembershipPlan.fromJson(Map<String, Object?> json) {
    return MembershipPlan(
      id: _requiredBoundedText(json, 'id', maxLength: 64),
      label: _requiredBoundedText(json, 'label', maxLength: 128),
      detail: _presentBoundedText(json, 'detail', maxLength: 512),
      priceLabel: _optionalBoundedText(json, 'priceLabel', maxLength: 64),
      available: _requiredBool(json, 'available'),
    );
  }

  final String id;
  final String label;
  final String detail;
  final String? priceLabel;
  final bool available;
}

class PersonalizationSetting {
  const PersonalizationSetting({
    required this.id,
    required this.title,
    required this.description,
    required this.available,
    required this.writable,
    required this.reason,
    this.enabled,
    this.value,
  });

  factory PersonalizationSetting.fromJson(Map<String, Object?> json) {
    final writable = _requiredBool(json, 'writable');
    if (writable) {
      throw const FormatException('会员个性化写入能力尚未验证');
    }
    return PersonalizationSetting(
      id: _requiredBoundedText(json, 'id', maxLength: 64),
      title: _requiredBoundedText(json, 'title', maxLength: 128),
      description: _presentBoundedText(json, 'description', maxLength: 512),
      available: _requiredBool(json, 'available'),
      enabled: _optionalBool(json, 'enabled'),
      value: _optionalBoundedText(json, 'value', maxLength: 160),
      writable: writable,
      reason: _presentBoundedText(json, 'reason', maxLength: 512),
    );
  }

  final String id;
  final String title;
  final String description;
  final bool available;
  final bool? enabled;
  final String? value;
  final bool writable;
  final String reason;
}

const _accountEntryIds = <String>[
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

const _accountFactIds = <String>[
  'singleFileLimit',
  'storageStatistics',
  'downloadWithoutLogin',
  'downloadSpeed',
  'downloadCount',
  'downloadTraffic',
  'storageCapacity',
  'allowedUploadTypes',
];

const _membershipPlanIds = <String>[
  'month1',
  'month2',
  'month6',
  'year1',
  'monthly',
  'yearly',
  'downloadPack',
];

const _personalizationSettingIds = <String>[
  'adFreeDownloads',
  'uploadTimeVisibility',
  'subfolders',
  'search',
  'defaultFilePassword',
  'avatarUpload',
  'downloadPageTemplate',
  'publisherNickname',
  'dailyDownloadReport',
  'fileRetention',
  'directLinkDomain',
];

class AccountCapabilities {
  const AccountCapabilities({
    required this.authenticated,
    required this.userId,
    required this.accountPortalUrl,
    required this.membershipPortalUrl,
    required this.personalizationPortalUrl,
    required this.membershipProfile,
    required this.entries,
    required this.facts,
    required this.plans,
    required this.personalization,
    required this.acceptsPaymentData,
  });

  factory AccountCapabilities.fromJson(Map<String, Object?> json) {
    final acceptsPaymentData = _requiredBool(json, 'acceptsPaymentData');
    if (acceptsPaymentData) {
      throw const FormatException('核心响应不得请求付款数据');
    }
    final entries = _requiredObjectList(
      json,
      'entries',
      maxItems: 16,
      parse: AccountEntry.fromJson,
    );
    final facts = _requiredObjectList(
      json,
      'facts',
      maxItems: 32,
      parse: AccountFact.fromJson,
    );
    final plans = _requiredObjectList(
      json,
      'plans',
      maxItems: 8,
      parse: MembershipPlan.fromJson,
    );
    final personalization = _requiredObjectList(
      json,
      'personalization',
      maxItems: 32,
      parse: PersonalizationSetting.fromJson,
    );
    _requireExactIds(
      entries.map((entry) => entry.id),
      _accountEntryIds,
      'entries',
    );
    _requireExactIds(facts.map((fact) => fact.id), _accountFactIds, 'facts');
    _requireExactIds(plans.map((plan) => plan.id), _membershipPlanIds, 'plans');
    _requireExactIds(
      personalization.map((setting) => setting.id),
      _personalizationSettingIds,
      'personalization',
    );
    return AccountCapabilities(
      authenticated: _requiredBool(json, 'authenticated'),
      userId: _requiredBoundedText(json, 'userId', maxLength: 128),
      accountPortalUrl: _trustedPortalUrl(
        json['accountPortalUrl'],
        field: 'accountPortalUrl',
        item: 'profile',
        action: 'mypower',
      ),
      membershipPortalUrl: _trustedPortalUrl(
        json['membershipPortalUrl'],
        field: 'membershipPortalUrl',
        item: 'profile',
        action: 'huiyuan',
      ),
      personalizationPortalUrl: _trustedPortalUrl(
        json['personalizationPortalUrl'],
        field: 'personalizationPortalUrl',
        item: 'profile',
        action: 'huiyuan',
      ),
      membershipProfile: MembershipProfile.fromJson(
        _requiredMap(json, 'membershipProfile'),
      ),
      entries: entries,
      facts: facts,
      plans: plans,
      personalization: personalization,
      acceptsPaymentData: acceptsPaymentData,
    );
  }

  final bool authenticated;
  final String userId;
  final Uri accountPortalUrl;
  final Uri membershipPortalUrl;
  final Uri personalizationPortalUrl;
  final MembershipProfile membershipProfile;
  final List<AccountEntry> entries;
  final List<AccountFact> facts;
  final List<MembershipPlan> plans;
  final List<PersonalizationSetting> personalization;
  final bool acceptsPaymentData;
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

String _requiredBoundedText(
  Map<String, Object?> json,
  String key, {
  required int maxLength,
}) {
  final value = json[key];
  if (value is String && value.isNotEmpty && value.length <= maxLength) {
    return value;
  }
  throw FormatException('核心响应包含无效 $key');
}

String _presentBoundedText(
  Map<String, Object?> json,
  String key, {
  required int maxLength,
}) {
  final value = json[key];
  if (value is String && value.length <= maxLength) return value;
  throw FormatException('核心响应包含无效 $key');
}

String? _optionalBoundedText(
  Map<String, Object?> json,
  String key, {
  required int maxLength,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is String && value.isNotEmpty && value.length <= maxLength) {
    return value;
  }
  throw FormatException('核心响应包含无效 $key');
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('核心响应包含无效 $key');
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is bool) return value;
  throw FormatException('核心响应包含无效 $key');
}

MembershipState _requiredMembershipState(Object? value) {
  return switch (value) {
    'vip' => MembershipState.vip,
    'free' => MembershipState.free,
    'unknown' => MembershipState.unknown,
    _ => throw const FormatException('核心响应包含无效会员状态'),
  };
}

DateTime? _optionalDate(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  final match = value is String
      ? RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value)
      : null;
  if (match == null) {
    throw FormatException('核心响应包含无效 $key');
  }
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    throw FormatException('核心响应包含无效 $key');
  }
  return date;
}

List<T> _requiredObjectList<T>(
  Map<String, Object?> json,
  String key, {
  required int maxItems,
  required T Function(Map<String, Object?>) parse,
}) {
  final value = json[key];
  if (value is! List || value.length > maxItems) {
    throw FormatException('核心响应包含无效 $key');
  }
  final result = <T>[];
  for (final item in value) {
    if (item is! Map) {
      throw FormatException('核心响应包含无效 $key');
    }
    result.add(parse(item.cast<String, Object?>()));
  }
  return List<T>.unmodifiable(result);
}

void _requireExactIds(
  Iterable<String> actualValues,
  List<String> expected,
  String field,
) {
  final actual = actualValues.toList(growable: false);
  if (actual.length != expected.length) {
    throw FormatException('核心响应缺少完整 $field');
  }
  for (var index = 0; index < expected.length; index++) {
    if (actual[index] != expected[index]) {
      throw FormatException('核心响应包含无效或重复的 $field');
    }
  }
}

const _accountEntryRoutes = <String, (String, String)>{
  'permissions': ('profile', 'mypower'),
  'balance': ('profile', 'goods'),
  'fileUpgrade': ('profile', 'buygoods'),
  'downloadCashout': ('profile', 'exchange'),
  'cashoutRecords': ('profile', 'orders'),
  'invite': ('buddy', 'invite'),
  'password': ('profile', 'password'),
  'phone': ('profile', 'mypower'),
  'closeAccount': ('profile', 'mypower'),
};

Uri _trustedAccountEntryUrl(Object? value, {required String id}) {
  final route = _accountEntryRoutes[id];
  if (route == null) {
    throw const FormatException('核心响应包含无效账号入口');
  }
  return _trustedPortalUrl(
    value,
    field: 'entries.$id.portalUrl',
    item: route.$1,
    action: route.$2,
  );
}

const _trustedAccountPortalRoutes = <String>{
  'profile:mypower',
  'profile:huiyuan',
  'profile:goods',
  'profile:buygoods',
  'profile:exchange',
  'profile:orders',
  'profile:password',
  'buddy:invite',
};

bool isTrustedAccountPortalUri(Uri uri) {
  final query = uri.queryParametersAll;
  final items = query['item'];
  final actions = query['action'];
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.host != 'pc.woozooo.com' ||
      uri.path != '/mydisk.php' ||
      uri.fragment.isNotEmpty ||
      query.length != 2 ||
      items == null ||
      items.length != 1 ||
      actions == null ||
      actions.length != 1) {
    return false;
  }
  return _trustedAccountPortalRoutes.contains(
    '${items.single}:${actions.single}',
  );
}

Uri _trustedPortalUrl(
  Object? value, {
  required String field,
  required String item,
  required String action,
}) {
  final uri = value is String ? Uri.tryParse(value) : null;
  final query = uri?.queryParametersAll;
  final items = query?['item'];
  final actions = query?['action'];
  if (uri == null ||
      !isTrustedAccountPortalUri(uri) ||
      items == null ||
      items.single != item ||
      actions == null ||
      actions.single != action) {
    throw FormatException('核心响应包含不受信任的 $field');
  }
  return uri;
}
