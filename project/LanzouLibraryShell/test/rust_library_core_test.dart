import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/config/library_config.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';
import 'package:lanzou_library_shell/services/rust_library_core.dart';

void main() {
  late RecordingTransport transport;
  late RustLibraryCore core;
  late LibrarySource source;

  setUp(() {
    transport = RecordingTransport();
    core = RustLibraryCore.testHarness(transport: transport);
    source = LibrarySource.fromJson({
      'sourceId': 'main',
      'title': '主源',
      'shareUrl': 'https://www.lanzouw.com/b000000',
      'password': 'private-value',
      'searchable': true,
      'recommended': true,
    });
  });

  test('uses only the fixed library JSON operation contracts', () async {
    transport.responses.addAll([
      ok({
        'source': {
          'sourceId': 'main',
          'title': '主源',
          'shareUrl': 'https://www.lanzouw.com/b000000',
          'searchable': true,
        },
        'folder': folderJson(items: const []),
      }),
      ok(folderJson(items: const [], page: 2)),
      ok({'items': <Object?>[], 'query': '工具'}),
      ok({'files': <Object?>[], 'foldersScanned': 0}),
      ok({'url': 'https://download.invalid/file.zip', 'fileName': 'file.zip'}),
      ok({
        'path': r'C:\Users\tester\Downloads\file.zip',
        'fileName': 'file.zip',
        'bytesWritten': 2048,
      }),
      ok({'description': '官网最新版链接：https://example.invalid/'}),
      ok({
        'mediaType': 'image/png',
        'bytesBase64':
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
            'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      }),
    ]);

    await core.probe(source);
    await core.browse(
      sourceId: 'main',
      shareUrl: source.shareUrl,
      password: source.password,
      page: 2,
      refresh: true,
    );
    await core.search(
      query: '工具',
      sources: [source],
      options: const LibrarySearchOptions(),
    );
    await core.collect(
      items: const [
        LibraryItem(
          sourceId: 'main',
          title: '文件',
          url: 'https://www.lanzouw.com/i000000',
          shareUrl: 'https://www.lanzouw.com/i000000',
          isFolder: false,
        ),
      ],
      sources: [source],
    );
    await core.resolve(
      sourceId: 'main',
      shareUrl: 'https://www.lanzouw.com/i000000',
      password: 'private-value',
    );
    final download = await core.download(
      sourceId: 'main',
      shareUrl: 'https://www.lanzouw.com/i000000',
      password: 'private-value',
      destinationDirectory: r'C:\Users\tester\Downloads',
      operationId: 'download-test-1',
    );
    final description = await core.describe(
      sourceId: 'main',
      shareUrl: 'https://www.lanzouw.com/i000000',
      password: 'private-value',
    );
    final asset = await core.fetchAsset(
      url: 'https://image.dmpdmp.com/example.png',
    );

    expect(description.description, '官网最新版链接：https://example.invalid/');
    expect(download.bytesWritten, 2048);
    expect(asset.mediaType, 'image/png');
    expect(asset.bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);

    expect(transport.requests, [
      {'op': 'library_probe', 'source': source.toCoreJson()},
      {
        'op': 'library_browse',
        'sourceId': 'main',
        'shareUrl': source.shareUrl,
        'password': 'private-value',
        'page': 2,
        'refresh': true,
      },
      {
        'op': 'library_search',
        'query': '工具',
        'sources': [source.toCoreJson()],
        'options': {
          'concurrency': 16,
          'sourceSwitchDelayMs': 15000,
          'untilLastPage': true,
          'maxPages': 0,
        },
      },
      {
        'op': 'library_collect',
        'items': [
          {
            'sourceId': 'main',
            'title': '文件',
            'url': 'https://www.lanzouw.com/i000000',
            'shareUrl': 'https://www.lanzouw.com/i000000',
            'isFolder': false,
          },
        ],
        'sources': [source.toCoreJson()],
      },
      {
        'op': 'library_resolve',
        'sourceId': 'main',
        'shareUrl': 'https://www.lanzouw.com/i000000',
        'password': 'private-value',
      },
      {
        'op': 'library_download',
        'sourceId': 'main',
        'shareUrl': 'https://www.lanzouw.com/i000000',
        'password': 'private-value',
        'destinationDirectory': r'C:\Users\tester\Downloads',
        'operationId': 'download-test-1',
      },
      {
        'op': 'library_describe',
        'sourceId': 'main',
        'shareUrl': 'https://www.lanzouw.com/i000000',
        'password': 'private-value',
      },
      {
        'op': 'library_fetch_asset',
        'url': 'https://image.dmpdmp.com/example.png',
      },
    ]);
  });

  test(
    'uses the bounded operation progress and cancellation contracts',
    () async {
      const operationId = 'library-search-test-1';
      transport.responses.addAll([
        ok({'items': <Object?>[], 'sources': <Object?>[]}),
        ok({
          'operationId': operationId,
          'kind': 'library_search',
          'state': 'running',
          'completedUnits': 1,
          'totalUnits': 2,
          'bytesTransferred': 0,
          'totalBytes': 0,
          'itemsFound': 3,
          'revision': 2,
        }),
        ok({'operationId': operationId, 'cancelRequested': true}),
        ok({}),
      ]);

      await core.search(
        query: '工具',
        sources: [source],
        operationId: operationId,
      );
      final status = await core.operationStatus(operationId);
      await core.cancelOperation(operationId);
      await core.forgetOperation(operationId);

      expect(status.state, LibraryOperationState.running);
      expect(status.fraction, 0.5);
      expect(status.itemsFound, 3);
      expect(transport.requests, [
        {
          'op': 'library_search',
          'query': '工具',
          'sources': [source.toCoreJson()],
          'options': {
            'concurrency': 16,
            'sourceSwitchDelayMs': 15000,
            'untilLastPage': true,
            'maxPages': 0,
          },
          'operationId': operationId,
        },
        {'op': 'operation_status', 'operationId': operationId},
        {'op': 'operation_cancel', 'operationId': operationId},
        {'op': 'operation_forget', 'operationId': operationId},
      ]);
    },
  );

  test('rejects operation status with a different identity or kind', () async {
    const operationId = 'library-search-identity';
    transport.responses.addAll([
      ok(operationStatusJson(operationId: 'another-operation')),
      ok(operationStatusJson(operationId: operationId, kind: 'upload')),
    ]);

    for (var index = 0; index < 2; index++) {
      await expectLater(
        core.operationStatus(operationId),
        throwsA(
          isA<LibraryCoreFailure>().having(
            (error) => error.code,
            'code',
            'invalidResponse',
          ),
        ),
      );
    }
  });

  test('accepts byte progress for download operations', () async {
    const operationId = 'download-progress-1';
    transport.responses.add(
      ok({
        ...operationStatusJson(operationId: operationId, kind: 'download'),
        'completedUnits': 0,
        'totalUnits': 0,
        'bytesTransferred': 512,
        'totalBytes': 1024,
        'itemsFound': 0,
      }),
    );

    final status = await core.operationStatus(operationId);

    expect(status.kind, 'download');
    expect(status.fraction, 0.5);
  });

  test('accepts paused operation state with a monotonic revision', () {
    final status = LibraryOperationStatus.fromJson({
      ...operationStatusJson(operationId: 'library-search-paused'),
      'state': 'paused',
      'revision': 9,
    });

    expect(status.state, LibraryOperationState.paused);
    expect(status.revision, 9);
    expect(status.state.isTerminal, isFalse);
  });

  test('operation status IDs mirror the native 1 to 64 byte contract', () {
    for (final operationId in [
      'a',
      '.',
      '_leading',
      '-leading',
      List.filled(64, 'z').join(),
    ]) {
      expect(
        () => LibraryOperationStatus.fromJson(
          operationStatusJson(operationId: operationId),
        ),
        returnsNormally,
      );
    }
    for (final operationId in [
      '',
      'contains/slash',
      List.filled(65, 'z').join(),
    ]) {
      expect(
        () => LibraryOperationStatus.fromJson(
          operationStatusJson(operationId: operationId),
        ),
        throwsFormatException,
      );
    }
  });

  test('requires camelCase, sourceId, and credential-free output', () async {
    transport.responses.add(
      ok(
        folderJson(
          items: [
            {
              'title': '文件',
              'url': 'https://www.lanzouw.com/i000000',
              'shareUrl': 'https://www.lanzouw.com/i000000',
              'isFolder': false,
            },
          ],
        ),
      ),
    );
    await expectLater(
      core.browse(
        sourceId: 'main',
        shareUrl: source.shareUrl,
        password: source.password,
      ),
      throwsA(isA<LibraryCoreFailure>()),
    );

    transport.responses.add(ok({'direct_url': 'https://download.invalid'}));
    await expectLater(
      core.resolve(sourceId: 'main', shareUrl: source.shareUrl),
      throwsA(isA<LibraryCoreFailure>()),
    );

    transport.responses.add(ok({'cookie': 'must-not-leak'}));
    await expectLater(core.probe(source), throwsA(isA<LibraryCoreFailure>()));

    transport.responses.add(ok({'description': 1}));
    await expectLater(
      core.describe(sourceId: 'main', shareUrl: source.shareUrl),
      throwsA(isA<LibraryCoreFailure>()),
    );

    transport.responses.add(
      ok({'mediaType': 'image/jpeg', 'bytesBase64': 'bm90LWEtcG5n'}),
    );
    await expectLater(
      core.fetchAsset(url: 'https://image.dmpdmp.com/example.png'),
      throwsA(isA<LibraryCoreFailure>()),
    );
  });
}

Map<String, Object?> folderJson({required List<Object?> items, int page = 1}) =>
    {
      'sourceId': 'main',
      'title': '主源',
      'url': 'https://www.lanzouw.com/b000000',
      'folderId': 'root',
      'page': page,
      'hasMore': false,
      'items': items,
    };

String ok(Map<String, Object?> data) =>
    jsonEncode({'ok': true, 'data': data, 'error': null});

Map<String, Object?> operationStatusJson({
  required String operationId,
  String kind = 'library_search',
}) => {
  'operationId': operationId,
  'kind': kind,
  'state': 'running',
  'completedUnits': 1,
  'totalUnits': 2,
  'bytesTransferred': 0,
  'totalBytes': 0,
  'itemsFound': 3,
  'revision': 1,
};

class RecordingTransport implements JsonCoreTransport {
  final List<Map<String, Object?>> requests = [];
  final List<String> responses = [];

  @override
  Future<String> dispatch(String request) async {
    requests.add((jsonDecode(request) as Map).cast<String, Object?>());
    return responses.removeAt(0);
  }
}
