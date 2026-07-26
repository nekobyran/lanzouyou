import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/services/library_core.dart';

class IncrementalSearchStart {
  const IncrementalSearchStart({
    required this.operationId,
    required this.cursor,
    required this.state,
    required this.revision,
  });

  factory IncrementalSearchStart.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'operationId', 'cursor', 'state', 'revision'});
    return IncrementalSearchStart(
      operationId: _requiredString(json, 'operationId'),
      cursor: _requiredCursor(json, 'cursor'),
      state: _state(json['state']),
      revision: _nonNegativeInt(json, 'revision'),
    );
  }

  final String operationId;
  final String cursor;
  final LibraryOperationState state;
  final int revision;
}

class IncrementalSearchSourceUpdate {
  const IncrementalSearchSourceUpdate({
    required this.sourceId,
    required this.title,
    required this.found,
    required this.completed,
    this.errorCode = '',
    this.error = '',
  });

  factory IncrementalSearchSourceUpdate.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {'sourceId', 'title', 'found', 'completed'},
      optional: const {'errorCode', 'error'},
    );
    return IncrementalSearchSourceUpdate(
      sourceId: _requiredString(json, 'sourceId'),
      title: _requiredString(json, 'title'),
      found: _nonNegativeInt(json, 'found'),
      completed: _requiredBool(json, 'completed'),
      errorCode: _optionalString(json, 'errorCode'),
      error: _optionalString(json, 'error'),
    );
  }

  final String sourceId;
  final String title;
  final int found;
  final bool completed;
  final String errorCode;
  final String error;
}

class IncrementalSearchStateUpdate {
  const IncrementalSearchStateUpdate({
    required this.state,
    required this.operationRevision,
    this.errorCode = '',
    this.error = '',
  });

  factory IncrementalSearchStateUpdate.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {'state', 'operationRevision'},
      optional: const {'errorCode', 'error'},
    );
    return IncrementalSearchStateUpdate(
      state: _state(json['state']),
      operationRevision: _nonNegativeInt(json, 'operationRevision'),
      errorCode: _optionalString(json, 'errorCode'),
      error: _optionalString(json, 'error'),
    );
  }

  final LibraryOperationState state;
  final int operationRevision;
  final String errorCode;
  final String error;
}

class IncrementalSearchBatch {
  const IncrementalSearchBatch({
    required this.cursor,
    required this.revision,
    required this.items,
    required this.sources,
    this.state,
  });

  factory IncrementalSearchBatch.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {'cursor', 'revision', 'items', 'sources'},
      optional: const {'state'},
    );
    final rawItems = _requiredList(json, 'items');
    if (rawItems.length > 100) {
      throw const FormatException('incremental search batch exceeds 100 items');
    }
    final rawSources = _requiredList(json, 'sources');
    return IncrementalSearchBatch(
      cursor: _requiredCursor(json, 'cursor'),
      revision: _nonNegativeInt(json, 'revision'),
      items: rawItems
          .map((value) => LibraryItem.fromJson(_object(value, 'search item')))
          .toList(growable: false),
      sources: rawSources
          .map(
            (value) => IncrementalSearchSourceUpdate.fromJson(
              _object(value, 'search source update'),
            ),
          )
          .toList(growable: false),
      state: json['state'] == null
          ? null
          : IncrementalSearchStateUpdate.fromJson(
              _object(json['state'], 'search state update'),
            ),
    );
  }

  final String cursor;
  final int revision;
  final List<LibraryItem> items;
  final List<IncrementalSearchSourceUpdate> sources;
  final IncrementalSearchStateUpdate? state;
}

class IncrementalSearchRead {
  const IncrementalSearchRead({
    required this.cursor,
    required this.acknowledgedCursor,
    required this.batches,
    required this.hasMore,
  });

  factory IncrementalSearchRead.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'cursor',
      'acknowledgedCursor',
      'batches',
      'hasMore',
    });
    final rawBatches = _requiredList(json, 'batches');
    if (rawBatches.length > 100) {
      throw const FormatException(
        'incremental search read exceeds 100 batches',
      );
    }
    return IncrementalSearchRead(
      cursor: _requiredCursor(json, 'cursor'),
      acknowledgedCursor: _requiredCursor(json, 'acknowledgedCursor'),
      batches: rawBatches
          .map(
            (value) =>
                IncrementalSearchBatch.fromJson(_object(value, 'search batch')),
          )
          .toList(growable: false),
      hasMore: _requiredBool(json, 'hasMore'),
    );
  }

  final String cursor;
  final String acknowledgedCursor;
  final List<IncrementalSearchBatch> batches;
  final bool hasMore;
}

class IncrementalSearchControl {
  const IncrementalSearchControl({
    required this.operation,
    required this.cursor,
  });

  factory IncrementalSearchControl.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'operation', 'cursor'});
    return IncrementalSearchControl(
      operation: LibraryOperationStatus.fromJson(
        _object(json['operation'], 'search operation'),
      ),
      cursor: _requiredCursor(json, 'cursor'),
    );
  }

  final LibraryOperationStatus operation;
  final String cursor;
}

class IncrementalSearchForget {
  const IncrementalSearchForget({
    required this.operationId,
    required this.forgotten,
  });

  factory IncrementalSearchForget.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'operationId', 'forgotten'});
    return IncrementalSearchForget(
      operationId: _requiredString(json, 'operationId'),
      forgotten: _requiredBool(json, 'forgotten'),
    );
  }

  final String operationId;
  final bool forgotten;
}

abstract interface class PublicLibraryIncrementalSearchCore {
  Future<IncrementalSearchStart> startIncrementalSearch({
    required String operationId,
    required String query,
    List<String> scopeIds = const [],
    LibrarySearchOptions options = const LibrarySearchOptions(),
  });

  Future<IncrementalSearchRead> readIncrementalSearch({
    required String operationId,
    required String cursor,
    String acknowledgeCursor = '',
    int maxBatches = 8,
  });

  Future<IncrementalSearchControl> pauseIncrementalSearch(String operationId);

  Future<IncrementalSearchControl> resumeIncrementalSearch(String operationId);

  Future<IncrementalSearchControl> cancelIncrementalSearch(String operationId);

  Future<IncrementalSearchForget> forgetIncrementalSearch(String operationId);
}

void _expectKeys(
  Map<String, Object?> json,
  Set<String> required, {
  Set<String> optional = const {},
}) {
  if (!json.keys.toSet().containsAll(required) ||
      json.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    throw const FormatException('incremental search response shape is invalid');
  }
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map) throw FormatException('$label must be an object');
  return value.cast<String, Object?>();
}

List<Object?> _requiredList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be a list');
  return value.cast<Object?>();
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty || value.length > 4096) {
    throw FormatException('$key must be a bounded non-empty string');
  }
  return value;
}

String _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return '';
  if (value is! String || value.length > 4096) {
    throw FormatException('$key must be a bounded string');
  }
  return value;
}

String _requiredCursor(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  if (value.length > 128 || !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value)) {
    throw FormatException('$key is invalid');
  }
  return value;
}

int _nonNegativeInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value.toInt() != value || value < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  return value.toInt();
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

LibraryOperationState _state(Object? value) {
  if (value is! String) {
    throw const FormatException('incremental search state must be a string');
  }
  return LibraryOperationState.values.firstWhere(
    (candidate) => candidate.name == value,
    orElse: () =>
        throw FormatException('unknown incremental search state: $value'),
  );
}
