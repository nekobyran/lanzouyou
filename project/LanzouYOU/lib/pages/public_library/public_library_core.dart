import 'package:lanzou_library_shell/library_preview.dart';

import 'public_library_models.dart';
import 'public_library_link_models.dart';

/// Password-free Flutter contract for the Rust-owned LanzouMax catalog.
///
/// Implementations must keep source assets, access codes, traversal and
/// cross-source scheduling in Rust. Dart receives only bounded pages or
/// already-materialized public library results.
abstract interface class PublicLibraryCatalogCore {
  Future<PublicLibraryCatalogSummary> catalogSummary();

  Future<PublicLibraryCatalogPage> catalogPage({
    String parentId = '',
    String categoryId = 'all',
    String query = '',
    String cursor = '',
    int limit = 100,
  });

  Future<LibraryFolder> catalogBrowse({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
    int page = 1,
    bool refresh = false,
  });

  Future<LibrarySearchResult> catalogSearch({
    required String query,
    List<String> scopeIds = const [],
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  });

  Future<LibraryDescribeResult> catalogDescribe({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
  });

  Future<LibraryResolveResult> catalogResolve({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
  });

  Future<LibraryDownloadResult> catalogDownload({
    String nodeId = '',
    PublicLibraryItemRef? itemRef,
    required String destinationDirectory,
    String? operationId,
  });

  Future<LibraryOperationStatus> operationStatus(String operationId);

  Future<void> cancelOperation(String operationId);

  Future<void> forgetOperation(String operationId);
}

abstract interface class PublicLibraryLinkRouterCore {
  Future<PublicLibraryLinkTokens> tokenizeLinks(String text);

  Future<PublicLibraryLinkRoute> routeLink({
    required String text,
    required int tokenIndex,
    required PublicLibraryLinkPreference preference,
  });

  Future<LibraryFolder> browseRoutedLink({
    required String routeHandle,
    int page = 1,
    bool refresh = false,
  });
}
