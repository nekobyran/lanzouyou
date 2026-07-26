enum DirectoryUploadState { succeeded, partial, cancelled }

enum DirectoryUploadFailureStage {
  createRoot,
  createFolder,
  uploadFile,
  prepareIcon,
  setIcon,
  parentUnavailable,
}

class DirectoryUploadRequest {
  const DirectoryUploadRequest({
    required this.path,
    this.displayName,
    this.compatibilityWrap = false,
    this.kind = 'auto',
    this.autoApkIcons = false,
  });

  final String path;
  final String? displayName;
  final bool compatibilityWrap;
  final String kind;
  final bool autoApkIcons;
}

class DirectoryUploadFailure {
  const DirectoryUploadFailure({
    required this.relativePath,
    required this.stage,
    required this.code,
    required this.message,
    required this.retriable,
  });

  factory DirectoryUploadFailure.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const <String>{
      'relativePath',
      'stage',
      'code',
      'message',
      'retriable',
    }, 'failure');
    final path = _requiredText(json, 'relativePath');
    final code = _requiredText(json, 'code');
    final message = _requiredText(json, 'message');
    if (path.length > 4096 || !_isSafeRelativePath(path)) {
      throw const FormatException('核心返回了不安全的失败相对路径');
    }
    if (!RegExp(r'^[a-z0-9_]{1,64}$').hasMatch(code)) {
      throw const FormatException('核心返回了无效失败代码');
    }
    if (message.length > 512 || message.contains(RegExp(r'[\r\n\u0000]'))) {
      throw const FormatException('核心返回了无效失败说明');
    }
    return DirectoryUploadFailure(
      relativePath: path.replaceAll('\\', '/'),
      stage: _parseFailureStage(_requiredText(json, 'stage')),
      code: code,
      message: message,
      retriable: json['retriable'] == true,
    );
  }

  final String relativePath;
  final DirectoryUploadFailureStage stage;
  final String code;
  final String message;
  final bool retriable;
}

class DirectoryUploadResult {
  const DirectoryUploadResult({
    required this.state,
    required this.rootName,
    required this.remoteRootId,
    required this.totalDirectories,
    required this.createdDirectories,
    required this.totalFiles,
    required this.processedFiles,
    required this.uploadedFiles,
    required this.totalBytes,
    required this.uploadedBytes,
    required this.autoApkIcons,
    required this.iconBoundFiles,
    required this.failures,
  });

  factory DirectoryUploadResult.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const <String>{
      'state',
      'atomic',
      'partialRemoteRetained',
      'rootName',
      'remoteRootId',
      'totalDirectories',
      'createdDirectories',
      'totalFiles',
      'processedFiles',
      'uploadedFiles',
      'totalBytes',
      'uploadedBytes',
      'autoApkIcons',
      'iconBoundFiles',
      'failures',
    }, 'directory upload result');
    if (json['atomic'] != false) {
      throw const FormatException('目录上传不能声称原子回滚');
    }
    if (json['partialRemoteRetained'] != true) {
      throw const FormatException('核心响应缺少部分上传保留策略');
    }
    final state = _parseState(_requiredText(json, 'state'));
    final rootName = _requiredText(json, 'rootName');
    if (!_isSafeName(rootName)) {
      throw const FormatException('核心响应包含无效根目录名称');
    }
    final remoteRootId = _optionalId(json['remoteRootId']);
    final totalDirectories = _requiredCount(json, 'totalDirectories');
    final createdDirectories = _requiredCount(json, 'createdDirectories');
    final totalFiles = _requiredCount(json, 'totalFiles');
    final processedFiles = _requiredCount(json, 'processedFiles');
    final uploadedFiles = _requiredCount(json, 'uploadedFiles');
    final totalBytes = _requiredCount(json, 'totalBytes');
    final uploadedBytes = _requiredCount(json, 'uploadedBytes');
    final iconBoundFiles = _requiredCount(json, 'iconBoundFiles');
    final autoApkIcons = json['autoApkIcons'];
    if (autoApkIcons is! bool) {
      throw const FormatException('核心响应缺少 autoApkIcons');
    }
    final rawFailures = json['failures'];
    if (rawFailures is! List || rawFailures.length > 10000) {
      throw const FormatException('核心响应包含无效 failures');
    }
    final failures = List<DirectoryUploadFailure>.unmodifiable(
      rawFailures.map((value) {
        if (value is! Map) {
          throw const FormatException('核心响应包含无效 failure');
        }
        return DirectoryUploadFailure.fromJson(value.cast<String, Object?>());
      }),
    );

    final countsValid =
        totalDirectories >= 1 &&
        createdDirectories <= totalDirectories &&
        processedFiles <= totalFiles &&
        uploadedFiles <= processedFiles &&
        uploadedBytes <= totalBytes &&
        iconBoundFiles <= uploadedFiles;
    if (!countsValid) {
      throw const FormatException('核心响应的目录上传计数不一致');
    }
    switch (state) {
      case DirectoryUploadState.succeeded:
        if (remoteRootId == null ||
            failures.isNotEmpty ||
            createdDirectories != totalDirectories ||
            processedFiles != totalFiles ||
            uploadedFiles != totalFiles ||
            uploadedBytes != totalBytes) {
          throw const FormatException('核心错误声称目录上传全部成功');
        }
      case DirectoryUploadState.partial:
        if (remoteRootId == null || failures.isEmpty) {
          throw const FormatException('核心缺少部分失败的残留信息');
        }
      case DirectoryUploadState.cancelled:
        break;
    }

    return DirectoryUploadResult(
      state: state,
      rootName: rootName,
      remoteRootId: remoteRootId,
      totalDirectories: totalDirectories,
      createdDirectories: createdDirectories,
      totalFiles: totalFiles,
      processedFiles: processedFiles,
      uploadedFiles: uploadedFiles,
      totalBytes: totalBytes,
      uploadedBytes: uploadedBytes,
      autoApkIcons: autoApkIcons,
      iconBoundFiles: iconBoundFiles,
      failures: failures,
    );
  }

  final DirectoryUploadState state;
  final String rootName;
  final String? remoteRootId;
  final int totalDirectories;
  final int createdDirectories;
  final int totalFiles;
  final int processedFiles;
  final int uploadedFiles;
  final int totalBytes;
  final int uploadedBytes;
  final bool autoApkIcons;
  final int iconBoundFiles;
  final List<DirectoryUploadFailure> failures;

  bool get hasRemoteChanges => remoteRootId != null;

  String get summary {
    final root = remoteRootId == null ? '' : '，已创建云端目录「$rootName」';
    return switch (state) {
      DirectoryUploadState.succeeded =>
        '已上传 $uploadedFiles/$totalFiles 个文件$root',
      DirectoryUploadState.partial =>
        '已上传 $uploadedFiles/$totalFiles 个文件$root；${failures.length} 项未完成，已上传内容不会自动回滚',
      DirectoryUploadState.cancelled =>
        '已取消，已上传 $uploadedFiles/$totalFiles 个文件$root；不会继续开始新项目',
    };
  }
}

DirectoryUploadState _parseState(String value) => switch (value) {
  'succeeded' => DirectoryUploadState.succeeded,
  'partial' => DirectoryUploadState.partial,
  'cancelled' => DirectoryUploadState.cancelled,
  _ => throw const FormatException('核心响应包含无效目录上传状态'),
};

DirectoryUploadFailureStage _parseFailureStage(String value) => switch (value) {
  'create_root' => DirectoryUploadFailureStage.createRoot,
  'create_folder' => DirectoryUploadFailureStage.createFolder,
  'upload_file' => DirectoryUploadFailureStage.uploadFile,
  'prepare_icon' => DirectoryUploadFailureStage.prepareIcon,
  'set_icon' => DirectoryUploadFailureStage.setIcon,
  'parent_unavailable' => DirectoryUploadFailureStage.parentUnavailable,
  _ => throw const FormatException('核心响应包含无效目录上传失败阶段'),
};

String _requiredText(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty && !value.contains('\u0000')) {
    return value;
  }
  throw FormatException('核心响应缺少 $key');
}

int _requiredCount(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int && value >= 0) return value;
  throw FormatException('核心响应包含无效 $key');
}

String? _optionalId(Object? value) {
  if (value == null) return null;
  if (value is String && RegExp(r'^\d{1,64}$').hasMatch(value)) return value;
  throw const FormatException('核心响应包含无效远端目录 ID');
}

bool _isSafeRelativePath(String value) {
  final normalized = value.replaceAll('\\', '/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    return false;
  }
  final parts = normalized.split('/');
  return parts.every((part) => part.isNotEmpty && part != '.' && part != '..');
}

bool _isSafeName(String value) {
  if (value.isEmpty || value.length > 255 || value.trim() != value) {
    return false;
  }
  if (value.contains(RegExp(r'[\\/:*?"<>|\u0000-\u001f]')) ||
      value.endsWith('.') ||
      value.endsWith(' ')) {
    return false;
  }
  final stem = value.split('.').first.toUpperCase();
  if (<String>{
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'CLOCK\$',
    'CONIN\$',
    'CONOUT\$',
  }.contains(stem)) {
    return false;
  }
  return !RegExp(r'^(COM|LPT)[1-9]$').hasMatch(stem);
}

void _requireExactKeys(
  Map<String, Object?> json,
  Set<String> expected,
  String label,
) {
  if (json.length != expected.length || !json.keys.every(expected.contains)) {
    throw FormatException('核心响应包含未知 $label 字段');
  }
}
