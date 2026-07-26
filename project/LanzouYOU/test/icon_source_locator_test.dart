import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/services/icon_source_locator.dart';

void main() {
  late Directory directory;
  const locator = IconSourceLocator();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lanzouyou_icon_test_');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('finds a same-name supported sidecar image', () async {
    final source = File(
      '${directory.path}${Platform.pathSeparator}archive.exe',
    );
    final icon = File('${directory.path}${Platform.pathSeparator}archive.png');
    await source.writeAsBytes(const <int>[1, 2, 3]);
    await icon.writeAsBytes(const <int>[4, 5, 6]);

    expect(await locator.findSidecar(source.path), icon.path);
  });

  test('does not treat an unrelated file as an icon override', () async {
    final source = File(
      '${directory.path}${Platform.pathSeparator}archive.apk',
    );
    final unrelated = File(
      '${directory.path}${Platform.pathSeparator}other.png',
    );
    await source.writeAsBytes(const <int>[1]);
    await unrelated.writeAsBytes(const <int>[2]);

    expect(await locator.findSidecar(source.path), isNull);
  });
}
