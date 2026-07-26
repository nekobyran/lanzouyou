import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const seed = Color(0xFF2563EB);
  static const windowsFontFamilyFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Segoe UI Symbol',
  ];

  static ThemeData light() => _theme(Brightness.light);

  static ThemeData dark() => _theme(Brightness.dark);

  static ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final fontFamilyFallback = defaultTargetPlatform == TargetPlatform.windows
        ? windowsFontFamilyFallback
        : null;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamilyFallback: fontFamilyFallback,
      scaffoldBackgroundColor: scheme.surface,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      focusColor: scheme.primary.withValues(alpha: 0.14),
      hoverColor: scheme.onSurface.withValues(alpha: 0.08),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
      ),
      navigationBarTheme: const NavigationBarThemeData(height: 72),
      navigationRailTheme: const NavigationRailThemeData(
        minWidth: 80,
        minExtendedWidth: 232,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      listTileTheme: const ListTileThemeData(
        minTileHeight: 56,
        contentPadding: EdgeInsets.symmetric(horizontal: 20),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: WidgetStateProperty.resolveWith(
          (states) => defaultTargetPlatform == TargetPlatform.windows
              ? states.contains(WidgetState.hovered)
              : null,
        ),
      ),
      visualDensity: VisualDensity.standard,
    );
  }
}
