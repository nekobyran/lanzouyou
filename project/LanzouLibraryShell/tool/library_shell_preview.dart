import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lanzou_library_shell/app/library_shell_app.dart';
import 'package:lanzou_library_shell/config/library_config.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';
import 'package:lanzou_library_shell/services/link_opener.dart';

void main() {
  if (kReleaseMode) {
    throw StateError('界面验收入口禁止用于正式发布');
  }
  runApp(
    LibraryShellApp.testHarness(
      config: _previewConfig,
      core: _UiTestHarnessCore(),
      linkOpener: const _UiTestHarnessLinkOpener(),
    ),
  );
}

final _previewConfig = LibraryConfig.fromJson({
  'schemaVersion': 1,
  'identity': {
    'projectId': 'preview_library',
    'displayName': '界面验收样机（非正式数据）',
    'applicationId': 'cc.nkbr.previewlibrary',
    'versionName': '1.0.0',
    'versionCode': 1,
    'windowsExeName': 'preview-library',
  },
  'branding': {
    'seedColor': '#2563EB',
    'themeMode': 'light',
    'officialUrl': 'https://example.com/',
    'publisher': '仅用于本地 UI 自动化验收',
    'logoAsset': 'assets/runtime/logo.png',
  },
  'sources': [
    {
      'sourceId': 'preview',
      'title': '软件库合集',
      'shareUrl': 'https://example.lanzouw.com/bpreview',
      'password': '',
      'searchable': true,
      'recommended': true,
    },
    {
      'sourceId': 'tools',
      'title': '效率工具',
      'shareUrl': 'https://example.lanzoui.com/btools',
      'password': '',
      'searchable': true,
      'recommended': false,
    },
  ],
  'features': {
    'browse': true,
    'search': true,
    'download': true,
    'showDescription': true,
  },
});

class _UiTestHarnessCore implements LibraryCore, LibraryOperationCore {
  final Map<String, LibraryOperationStatus> _operations = {};
  final Set<String> _cancelled = {};

  @override
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async => LibraryFolder(
    sourceId: sourceId,
    title: sourceId == 'tools' ? '效率工具' : '软件库合集',
    url: shareUrl,
    page: page,
    hasMore: false,
    items: const [
      LibraryItem(
        sourceId: 'preview',
        title: '常用工具',
        url: 'lanzou-folder://preview/tools',
        shareUrl: 'https://example.lanzouw.com/bpreview',
        folderId: 'tools',
        isFolder: true,
      ),
      LibraryItem(
        sourceId: 'preview',
        title: 'LanzouYOU 1.0.0.apk',
        url: 'https://example.lanzouw.com/ipreview1',
        shareUrl: 'https://example.lanzouw.com/ipreview1',
        size: '32.8 MB',
        time: '今天',
        description: '跨平台蓝奏云管理与自定义软件库生成工具。',
        isFolder: false,
      ),
      LibraryItem(
        sourceId: 'preview',
        title: '桌面效率工具.zip',
        url: 'https://example.lanzouw.com/ipreview2',
        shareUrl: 'https://example.lanzouw.com/ipreview2',
        size: '18.4 MB',
        time: '昨天',
        description: '适用于 Windows x64 的便携工具合集。',
        isFolder: false,
      ),
    ],
  );

  @override
  Future<LibraryDescribeResult> describe({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryDescribeResult(description: '本地验收简介');

  @override
  Future<LibraryCollectResult> collect({
    required List<LibraryItem> items,
    required List<LibrarySource> sources,
  }) async => LibraryCollectResult(files: items, foldersScanned: 0);

  @override
  Future<LibraryProbeResult> probe(LibrarySource source) async =>
      LibraryProbeResult(
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

  @override
  Future<LibraryResolveResult> resolve({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryResolveResult(
    url: 'https://example.com/download',
    fileName: 'preview.bin',
  );

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) async {
    if (operationId == null) {
      return LibrarySearchResult(
        items: (await browse(
          sourceId: sources.first.sourceId,
          shareUrl: sources.first.shareUrl,
        )).items,
      );
    }
    _operations[operationId] = _status(operationId, totalUnits: sources.length);
    final found = <LibraryItem>[];
    for (var sourceIndex = 0; sourceIndex < sources.length; sourceIndex++) {
      for (var tick = 0; tick < 30; tick++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (_cancelled.contains(operationId)) {
          _operations[operationId] = _status(
            operationId,
            state: LibraryOperationState.cancelled,
            completedUnits: sourceIndex,
            totalUnits: sources.length,
            itemsFound: found.length,
          );
          throw const LibraryCoreFailure('cancelled', '搜索已取消');
        }
      }
      if (sourceIndex == 0) {
        found.addAll(
          (await browse(
            sourceId: sources.first.sourceId,
            shareUrl: sources.first.shareUrl,
          )).items,
        );
      }
      _operations[operationId] = _status(
        operationId,
        completedUnits: sourceIndex + 1,
        totalUnits: sources.length,
        itemsFound: found.length,
      );
    }
    _operations[operationId] = _status(
      operationId,
      state: LibraryOperationState.succeeded,
      completedUnits: sources.length,
      totalUnits: sources.length,
      itemsFound: found.length,
    );
    return LibrarySearchResult(items: found);
  }

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) async {
    final status = _operations[operationId];
    if (status == null) {
      throw const LibraryCoreFailure('not_found', '找不到验收任务');
    }
    return status;
  }

  @override
  Future<void> cancelOperation(String operationId) async {
    final status = _operations[operationId];
    if (status == null || status.state.isTerminal) return;
    _cancelled.add(operationId);
    _operations[operationId] = _status(
      operationId,
      state: LibraryOperationState.cancelling,
      completedUnits: status.completedUnits,
      totalUnits: status.totalUnits,
      itemsFound: status.itemsFound,
    );
  }

  @override
  Future<void> forgetOperation(String operationId) async {
    _operations.remove(operationId);
    _cancelled.remove(operationId);
  }

  LibraryOperationStatus _status(
    String operationId, {
    LibraryOperationState state = LibraryOperationState.running,
    int completedUnits = 0,
    required int totalUnits,
    int itemsFound = 0,
  }) => LibraryOperationStatus(
    operationId: operationId,
    kind: 'library_search',
    state: state,
    completedUnits: completedUnits,
    totalUnits: totalUnits,
    bytesTransferred: 0,
    totalBytes: 0,
    itemsFound: itemsFound,
  );
}

class _UiTestHarnessLinkOpener implements LinkOpener {
  const _UiTestHarnessLinkOpener();

  @override
  Future<void> open(String url) async {}
}
