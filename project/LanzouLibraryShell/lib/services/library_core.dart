import 'dart:convert';
import 'dart:typed_data';

import '../config/library_config.dart';
import '../models/library_item.dart';

abstract interface class LibraryCore {
  Future<LibraryProbeResult> probe(LibrarySource source);

  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  });

  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  });

  Future<LibraryCollectResult> collect({
    required List<LibraryItem> items,
    required List<LibrarySource> sources,
  });

  Future<LibraryResolveResult> resolve({
    required String sourceId,
    required String shareUrl,
    String password = '',
  });

  Future<LibraryDescribeResult> describe({
    required String sourceId,
    required String shareUrl,
    String password = '',
  });
}

abstract interface class LibraryAssetCore {
  Future<LibraryAssetResult> fetchAsset({required String url});
}

abstract interface class LibraryDownloadCore {
  Future<LibraryDownloadResult> download({
    required String sourceId,
    required String shareUrl,
    String password = '',
    required String destinationDirectory,
    String? operationId,
  });
}

abstract interface class LibraryOperationCore {
  Future<LibraryOperationStatus> operationStatus(String operationId);

  Future<void> cancelOperation(String operationId);

  Future<void> forgetOperation(String operationId);
}

abstract interface class LibraryDownloadRuntime
    implements LibraryDownloadCore, LibraryOperationCore {}

/// Optional lifecycle for cores that own isolates, native handles, or sockets.
abstract interface class LibraryCoreLifecycle {
  Future<void> close();
}

class LibraryCoreFailure implements Exception {
  const LibraryCoreFailure(this.code, this.message, {this.retriable = false});

  final String code;
  final String message;
  final bool retriable;

  @override
  String toString() => 'LibraryCoreFailure($code): $message';
}

class LibraryProbeSource {
  const LibraryProbeSource({
    required this.sourceId,
    required this.title,
    required this.shareUrl,
    required this.searchable,
  });

  factory LibraryProbeSource.fromJson(Map<String, Object?> json) =>
      LibraryProbeSource(
        sourceId: requiredString(json, 'sourceId'),
        title: requiredString(json, 'title'),
        shareUrl: requiredString(json, 'shareUrl'),
        searchable: json['searchable'] == true,
      );

  final String sourceId;
  final String title;
  final String shareUrl;
  final bool searchable;
}

class LibraryProbeResult {
  const LibraryProbeResult({required this.source, required this.folder});

  final LibraryProbeSource source;
  final LibraryFolder folder;
}

class LibrarySearchOptions {
  const LibrarySearchOptions({
    this.concurrency = 16,
    this.sourceSwitchDelayMs = 15000,
    this.untilLastPage = true,
    this.maxPages = 0,
  });

  final int concurrency;
  final int sourceSwitchDelayMs;
  final bool untilLastPage;
  final int maxPages;

  Map<String, Object?> toJson() => {
    'concurrency': concurrency,
    'sourceSwitchDelayMs': sourceSwitchDelayMs,
    'untilLastPage': untilLastPage,
    'maxPages': maxPages,
  };
}

class LibrarySearchSourceResult {
  const LibrarySearchSourceResult({
    required this.sourceId,
    required this.title,
    required this.found,
    this.error = '',
  });

  factory LibrarySearchSourceResult.fromJson(Map<String, Object?> json) =>
      LibrarySearchSourceResult(
        sourceId: requiredString(json, 'sourceId'),
        title: requiredString(json, 'title'),
        found: (json['found'] as num?)?.toInt() ?? 0,
        error: optionalString(json, 'error'),
      );

  final String sourceId;
  final String title;
  final int found;
  final String error;
}

class LibrarySearchResult {
  const LibrarySearchResult({this.items = const [], this.sources = const []});

  final List<LibraryItem> items;
  final List<LibrarySearchSourceResult> sources;
}

enum LibraryOperationState {
  running,
  paused,
  cancelling,
  succeeded,
  cancelled,
  failed;

  bool get isTerminal => switch (this) {
    succeeded || cancelled || failed => true,
    running || paused || cancelling => false,
  };
}

class LibraryOperationStatus {
  const LibraryOperationStatus({
    required this.operationId,
    required this.kind,
    required this.state,
    required this.completedUnits,
    required this.totalUnits,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.itemsFound,
    this.revision = 0,
  });

  factory LibraryOperationStatus.fromJson(Map<String, Object?> json) {
    int nonNegativeInt(String key) {
      final value = json[key];
      if (value is! num || value.toInt() != value || value < 0) {
        throw FormatException('$key must be a non-negative integer');
      }
      return value.toInt();
    }

    final operationId = requiredString(json, 'operationId');
    final kind = requiredString(json, 'kind');
    final rawState = requiredString(json, 'state');
    final state = LibraryOperationState.values.where(
      (candidate) => candidate.name == rawState,
    );
    if (state.length != 1 ||
        !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(operationId) ||
        !const {'upload', 'download', 'library_search'}.contains(kind)) {
      throw const FormatException('operation status is invalid');
    }
    final completedUnits = nonNegativeInt('completedUnits');
    final totalUnits = nonNegativeInt('totalUnits');
    final bytesTransferred = nonNegativeInt('bytesTransferred');
    final totalBytes = nonNegativeInt('totalBytes');
    final itemsFound = nonNegativeInt('itemsFound');
    final revision = nonNegativeInt('revision');
    if ((totalUnits > 0 && completedUnits > totalUnits) ||
        (totalBytes > 0 && bytesTransferred > totalBytes)) {
      throw const FormatException('operation progress exceeds its total');
    }
    return LibraryOperationStatus(
      operationId: operationId,
      kind: kind,
      state: state.single,
      completedUnits: completedUnits,
      totalUnits: totalUnits,
      bytesTransferred: bytesTransferred,
      totalBytes: totalBytes,
      itemsFound: itemsFound,
      revision: revision,
    );
  }

  final String operationId;
  final String kind;
  final LibraryOperationState state;
  final int completedUnits;
  final int totalUnits;
  final int bytesTransferred;
  final int totalBytes;
  final int itemsFound;
  final int revision;

  double? get fraction => totalUnits > 0
      ? (completedUnits / totalUnits).clamp(0, 1)
      : totalBytes > 0
      ? (bytesTransferred / totalBytes).clamp(0, 1)
      : null;
}

class LibraryCollectResult {
  const LibraryCollectResult({
    required this.files,
    required this.foldersScanned,
  });

  final List<LibraryItem> files;
  final int foldersScanned;
}

class LibraryResolveResult {
  const LibraryResolveResult({required this.url, required this.fileName});

  final String url;
  final String fileName;
}

class LibraryDownloadResult {
  const LibraryDownloadResult({
    required this.path,
    required this.fileName,
    required this.bytesWritten,
  });

  factory LibraryDownloadResult.fromJson(Map<String, Object?> json) {
    final path = requiredString(json, 'path');
    final fileName = requiredString(json, 'fileName');
    final bytesWritten = json['bytesWritten'];
    if (bytesWritten is! num ||
        bytesWritten.toInt() != bytesWritten ||
        bytesWritten < 0) {
      throw const FormatException(
        'bytesWritten must be a non-negative integer',
      );
    }
    return LibraryDownloadResult(
      path: path,
      fileName: fileName,
      bytesWritten: bytesWritten.toInt(),
    );
  }

  final String path;
  final String fileName;
  final int bytesWritten;
}

class LibraryDescribeResult {
  const LibraryDescribeResult({required this.description});

  factory LibraryDescribeResult.fromJson(Map<String, Object?> json) {
    final description = json['description'];
    if (description is! String) {
      throw const FormatException('description must be a string');
    }
    return LibraryDescribeResult(description: description);
  }

  final String description;
}

class LibraryAssetResult {
  LibraryAssetResult._({required this.mediaType, required this.bytes});

  factory LibraryAssetResult.fromJson(Map<String, Object?> json) {
    final mediaType = json['mediaType'];
    final encoded = json['bytesBase64'];
    if (mediaType != 'image/png' ||
        encoded is! String ||
        encoded.isEmpty ||
        encoded.length > 1400000) {
      throw const FormatException('asset response is invalid');
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const FormatException('asset bytes are invalid');
    }
    if (bytes.isEmpty ||
        bytes.length > 1048576 ||
        bytes.length < 8 ||
        !const [
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
        ].indexed.every((entry) => bytes[entry.$1] == entry.$2)) {
      throw const FormatException('asset PNG is invalid');
    }
    return LibraryAssetResult._(
      mediaType: 'image/png',
      bytes: Uint8List.fromList(bytes),
    );
  }

  final String mediaType;
  final Uint8List bytes;
}
