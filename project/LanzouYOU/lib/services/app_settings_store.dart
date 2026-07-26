import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

typedef AppSupportDirectoryProvider = Future<Directory> Function();

enum LanzouLinkOpenPreference { ask, parse, browser }

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.reduceMotion = false,
    this.linkOpenPreference = LanzouLinkOpenPreference.ask,
    this.showSourceLinks = false,
    this.searchViewCreationRate = 100,
  });

  static const schemaVersion = 2;

  final ThemeMode themeMode;
  final bool reduceMotion;
  final LanzouLinkOpenPreference linkOpenPreference;
  final bool showSourceLinks;
  final int searchViewCreationRate;

  Map<String, Object> toJson() => <String, Object>{
    'schemaVersion': schemaVersion,
    'themeMode': themeMode.name,
    'reduceMotion': reduceMotion,
    'linkOpenPreference': linkOpenPreference.name,
    'showSourceLinks': showSourceLinks,
    'searchViewCreationRate': searchViewCreationRate,
  };

  factory AppSettings.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('设置文件结构无效');
    }
    final version = value['schemaVersion'];
    final currentKeys = const {
      'schemaVersion',
      'themeMode',
      'reduceMotion',
      'linkOpenPreference',
      'showSourceLinks',
      'searchViewCreationRate',
    };
    if (version != schemaVersion ||
        value.length != currentKeys.length ||
        !value.keys.toSet().containsAll(currentKeys)) {
      throw const FormatException('设置文件版本无效');
    }
    final rate = value['searchViewCreationRate'];
    if (rate is! int || rate < 1 || rate > 500) {
      throw const FormatException('搜索视图创建速度无效');
    }
    return AppSettings(
      themeMode: _parseThemeMode(value['themeMode']),
      reduceMotion: _parseBool(value['reduceMotion'], '减少动效'),
      linkOpenPreference: switch (value['linkOpenPreference']) {
        'ask' => LanzouLinkOpenPreference.ask,
        'parse' => LanzouLinkOpenPreference.parse,
        'browser' => LanzouLinkOpenPreference.browser,
        _ => throw const FormatException('链接打开方式无效'),
      },
      showSourceLinks: _parseBool(value['showSourceLinks'], '来源链接显示'),
      searchViewCreationRate: rate,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.reduceMotion == reduceMotion &&
      other.linkOpenPreference == linkOpenPreference &&
      other.showSourceLinks == showSourceLinks &&
      other.searchViewCreationRate == searchViewCreationRate;

  @override
  int get hashCode => Object.hash(
    themeMode,
    reduceMotion,
    linkOpenPreference,
    showSourceLinks,
    searchViewCreationRate,
  );
}

ThemeMode _parseThemeMode(Object? value) => switch (value) {
  'system' => ThemeMode.system,
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => throw const FormatException('主题设置无效'),
};

bool _parseBool(Object? value, String label) {
  if (value is! bool) throw FormatException('$label设置无效');
  return value;
}

abstract interface class AppSettingsStore {
  Future<AppSettings> read();

  Future<void> write(AppSettings settings);
}

/// Stores durable user settings below the platform application-support root.
///
/// The concrete path is `<support>/data/settings/app.json`. Writes are flushed
/// to a sibling temporary file before the final rename, so an interrupted write
/// never exposes partially-written JSON.
class FileAppSettingsStore implements AppSettingsStore {
  FileAppSettingsStore({AppSupportDirectoryProvider? supportDirectoryProvider})
    : _supportDirectoryProvider =
          supportDirectoryProvider ?? getApplicationSupportDirectory;

  final AppSupportDirectoryProvider _supportDirectoryProvider;

  Future<File> get file async {
    final root = await _supportDirectoryProvider();
    return File(
      '${root.path}${Platform.pathSeparator}data${Platform.pathSeparator}'
      'settings${Platform.pathSeparator}app.json',
    );
  }

  @override
  Future<AppSettings> read() async {
    try {
      final target = await file;
      if (!await target.exists()) return const AppSettings();
      final decoded = jsonDecode(await target.readAsString());
      return AppSettings.fromJson(decoded);
    } on Object {
      // A missing, truncated, future-version, or otherwise malformed file must
      // not prevent the app from starting. Defaults are the safe recovery path.
      return const AppSettings();
    }
  }

  @override
  Future<void> write(AppSettings settings) async {
    final target = await file;
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    await temporary.writeAsString(
      '${jsonEncode(settings.toJson())}\n',
      flush: true,
    );

    try {
      await temporary.rename(target.path);
      if (await backup.exists()) await backup.delete();
      return;
    } on FileSystemException {
      // Some Windows filesystems do not replace an existing destination during
      // rename. Keep the previous complete file as a rollback point there.
    }

    var movedOriginal = false;
    try {
      if (await backup.exists()) await backup.delete();
      if (await target.exists()) {
        await target.rename(backup.path);
        movedOriginal = true;
      }
      await temporary.rename(target.path);
      if (movedOriginal && await backup.exists()) await backup.delete();
    } on Object {
      if (!await target.exists() && movedOriginal && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
