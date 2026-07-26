import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

abstract interface class DownloadStoragePaths {
  Future<String> downloadsDirectory();

  Future<File> historyFile();
}

class PathProviderDownloadStoragePaths implements DownloadStoragePaths {
  PathProviderDownloadStoragePaths.production()
    : this._(getDownloadsDirectory, getApplicationSupportDirectory);

  @visibleForTesting
  PathProviderDownloadStoragePaths.testHarness({
    required Future<Directory?> Function() getDownloads,
    required Future<Directory> Function() getApplicationSupport,
  }) : this._(getDownloads, getApplicationSupport);

  PathProviderDownloadStoragePaths._(
    this._getDownloads,
    this._getApplicationSupport,
  );

  final Future<Directory?> Function() _getDownloads;
  final Future<Directory> Function() _getApplicationSupport;

  @override
  Future<String> downloadsDirectory() async {
    final directory = await _getDownloads();
    if (directory == null || directory.path.trim().isEmpty) {
      throw const DownloadStorageFailure('downloadsUnavailable', '系统下载目录不可用');
    }
    await directory.create(recursive: true);
    return p.normalize(directory.absolute.path);
  }

  @override
  Future<File> historyFile() async {
    final support = await _getApplicationSupport();
    if (support.path.trim().isEmpty) {
      throw const DownloadStorageFailure('supportUnavailable', '应用数据目录不可用');
    }
    final directory = Directory(
      p.join(support.absolute.path, 'data', 'history'),
    );
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'downloads.json'));
  }
}

class FixedDownloadStoragePaths implements DownloadStoragePaths {
  const FixedDownloadStoragePaths({
    required this.downloadsPath,
    required this.applicationSupportPath,
  });

  final String downloadsPath;
  final String applicationSupportPath;

  @override
  Future<String> downloadsDirectory() async {
    final directory = Directory(p.normalize(downloadsPath));
    await directory.create(recursive: true);
    return directory.absolute.path;
  }

  @override
  Future<File> historyFile() async {
    final directory = Directory(
      p.join(applicationSupportPath, 'data', 'history'),
    );
    await directory.create(recursive: true);
    return File(p.join(directory.absolute.path, 'downloads.json'));
  }
}

class DownloadStorageFailure implements Exception {
  const DownloadStorageFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'DownloadStorageFailure($code): $message';
}
