import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const windowsFontFallback = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Segoe UI Symbol',
];

ThemeData buildLibraryTheme(Color seedColor, Brightness brightness) {
  final platform = defaultTargetPlatform;
  final colors = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    brightness: brightness,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    fontFamily: platform == TargetPlatform.windows ? 'Segoe UI' : null,
  );
  const minimumInteractiveSize = Size(48, 48);
  return base.copyWith(
    scaffoldBackgroundColor: colors.surface,
    textTheme: platform == TargetPlatform.windows
        ? _withWindowsFallback(base.textTheme)
        : base.textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 64,
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant, space: 1),
    listTileTheme: ListTileThemeData(
      minTileHeight: 56,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      selectedColor: colors.onSecondaryContainer,
      selectedTileColor: colors.secondaryContainer,
      shape: const RoundedRectangleBorder(),
    ),
    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: colors.surfaceContainerLow,
      indicatorColor: colors.secondaryContainer,
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerHigh),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return colors.onSurface.withValues(alpha: 0.10);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return colors.onSurface.withValues(alpha: 0.07);
        }
        return null;
      }),
      side: const WidgetStatePropertyAll(BorderSide.none),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      constraints: const BoxConstraints(minHeight: 56),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: minimumInteractiveSize),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: minimumInteractiveSize),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: minimumInteractiveSize),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: minimumInteractiveSize),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.primary,
      linearTrackColor: colors.surfaceContainerHighest,
    ),
    focusColor: colors.secondaryContainer,
    hoverColor: colors.onSurface.withValues(alpha: 0.06),
    splashColor: colors.onSurface.withValues(alpha: 0.10),
  );
}

TextTheme _withWindowsFallback(TextTheme textTheme) {
  TextStyle? style(TextStyle? value) =>
      value?.copyWith(fontFamilyFallback: windowsFontFallback);
  return textTheme.copyWith(
    displayLarge: style(textTheme.displayLarge),
    displayMedium: style(textTheme.displayMedium),
    displaySmall: style(textTheme.displaySmall),
    headlineLarge: style(textTheme.headlineLarge),
    headlineMedium: style(textTheme.headlineMedium),
    headlineSmall: style(textTheme.headlineSmall),
    titleLarge: style(textTheme.titleLarge),
    titleMedium: style(textTheme.titleMedium),
    titleSmall: style(textTheme.titleSmall),
    bodyLarge: style(textTheme.bodyLarge),
    bodyMedium: style(textTheme.bodyMedium),
    bodySmall: style(textTheme.bodySmall),
    labelLarge: style(textTheme.labelLarge),
    labelMedium: style(textTheme.labelMedium),
    labelSmall: style(textTheme.labelSmall),
  );
}
