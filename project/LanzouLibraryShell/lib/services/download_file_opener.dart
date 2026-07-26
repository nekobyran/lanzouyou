import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

abstract interface class DownloadFileOpener {
  Future<void> open(String filePath);
}

class OpenFilexDownloadFileOpener implements DownloadFileOpener {
  OpenFilexDownloadFileOpener.production()
    : this._(
        openFile: OpenFilex.open,
        isWindows: Platform.isWindows,
        openWindowsAssociation: _WindowsFileAssociation.open,
      );

  @visibleForTesting
  OpenFilexDownloadFileOpener.testHarness({
    required Future<OpenResult> Function(String filePath) openFile,
    bool isWindows = false,
    Future<int> Function(String filePath)? openWindowsAssociation,
  }) : this._(
         openFile: openFile,
         isWindows: isWindows,
         openWindowsAssociation:
             openWindowsAssociation ?? _WindowsFileAssociation.open,
       );

  const OpenFilexDownloadFileOpener._({
    required this._openFile,
    required this._isWindows,
    required this._openWindowsAssociation,
  });

  final Future<OpenResult> Function(String filePath) _openFile;
  final bool _isWindows;
  final Future<int> Function(String filePath) _openWindowsAssociation;

  @override
  Future<void> open(String filePath) async {
    final normalized = p.normalize(filePath.trim());
    if (normalized.isEmpty || !p.isAbsolute(normalized)) {
      throw const DownloadFileOpenFailure('invalidPath', '下载文件路径无效');
    }
    if (!await File(normalized).exists()) {
      throw const DownloadFileOpenFailure('fileNotFound', '下载文件已不存在');
    }
    if (_isWindows) {
      final resultCode = await _openWindowsFile(normalized);
      if (resultCode > 32) return;
      throw DownloadFileOpenFailure(
        switch (resultCode) {
          2 || 3 => 'fileNotFound',
          5 => 'permissionDenied',
          31 => 'noApplication',
          _ => 'openFailed',
        },
        switch (resultCode) {
          2 || 3 => '下载文件已不存在',
          5 => '没有权限打开下载文件',
          31 => '没有可打开此文件的应用',
          _ => '无法通过系统关联打开下载文件',
        },
      );
    }
    final result = await _openFile(normalized);
    if (result.type == ResultType.done) return;
    throw DownloadFileOpenFailure(
      switch (result.type) {
        ResultType.fileNotFound => 'fileNotFound',
        ResultType.noAppToOpen => 'noApplication',
        ResultType.permissionDenied => 'permissionDenied',
        ResultType.error => 'openFailed',
        ResultType.done => 'openFailed',
      },
      switch (result.type) {
        ResultType.fileNotFound => '下载文件已不存在',
        ResultType.noAppToOpen => '没有可打开此文件的应用',
        ResultType.permissionDenied => '没有权限打开下载文件',
        ResultType.error || ResultType.done => '无法打开下载文件',
      },
    );
  }

  Future<int> _openWindowsFile(String filePath) async {
    try {
      return await _openWindowsAssociation(filePath);
    } on Object {
      throw const DownloadFileOpenFailure('openFailed', '无法通过系统关联打开下载文件');
    }
  }
}

typedef _ShellExecuteWNative =
    IntPtr Function(
      IntPtr window,
      Pointer<Utf16> operation,
      Pointer<Utf16> file,
      Pointer<Utf16> parameters,
      Pointer<Utf16> directory,
      Int32 showCommand,
    );
typedef _ShellExecuteWDart =
    int Function(
      int window,
      Pointer<Utf16> operation,
      Pointer<Utf16> file,
      Pointer<Utf16> parameters,
      Pointer<Utf16> directory,
      int showCommand,
    );

/// Opens a file with its registered Windows handler without a command shell.
///
/// [ShellExecuteW] receives the UTF-16 path as a dedicated argument, so shell
/// metacharacters in a legitimate filename are never parsed as commands.
abstract final class _WindowsFileAssociation {
  static final _ShellExecuteWDart _shellExecute = DynamicLibrary.open(
    'shell32.dll',
  ).lookupFunction<_ShellExecuteWNative, _ShellExecuteWDart>('ShellExecuteW');

  static Future<int> open(String filePath) async {
    final operation = 'open'.toNativeUtf16();
    final file = filePath.toNativeUtf16();
    try {
      return _shellExecute(
        0,
        operation,
        file,
        nullptr.cast<Utf16>(),
        nullptr.cast<Utf16>(),
        1,
      );
    } finally {
      calloc
        ..free(operation)
        ..free(file);
    }
  }
}

// Windows intentionally uses the native association launcher rather than a
// command-interpreter fallback. Android still uses its platform plugin so APKs
// are handed to the system package installer.

class DownloadFileOpenFailure implements Exception {
  const DownloadFileOpenFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'DownloadFileOpenFailure($code): $message';
}
