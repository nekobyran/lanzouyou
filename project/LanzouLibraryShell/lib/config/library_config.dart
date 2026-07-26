import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const libraryConfigAsset = 'assets/runtime/library.json';
const maxLibrarySourceCount = 4096;

enum LibraryConfigErrorKind { invalid, unconfiguredTemplate }

class LibraryConfigException implements Exception {
  const LibraryConfigException(
    this.message, {
    this.kind = LibraryConfigErrorKind.invalid,
  });

  const LibraryConfigException.unconfiguredTemplate()
    : message = '请通过 LanzouYOU 生成软件库后再打开',
      kind = LibraryConfigErrorKind.unconfiguredTemplate;

  final String message;
  final LibraryConfigErrorKind kind;

  @override
  String toString() => 'LibraryConfigException: $message';
}

class LibraryConfigLoader {
  LibraryConfigLoader.embeddedRuntime()
    : bundle = rootBundle,
      asset = libraryConfigAsset;

  const LibraryConfigLoader.testHarness({
    required this.bundle,
    this.asset = libraryConfigAsset,
  });

  final AssetBundle bundle;
  final String asset;

  Future<LibraryConfig> load() async {
    try {
      final decoded = jsonDecode(await bundle.loadString(asset));
      if (decoded is! Map) {
        throw const LibraryConfigException('软件库配置必须是 JSON 对象');
      }
      final config = decoded.cast<String, Object?>();
      if (_isUnconfiguredTemplate(config)) {
        throw const LibraryConfigException.unconfiguredTemplate();
      }
      return LibraryConfig.fromJson(config);
    } on LibraryConfigException {
      rethrow;
    } on Object {
      throw const LibraryConfigException('无法读取软件库配置，请重新生成安装包');
    }
  }
}

bool _isUnconfiguredTemplate(Map<String, Object?> json) =>
    json.length == 2 &&
    json['schemaVersion'] == 0 &&
    json['templateState'] == 'requiresGeneration';

class LibraryConfig {
  const LibraryConfig({
    required this.schemaVersion,
    required this.identity,
    required this.branding,
    required this.home,
    required this.sources,
    required this.features,
  });

  factory LibraryConfig.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {'schemaVersion', 'identity', 'branding', 'sources', 'features'},
      'root',
      optional: const {'home'},
    );
    final schemaVersion = _int(json, 'schemaVersion');
    if (schemaVersion != 1) {
      throw const LibraryConfigException('schemaVersion 必须是 1');
    }
    final sources = _list(json, 'sources')
        .map((value) => LibrarySource.fromJson(_object(value, 'sources[]')))
        .toList(growable: false);
    if (sources.isEmpty || sources.length > maxLibrarySourceCount) {
      throw const LibraryConfigException('sources 必须包含 1-4096 个软件源');
    }
    final ids = <String>{};
    for (final source in sources) {
      if (!ids.add(source.sourceId)) {
        throw const LibraryConfigException('软件源 sourceId 不能重复');
      }
    }
    return LibraryConfig(
      schemaVersion: schemaVersion,
      identity: LibraryIdentity.fromJson(_map(json, 'identity')),
      branding: LibraryBranding.fromJson(_map(json, 'branding')),
      home: json.containsKey('home')
          ? LibraryHomeContent.fromJson(_map(json, 'home'))
          : const LibraryHomeContent(),
      sources: sources,
      features: LibraryFeatures.fromJson(_map(json, 'features')),
    );
  }

  final int schemaVersion;
  final LibraryIdentity identity;
  final LibraryBranding branding;
  final LibraryHomeContent home;
  final List<LibrarySource> sources;
  final LibraryFeatures features;

  LibrarySource? sourceById(String sourceId) {
    for (final source in sources) {
      if (source.sourceId == sourceId) return source;
    }
    return null;
  }
}

class LibraryWebPage {
  const LibraryWebPage({required this.name, required this.url, this.icon = ''});

  factory LibraryWebPage.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, const {'name', 'url', 'icon'}, 'home.webPages[]');
    final page = LibraryWebPage(
      name: _requiredText(json, 'name'),
      url: _requiredText(json, 'url'),
      icon: _text(json, 'icon'),
    );
    if (!_validDisplayText(page.name, allowEmpty: false) ||
        !_validHttpsUrl(page.url, restrictHost: false) ||
        (page.icon.isNotEmpty &&
            !_validHttpsUrl(page.icon, restrictHost: false))) {
      throw const LibraryConfigException('网页页面配置无效');
    }
    return page;
  }

  final String name;
  final String url;
  final String icon;
}

class LibraryHomeContent {
  const LibraryHomeContent({
    this.visible = true,
    this.splashImage = '',
    this.splashText = '',
    this.carouselImages = const <String>[],
    this.announcementUrl = '',
    this.webPages = const <LibraryWebPage>[],
  });

  factory LibraryHomeContent.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, const {
      'visible',
      'splashImage',
      'splashText',
      'carouselImages',
      'announcementUrl',
      'webPages',
    }, 'home');
    final rawImages = _list(json, 'carouselImages');
    final rawPages = _list(json, 'webPages');
    final home = LibraryHomeContent(
      visible: _bool(json, 'visible'),
      splashImage: _text(json, 'splashImage'),
      splashText: _text(json, 'splashText'),
      carouselImages: rawImages
          .map((value) {
            if (value is! String) {
              throw const LibraryConfigException('轮播图片必须是文本地址');
            }
            return value.trim();
          })
          .toList(growable: false),
      announcementUrl: _text(json, 'announcementUrl'),
      webPages: rawPages
          .map(
            (value) =>
                LibraryWebPage.fromJson(_object(value, 'home.webPages[]')),
          )
          .toList(growable: false),
    );
    if (home.splashText.runes.length > 2000 ||
        home.carouselImages.length > 50 ||
        home.webPages.length > 50) {
      throw const LibraryConfigException('主页内容超过安全上限');
    }
    for (final url in [
      home.splashImage,
      home.announcementUrl,
      ...home.carouselImages,
    ]) {
      if (url.isNotEmpty && !_validHttpsUrl(url, restrictHost: false)) {
        throw const LibraryConfigException('主页远程资源必须使用 HTTPS 地址');
      }
    }
    return home;
  }

  final bool visible;
  final String splashImage;
  final String splashText;
  final List<String> carouselImages;
  final String announcementUrl;
  final List<LibraryWebPage> webPages;
}

class LibraryIdentity {
  const LibraryIdentity({
    required this.projectId,
    required this.displayName,
    required this.applicationId,
    required this.versionName,
    required this.versionCode,
    required this.windowsExeName,
  });

  factory LibraryIdentity.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, const {
      'projectId',
      'displayName',
      'applicationId',
      'versionName',
      'versionCode',
      'windowsExeName',
    }, 'identity');
    final identity = LibraryIdentity(
      projectId: _requiredText(json, 'projectId'),
      displayName: _requiredText(json, 'displayName'),
      applicationId: _requiredText(json, 'applicationId'),
      versionName: _requiredText(json, 'versionName'),
      versionCode: _int(json, 'versionCode'),
      windowsExeName: _requiredText(json, 'windowsExeName'),
    );
    if (!RegExp(r'^[a-z][a-z0-9_]{1,39}$').hasMatch(identity.projectId)) {
      throw const LibraryConfigException('projectId 必须是 2-40 位安全 slug');
    }
    if (_isWindowsReservedName(identity.projectId)) {
      throw const LibraryConfigException('projectId 不能使用系统保留名');
    }
    if (!_validDisplayText(identity.displayName, allowEmpty: false)) {
      throw const LibraryConfigException('displayName 必须是 1-80 个字符');
    }
    if (identity.applicationId.length > 127 ||
        !RegExp(
          r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,7}$',
        ).hasMatch(identity.applicationId)) {
      throw const LibraryConfigException('applicationId 格式无效');
    }
    if (!RegExp(
      r'^\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?$',
    ).hasMatch(identity.versionName)) {
      throw const LibraryConfigException('versionName 格式无效');
    }
    final versionNumbers = identity.versionName
        .split(RegExp(r'[-+]'))
        .first
        .split('.')
        .map(int.parse);
    if (versionNumbers.any((value) => value > 65535)) {
      throw const LibraryConfigException('versionName 数字段不能大于 65535');
    }
    if (identity.versionCode < 1 || identity.versionCode > 0xFFFFFFFF) {
      throw const LibraryConfigException('versionCode 必须在 uint32 范围内');
    }
    if (!RegExp(r'^[a-z][a-z0-9_-]{1,39}$').hasMatch(identity.windowsExeName)) {
      throw const LibraryConfigException('windowsExeName 必须是 2-40 位安全 slug');
    }
    if (_isWindowsReservedName(identity.windowsExeName)) {
      throw const LibraryConfigException('windowsExeName 不能使用系统保留名');
    }
    return identity;
  }

  final String projectId;
  final String displayName;
  final String applicationId;
  final String versionName;
  final int versionCode;
  final String windowsExeName;
}

enum LibraryThemeMode {
  system,
  light,
  dark;

  ThemeMode get material => switch (this) {
    system => ThemeMode.system,
    light => ThemeMode.light,
    dark => ThemeMode.dark,
  };
}

class LibraryBranding {
  const LibraryBranding({
    required this.seedColor,
    required this.officialUrl,
    required this.publisher,
    this.logoAsset = 'assets/runtime/logo.png',
    this.themeMode = LibraryThemeMode.system,
  });

  factory LibraryBranding.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, const {
      'seedColor',
      'officialUrl',
      'publisher',
      'logoAsset',
      'themeMode',
    }, 'branding');
    final rawMode = _text(json, 'themeMode');
    final mode = LibraryThemeMode.values.where(
      (value) => value.name == rawMode,
    );
    if (mode.isEmpty) {
      throw const LibraryConfigException('themeMode 必须是 system、light 或 dark');
    }
    final branding = LibraryBranding(
      seedColor: _parseColor(_requiredText(json, 'seedColor')),
      officialUrl: _text(json, 'officialUrl'),
      publisher: _text(json, 'publisher'),
      logoAsset: _logoAsset(json),
      themeMode: mode.first,
    );
    if (branding.officialUrl.isNotEmpty &&
        (branding.officialUrl.runes.length > 2048 ||
            !_validHttpsUrl(branding.officialUrl, restrictHost: false))) {
      throw const LibraryConfigException('officialUrl 必须是 HTTPS 地址');
    }
    if (!_validDisplayText(branding.publisher, allowEmpty: true)) {
      throw const LibraryConfigException('publisher 必须是 0-80 个字符');
    }
    return branding;
  }

  final Color seedColor;
  final String officialUrl;
  final String publisher;
  final String logoAsset;
  final LibraryThemeMode themeMode;
}

class LibrarySource {
  const LibrarySource({
    required this.sourceId,
    required this.title,
    required this.shareUrl,
    required this.password,
    required this.searchable,
    required this.recommended,
  });

  factory LibrarySource.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, const {
      'sourceId',
      'title',
      'shareUrl',
      'password',
      'searchable',
      'recommended',
    }, 'source');
    final source = LibrarySource(
      sourceId: _requiredText(json, 'sourceId'),
      title: _requiredText(json, 'title'),
      shareUrl: _requiredText(json, 'shareUrl'),
      password: _rawText(json, 'password'),
      searchable: _bool(json, 'searchable'),
      recommended: _bool(json, 'recommended'),
    );
    if (!RegExp(r'^[a-z][a-z0-9_-]{1,63}$').hasMatch(source.sourceId)) {
      throw const LibraryConfigException('sourceId 必须是 2-64 位安全 slug');
    }
    if (!_validDisplayText(source.title, allowEmpty: false)) {
      throw const LibraryConfigException('source.title 必须是 1-80 个字符');
    }
    if (source.shareUrl.runes.length > 2048 ||
        !_validHttpsUrl(source.shareUrl, restrictHost: true)) {
      throw const LibraryConfigException('source.shareUrl 必须是受信的蓝奏 HTTPS 地址');
    }
    if (source.password.runes.length > 64 ||
        source.password.contains(RegExp(r'[\r\n\x00]'))) {
      throw const LibraryConfigException('source.password 格式无效');
    }
    return source;
  }

  final String sourceId;
  final String title;
  final String shareUrl;
  final String password;
  final bool searchable;
  final bool recommended;

  Map<String, Object?> toCoreJson() => {
    'sourceId': sourceId,
    'title': title,
    'shareUrl': shareUrl,
    'password': password,
  };

  Map<String, Object?> toPublicJson() => {
    'sourceId': sourceId,
    'title': title,
    'shareUrl': shareUrl,
    'searchable': searchable,
    'recommended': recommended,
  };
}

class LibraryFeatures {
  const LibraryFeatures({
    required this.browse,
    required this.search,
    required this.download,
    required this.showDescription,
  });

  factory LibraryFeatures.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, const {
      'browse',
      'search',
      'download',
      'showDescription',
    }, 'features');
    return LibraryFeatures(
      browse: _bool(json, 'browse'),
      search: _bool(json, 'search'),
      download: _bool(json, 'download'),
      showDescription: _bool(json, 'showDescription'),
    );
  }

  final bool browse;
  final bool search;
  final bool download;
  final bool showDescription;
}

Map<String, Object?> _map(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw LibraryConfigException('$key 必须是对象');
  return value.cast<String, Object?>();
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map) throw LibraryConfigException('$label 必须是对象');
  return value.cast<String, Object?>();
}

List<Object?> _list(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) throw LibraryConfigException('$key 必须是数组');
  return value;
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value.toInt() != value) {
    throw LibraryConfigException('$key 必须是整数');
  }
  return value.toInt();
}

String _requiredText(Map<String, Object?> json, String key) {
  final value = _text(json, key);
  if (value.isEmpty) throw LibraryConfigException('$key 不能为空');
  return value;
}

String _text(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) throw LibraryConfigException('$key 为必填字段');
  final value = json[key];
  if (value is! String) throw LibraryConfigException('$key 必须是文本');
  return value.trim();
}

String _rawText(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) throw LibraryConfigException('$key 为必填字段');
  final value = json[key];
  if (value is! String) throw LibraryConfigException('$key 必须是文本');
  return value;
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw LibraryConfigException('$key 必须是布尔值');
  return value;
}

Color _parseColor(String value) {
  final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(value);
  if (match == null) {
    throw const LibraryConfigException('seedColor 必须是 #RRGGBB');
  }
  final hex = match.group(1)!;
  return Color(int.parse('FF$hex', radix: 16));
}

String _logoAsset(Map<String, Object?> json) {
  final value = _requiredText(json, 'logoAsset');
  if (value != 'assets/runtime/logo.png') {
    throw const LibraryConfigException('logoAsset 必须是 assets/runtime/logo.png');
  }
  return value;
}

bool _validDisplayText(String value, {required bool allowEmpty}) {
  if ((!allowEmpty && value.isEmpty) || value.runes.length > 80) return false;
  return !value.contains(RegExp(r'[\r\n\x00-\x1F\x7F]'));
}

bool _isWindowsReservedName(String value) => RegExp(
  r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$',
  caseSensitive: false,
).hasMatch(value);

bool _validHttpsUrl(String value, {required bool restrictHost}) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      _hasExplicitAuthorityPort(value)) {
    return false;
  }
  if (!restrictHost) return true;
  return _isTrustedLanzouHost(uri.host);
}

bool _hasExplicitAuthorityPort(String value) {
  final schemeEnd = value.indexOf('://');
  if (schemeEnd < 0) return true;
  final authorityStart = schemeEnd + 3;
  var authorityEnd = value.length;
  for (final delimiter in const ['/', '?', '#']) {
    final index = value.indexOf(delimiter, authorityStart);
    if (index >= 0 && index < authorityEnd) authorityEnd = index;
  }
  final authority = value.substring(authorityStart, authorityEnd);
  return authority.isEmpty ||
      authority.startsWith('[') ||
      authority.contains(':');
}

const _trustedLanzouDomains = {'lanzouw.com', 'lanzoui.com'};

bool _isTrustedLanzouHost(String host) {
  final normalized = host.toLowerCase();
  if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(normalized) ||
      normalized.startsWith('.') ||
      normalized.endsWith('.') ||
      normalized.contains('..')) {
    return false;
  }
  return _trustedLanzouDomains.any(
    (domain) => normalized == domain || normalized.endsWith('.$domain'),
  );
}

void _expectExactKeys(
  Map<String, Object?> json,
  Set<String> expected,
  String label,
) {
  if (json.length != expected.length ||
      !json.keys.toSet().containsAll(expected)) {
    throw LibraryConfigException('$label 必须严格使用 v1 canonical 字段');
  }
}

void _expectKeys(
  Map<String, Object?> json,
  Set<String> required,
  String label, {
  Set<String> optional = const {},
}) {
  final allowed = {...required, ...optional};
  if (!json.keys.toSet().containsAll(required) ||
      json.keys.any((key) => !allowed.contains(key))) {
    throw LibraryConfigException('$label 必须严格使用 v1 canonical 字段');
  }
}
