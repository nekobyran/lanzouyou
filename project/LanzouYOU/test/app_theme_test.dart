import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/shared/app_theme.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'Windows text uses Segoe UI with a Simplified Chinese fallback chain',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final body = AppTheme.light().textTheme.bodyMedium!;

      expect(body.fontFamily, 'Segoe UI');
      expect(body.fontFamilyFallback, const <String>[
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'Segoe UI Symbol',
      ]);
    },
  );

  test('Android keeps its platform typography instead of Windows fonts', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    final body = AppTheme.light().textTheme.bodyMedium!;

    expect(body.fontFamily, isNot('Segoe UI'));
    expect(body.fontFamilyFallback, isNot(contains('Microsoft YaHei UI')));
  });
}
