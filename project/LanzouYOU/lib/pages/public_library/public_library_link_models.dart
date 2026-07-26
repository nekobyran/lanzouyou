enum PublicLibraryLinkTokenKind {
  lanzouShare,
  external,
  productRelease,
  blocked;

  static PublicLibraryLinkTokenKind parse(Object? value) => switch (value) {
    'lanzou_share' => PublicLibraryLinkTokenKind.lanzouShare,
    'external' => PublicLibraryLinkTokenKind.external,
    'product_release' => PublicLibraryLinkTokenKind.productRelease,
    'blocked' => PublicLibraryLinkTokenKind.blocked,
    _ => throw const FormatException('unsupported link token kind'),
  };
}

class PublicLibraryLinkToken {
  const PublicLibraryLinkToken({
    required this.text,
    required this.startUtf16,
    required this.endUtf16,
    required this.kind,
    this.canonicalUrl = '',
  });

  factory PublicLibraryLinkToken.fromJson(Map<String, Object?> json) {
    _expectLinkKeys(
      json,
      const {'text', 'startUtf16', 'endUtf16', 'kind', 'canonicalUrl'},
      optional: const {'canonicalUrl'},
    );
    final text = _linkString(json, 'text', required: true);
    final start = _linkInt(json, 'startUtf16');
    final end = _linkInt(json, 'endUtf16');
    if (end <= start || end - start > 4096) {
      throw const FormatException('link token range is invalid');
    }
    return PublicLibraryLinkToken(
      text: text,
      startUtf16: start,
      endUtf16: end,
      kind: PublicLibraryLinkTokenKind.parse(json['kind']),
      canonicalUrl: _linkString(json, 'canonicalUrl'),
    );
  }

  final String text;
  final int startUtf16;
  final int endUtf16;
  final PublicLibraryLinkTokenKind kind;
  final String canonicalUrl;
}

class PublicLibraryLinkTokens {
  const PublicLibraryLinkTokens(this.tokens);

  factory PublicLibraryLinkTokens.fromJson(Map<String, Object?> json) {
    _expectLinkKeys(json, const {'tokens'});
    final raw = json['tokens'];
    if (raw is! List || raw.length > 256) {
      throw const FormatException('link tokens must be a bounded list');
    }
    final tokens = raw
        .map(
          (value) =>
              PublicLibraryLinkToken.fromJson(_linkObject(value, 'link token')),
        )
        .toList(growable: false);
    var previousEnd = 0;
    for (final token in tokens) {
      if (token.startUtf16 < previousEnd) {
        throw const FormatException('link tokens overlap');
      }
      previousEnd = token.endUtf16;
    }
    return PublicLibraryLinkTokens(tokens);
  }

  final List<PublicLibraryLinkToken> tokens;
}

enum PublicLibraryLinkPreference { ask, parse, browser }

enum PublicLibraryLinkAction {
  ask,
  parse,
  browser,
  blocked;

  static PublicLibraryLinkAction fromJsonValue(Object? value) {
    if (value is! String) {
      throw const FormatException('link action must be a string');
    }
    return values.firstWhere(
      (candidate) => candidate.name == value,
      orElse: () => throw const FormatException('unsupported link action'),
    );
  }
}

class PublicLibraryLinkRoute {
  const PublicLibraryLinkRoute({
    required this.action,
    this.targetUrl = '',
    this.routeHandle = '',
  });

  factory PublicLibraryLinkRoute.fromJson(Map<String, Object?> json) {
    _expectLinkKeys(
      json,
      const {'action', 'targetUrl', 'routeHandle'},
      optional: const {'targetUrl', 'routeHandle'},
    );
    final route = PublicLibraryLinkRoute(
      action: PublicLibraryLinkAction.fromJsonValue(json['action']),
      targetUrl: _linkString(json, 'targetUrl'),
      routeHandle: _linkString(json, 'routeHandle'),
    );
    final valid = switch (route.action) {
      PublicLibraryLinkAction.browser =>
        route.targetUrl.isNotEmpty && route.routeHandle.isEmpty,
      PublicLibraryLinkAction.ask || PublicLibraryLinkAction.parse =>
        route.targetUrl.isEmpty && route.routeHandle.isNotEmpty,
      PublicLibraryLinkAction.blocked =>
        route.targetUrl.isEmpty && route.routeHandle.isEmpty,
    };
    if (!valid) {
      throw const FormatException('link route target shape is invalid');
    }
    return route;
  }

  final PublicLibraryLinkAction action;
  final String targetUrl;
  final String routeHandle;
}

void _expectLinkKeys(
  Map<String, Object?> json,
  Set<String> allowed, {
  Set<String> optional = const {},
}) {
  if (!json.keys.toSet().containsAll(allowed.difference(optional)) ||
      json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('link payload fields are invalid');
  }
}

Map<String, Object?> _linkObject(Object? value, String label) {
  if (value is! Map) throw FormatException('$label must be an object');
  return value.cast<String, Object?>();
}

String _linkString(
  Map<String, Object?> json,
  String key, {
  bool required = false,
}) {
  if (!json.containsKey(key)) return '';
  final value = json[key];
  if (value is! String || (required && value.isEmpty)) {
    throw FormatException('$key must be a string');
  }
  return value;
}

int _linkInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value.toInt() != value || value < 0) {
    throw FormatException('$key must be a non-negative integer');
  }
  return value.toInt();
}
