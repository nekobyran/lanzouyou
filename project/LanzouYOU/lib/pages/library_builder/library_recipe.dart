import 'package:lanzou_library_shell/config/library_config.dart'
    show maxLibrarySourceCount;

import '../../models/cloud_item.dart';

enum LibraryTarget { android, windows }

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
    _expectExactKeys(json, 'identity', const {
      'projectId',
      'displayName',
      'applicationId',
      'versionName',
      'versionCode',
      'windowsExeName',
    });
    return LibraryIdentity(
      projectId: _requiredString(json, 'projectId'),
      displayName: _requiredString(json, 'displayName'),
      applicationId: _requiredString(json, 'applicationId'),
      versionName: _requiredString(json, 'versionName'),
      versionCode: _requiredInt(json, 'versionCode'),
      windowsExeName: _requiredString(json, 'windowsExeName'),
    );
  }

  final String projectId;
  final String displayName;
  final String applicationId;
  final String versionName;
  final int versionCode;
  final String windowsExeName;

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'displayName': displayName,
    'applicationId': applicationId,
    'versionName': versionName,
    'versionCode': versionCode,
    'windowsExeName': windowsExeName,
  };

  LibraryIdentity copyWith({
    String? projectId,
    String? displayName,
    String? applicationId,
    String? versionName,
    int? versionCode,
    String? windowsExeName,
  }) => LibraryIdentity(
    projectId: projectId ?? this.projectId,
    displayName: displayName ?? this.displayName,
    applicationId: applicationId ?? this.applicationId,
    versionName: versionName ?? this.versionName,
    versionCode: versionCode ?? this.versionCode,
    windowsExeName: windowsExeName ?? this.windowsExeName,
  );

  @override
  bool operator ==(Object other) =>
      other is LibraryIdentity &&
      projectId == other.projectId &&
      displayName == other.displayName &&
      applicationId == other.applicationId &&
      versionName == other.versionName &&
      versionCode == other.versionCode &&
      windowsExeName == other.windowsExeName;

  @override
  int get hashCode => Object.hash(
    projectId,
    displayName,
    applicationId,
    versionName,
    versionCode,
    windowsExeName,
  );
}

class LibraryBranding {
  const LibraryBranding({
    this.seedColor = '#2563EB',
    this.officialUrl = '',
    this.publisher = '',
    this.logoAsset = 'assets/runtime/logo.png',
    this.themeMode = 'system',
  });

  factory LibraryBranding.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, 'branding', const {
      'seedColor',
      'officialUrl',
      'publisher',
      'logoAsset',
      'themeMode',
    });
    return LibraryBranding(
      seedColor: _requiredString(json, 'seedColor'),
      officialUrl: _requiredString(json, 'officialUrl'),
      publisher: _requiredString(json, 'publisher'),
      logoAsset: _requiredString(json, 'logoAsset'),
      themeMode: _requiredString(json, 'themeMode'),
    );
  }

  final String seedColor;
  final String officialUrl;
  final String publisher;
  final String logoAsset;
  final String themeMode;

  Map<String, Object?> toJson() => {
    'seedColor': seedColor,
    'officialUrl': officialUrl,
    'publisher': publisher,
    'logoAsset': logoAsset,
    'themeMode': themeMode,
  };

  LibraryBranding copyWith({
    String? seedColor,
    String? officialUrl,
    String? publisher,
    String? logoAsset,
    String? themeMode,
  }) => LibraryBranding(
    seedColor: seedColor ?? this.seedColor,
    officialUrl: officialUrl ?? this.officialUrl,
    publisher: publisher ?? this.publisher,
    logoAsset: logoAsset ?? this.logoAsset,
    themeMode: themeMode ?? this.themeMode,
  );

  @override
  bool operator ==(Object other) =>
      other is LibraryBranding &&
      seedColor == other.seedColor &&
      officialUrl == other.officialUrl &&
      publisher == other.publisher &&
      logoAsset == other.logoAsset &&
      themeMode == other.themeMode;

  @override
  int get hashCode =>
      Object.hash(seedColor, officialUrl, publisher, logoAsset, themeMode);
}

class LibrarySourceRecipe {
  const LibrarySourceRecipe({
    required this.sourceId,
    required this.title,
    required this.shareUrl,
    this.password = '',
    this.searchable = true,
    this.recommended = true,
  });

  factory LibrarySourceRecipe.fromShareInfo(
    ShareInfo info, {
    String sourceId = 'source-1',
  }) => LibrarySourceRecipe(
    sourceId: sourceId,
    title: info.name.trim().isEmpty ? '软件库' : info.name.trim(),
    shareUrl: info.shareUrl.trim(),
    password: info.password,
  );

  factory LibrarySourceRecipe.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, 'source', const {
      'sourceId',
      'title',
      'shareUrl',
      'password',
      'searchable',
      'recommended',
    });
    return LibrarySourceRecipe(
      sourceId: _requiredString(json, 'sourceId'),
      title: _requiredString(json, 'title'),
      shareUrl: _requiredString(json, 'shareUrl'),
      password: _requiredString(json, 'password'),
      searchable: _requiredBool(json, 'searchable'),
      recommended: _requiredBool(json, 'recommended'),
    );
  }

  final String sourceId;
  final String title;
  final String shareUrl;
  final String password;
  final bool searchable;
  final bool recommended;

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'title': title,
    'shareUrl': shareUrl,
    'password': password,
    'searchable': searchable,
    'recommended': recommended,
  };

  Map<String, Object?> redactedJson() => {
    'sourceId': sourceId,
    'title': title,
    'shareUrl': shareUrl,
    'searchable': searchable,
    'recommended': recommended,
  };

  LibrarySourceRecipe copyWith({
    String? sourceId,
    String? title,
    String? shareUrl,
    String? password,
    bool? searchable,
    bool? recommended,
  }) => LibrarySourceRecipe(
    sourceId: sourceId ?? this.sourceId,
    title: title ?? this.title,
    shareUrl: shareUrl ?? this.shareUrl,
    password: password ?? this.password,
    searchable: searchable ?? this.searchable,
    recommended: recommended ?? this.recommended,
  );

  @override
  bool operator ==(Object other) =>
      other is LibrarySourceRecipe &&
      sourceId == other.sourceId &&
      title == other.title &&
      shareUrl == other.shareUrl &&
      password == other.password &&
      searchable == other.searchable &&
      recommended == other.recommended;

  @override
  int get hashCode =>
      Object.hash(sourceId, title, shareUrl, password, searchable, recommended);
}

class LibraryFeatures {
  const LibraryFeatures({
    this.browse = true,
    this.search = true,
    this.download = true,
    this.showDescription = true,
  });

  factory LibraryFeatures.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, 'features', const {
      'browse',
      'search',
      'download',
      'showDescription',
    });
    return LibraryFeatures(
      browse: _requiredBool(json, 'browse'),
      search: _requiredBool(json, 'search'),
      download: _requiredBool(json, 'download'),
      showDescription: _requiredBool(json, 'showDescription'),
    );
  }

  final bool browse;
  final bool search;
  final bool download;
  final bool showDescription;

  Map<String, Object?> toJson() => {
    'browse': browse,
    'search': search,
    'download': download,
    'showDescription': showDescription,
  };

  LibraryFeatures copyWith({
    bool? browse,
    bool? search,
    bool? download,
    bool? showDescription,
  }) => LibraryFeatures(
    browse: browse ?? this.browse,
    search: search ?? this.search,
    download: download ?? this.download,
    showDescription: showDescription ?? this.showDescription,
  );

  @override
  bool operator ==(Object other) =>
      other is LibraryFeatures &&
      browse == other.browse &&
      search == other.search &&
      download == other.download &&
      showDescription == other.showDescription;

  @override
  int get hashCode => Object.hash(browse, search, download, showDescription);
}

class LibraryBuildOptions {
  const LibraryBuildOptions({
    this.targets = const {LibraryTarget.android, LibraryTarget.windows},
    this.iconSourcePath = '',
  });

  factory LibraryBuildOptions.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, 'build', const {'targets', 'iconSourcePath'});
    final rawTargets = json['targets'];
    if (rawTargets is! List) {
      throw const FormatException('build.targets 必须是数组');
    }
    final targets = <LibraryTarget>{};
    for (final value in rawTargets) {
      final target = switch (value) {
        'android' => LibraryTarget.android,
        'windows' => LibraryTarget.windows,
        _ => throw const FormatException('build.targets 包含未支持的目标'),
      };
      if (!targets.add(target)) {
        throw const FormatException('build.targets 不能重复');
      }
    }
    return LibraryBuildOptions(
      targets: targets,
      iconSourcePath: _requiredString(json, 'iconSourcePath'),
    );
  }

  final Set<LibraryTarget> targets;
  final String iconSourcePath;

  Map<String, Object?> toJson() => {
    'targets': targets.map((target) => target.name).toList()..sort(),
    'iconSourcePath': iconSourcePath,
  };

  LibraryBuildOptions copyWith({
    Set<LibraryTarget>? targets,
    String? iconSourcePath,
  }) => LibraryBuildOptions(
    targets: targets ?? this.targets,
    iconSourcePath: iconSourcePath ?? this.iconSourcePath,
  );

  @override
  bool operator ==(Object other) =>
      other is LibraryBuildOptions &&
      _setEquals(targets, other.targets) &&
      iconSourcePath == other.iconSourcePath;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(targets.map((value) => value.index).toList()..sort()),
    iconSourcePath,
  );
}

class LibraryWorkspace {
  const LibraryWorkspace({
    this.rootFolderId = '',
    this.rootFolderName = '',
    this.rootShareUrl = '',
    this.imageFolderName = 'img1',
    this.textFolderName = 'txt1',
    this.libraryFolderName = 'rjk',
    this.webFolderName = 'url',
    this.pageSize = 50,
  });

  factory LibraryWorkspace.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, 'workspace', const {
      'rootFolderId',
      'rootFolderName',
      'rootShareUrl',
      'imageFolderName',
      'textFolderName',
      'libraryFolderName',
      'webFolderName',
      'pageSize',
    });
    return LibraryWorkspace(
      rootFolderId: _requiredString(json, 'rootFolderId'),
      rootFolderName: _requiredString(json, 'rootFolderName'),
      rootShareUrl: _requiredString(json, 'rootShareUrl'),
      imageFolderName: _requiredString(json, 'imageFolderName'),
      textFolderName: _requiredString(json, 'textFolderName'),
      libraryFolderName: _requiredString(json, 'libraryFolderName'),
      webFolderName: _requiredString(json, 'webFolderName'),
      pageSize: _requiredInt(json, 'pageSize'),
    );
  }

  final String rootFolderId;
  final String rootFolderName;
  final String rootShareUrl;
  final String imageFolderName;
  final String textFolderName;
  final String libraryFolderName;
  final String webFolderName;
  final int pageSize;

  Map<String, Object?> toJson() => {
    'rootFolderId': rootFolderId,
    'rootFolderName': rootFolderName,
    'rootShareUrl': rootShareUrl,
    'imageFolderName': imageFolderName,
    'textFolderName': textFolderName,
    'libraryFolderName': libraryFolderName,
    'webFolderName': webFolderName,
    'pageSize': pageSize,
  };
}

class LibraryWebPageRecipe {
  const LibraryWebPageRecipe({
    required this.name,
    required this.url,
    this.icon = '',
  });

  factory LibraryWebPageRecipe.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, 'home.webPages[]', const {'name', 'url', 'icon'});
    return LibraryWebPageRecipe(
      name: _requiredString(json, 'name'),
      url: _requiredString(json, 'url'),
      icon: _requiredString(json, 'icon'),
    );
  }

  final String name;
  final String url;
  final String icon;

  Map<String, Object?> toJson() => {'name': name, 'url': url, 'icon': icon};
}

class LibraryHomeContent {
  const LibraryHomeContent({
    this.visible = true,
    this.splashImage = '',
    this.splashText = '',
    this.carouselImages = const <String>[],
    this.announcementUrl = '',
    this.webPages = const <LibraryWebPageRecipe>[],
  });

  factory LibraryHomeContent.fromJson(Map<String, Object?> json) {
    _expectExactKeys(json, 'home', const {
      'visible',
      'splashImage',
      'splashText',
      'carouselImages',
      'announcementUrl',
      'webPages',
    });
    final images = json['carouselImages'];
    final pages = json['webPages'];
    return LibraryHomeContent(
      visible: _requiredBool(json, 'visible'),
      splashImage: _requiredString(json, 'splashImage'),
      splashText: _requiredString(json, 'splashText'),
      carouselImages: images is List
          ? images.map((value) => '$value'.trim()).toList(growable: false)
          : throw const FormatException('carouselImages 必须是数组'),
      announcementUrl: _requiredString(json, 'announcementUrl'),
      webPages: pages is List
          ? pages
                .map(
                  (value) => LibraryWebPageRecipe.fromJson(
                    _requiredMapValue(value, 'home.webPages[]'),
                  ),
                )
                .toList(growable: false)
          : throw const FormatException('webPages 必须是数组'),
    );
  }

  final bool visible;
  final String splashImage;
  final String splashText;
  final List<String> carouselImages;
  final String announcementUrl;
  final List<LibraryWebPageRecipe> webPages;

  Map<String, Object?> toJson() => {
    'visible': visible,
    'splashImage': splashImage,
    'splashText': splashText,
    'carouselImages': carouselImages,
    'announcementUrl': announcementUrl,
    'webPages': webPages.map((value) => value.toJson()).toList(),
  };

  LibraryHomeContent copyWith({
    bool? visible,
    String? splashImage,
    String? splashText,
    List<String>? carouselImages,
    String? announcementUrl,
    List<LibraryWebPageRecipe>? webPages,
  }) => LibraryHomeContent(
    visible: visible ?? this.visible,
    splashImage: splashImage ?? this.splashImage,
    splashText: splashText ?? this.splashText,
    carouselImages: List.unmodifiable(carouselImages ?? this.carouselImages),
    announcementUrl: announcementUrl ?? this.announcementUrl,
    webPages: List.unmodifiable(webPages ?? this.webPages),
  );
}

class LibraryBuildRecipe {
  const LibraryBuildRecipe({
    required this.schemaVersion,
    required this.identity,
    required this.branding,
    this.workspace = const LibraryWorkspace(),
    this.home = const LibraryHomeContent(),
    required this.sources,
    required this.features,
    required this.build,
  });

  factory LibraryBuildRecipe.fromShareInfo(ShareInfo info) {
    final projectId = suggestProjectId(info.name);
    return LibraryBuildRecipe(
      schemaVersion: 1,
      identity: LibraryIdentity(
        projectId: projectId,
        displayName: info.name.trim().isEmpty ? '我的软件库' : info.name.trim(),
        applicationId: suggestApplicationId(projectId),
        versionName: '1.0.0',
        versionCode: 1,
        windowsExeName: projectId.replaceAll('_', '-'),
      ),
      branding: const LibraryBranding(),
      workspace: LibraryWorkspace(
        rootFolderId: info.id,
        rootFolderName: info.name,
        rootShareUrl: info.shareUrl,
      ),
      home: const LibraryHomeContent(),
      sources: [LibrarySourceRecipe.fromShareInfo(info)],
      features: const LibraryFeatures(),
      build: const LibraryBuildOptions(),
    );
  }

  /// Starts a real editable project without inventing a cloud source.
  ///
  /// A source is intentionally required by [validate] before save or build, so
  /// the top-level entry cannot silently package placeholder or example data.
  factory LibraryBuildRecipe.newProject() => const LibraryBuildRecipe(
    schemaVersion: 1,
    identity: LibraryIdentity(
      projectId: 'my_library',
      displayName: '我的软件库',
      applicationId: 'cc.nkbr.my_library',
      versionName: '1.0.0',
      versionCode: 1,
      windowsExeName: 'my-library',
    ),
    branding: LibraryBranding(),
    workspace: LibraryWorkspace(),
    home: LibraryHomeContent(),
    sources: <LibrarySourceRecipe>[],
    features: LibraryFeatures(),
    build: LibraryBuildOptions(),
  );

  factory LibraryBuildRecipe.fromJson(Map<String, Object?> json) {
    const legacyKeys = {
      'schemaVersion',
      'identity',
      'branding',
      'sources',
      'features',
      'build',
    };
    const currentKeys = {...legacyKeys, 'workspace', 'home'};
    if (json.keys.toSet().difference(currentKeys).isNotEmpty ||
        (!json.keys.toSet().containsAll(legacyKeys)) ||
        (json.length != legacyKeys.length &&
            json.length != currentKeys.length)) {
      throw const FormatException('recipe 字段与 v1 契约不一致');
    }
    final identity = _jsonMap(json['identity']);
    final branding = _jsonMap(json['branding']);
    final workspace = json.containsKey('workspace')
        ? _jsonMap(json['workspace'])
        : const <String, Object?>{};
    final home = json.containsKey('home')
        ? _jsonMap(json['home'])
        : const <String, Object?>{};
    final features = _jsonMap(json['features']);
    final build = _jsonMap(json['build']);
    final rawSources = json['sources'];
    return LibraryBuildRecipe(
      schemaVersion: _requiredInt(json, 'schemaVersion'),
      identity: LibraryIdentity.fromJson(identity),
      branding: LibraryBranding.fromJson(branding),
      workspace: workspace.isEmpty
          ? const LibraryWorkspace()
          : LibraryWorkspace.fromJson(workspace),
      home: home.isEmpty
          ? const LibraryHomeContent()
          : LibraryHomeContent.fromJson(home),
      sources: rawSources is List
          ? rawSources
                .map(
                  (value) => LibrarySourceRecipe.fromJson(
                    _requiredMapValue(value, 'sources[]'),
                  ),
                )
                .toList(growable: false)
          : throw const FormatException('sources 必须是数组'),
      features: LibraryFeatures.fromJson(features),
      build: LibraryBuildOptions.fromJson(build),
    );
  }

  final int schemaVersion;
  final LibraryIdentity identity;
  final LibraryBranding branding;
  final LibraryWorkspace workspace;
  final LibraryHomeContent home;
  final List<LibrarySourceRecipe> sources;
  final LibraryFeatures features;
  final LibraryBuildOptions build;

  bool get hasEmbeddedPasswords =>
      sources.any((source) => source.password.trim().isNotEmpty);

  Map<String, Object?> runtimeJson() => {
    'schemaVersion': schemaVersion,
    'identity': identity.toJson(),
    'branding': branding.toJson(),
    'home': home.toJson(),
    'sources': sources.map((source) => source.toJson()).toList(),
    'features': features.toJson(),
  };

  Map<String, Object?> toJson() => {
    ...runtimeJson(),
    'workspace': workspace.toJson(),
    'build': build.toJson(),
  };

  Map<String, Object?> redactedJson() => {
    'schemaVersion': schemaVersion,
    'identity': identity.toJson(),
    'branding': branding.toJson(),
    'workspace': workspace.toJson(),
    'home': home.toJson(),
    'sources': sources.map((source) => source.redactedJson()).toList(),
    'features': features.toJson(),
    'build': build.copyWith(iconSourcePath: '').toJson(),
  };

  List<String> validate() {
    final errors = <String>[];
    if (schemaVersion != 1) errors.add('仅支持 schemaVersion 1');
    if (!RegExp(r'^[a-z][a-z0-9_]{1,39}$').hasMatch(identity.projectId) ||
        _isWindowsReservedName(identity.projectId)) {
      errors.add('项目 ID 必须为 2-40 位小写字母、数字或下划线');
    }
    if (identity.displayName.trim().isEmpty ||
        identity.displayName.runes.length > 80 ||
        identity.displayName.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      errors.add('应用名称必须为 1-80 个字符');
    }
    if (!RegExp(
          r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,7}$',
        ).hasMatch(identity.applicationId) ||
        identity.applicationId.length > 127) {
      errors.add('应用 ID 格式无效');
    }
    if (!RegExp(
          r'^\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?$',
        ).hasMatch(identity.versionName) ||
        !_versionSegmentsFitUint16(identity.versionName)) {
      errors.add('版本号格式无效');
    }
    if (identity.versionCode < 1 || identity.versionCode > 0xFFFFFFFF) {
      errors.add('版本码必须为 1-4294967295');
    }
    if (!RegExp(r'^[a-z][a-z0-9_-]{1,39}$').hasMatch(identity.windowsExeName) ||
        _isWindowsReservedName(identity.windowsExeName)) {
      errors.add('Windows exe 名必须为 2-40 位安全 slug');
    }
    if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(branding.seedColor)) {
      errors.add('主题色必须是 #RRGGBB');
    }
    if (branding.logoAsset != 'assets/runtime/logo.png') {
      errors.add('图标资源必须使用固定的 assets/runtime/logo.png');
    }
    if (!const {'system', 'light', 'dark'}.contains(branding.themeMode)) {
      errors.add('主题模式仅支持 system、light 或 dark');
    }
    if (branding.officialUrl.isNotEmpty &&
        (branding.officialUrl.runes.length > 2048 ||
            !_validHttpsUrl(branding.officialUrl, restrictHost: false))) {
      errors.add('官网必须是 HTTPS 地址');
    }
    if (branding.publisher.runes.length > 80 ||
        branding.publisher.contains(RegExp(r'[\r\n\x00]'))) {
      errors.add('发布者必须为 0-80 个字符');
    }
    if (workspace.pageSize != 50) errors.add('云端分区单页上限必须为 50');
    if (home.splashText.runes.length > 2000) errors.add('开始文本不能超过 2000 个字符');
    for (final url in [
      home.splashImage,
      home.announcementUrl,
      ...home.carouselImages,
      ...home.webPages.expand((page) => [page.url, page.icon]),
    ]) {
      if (url.isNotEmpty && !_validHttpsUrl(url, restrictHost: false)) {
        errors.add('主页远程资源必须使用 HTTPS 地址');
        break;
      }
    }
    if (sources.isEmpty || sources.length > maxLibrarySourceCount) {
      errors.add('软件库来源必须为 1-$maxLibrarySourceCount 个');
    }
    final sourceIds = <String>{};
    for (final source in sources) {
      if (!RegExp(r'^[a-z][a-z0-9_-]{1,63}$').hasMatch(source.sourceId)) {
        errors.add('来源 ID ${source.sourceId} 格式无效');
      } else if (!sourceIds.add(source.sourceId)) {
        errors.add('来源 ID ${source.sourceId} 重复');
      }
      if (source.title.trim().isEmpty ||
          source.title.runes.length > 80 ||
          source.title.contains(RegExp(r'[\r\n\x00]'))) {
        errors.add('来源标题必须为 1-80 个字符');
      }
      if (source.shareUrl.runes.length > 2048 ||
          !_validHttpsUrl(source.shareUrl, restrictHost: true)) {
        errors.add('来源 ${source.title} 不是受信的蓝奏 HTTPS 地址');
      }
      if (source.password.runes.length > 64 ||
          source.password.contains(RegExp(r'[\r\n\x00]'))) {
        errors.add('来源 ${source.title} 的访问码无效');
      }
    }
    if (build.targets.isEmpty) errors.add('至少选择一个生成目标');
    return errors;
  }

  LibraryBuildRecipe copyWith({
    int? schemaVersion,
    LibraryIdentity? identity,
    LibraryBranding? branding,
    LibraryWorkspace? workspace,
    LibraryHomeContent? home,
    List<LibrarySourceRecipe>? sources,
    LibraryFeatures? features,
    LibraryBuildOptions? build,
  }) => LibraryBuildRecipe(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    identity: identity ?? this.identity,
    branding: branding ?? this.branding,
    workspace: workspace ?? this.workspace,
    home: home ?? this.home,
    sources: List.unmodifiable(sources ?? this.sources),
    features: features ?? this.features,
    build: build ?? this.build,
  );

  @override
  bool operator ==(Object other) =>
      other is LibraryBuildRecipe &&
      schemaVersion == other.schemaVersion &&
      identity == other.identity &&
      branding == other.branding &&
      workspace.toJson().toString() == other.workspace.toJson().toString() &&
      home.toJson().toString() == other.home.toJson().toString() &&
      _listEquals(sources, other.sources) &&
      features == other.features &&
      build == other.build;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    identity,
    branding,
    workspace.toJson().toString(),
    home.toJson().toString(),
    Object.hashAll(sources),
    features,
    build,
  );
}

String suggestProjectId(String value) {
  final normalized = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final prefixed = normalized.isEmpty
      ? 'custom_library'
      : RegExp(r'^[a-z]').hasMatch(normalized)
      ? normalized
      : 'library_$normalized';
  var safeLength = prefixed.length < 2 ? '${prefixed}_library' : prefixed;
  if (_isWindowsReservedName(safeLength)) safeLength = '${safeLength}_library';
  return safeLength.length <= 40 ? safeLength : safeLength.substring(0, 40);
}

String suggestApplicationId(String projectId) {
  final segment = projectId.replaceAll('_', '');
  return 'cc.nkbr.${segment.isEmpty ? 'customlibrary' : segment}';
}

Map<String, Object?> _jsonMap(Object? value) =>
    _requiredMapValue(value, '配置字段');

Map<String, Object?> _requiredMapValue(Object? value, String label) {
  if (value is! Map) throw FormatException('$label 必须是对象');
  return value.cast<String, Object?>();
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key 必须是文本');
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite || value.toInt() != value) {
    throw FormatException('$key 必须是整数');
  }
  return value.toInt();
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key 必须是布尔值');
  return value;
}

void _expectExactKeys(
  Map<String, Object?> json,
  String label,
  Set<String> expected,
) {
  if (json.length != expected.length ||
      !json.keys.toSet().containsAll(expected)) {
    throw FormatException('$label 字段与 v1 契约不一致');
  }
}

bool _versionSegmentsFitUint16(String value) {
  final numeric = value.split(RegExp(r'[-+]')).first;
  return numeric.split('.').every((part) {
    final parsed = int.tryParse(part);
    return parsed != null && parsed <= 0xFFFF;
  });
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

bool _setEquals<T>(Set<T> first, Set<T> second) =>
    first.length == second.length && first.containsAll(second);

bool _listEquals<T>(List<T> first, List<T> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
