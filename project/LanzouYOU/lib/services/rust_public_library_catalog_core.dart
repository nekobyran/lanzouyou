import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';

import '../pages/public_library/public_library_core.dart';
import '../pages/public_library/public_library_link_models.dart';
import '../pages/public_library/public_library_models.dart';
import 'cloud_service.dart';
import 'public_library_storage.dart';
import 'rust_public_library_protocol.dart';

/// Password-free Dart adapter for the Rust-owned LanzouMax catalog.
///
/// One adapter call maps to one batched JSON FFI request. Source assets,
/// access codes, traversal and cross-source scheduling never move into Dart.
class RustPublicLibraryCatalogCore
    implements PublicLibraryCatalogCore, PublicLibraryLinkRouterCore {
  RustPublicLibraryCatalogCore.production(
    this._dispatch, {
    PublicLibraryStorageRootProvider? storageRootProvider,
  }) : _storageRoot = PublicLibraryStorageRoot(provider: storageRootProvider);

  RustPublicLibraryCatalogCore.testHarness(this._dispatch, String storageRoot)
    : _storageRoot = PublicLibraryStorageRoot.fixed(storageRoot);

  final RustJsonDispatch _dispatch;
  final PublicLibraryStorageRoot _storageRoot;

  @override
  Future<PublicLibraryCatalogSummary> catalogSummary() async {
    final data = await _catalogRequest(const {'op': 'catalog_summary'});
    return _parse(() => PublicLibraryCatalogSummary.fromJson(data), '来源统计响应无效');
  }

  @override
  Future<PublicLibraryCatalogPage> catalogPage({
    String parentId = '',
    String categoryId = 'all',
    String query = '',
    String cursor = '',
    int limit = 100,
  }) async {
    final data = await _catalogRequest({
      'op': 'catalog_page',
      'parentId': parentId,
      'categoryId': categoryId,
      'query': query,
      'cursor': cursor,
      'limit': limit,
    });
    return _parse(() => PublicLibraryCatalogPage.fromJson(data), '来源目录响应无效');
  }

  @override
  Future<LibraryFolder> catalogBrowse({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
    int page = 1,
    bool refresh = false,
  }) async {
    final target = _target(nodeId, itemRef);
    final data = await _catalogRequest({
      'op': 'catalog_browse',
      ...target,
      'page': page,
      'refresh': refresh,
    });
    return _parse(() => LibraryFolder.fromJson(data), '软件目录响应无效');
  }

  @override
  Future<LibrarySearchResult> catalogSearch({
    required String query,
    List<String> scopeIds = const [],
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) async {
    final data = await _catalogRequest({
      'op': 'catalog_search',
      'query': query,
      'scopeIds': scopeIds,
      'options': options.toJson(),
      'operationId': ?operationId,
    });
    return _parse(() {
      final rawItems = jsonList(data, 'items');
      final rawSources = data['sources'];
      if (rawSources != null && rawSources is! List) {
        throw const FormatException('sources must be a list');
      }
      return LibrarySearchResult(
        items: rawItems
            .map(
              (value) =>
                  LibraryItem.fromJson(jsonObject(value, 'catalog item')),
            )
            .toList(growable: false),
        sources: (rawSources as List? ?? const <Object?>[])
            .map(
              (value) => LibrarySearchSourceResult.fromJson(
                jsonObject(value, 'catalog source status'),
              ),
            )
            .toList(growable: false),
      );
    }, '软件搜索响应无效');
  }

  @override
  Future<LibraryDescribeResult> catalogDescribe({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
  }) async {
    final data = await _catalogRequest({
      'op': 'catalog_describe',
      ..._target(nodeId, itemRef),
    });
    return _parse(() => LibraryDescribeResult.fromJson(data), '软件简介响应无效');
  }

  @override
  Future<LibraryResolveResult> catalogResolve({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
  }) async {
    final data = await _catalogRequest({
      'op': 'catalog_resolve',
      ..._target(nodeId, itemRef),
    });
    return _parse(
      () => LibraryResolveResult(
        url: requiredString(data, 'url'),
        fileName: requiredString(data, 'fileName'),
      ),
      '软件直链响应无效',
    );
  }

  @override
  Future<LibraryDownloadResult> catalogDownload({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
    required String destinationDirectory,
    String? operationId,
  }) async {
    final data = await _catalogRequest({
      'op': 'catalog_download',
      ..._target(nodeId, itemRef),
      'destinationDirectory': destinationDirectory,
      'operationId': ?operationId,
    });
    return _parse(() => LibraryDownloadResult.fromJson(data), '软件下载响应无效');
  }

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) async {
    final data = await _request({
      'op': 'operation_status',
      'operationId': operationId,
    });
    return _parse(() {
      final status = LibraryOperationStatus.fromJson(data);
      if (status.operationId != operationId ||
          !const {'library_search', 'download'}.contains(status.kind)) {
        throw const FormatException('operation identity does not match');
      }
      return status;
    }, '操作进度响应无效');
  }

  @override
  Future<void> cancelOperation(String operationId) =>
      _request({'op': 'operation_cancel', 'operationId': operationId});

  @override
  Future<void> forgetOperation(String operationId) =>
      _request({'op': 'operation_forget', 'operationId': operationId});

  @override
  Future<PublicLibraryLinkTokens> tokenizeLinks(String text) async {
    final data = await _request({'op': 'link_tokenize', 'text': text});
    return _parse(
      () => PublicLibraryLinkTokens.fromJson(data),
      '链接识别响应无效',
    );
  }

  @override
  Future<PublicLibraryLinkRoute> routeLink({
    required String text,
    required int tokenIndex,
    required PublicLibraryLinkPreference preference,
  }) async {
    final data = await _request({
      'op': 'link_route',
      'text': text,
      'tokenIndex': tokenIndex,
      'preference': preference.name,
    });
    return _parse(
      () => PublicLibraryLinkRoute.fromJson(data),
      '链接路由响应无效',
    );
  }

  @override
  Future<LibraryFolder> browseRoutedLink({
    required String routeHandle,
    int page = 1,
    bool refresh = false,
  }) async {
    final data = await _catalogRequest({
      'op': 'catalog_browse_link',
      'routeHandle': routeHandle,
      'page': page,
      'refresh': refresh,
    });
    return _parse(() => LibraryFolder.fromJson(data), '链接目录响应无效');
  }

  Map<String, Object?> _target(String nodeId, PublicLibraryItemRef? itemRef) {
    final hasNode = nodeId.trim().isNotEmpty;
    if (hasNode == (itemRef != null)) {
      throw ArgumentError('必须且只能提供 nodeId 或 itemRef');
    }
    return hasNode
        ? <String, Object?>{'nodeId': nodeId}
        : <String, Object?>{'itemRef': itemRef!.toJson()};
  }

  Future<Map<String, Object?>> _catalogRequest(
    Map<String, Object?> request,
  ) async =>
      _request({...request, 'storageRoot': await _storageRoot.resolve()});

  Future<Map<String, Object?>> _request(Map<String, Object?> request) async {
    try {
      final data = await _dispatch(request);
      validatePasswordFreePublicLibraryPayload(data);
      return data;
    } on LibraryCoreFailure {
      rethrow;
    } on CloudFailure catch (error) {
      throw LibraryCoreFailure(
        error.code,
        error.message,
        retriable: error.retriable,
      );
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', error.message);
    } on Object {
      throw const LibraryCoreFailure(
        'coreUnavailable',
        'LanzouYOU 核心调用失败，请稍后重试',
        retriable: true,
      );
    }
  }
}

T _parse<T>(T Function() parser, String message) {
  try {
    return parser();
  } on LibraryCoreFailure {
    rethrow;
  } on FormatException catch (error) {
    throw LibraryCoreFailure('invalidResponse', '$message：${error.message}');
  }
}
