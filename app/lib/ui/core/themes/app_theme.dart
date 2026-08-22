import 'package:flutter/material.dart';

import 'package:app/ui/core/themes/app_colors.dart';
import 'package:app/ui/core/themes/app_font_family.dart';
import 'package:app/ui/core/themes/app_typography.dart';
/// Builds the [ThemeData] for a given [AppColors] / [AppTypography] pair.
///
/// Wires the semantic tokens into both the standard Material [ColorScheme]
/// (so framework widgets — dialogs, switches, progress indicators, text
/// fields — render correctly per brightness) AND attaches [AppColors] /
/// [AppTypography] as theme extensions (so app widgets read
/// `context.colors.*` / `context.typo.*`).
ThemeData _buildTheme({
  required Brightness brightness,
  required AppColors colors,
  required AppTypography typo,
}) {
  final monoFontFamily = typo.mono.fontFamily ?? kMonoFamily;
  return ThemeData(
    brightness: brightness,
    fontFamily: monoFontFamily,
    scaffoldBackgroundColor: colors.bg,
    colorScheme: ColorScheme(
      brightness: brightness,
      surface: colors.bg,
      onSurface: colors.text,
      primary: colors.accent,
      onPrimary: colors.onAccent,
      secondary: colors.muted,
      onSecondary: colors.text,
      error: colors.error,
      onError: colors.onAccent,
      outline: colors.border,
    ),
    dividerColor: colors.border,
    extensions: <ThemeExtension<dynamic>>[colors, typo],
    appBarTheme: AppBarTheme(
      backgroundColor: colors.bg,
      foregroundColor: colors.text,
      elevation: 0,
      titleTextStyle: typo.mono.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: colors.text,
        letterSpacing: -0.2,
      ),
    ),
    textTheme: TextTheme(
      bodyLarge: typo.mono.copyWith(fontSize: 14, color: colors.text),
      bodyMedium: typo.mono.copyWith(fontSize: 13, color: colors.text),
      bodySmall: typo.monoSmall.copyWith(fontSize: 11, color: colors.muted),
      headlineLarge: typo.mono.copyWith(
        fontSize: 16.5,
        fontWeight: FontWeight.w700,
        color: colors.text,
        letterSpacing: -0.2,
      ),
      headlineMedium: typo.mono.copyWith(
        fontSize: 15.0,
        fontWeight: FontWeight.w700,
        color: colors.text,
        letterSpacing: -0.2,
      ),
      headlineSmall: typo.mono.copyWith(
        fontSize: 14.0,
        fontWeight: FontWeight.w700,
        color: colors.text,
      ),
      titleLarge: typo.mono.copyWith(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: colors.text,
      ),
      titleMedium: typo.mono.copyWith(
        fontSize: 13.0,
        fontWeight: FontWeight.w600,
        color: colors.text,
      ),
      titleSmall: typo.mono.copyWith(
        fontSize: 12.0,
        fontWeight: FontWeight.w600,
        color: colors.muted,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.inputFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(19),
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(19),
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(19),
        borderSide: BorderSide(color: colors.accent, width: 1.2),
      ),
      hintStyle: TextStyle(
        color: colors.muted,
        fontFamily: monoFontFamily,
        fontSize: 13,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    ),
  );
}

/// Dark theme — the app's original look.
ThemeData buildDarkTheme({AppFontFamily fontFamily = AppFontFamily.system}) =>
    _buildTheme(
      brightness: Brightness.dark,
      colors: AppColors.dark,
      typo: AppTypography.dark(fontFamily: fontFamily),
    );

/// Light theme — derived palette (tune hexes in `app_colors.dart`).
ThemeData buildLightTheme({AppFontFamily fontFamily = AppFontFamily.system}) =>
    _buildTheme(
      brightness: Brightness.light,
      colors: AppColors.light,
      typo: AppTypography.light(fontFamily: fontFamily),
    );
