import 'dart:convert';

import '../config/library_config.dart';
import '../models/library_item.dart';
import 'json_core_transport.dart';
import 'library_core.dart';

export 'json_core_transport.dart' show JsonCoreTransport;

class RustLibraryCore
    implements
        LibraryCore,
        LibraryAssetCore,
        LibraryDownloadRuntime,
        LibraryCoreLifecycle {
  RustLibraryCore.production()
    : this._(PersistentIsolateJsonCoreTransport.production());

  factory RustLibraryCore.testHarness({required JsonCoreTransport transport}) =>
      RustLibraryCore._(transport);

  RustLibraryCore._(this._transport);

  final JsonCoreTransport _transport;

  @override
  Future<void> close() {
    final transport = _transport;
    return transport is ClosableJsonCoreTransport
        ? transport.close()
        : Future.value();
  }

  @override
  Future<LibraryProbeResult> probe(LibrarySource source) async {
    final data = await _request({
      'op': 'library_probe',
      'source': source.toCoreJson(),
    });
    try {
      return LibraryProbeResult(
        source: LibraryProbeSource.fromJson(_map(data['source'], 'source')),
        folder: LibraryFolder.fromJson(_map(data['folder'], 'folder')),
      );
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', '核心探测响应无效：${error.message}');
    }
  }

  @override
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async {
    final data = await _request({
      'op': 'library_browse',
      'sourceId': sourceId,
      'shareUrl': shareUrl,
      'password': password,
      'page': page,
      'refresh': refresh,
    });
    try {
      return LibraryFolder.fromJson(data);
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', '目录响应无效：${error.message}');
    }
  }

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) async {
    final data = await _request({
      'op': 'library_search',
      'query': query,
      'sources': sources.map((source) => source.toCoreJson()).toList(),
      'options': options.toJson(),
      'operationId': ?operationId,
    });
    try {
      return LibrarySearchResult(
        items: _items(data, 'items'),
        sources: _optionalList(data, 'sources')
            .map(
              (value) =>
                  LibrarySearchSourceResult.fromJson(_map(value, 'sources[]')),
            )
            .toList(growable: false),
      );
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', '搜索响应无效：${error.message}');
    }
  }

  @override
  Future<LibraryCollectResult> collect({
    required List<LibraryItem> items,
    required List<LibrarySource> sources,
  }) async {
    final data = await _request({
      'op': 'library_collect',
      'items': items.map((item) => item.toCoreJson()).toList(),
      'sources': sources.map((source) => source.toCoreJson()).toList(),
    });
    try {
      return LibraryCollectResult(
        files: _items(data, 'files'),
        foldersScanned: (data['foldersScanned'] as num?)?.toInt() ?? 0,
      );
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', '聚合响应无效：${error.message}');
    }
  }

  @override
  Future<LibraryResolveResult> resolve({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async {
    final data = await _request({
      'op': 'library_resolve',
      'sourceId': sourceId,
      'shareUrl': shareUrl,
      'password': password,
    });
    try {
      return LibraryResolveResult(
        url: requiredString(data, 'url'),
        fileName: requiredString(data, 'fileName'),
      );
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', '解析响应无效：${error.message}');
    }
  }

  @override
  Future<LibraryDownloadResult> download({
    required String sourceId,
    required String shareUrl,
    String password = '',
    required String destinationDirectory,
    String? operationId,
  }) async {
    final data = await _request({
      'op': 'library_download',
      'sourceId': sourceId,
      'shareUrl': shareUrl,
      'password': password,
      'destinationDirectory': destinationDirectory,
      'operationId': ?operationId,
    });
    try {
      return LibraryDownloadResult.fromJson(data);
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', '下载响应无效：${error.message}');
    }
  }

  @override
  Future<LibraryDescribeResult> describe({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async {
    final data = await _request({
      'op': 'library_describe',
      'sourceId': sourceId,
      'shareUrl': shareUrl,
      'password': password,
    });
    try {
      return LibraryDescribeResult.fromJson(data);
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', '简介响应无效：${error.message}');
    }
  }

  @override
  Future<LibraryAssetResult> fetchAsset({required String url}) async {
    final data = await _request({'op': 'library_fetch_asset', 'url': url});
    try {
      return LibraryAssetResult.fromJson(data);
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', '图标响应无效：${error.message}');
    }
  }

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) async {
    final data = await _request({
      'op': 'operation_status',
      'operationId': operationId,
    });
    try {
      final status = LibraryOperationStatus.fromJson(data);
      if (status.operationId != operationId ||
          !const {'library_search', 'download'}.contains(status.kind)) {
        throw const FormatException(
          'operation identity or kind does not match',
        );
      }
      return status;
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', '进度响应无效：${error.message}');
    }
  }

  @override
  Future<void> cancelOperation(String operationId) async {
    await _request({'op': 'operation_cancel', 'operationId': operationId});
  }

  @override
  Future<void> forgetOperation(String operationId) async {
    await _request({'op': 'operation_forget', 'operationId': operationId});
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> request) async {
    final String response;
    try {
      response = await _transport.dispatch(jsonEncode(request));
    } on LibraryCoreFailure {
      rethrow;
    } on Object {
      throw const LibraryCoreFailure(
        'coreUnavailable',
        'LanzouYOU 核心不可用，请安装包含原生核心的完整软件库',
        retriable: true,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response);
    } on Object {
      throw const LibraryCoreFailure('invalidResponse', '核心返回的不是有效 JSON');
    }
    if (decoded is! Map) {
      throw const LibraryCoreFailure('invalidResponse', '核心返回的不是 JSON 对象');
    }
    final envelope = decoded.cast<String, Object?>();
    _validateOutput(envelope);
    if (envelope['ok'] != true) {
      final error = envelope['error'];
      final details = error is Map
          ? error.cast<String, Object?>()
          : const <String, Object?>{};
      throw LibraryCoreFailure(
        '${details['code'] ?? 'coreError'}',
        '${details['message'] ?? '核心操作失败'}',
        retriable: details['retriable'] == true,
      );
    }
    final data = envelope['data'];
    if (data is! Map) {
      throw const LibraryCoreFailure('invalidResponse', '核心响应缺少 data 对象');
    }
    return data.cast<String, Object?>();
  }
}

List<LibraryItem> _items(Map<String, Object?> json, String key) {
  final values = json[key];
  if (values is! List) throw FormatException('$key must be a list');
  return values
      .map((value) => LibraryItem.fromJson(_map(value, '$key[]')))
      .toList(growable: false);
}

List<Object?> _optionalList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List) throw FormatException('$key must be a list');
  return value;
}

Map<String, Object?> _map(Object? value, String label) {
  if (value is! Map) throw FormatException('$label must be an object');
  return value.cast<String, Object?>();
}

final RegExp _camelCaseKey = RegExp(r'^[a-z][A-Za-z0-9]*$');

void _validateOutput(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String || !_camelCaseKey.hasMatch(key)) {
        throw const LibraryCoreFailure(
          'invalidResponse',
          '核心响应字段必须使用 camelCase',
        );
      }
      final lower = key.toLowerCase();
      if (lower.contains('password') || lower.contains('cookie')) {
        throw const LibraryCoreFailure('unsafeResponse', '核心响应包含不允许返回的凭据字段');
      }
      _validateOutput(entry.value);
    }
  } else if (value is List) {
    for (final item in value) {
      _validateOutput(item);
    }
  }
}
