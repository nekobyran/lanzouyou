import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../../../controllers/transfer_controller.dart';
import '../../../models/directory_upload.dart';

typedef DirectoryPathPicker = Future<String?> Function();

class FolderUploadLaunchResult {
  const FolderUploadLaunchResult._({
    required this.enqueued,
    required this.cancelled,
    this.message,
  });

  const FolderUploadLaunchResult.enqueued()
    : this._(enqueued: true, cancelled: false, message: null);

  const FolderUploadLaunchResult.cancelled()
    : this._(enqueued: false, cancelled: true, message: null);

  const FolderUploadLaunchResult.rejected(String message)
    : this._(enqueued: false, cancelled: false, message: message);

  final bool enqueued;
  final bool cancelled;
  final String? message;
}

class FolderUploadLauncher {
  const FolderUploadLauncher._();

  static Future<FolderUploadLaunchResult> pickAndEnqueue({
    required TransferController transferController,
    required String cloudFolderId,
    required bool compatibilityWrap,
    required bool autoApkIcons,
    required void Function() onFolderChanged,
    DirectoryPathPicker? picker,
  }) async {
    final String? selected;
    try {
      selected = await (picker ?? _pickDirectory)();
    } on PlatformException {
      return const FolderUploadLaunchResult.rejected('该目录受系统保护，请选择可访问目录');
    } on FileSystemException {
      return const FolderUploadLaunchResult.rejected('无法读取该目录，请选择可访问目录');
    }
    if (selected == null) return const FolderUploadLaunchResult.cancelled();
    if (!_looksAbsolute(selected) || _isRootPath(selected)) {
      return const FolderUploadLaunchResult.rejected('该目录受系统保护，请选择可访问目录');
    }
    final directory = Directory(selected);
    try {
      if (!await directory.exists()) {
        return const FolderUploadLaunchResult.rejected('无法读取该目录，请选择可访问目录');
      }
    } on FileSystemException {
      return const FolderUploadLaunchResult.rejected('无法读取该目录，请选择可访问目录');
    }
    final rootName = _baseName(selected);
    if (rootName.isEmpty) {
      return const FolderUploadLaunchResult.rejected('该目录受系统保护，请选择可访问目录');
    }
    transferController.enqueueDirectoryUpload(
      folderId: cloudFolderId,
      request: DirectoryUploadRequest(
        path: selected,
        displayName: rootName,
        compatibilityWrap: compatibilityWrap,
        autoApkIcons: autoApkIcons,
      ),
      onFolderChanged: onFolderChanged,
    );
    return const FolderUploadLaunchResult.enqueued();
  }

  static Future<String?> _pickDirectory() => FilePicker.getDirectoryPath(
    dialogTitle: '选择要完整上传的文件夹',
    lockParentWindow: true,
  );
}

bool _looksAbsolute(String value) {
  if (value.isEmpty || value.trim() != value || value.contains('\u0000')) {
    return false;
  }
  if (Platform.isWindows) {
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
        value.startsWith(r'\\');
  }
  return value.startsWith('/');
}

bool _isRootPath(String value) {
  final normalized = value
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  if (Platform.isWindows) {
    return RegExp(r'^[A-Za-z]:$').hasMatch(normalized) ||
        RegExp(r'^//[^/]+/[^/]+$').hasMatch(normalized);
  }
  return normalized.isEmpty;
}

String _baseName(String value) {
  final normalized = value
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  return normalized.split('/').lastOrNull ?? '';
}
