import 'package:lanzou_library_shell/library_preview.dart';

enum PublicLibraryNodeKind {
  remoteSource,
  composite,
  folder,
  singleSoftware,
  file;

  static PublicLibraryNodeKind parse(Object? value) {
    if (value is! String) {
      throw const FormatException('catalog node kind must be a string');
    }
    return values.firstWhere(
      (candidate) => candidate.name == value,
      orElse: () =>
          throw FormatException('unsupported catalog node kind: $value'),
    );
  }
}

class PublicLibraryCatalogSummary {
  const PublicLibraryCatalogSummary({
    required this.revision,
    required this.officialCount,
    required this.compositeCount,
    required this.nodeCount,
    required this.searchableCount,
  });

  factory PublicLibraryCatalogSummary.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, const {
      'revision',
      'officialCount',
      'compositeCount',
      'nodeCount',
      'searchableCount',
    });
    return PublicLibraryCatalogSummary(
      revision: _revision(json['revision']),
      officialCount: _nonNegativeInt(json, 'officialCount'),
      compositeCount: _nonNegativeInt(json, 'compositeCount'),
      nodeCount: _nonNegativeInt(json, 'nodeCount'),
      searchableCount: _nonNegativeInt(json, 'searchableCount'),
    );
  }

  final String revision;
  final int officialCount;
  final int compositeCount;
  final int nodeCount;
  final int searchableCount;

  int get totalSourceCount => officialCount + compositeCount;

  @override
  String toString() =>
      'PublicLibraryCatalogSummary(revision: $revision, '
      'officialCount: $officialCount, compositeCount: $compositeCount, '
      'nodeCount: $nodeCount, searchableCount: $searchableCount)';
}

class PublicLibraryCatalogNode {
  const PublicLibraryCatalogNode({
    required this.id,
    required this.parentId,
    required this.kind,
    required this.sourceId,
    required this.title,
    required this.publisher,
    required this.description,
    required this.iconUrl,
    required this.size,
    required this.time,
    required this.searchable,
    required this.childDirectory,
    required this.originPath,
    required this.originUrl,
    required this.shareUrl,
    required this.hasChildren,
    this.errorCode = '',
  });

  factory PublicLibraryCatalogNode.fromJson(Map<String, Object?> json) {
    _expectExactKeys(
      json,
      const {
        'id',
        'parentId',
        'kind',
        'sourceId',
        'title',
        'publisher',
        'description',
        'iconUrl',
        'size',
        'time',
        'searchable',
        'childDirectory',
        'originPath',
        'originUrl',
        'shareUrl',
        'hasChildren',
        'errorCode',
      },
      optionalKeys: const {'errorCode'},
    );
    final node = PublicLibraryCatalogNode(
      id: _requiredString(json, 'id'),
      parentId: _string(json, 'parentId'),
      kind: PublicLibraryNodeKind.parse(json['kind']),
      sourceId: _string(json, 'sourceId'),
      title: _requiredString(json, 'title'),
      publisher: _string(json, 'publisher'),
      description: _string(json, 'description'),
      iconUrl: _string(json, 'iconUrl'),
      size: _string(json, 'size'),
      time: _string(json, 'time'),
      searchable: _bool(json, 'searchable'),
      childDirectory: _bool(json, 'childDirectory'),
      originPath: _string(json, 'originPath'),
      originUrl: _string(json, 'originUrl'),
      shareUrl: _string(json, 'shareUrl'),
      hasChildren: _bool(json, 'hasChildren'),
      errorCode: _string(json, 'errorCode', optional: true),
    );
    if (node.id.runes.length > 512 || node.title.runes.length > 512) {
      throw const FormatException('catalog node text exceeds its limit');
    }
    return node;
  }

  final String id;
  final String parentId;
  final PublicLibraryNodeKind kind;
  final String sourceId;
  final String title;
  final String publisher;
  final String description;
  final String iconUrl;
  final String size;
  final String time;
  final bool searchable;
  final bool childDirectory;
  final String originPath;
  final String originUrl;
  final String shareUrl;
  final bool hasChildren;
  final String errorCode;

  bool get opensCatalog =>
      kind == PublicLibraryNodeKind.composite ||
      kind == PublicLibraryNodeKind.folder;

  bool get opensRemoteFolder => kind == PublicLibraryNodeKind.remoteSource;

  bool get isSoftware =>
      kind == PublicLibraryNodeKind.singleSoftware ||
      kind == PublicLibraryNodeKind.file;

  String get sourceLabel => publisher.isNotEmpty
      ? publisher
      : originPath.isNotEmpty
      ? originPath
      : sourceId;
}

class PublicLibraryCatalogPage {
  const PublicLibraryCatalogPage({
    required this.revision,
    required this.total,
    required this.nextCursor,
    required this.hasMore,
    required this.nodes,
  });

  factory PublicLibraryCatalogPage.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, const {
      'revision',
      'total',
      'nextCursor',
      'hasMore',
      'nodes',
    });
    final rawNodes = json['nodes'];
    if (rawNodes is! List) {
      throw const FormatException('catalog page nodes must be a list');
    }
    final nodes = rawNodes
        .map(
          (value) => PublicLibraryCatalogNode.fromJson(
            _object(value, 'catalog page node'),
          ),
        )
        .toList(growable: false);
    final page = PublicLibraryCatalogPage(
      revision: _revision(json['revision']),
      total: _nonNegativeInt(json, 'total'),
      nextCursor: _string(json, 'nextCursor'),
      hasMore: _bool(json, 'hasMore'),
      nodes: nodes,
    );
    if (page.hasMore && page.nextCursor.isEmpty) {
      throw const FormatException('catalog page cursor is missing');
    }
    return page;
  }

  final String revision;
  final int total;
  final String nextCursor;
  final bool hasMore;
  final List<PublicLibraryCatalogNode> nodes;

  @override
  String toString() =>
      'PublicLibraryCatalogPage(revision: $revision, total: $total, '
      'nextCursor: $nextCursor, hasMore: $hasMore, nodes: ${nodes.length})';
}

/// A password-free reference to an item already returned by the Rust catalog.
///
/// Rust remains authoritative for source lookup and access codes. This object
/// only sends the identity fields needed to match the previously-returned item.
class PublicLibraryItemRef {
  const PublicLibraryItemRef({
    required this.sourceId,
    required this.title,
    required this.url,
    required this.shareUrl,
    required this.folderId,
    required this.isFolder,
  });

  factory PublicLibraryItemRef.fromItem(LibraryItem item) =>
      PublicLibraryItemRef(
        sourceId: item.sourceId,
        title: item.title,
        url: item.url,
        shareUrl: item.shareUrl,
        folderId: item.folderId,
        isFolder: item.isFolder,
      );

  final String sourceId;
  final String title;
  final String url;
  final String shareUrl;
  final String folderId;
  final bool isFolder;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'title': title,
    'url': url,
    'shareUrl': shareUrl,
    'folderId': folderId,
    'isFolder': isFolder,
  };
}

void _expectExactKeys(
  Map<String, Object?> json,
  Set<String> allowedKeys, {
  Set<String> optionalKeys = const {},
}) {
  final requiredKeys = allowedKeys.difference(optionalKeys);
  if (!json.keys.toSet().containsAll(requiredKeys) ||
      json.keys.any((key) => !allowedKeys.contains(key))) {
    throw const FormatException('catalog payload fields are invalid');
  }
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map) throw FormatException('$label must be an object');
  return value.cast<String, Object?>();
}

String _revision(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  if (value is int && value >= 0) return value.toString();
  throw const FormatException('catalog revision is invalid');
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  if (value.isEmpty) throw FormatException('$key is required');
  return value;
}

String _string(Map<String, Object?> json, String key, {bool optional = false}) {
  if (optional && !json.containsKey(key)) return '';
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a bool');
  return value;
}

int _nonNegativeInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value.toInt() != value || value < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  return value.toInt();
}
