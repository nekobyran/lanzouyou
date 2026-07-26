import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/shared/app_theme.dart';

void main() {
  test('uses Material 3 with Windows Chinese font fallbacks', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final theme = buildLibraryTheme(const Color(0xFF2563EB), Brightness.light);

    expect(theme.useMaterial3, isTrue);
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback, <String>[
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Segoe UI Symbol',
    ]);
    expect(theme.searchBarTheme.elevation?.resolve({}), 0);
    expect(
      theme.filledButtonTheme.style?.minimumSize?.resolve({}),
      const Size(48, 48),
    );
  });

  test('keeps the Android platform font without Windows fallbacks', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final theme = buildLibraryTheme(const Color(0xFF2563EB), Brightness.light);

    expect(theme.textTheme.bodyMedium?.fontFamily, 'Roboto');
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback, isNull);
  });
}
