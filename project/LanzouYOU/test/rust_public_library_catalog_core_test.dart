import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/services/json_core_transport.dart';
import 'package:lanzou_library_shell/library_preview.dart';
import 'package:lanzouyou/pages/public_library/public_library.dart';
import 'package:lanzouyou/services/cloud_service.dart';
import 'package:lanzouyou/services/rust_cloud_service.dart';
import 'package:lanzouyou/services/rust_public_library_catalog_core.dart';

void main() {
  test(
    'managed and catalog adapters share one persistent JSON transport',
    () async {
      final transport = _RecordingTransport();
      final cloud = RustCloudService.testHarness(transport);
      final catalog = RustPublicLibraryCatalogCore.testHarness(
        cloud.dispatchRaw,
        r'D:\app-data\sources',
      );

      final session = await cloud.sessionInfo();
      final summary = await catalog.catalogSummary();
      final page = await catalog.catalogPage(query: '工具', limit: 80);

      expect(session.authenticated, isTrue);
      expect(summary.officialCount, 597);
      expect(summary.compositeCount, 9);
      expect(page.nodes.single.title, '真实来源');
      expect(transport.requests.map((value) => value['op']), <Object?>[
        'session_info',
        'catalog_summary',
        'catalog_page',
      ]);
      expect(transport.requests.last, containsPair('query', '工具'));
      expect(transport.requests.last, containsPair('limit', 80));
      expect(
        transport.requests.skip(1),
        everyElement(containsPair('storageRoot', r'D:\app-data\sources')),
      );
      expect(
        jsonEncode(transport.requests),
        isNot(contains(RegExp('password|cookie', caseSensitive: false))),
      );
    },
  );

  test('item references cross FFI in one password-free batch object', () async {
    final transport = _RecordingTransport();
    final cloud = RustCloudService.testHarness(transport);
    final catalog = RustPublicLibraryCatalogCore.testHarness(
      cloud.dispatchRaw,
      r'D:\app-data\sources',
    );
    const item = LibraryItem(
      sourceId: 'opaque-source-id',
      title: '软件.apk',
      url: 'https://www.lanzouw.com/folder',
      shareUrl: 'https://www.lanzouw.com/file',
      folderId: 'folder-1',
      isFolder: false,
    );

    final folder = await catalog.catalogBrowse(
      itemRef: PublicLibraryItemRef.fromItem(item),
      refresh: true,
    );

    expect(folder.items, isEmpty);
    final request = transport.requests.single;
    expect(request['op'], 'catalog_browse');
    expect(request['storageRoot'], r'D:\app-data\sources');
    expect(request['itemRef'], <String, Object?>{
      'sourceId': 'opaque-source-id',
      'title': '软件.apk',
      'url': 'https://www.lanzouw.com/folder',
      'shareUrl': 'https://www.lanzouw.com/file',
      'folderId': 'folder-1',
      'isFolder': false,
    });
    expect(request.containsKey('password'), isFalse);
  });

  test(
    'native worker failures become the managed CloudFailure contract',
    () async {
      final cloud = RustCloudService.testHarness(
        _FailingTransport(
          const LibraryCoreFailure(
            'coreUnavailable',
            '核心暂不可用',
            retriable: true,
          ),
        ),
      );

      await expectLater(
        cloud.sessionInfo(),
        throwsA(
          isA<CloudFailure>()
              .having((error) => error.code, 'code', 'coreUnavailable')
              .having((error) => error.retriable, 'retriable', isTrue),
        ),
      );
    },
  );
}

class _RecordingTransport implements JsonCoreTransport {
  final List<Map<String, Object?>> requests = [];

  @override
  Future<String> dispatch(String request) async {
    final decoded = (jsonDecode(request) as Map).cast<String, Object?>();
    requests.add(decoded);
    final data = switch (decoded['op']) {
      'session_info' => <String, Object?>{
        'authenticated': true,
        'userId': 'test-user',
      },
      'catalog_summary' => <String, Object?>{
        'revision': 'fixture-revision',
        'officialCount': 597,
        'compositeCount': 9,
        'nodeCount': 3370,
        'searchableCount': 274,
      },
      'catalog_page' => <String, Object?>{
        'revision': 'fixture-revision',
        'total': 1,
        'nextCursor': '',
        'hasMore': false,
        'nodes': <Object?>[
          <String, Object?>{
            'id': 'source-1',
            'parentId': '',
            'kind': 'remoteSource',
            'sourceId': 'opaque-source-id',
            'title': '真实来源',
            'publisher': '',
            'description': '',
            'iconUrl': '',
            'size': '',
            'time': '',
            'searchable': true,
            'childDirectory': false,
            'originPath': '',
            'originUrl': '',
            'shareUrl': 'https://www.lanzouw.com/source',
            'hasChildren': true,
          },
        ],
      },
      'catalog_browse' => <String, Object?>{
        'sourceId': 'opaque-source-id',
        'title': '软件目录',
        'url': 'https://www.lanzouw.com/source',
        'items': <Object?>[],
        'page': 1,
        'hasMore': false,
      },
      _ => throw StateError('unexpected request: ${decoded['op']}'),
    };
    return jsonEncode(<String, Object?>{
      'ok': true,
      'data': data,
      'error': null,
    });
  }
}

class _FailingTransport implements JsonCoreTransport {
  const _FailingTransport(this.error);

  final Object error;

  @override
  Future<String> dispatch(String request) => Future<String>.error(error);
}
