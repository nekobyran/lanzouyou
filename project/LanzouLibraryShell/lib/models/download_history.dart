enum DownloadHistoryStatus {
  queued,
  resolving,
  downloading,
  cancelling,
  succeeded,
  cancelled,
  failed;

  bool get isTerminal => switch (this) {
    succeeded || cancelled || failed => true,
    queued || resolving || downloading || cancelling => false,
  };
}

enum DownloadActivityState {
  queued,
  resolving,
  downloading,
  cancelling,
  succeeded,
  cancelled,
  failed;

  bool get isTerminal => switch (this) {
    succeeded || cancelled || failed => true,
    queued || resolving || downloading || cancelling => false,
  };
}

/// Semantic suffix groups shared by the downloads page and tests.
///
/// This intentionally classifies by the final suffix only. It does not inspect
/// file contents and therefore never claims that an unverified file is safe to
/// install or open.
enum DownloadExtensionCategory {
  all,
  installationPackage,
  application,
  archive,
  document,
  video,
  audio,
  other,
}

DownloadExtensionCategory classifyDownloadExtension(String fileName) {
  final normalized = fileName.trim().replaceAll('\\', '/');
  final baseName = normalized.substring(normalized.lastIndexOf('/') + 1);
  final dot = baseName.lastIndexOf('.');
  final extension = dot >= 0 && dot < baseName.length - 1
      ? baseName.substring(dot + 1).toUpperCase()
      : '';
  if (_installationPackageExtensions.contains(extension)) {
    return DownloadExtensionCategory.installationPackage;
  }
  if (_applicationExtensions.contains(extension)) {
    return DownloadExtensionCategory.application;
  }
  if (_archiveExtensions.contains(extension)) {
    return DownloadExtensionCategory.archive;
  }
  if (_documentExtensions.contains(extension)) {
    return DownloadExtensionCategory.document;
  }
  if (_videoExtensions.contains(extension)) {
    return DownloadExtensionCategory.video;
  }
  if (_audioExtensions.contains(extension)) {
    return DownloadExtensionCategory.audio;
  }
  return DownloadExtensionCategory.other;
}

class DownloadHistoryEntry {
  const DownloadHistoryEntry({
    required this.id,
    required this.operationId,
    required this.sourceId,
    required this.shareUrl,
    required this.itemStableKey,
    required this.displayName,
    required this.suggestedFileName,
    required this.filePath,
    required this.status,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
    this.errorCode = '',
    this.errorMessage = '',
  });

  factory DownloadHistoryEntry.fromJson(Map<String, Object?> json) {
    if (json.keys.any((key) {
      final normalized = key.toLowerCase();
      return normalized.contains('password') || normalized.contains('cookie');
    })) {
      throw const FormatException('download history contains credentials');
    }
    final unexpected = json.keys.toSet().difference(_historyJsonKeys);
    if (unexpected.isNotEmpty) {
      throw FormatException(
        'unexpected download history field: ${unexpected.first}',
      );
    }
    final id = _requiredBoundedString(json, 'id', 64);
    final operationId = _requiredBoundedString(json, 'operationId', 64);
    if (!_operationIdPattern.hasMatch(id) ||
        !_operationIdPattern.hasMatch(operationId)) {
      throw const FormatException('download history ID is invalid');
    }
    final sourceId = _requiredBoundedString(json, 'sourceId', 128);
    final shareUrl = _requiredBoundedString(json, 'shareUrl', 4096);
    if (!isSafeDownloadShareUrl(shareUrl)) {
      throw const FormatException(
        'download shareUrl must be credential-free HTTPS',
      );
    }
    final itemStableKey = _requiredBoundedString(json, 'itemStableKey', 8192);
    final displayName = _requiredBoundedString(json, 'displayName', 512);
    final suggestedFileName = _boundedString(json, 'suggestedFileName', 512);
    final filePath = _boundedString(json, 'filePath', 32768);
    final rawStatus = _requiredBoundedString(json, 'status', 32);
    final statuses = DownloadHistoryStatus.values.where(
      (candidate) => candidate.name == rawStatus,
    );
    if (statuses.length != 1) {
      throw const FormatException('download history status is invalid');
    }
    final status = statuses.single;
    final bytesTransferred = _nonNegativeInt(json, 'bytesTransferred');
    final totalBytes = _nonNegativeInt(json, 'totalBytes');
    if (totalBytes > 0 && bytesTransferred > totalBytes) {
      throw const FormatException('download progress exceeds total bytes');
    }
    final createdAt = _dateTime(json, 'createdAt');
    final updatedAt = _dateTime(json, 'updatedAt');
    final completedAt = _nullableDateTime(json, 'completedAt');
    if (updatedAt.isBefore(createdAt) ||
        (completedAt != null && completedAt.isBefore(createdAt)) ||
        (status == DownloadHistoryStatus.succeeded &&
            (filePath.isEmpty || completedAt == null)) ||
        (status.isTerminal && completedAt == null)) {
      throw const FormatException('download history timestamps are invalid');
    }
    return DownloadHistoryEntry(
      id: id,
      operationId: operationId,
      sourceId: sourceId,
      shareUrl: shareUrl,
      itemStableKey: itemStableKey,
      displayName: displayName,
      suggestedFileName: suggestedFileName,
      filePath: filePath,
      status: status,
      bytesTransferred: bytesTransferred,
      totalBytes: totalBytes,
      createdAt: createdAt,
      updatedAt: updatedAt,
      completedAt: completedAt,
      errorCode: _boundedString(json, 'errorCode', 128),
      errorMessage: _boundedString(json, 'errorMessage', 1024),
    );
  }

  final String id;
  final String operationId;
  final String sourceId;
  final String shareUrl;
  final String itemStableKey;
  final String displayName;
  final String suggestedFileName;
  final String filePath;
  final DownloadHistoryStatus status;
  final int bytesTransferred;
  final int totalBytes;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final String errorCode;
  final String errorMessage;

  Map<String, Object?> toJson() => {
    'id': id,
    'operationId': operationId,
    'sourceId': sourceId,
    'shareUrl': shareUrl,
    'itemStableKey': itemStableKey,
    'displayName': displayName,
    'suggestedFileName': suggestedFileName,
    'filePath': filePath,
    'status': status.name,
    'bytesTransferred': bytesTransferred,
    'totalBytes': totalBytes,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'completedAt': completedAt?.toUtc().toIso8601String(),
    'errorCode': errorCode,
    'errorMessage': errorMessage,
  };

  DownloadHistoryEntry copyWith({
    String? operationId,
    String? filePath,
    DownloadHistoryStatus? status,
    int? bytesTransferred,
    int? totalBytes,
    DateTime? updatedAt,
    Object? completedAt = _unset,
    String? errorCode,
    String? errorMessage,
  }) => DownloadHistoryEntry(
    id: id,
    operationId: operationId ?? this.operationId,
    sourceId: sourceId,
    shareUrl: shareUrl,
    itemStableKey: itemStableKey,
    displayName: displayName,
    suggestedFileName: suggestedFileName,
    filePath: filePath ?? this.filePath,
    status: status ?? this.status,
    bytesTransferred: bytesTransferred ?? this.bytesTransferred,
    totalBytes: totalBytes ?? this.totalBytes,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    completedAt: identical(completedAt, _unset)
        ? this.completedAt
        : completedAt as DateTime?,
    errorCode: errorCode ?? this.errorCode,
    errorMessage: errorMessage ?? this.errorMessage,
  );
}

class DownloadSnapshot {
  const DownloadSnapshot({
    required this.operationId,
    required this.historyId,
    required this.itemStableKey,
    required this.fileName,
    required this.state,
    required this.bytesTransferred,
    required this.totalBytes,
    this.filePath = '',
    this.safeError = '',
    this.bytesPerSecond = 0,
  });

  final String operationId;
  final String historyId;
  final String itemStableKey;
  final String fileName;
  final DownloadActivityState state;
  final int bytesTransferred;
  final int totalBytes;
  final String filePath;
  final String safeError;
  final int bytesPerSecond;

  double? get fraction =>
      totalBytes > 0 ? (bytesTransferred / totalBytes).clamp(0, 1) : null;

  Duration? get estimatedRemaining {
    if (state != DownloadActivityState.downloading ||
        bytesPerSecond <= 0 ||
        totalBytes <= bytesTransferred) {
      return null;
    }
    return Duration(
      seconds: ((totalBytes - bytesTransferred) / bytesPerSecond).ceil(),
    );
  }

  DownloadSnapshot copyWith({
    String? fileName,
    DownloadActivityState? state,
    int? bytesTransferred,
    int? totalBytes,
    String? filePath,
    String? safeError,
    int? bytesPerSecond,
  }) => DownloadSnapshot(
    operationId: operationId,
    historyId: historyId,
    itemStableKey: itemStableKey,
    fileName: fileName ?? this.fileName,
    state: state ?? this.state,
    bytesTransferred: bytesTransferred ?? this.bytesTransferred,
    totalBytes: totalBytes ?? this.totalBytes,
    filePath: filePath ?? this.filePath,
    safeError: safeError ?? this.safeError,
    bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
  );
}

const Object _unset = Object();
final RegExp _operationIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

bool isSafeDownloadShareUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasPort;
}

const Set<String> _historyJsonKeys = {
  'id',
  'operationId',
  'sourceId',
  'shareUrl',
  'itemStableKey',
  'displayName',
  'suggestedFileName',
  'filePath',
  'status',
  'bytesTransferred',
  'totalBytes',
  'createdAt',
  'updatedAt',
  'completedAt',
  'errorCode',
  'errorMessage',
};

const Set<String> _installationPackageExtensions = {
  'APK',
  'APKS',
  'APKM',
  'XAPK',
  'AAB',
};
const Set<String> _applicationExtensions = {
  'EXE',
  'MSI',
  'MSIX',
  'APPX',
  'APPXBUNDLE',
  'DMG',
  'PKG',
  'DEB',
  'RPM',
  'APPIMAGE',
  'JAR',
};
const Set<String> _archiveExtensions = {
  'ZIP',
  'RAR',
  '7Z',
  'TAR',
  'GZ',
  'BZ2',
  'XZ',
  'ZST',
  'TGZ',
  'TBZ',
  'CAB',
  'ISO',
};
const Set<String> _documentExtensions = {
  'TXT',
  'MD',
  'LOG',
  'CSV',
  'JSON',
  'XML',
  'YAML',
  'YML',
  'INI',
  'CONF',
  'RTF',
  'PDF',
  'DOC',
  'DOCX',
  'ODT',
  'XLS',
  'XLSX',
  'PPT',
  'PPTX',
  'EPUB',
  'MOBI',
};
const Set<String> _videoExtensions = {
  'MP4',
  'MKV',
  'AVI',
  'MOV',
  'WMV',
  'FLV',
  'WEBM',
  'M4V',
  'TS',
  '3GP',
  'MPEG',
  'MPG',
};
const Set<String> _audioExtensions = {
  'MP3',
  'FLAC',
  'WAV',
  'AAC',
  'M4A',
  'OGG',
  'OPUS',
  'WMA',
  'APE',
  'MID',
  'MIDI',
};

String _requiredBoundedString(
  Map<String, Object?> json,
  String key,
  int maxLength,
) {
  final value = _boundedString(json, key, maxLength);
  if (value.isEmpty) throw FormatException('$key is required');
  return value;
}

String _boundedString(Map<String, Object?> json, String key, int maxLength) {
  final value = json[key];
  if (value == null) return '';
  if (value is! String || value.length > maxLength) {
    throw FormatException('$key must be a bounded string');
  }
  return value;
}

int _nonNegativeInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value.toInt() != value || value < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  return value.toInt();
}

DateTime _dateTime(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a timestamp');
  return DateTime.parse(value).toUtc();
}

DateTime? _nullableDateTime(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a timestamp');
  return DateTime.parse(value).toUtc();
}
