import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/services/app_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory supportDirectory;
  late FileAppSettingsStore store;

  setUp(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'lanzouyou-settings-',
    );
    store = FileAppSettingsStore(
      supportDirectoryProvider: () async => supportDirectory,
    );
  });

  tearDown(() async {
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
    await Future<void>.delayed(Duration.zero);
  });

  test('settings round-trip at the durable data/settings path', () async {
    const settings = AppSettings(
      themeMode: ThemeMode.dark,
      reduceMotion: true,
      linkOpenPreference: LanzouLinkOpenPreference.parse,
      showSourceLinks: true,
      searchViewCreationRate: 150,
    );

    await store.write(settings);

    final file = await store.file;
    expect(
      file.path,
      endsWith(
        <String>['data', 'settings', 'app.json'].join(Platform.pathSeparator),
      ),
    );
    expect(await store.read(), settings);
    expect(jsonDecode(await file.readAsString()), <String, Object>{
      'schemaVersion': 2,
      'themeMode': 'dark',
      'reduceMotion': true,
      'linkOpenPreference': 'parse',
      'showSourceLinks': true,
      'searchViewCreationRate': 150,
    });
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    expect(File('${file.path}.bak').existsSync(), isFalse);
  });

  test('atomic replacement leaves one complete latest document', () async {
    await store.write(const AppSettings(themeMode: ThemeMode.light));
    await store.write(
      const AppSettings(themeMode: ThemeMode.dark, reduceMotion: true),
    );

    final file = await store.file;
    final decoded = jsonDecode(await file.readAsString());
    expect(
      AppSettings.fromJson(decoded),
      const AppSettings(themeMode: ThemeMode.dark, reduceMotion: true),
    );
    expect(await file.parent.list().length, 1);
  });

  test('unknown, future, and malformed schemas recover to defaults', () async {
    final file = await store.file;
    await file.parent.create(recursive: true);
    final invalidDocuments = <String>[
      '{',
      jsonEncode(<String, Object>{
        'schemaVersion': 3,
        'themeMode': 'dark',
        'reduceMotion': true,
      }),
      jsonEncode(<String, Object>{
        'schemaVersion': 2,
        'themeMode': 'dark',
        'reduceMotion': true,
        'linkOpenPreference': 'ask',
        'showSourceLinks': false,
        'searchViewCreationRate': 100,
        'unknown': false,
      }),
      jsonEncode(<String, Object>{
        'schemaVersion': 2,
        'themeMode': 'blue',
        'reduceMotion': 'yes',
        'linkOpenPreference': 'auto',
        'showSourceLinks': false,
        'searchViewCreationRate': 0,
      }),
    ];

    for (final document in invalidDocuments) {
      await file.writeAsString(document, flush: true);
      expect(await store.read(), const AppSettings());
    }
  });
}
