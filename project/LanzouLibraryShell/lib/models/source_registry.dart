enum SourceRegistrySourceKind {
  official,
  composite,
  singleSoftware;

  static SourceRegistrySourceKind parse(Object? value) {
    if (value is! String) {
      throw const FormatException('source registry kind must be a string');
    }
    return values.firstWhere(
      (candidate) => candidate.name == value,
      orElse: () => throw FormatException('unsupported source kind: $value'),
    );
  }
}

/// Rust-owned filtering applied before source-registry pagination.
///
/// Nullable boolean fields deliberately preserve the three wire states:
/// omitted (all), `true`, and `false`.
class SourceRegistryFilter {
  const SourceRegistryFilter({
    this.kind,
    this.searchable,
    this.childDirectory,
    this.builtIn,
  });

  final SourceRegistrySourceKind? kind;
  final bool? searchable;
  final bool? childDirectory;
  final bool? builtIn;

  String get wireKind => kind?.name ?? 'all';

  SourceRegistryFilter withKind(SourceRegistrySourceKind? value) =>
      SourceRegistryFilter(
        kind: value,
        searchable: searchable,
        childDirectory: childDirectory,
        builtIn: builtIn,
      );

  SourceRegistryFilter withSearchable(bool? value) => SourceRegistryFilter(
    kind: kind,
    searchable: value,
    childDirectory: childDirectory,
    builtIn: builtIn,
  );

  SourceRegistryFilter withChildDirectory(bool? value) => SourceRegistryFilter(
    kind: kind,
    searchable: searchable,
    childDirectory: value,
    builtIn: builtIn,
  );

  SourceRegistryFilter withBuiltIn(bool? value) => SourceRegistryFilter(
    kind: kind,
    searchable: searchable,
    childDirectory: childDirectory,
    builtIn: value,
  );

  bool get isDefault =>
      kind == null &&
      searchable == null &&
      childDirectory == null &&
      builtIn == null;

  @override
  bool operator ==(Object other) =>
      other is SourceRegistryFilter &&
      other.kind == kind &&
      other.searchable == searchable &&
      other.childDirectory == childDirectory &&
      other.builtIn == builtIn;

  @override
  int get hashCode => Object.hash(kind, searchable, childDirectory, builtIn);
}

class SourceRegistrySource {
  const SourceRegistrySource({
    required this.id,
    required this.kind,
    required this.title,
    required this.publisher,
    required this.description,
    required this.avatarUrl,
    required this.shareUrl,
    required this.searchable,
    required this.childDirectory,
    required this.originPath,
    required this.originUrl,
    required this.memberCount,
    required this.builtIn,
    this.errorCode = '',
  });

  factory SourceRegistrySource.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(
      json,
      const {
        'id',
        'kind',
        'title',
        'publisher',
        'description',
        'avatarUrl',
        'shareUrl',
        'searchable',
        'childDirectory',
        'originPath',
        'originUrl',
        'memberCount',
        'builtIn',
        'errorCode',
      },
      optional: const {'errorCode'},
    );
    return SourceRegistrySource(
      id: _requiredRegistryString(json, 'id'),
      kind: SourceRegistrySourceKind.parse(json['kind']),
      title: _requiredRegistryString(json, 'title'),
      publisher: _registryString(json, 'publisher'),
      description: _registryString(json, 'description'),
      avatarUrl: _registryString(json, 'avatarUrl'),
      shareUrl: _registryString(json, 'shareUrl'),
      searchable: _registryBool(json, 'searchable'),
      childDirectory: _registryBool(json, 'childDirectory'),
      originPath: _registryString(json, 'originPath'),
      originUrl: _registryString(json, 'originUrl'),
      memberCount: _registryNonNegativeInt(json, 'memberCount'),
      builtIn: _registryBool(json, 'builtIn'),
      errorCode: _registryString(json, 'errorCode', optional: true),
    );
  }

  final String id;
  final SourceRegistrySourceKind kind;
  final String title;
  final String publisher;
  final String description;
  final String avatarUrl;
  final String shareUrl;
  final bool searchable;
  final bool childDirectory;
  final String originPath;
  final String originUrl;
  final int memberCount;
  final bool builtIn;
  final String errorCode;
}

class SourceRegistryCategory {
  const SourceRegistryCategory({
    required this.id,
    required this.title,
    required this.sourceIds,
  });

  factory SourceRegistryCategory.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {'id', 'title', 'sourceIds'});
    final sourceIds = json['sourceIds'];
    if (sourceIds is! List || sourceIds.any((value) => value is! String)) {
      throw const FormatException('sourceIds must be a string list');
    }
    return SourceRegistryCategory(
      id: _requiredRegistryString(json, 'id'),
      title: _requiredRegistryString(json, 'title'),
      sourceIds: sourceIds.cast<String>().toList(growable: false),
    );
  }

  final String id;
  final String title;
  final List<String> sourceIds;
}

class SourceRegistrySnapshot {
  const SourceRegistrySnapshot({
    required this.generation,
    required this.baselineRevision,
    required this.baselineCount,
    required this.userCount,
    required this.mergedCount,
    required this.categories,
    required this.userSources,
  });

  factory SourceRegistrySnapshot.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {
      'generation',
      'baselineRevision',
      'baselineCount',
      'userCount',
      'mergedCount',
      'categories',
      'userSources',
    });
    return SourceRegistrySnapshot(
      generation: _registryNonNegativeInt(json, 'generation'),
      baselineRevision: _requiredRegistryString(json, 'baselineRevision'),
      baselineCount: _registryNonNegativeInt(json, 'baselineCount'),
      userCount: _registryNonNegativeInt(json, 'userCount'),
      mergedCount: _registryNonNegativeInt(json, 'mergedCount'),
      categories: _registryList(json, 'categories')
          .map(
            (value) => SourceRegistryCategory.fromJson(
              _registryObject(value, 'source registry category'),
            ),
          )
          .toList(growable: false),
      userSources: _registryList(json, 'userSources')
          .map(
            (value) => SourceRegistrySource.fromJson(
              _registryObject(value, 'source registry source'),
            ),
          )
          .toList(growable: false),
    );
  }

  final int generation;
  final String baselineRevision;
  final int baselineCount;
  final int userCount;
  final int mergedCount;
  final List<SourceRegistryCategory> categories;
  final List<SourceRegistrySource> userSources;
}

class SourceRegistryPage {
  const SourceRegistryPage({
    required this.generation,
    required this.total,
    required this.nextCursor,
    required this.hasMore,
    required this.sources,
  });

  factory SourceRegistryPage.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {
      'generation',
      'total',
      'nextCursor',
      'hasMore',
      'sources',
    });
    final page = SourceRegistryPage(
      generation: _registryNonNegativeInt(json, 'generation'),
      total: _registryNonNegativeInt(json, 'total'),
      nextCursor: _registryString(json, 'nextCursor'),
      hasMore: _registryBool(json, 'hasMore'),
      sources: _registryList(json, 'sources')
          .map(
            (value) => SourceRegistrySource.fromJson(
              _registryObject(value, 'source registry page source'),
            ),
          )
          .toList(growable: false),
    );
    if (page.hasMore && page.nextCursor.isEmpty) {
      throw const FormatException('source registry cursor is missing');
    }
    return page;
  }

  final int generation;
  final int total;
  final String nextCursor;
  final bool hasMore;
  final List<SourceRegistrySource> sources;
}

class SourceRegistryMutation {
  const SourceRegistryMutation({required this.generation});

  factory SourceRegistryMutation.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {'generation'});
    return SourceRegistryMutation(
      generation: _registryNonNegativeInt(json, 'generation'),
    );
  }

  final int generation;
}

class SourceRegistryImportResult extends SourceRegistryMutation {
  const SourceRegistryImportResult({
    required super.generation,
    required this.added,
    required this.duplicates,
    required this.invalid,
  });

  factory SourceRegistryImportResult.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {
      'generation',
      'added',
      'duplicates',
      'invalid',
    });
    return SourceRegistryImportResult(
      generation: _registryNonNegativeInt(json, 'generation'),
      added: _registryNonNegativeInt(json, 'added'),
      duplicates: _registryNonNegativeInt(json, 'duplicates'),
      invalid: _registryNonNegativeInt(json, 'invalid'),
    );
  }

  final int added;
  final int duplicates;
  final int invalid;
}

class SourceRegistryDeleteResult extends SourceRegistryMutation {
  const SourceRegistryDeleteResult({
    required super.generation,
    required this.removed,
    required this.hidden,
    required this.missing,
  });

  factory SourceRegistryDeleteResult.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {
      'generation',
      'removed',
      'hidden',
      'missing',
    });
    return SourceRegistryDeleteResult(
      generation: _registryNonNegativeInt(json, 'generation'),
      removed: _registryNonNegativeInt(json, 'removed'),
      hidden: _registryNonNegativeInt(json, 'hidden'),
      missing: _registryNonNegativeInt(json, 'missing'),
    );
  }

  final int removed;
  final int hidden;
  final int missing;
}

class SourceRegistryCompositeMutation extends SourceRegistryMutation {
  const SourceRegistryCompositeMutation({
    required super.generation,
    required this.sourceId,
  });

  factory SourceRegistryCompositeMutation.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {'generation', 'sourceId'});
    return SourceRegistryCompositeMutation(
      generation: _registryNonNegativeInt(json, 'generation'),
      sourceId: _requiredRegistryString(json, 'sourceId'),
    );
  }

  final String sourceId;
}

class SourceRegistryExportResult extends SourceRegistryMutation {
  const SourceRegistryExportResult({
    required super.generation,
    required this.count,
    required this.bytesWritten,
    required this.sha256,
  });

  factory SourceRegistryExportResult.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {
      'generation',
      'count',
      'bytesWritten',
      'sha256',
    });
    final sha256 = _requiredRegistryString(json, 'sha256');
    if (!RegExp(r'^[0-9A-F]{64}$').hasMatch(sha256)) {
      throw const FormatException('source registry hash is invalid');
    }
    return SourceRegistryExportResult(
      generation: _registryNonNegativeInt(json, 'generation'),
      count: _registryNonNegativeInt(json, 'count'),
      bytesWritten: _registryNonNegativeInt(json, 'bytesWritten'),
      sha256: sha256,
    );
  }

  final int count;
  final int bytesWritten;
  final String sha256;
}

class SourceRegistryImportPreview {
  const SourceRegistryImportPreview({
    required this.generation,
    required this.previewId,
    required this.valid,
    required this.duplicates,
    required this.invalid,
  });

  factory SourceRegistryImportPreview.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {
      'generation',
      'previewId',
      'valid',
      'duplicates',
      'invalid',
    });
    return SourceRegistryImportPreview(
      generation: _registryNonNegativeInt(json, 'generation'),
      previewId: _requiredRegistryString(json, 'previewId'),
      valid: _registryList(json, 'valid')
          .map(
            (value) => SourceRegistryPreviewValid.fromJson(
              _registryObject(value, 'valid source'),
            ),
          )
          .toList(growable: false),
      duplicates: _registryList(json, 'duplicates')
          .map(
            (value) => SourceRegistryPreviewDuplicate.fromJson(
              _registryObject(value, 'duplicate source'),
            ),
          )
          .toList(growable: false),
      invalid: _registryList(json, 'invalid')
          .map(
            (value) => SourceRegistryPreviewInvalid.fromJson(
              _registryObject(value, 'invalid source'),
            ),
          )
          .toList(growable: false),
    );
  }

  final int generation;
  final String previewId;
  final List<SourceRegistryPreviewValid> valid;
  final List<SourceRegistryPreviewDuplicate> duplicates;
  final List<SourceRegistryPreviewInvalid> invalid;

  int get total => valid.length + duplicates.length + invalid.length;
}

class SourceRegistryPreviewValid {
  const SourceRegistryPreviewValid({
    required this.line,
    required this.title,
    required this.shareUrl,
    required this.requiresCode,
    required this.categoryId,
  });

  factory SourceRegistryPreviewValid.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {
      'line',
      'title',
      'shareUrl',
      'requiresCode',
      'categoryId',
    });
    return SourceRegistryPreviewValid(
      line: _registryNonNegativeInt(json, 'line'),
      title: _requiredRegistryString(json, 'title'),
      shareUrl: _requiredRegistryString(json, 'shareUrl'),
      requiresCode: _registryBool(json, 'requiresCode'),
      categoryId: _registryString(json, 'categoryId'),
    );
  }

  final int line;
  final String title;
  final String shareUrl;
  final bool requiresCode;
  final String categoryId;
}

class SourceRegistryPreviewDuplicate {
  const SourceRegistryPreviewDuplicate({
    required this.line,
    required this.shareUrl,
  });

  factory SourceRegistryPreviewDuplicate.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {'line', 'shareUrl'});
    return SourceRegistryPreviewDuplicate(
      line: _registryNonNegativeInt(json, 'line'),
      shareUrl: _requiredRegistryString(json, 'shareUrl'),
    );
  }

  final int line;
  final String shareUrl;
}

class SourceRegistryPreviewInvalid {
  const SourceRegistryPreviewInvalid({
    required this.line,
    required this.code,
    required this.message,
  });

  factory SourceRegistryPreviewInvalid.fromJson(Map<String, Object?> json) {
    _expectExactRegistryKeys(json, const {'line', 'code', 'message'});
    return SourceRegistryPreviewInvalid(
      line: _registryNonNegativeInt(json, 'line'),
      code: _requiredRegistryString(json, 'code'),
      message: _requiredRegistryString(json, 'message'),
    );
  }

  final int line;
  final String code;
  final String message;
}

class SourceRegistrySourceDraft {
  const SourceRegistrySourceDraft({
    required this.title,
    required this.url,
    this.accessCode = '',
    this.searchable = false,
    this.categoryId = '',
  });

  final String title;
  final String url;
  final String accessCode;
  final bool searchable;
  final String categoryId;

  Map<String, Object?> toJson() => {
    'title': title,
    'url': url,
    'password': accessCode,
    'searchable': searchable,
    'categoryId': categoryId,
  };
}

class SourceRegistryRawImportDraft {
  const SourceRegistryRawImportDraft({
    required this.rawText,
    this.categoryId = '',
  });

  final String rawText;
  final String categoryId;
}

class SourceRegistrySourceUpdateDraft {
  const SourceRegistrySourceUpdateDraft({
    required this.sourceId,
    required this.title,
    required this.searchable,
    this.accessCode,
  });

  final String sourceId;
  final String title;
  final bool searchable;

  /// `null` preserves the current access code. A present empty string clears it.
  final String? accessCode;

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'title': title,
    'searchable': searchable,
    if (accessCode != null) 'accessCode': accessCode,
  };
}

class SourceRegistryCategoryDraft {
  const SourceRegistryCategoryDraft({
    required this.id,
    required this.title,
    this.sourceIds = const [],
  });

  final String id;
  final String title;
  final List<String> sourceIds;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'sourceIds': sourceIds,
  };
}

enum SourceRegistryMemberKind { file, directory, folder, remoteFolder }

class SourceRegistryMemberDraft {
  const SourceRegistryMemberDraft({
    required this.kind,
    this.id = '',
    this.parentId = '',
    this.title = '',
    this.url = '',
    this.accessCode = '',
    this.searchable = false,
    this.iconUrl = '',
    this.size = '',
    this.time = '',
    this.description = '',
  });

  final SourceRegistryMemberKind kind;
  final String id;
  final String parentId;
  final String title;
  final String url;
  final String accessCode;
  final bool searchable;
  final String iconUrl;
  final String size;
  final String time;
  final String description;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'id': id,
    'parentId': parentId,
    'title': title,
    'url': url,
    'password': accessCode,
    'searchable': searchable,
    'iconUrl': iconUrl,
    'size': size,
    'time': time,
    'description': description,
  };
}

class SourceRegistryCompositeDraft {
  const SourceRegistryCompositeDraft({
    required this.title,
    required this.members,
    this.id = '',
    this.publisher = '',
    this.avatarUrl = '',
    this.description = '',
  });

  final String id;
  final String title;
  final String publisher;
  final String avatarUrl;
  final String description;
  final List<SourceRegistryMemberDraft> members;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'publisher': publisher,
    'avatarUrl': avatarUrl,
    'description': description,
    'members': members.map((member) => member.toJson()).toList(growable: false),
  };
}

void _expectExactRegistryKeys(
  Map<String, Object?> json,
  Set<String> allowed, {
  Set<String> optional = const {},
}) {
  if (!json.keys.toSet().containsAll(allowed.difference(optional)) ||
      json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('source registry payload fields are invalid');
  }
}

Map<String, Object?> _registryObject(Object? value, String label) {
  if (value is! Map) throw FormatException('$label must be an object');
  return value.cast<String, Object?>();
}

List<Object?> _registryList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be a list');
  return value;
}

String _requiredRegistryString(Map<String, Object?> json, String key) {
  final value = _registryString(json, key);
  if (value.isEmpty) throw FormatException('$key is required');
  return value;
}

String _registryString(
  Map<String, Object?> json,
  String key, {
  bool optional = false,
}) {
  if (optional && !json.containsKey(key)) return '';
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

bool _registryBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a bool');
  return value;
}

int _registryNonNegativeInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value.toInt() != value || value < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  return value.toInt();
}
