import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lanzou_library_shell/app/library_shell_app.dart';
import 'package:lanzou_library_shell/config/library_config.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';
import 'package:lanzou_library_shell/services/link_opener.dart';

const libraryPerformanceItemCount = 1000;

void main() {
  if (!kDebugMode && !kProfileMode) {
    throw StateError('性能验收入口只允许 Debug/Profile 构建');
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(buildLibraryPerformanceHarness());
}

Widget buildLibraryPerformanceHarness({LibraryPerformanceCore? core}) {
  return LibraryShellApp.testHarness(
    config: libraryPerformanceConfig,
    core: core ?? LibraryPerformanceCore(),
    linkOpener: const LibraryPerformanceLinkOpener(),
  );
}

final libraryPerformanceConfig = LibraryConfig.fromJson({
  'schemaVersion': 1,
  'identity': {
    'projectId': 'profile_library',
    'displayName': '长列表性能验收',
    'applicationId': 'cc.nkbr.profilelibrary',
    'versionName': '1.0.0',
    'versionCode': 1,
    'windowsExeName': 'profile-library',
  },
  'branding': {
    'seedColor': '#2563EB',
    'themeMode': 'light',
    'officialUrl': '',
    'publisher': '本地性能验收',
    'logoAsset': 'assets/runtime/logo.png',
  },
  'sources': [
    {
      'sourceId': 'profile',
      'title': '1000 项性能目录',
      'shareUrl': 'https://example.lanzouw.com/bprofile',
      'password': '',
      'searchable': true,
      'recommended': true,
    },
  ],
  'features': {
    'browse': true,
    'search': true,
    'download': true,
    'showDescription': true,
  },
});

final libraryPerformanceItems = List<LibraryItem>.unmodifiable(
  List<LibraryItem>.generate(
    libraryPerformanceItemCount,
    (index) => LibraryItem(
      sourceId: 'profile',
      title: '性能项目 ${(index + 1).toString().padLeft(4, '0')}',
      url: 'https://files.invalid/profile/${index + 1}',
      shareUrl: 'https://files.invalid/profile/${index + 1}',
      size: '${24 + (index % 120)} MB',
      time: '本地样本',
      iconUrl: 'https://assets.invalid/icons/${index + 1}.png',
      description: '用于验证软件目录惰性构建、图标解码与滚动性能。',
      isFolder: false,
    ),
    growable: false,
  ),
);

final libraryPerformanceIndexByStableKey = <String, int>{
  for (final (index, item) in libraryPerformanceItems.indexed)
    item.stableKey: index,
};

class LibraryPerformanceCore implements LibraryCore, LibraryAssetCore {
  int assetFetchCount = 0;

  @override
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async {
    return LibraryFolder(
      sourceId: sourceId,
      title: '1000 项性能目录',
      url: shareUrl,
      page: page,
      hasMore: false,
      items: page == 1 ? libraryPerformanceItems : const <LibraryItem>[],
    );
  }

  @override
  Future<LibraryProbeResult> probe(LibrarySource source) async {
    return LibraryProbeResult(
      source: LibraryProbeSource(
        sourceId: source.sourceId,
        title: source.title,
        shareUrl: source.shareUrl,
        searchable: source.searchable,
      ),
      folder: await browse(
        sourceId: source.sourceId,
        shareUrl: source.shareUrl,
      ),
    );
  }

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) async {
    final normalized = query.trim().toLowerCase();
    return LibrarySearchResult(
      items: libraryPerformanceItems
          .where((item) => item.title.toLowerCase().contains(normalized))
          .toList(growable: false),
    );
  }

  @override
  Future<LibraryCollectResult> collect({
    required List<LibraryItem> items,
    required List<LibrarySource> sources,
  }) async => LibraryCollectResult(files: items, foldersScanned: 0);

  @override
  Future<LibraryResolveResult> resolve({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryResolveResult(
    url: 'https://files.invalid/profile/download',
    fileName: 'profile.bin',
  );

  @override
  Future<LibraryDescribeResult> describe({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryDescribeResult(description: '本地性能验收项目');

  @override
  Future<LibraryAssetResult> fetchAsset({required String url}) async {
    assetFetchCount++;
    await Future<void>.delayed(const Duration(milliseconds: 3));
    return _performanceIcon;
  }
}

class LibraryPerformanceLinkOpener implements LinkOpener {
  const LibraryPerformanceLinkOpener();

  @override
  Future<void> open(String url) async {}
}

final LibraryAssetResult _performanceIcon = LibraryAssetResult.fromJson({
  'mediaType': 'image/png',
  'bytesBase64': base64Encode(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  ),
});
