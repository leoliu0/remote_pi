import 'package:flutter/material.dart';

import 'package:app/ui/core/themes/app_colors.dart';
import 'package:app/ui/core/themes/app_typography.dart';

/// Ergonomic access to the app's themed tokens from any widget.
///
/// ```dart
/// Container(color: context.colors.surface);
/// Text('hi', style: context.typo.mono.copyWith(color: context.colors.accent));
/// ```
///
/// The [AppColors] / [AppTypography] extensions are installed on the active
/// [ThemeData] by `buildDarkTheme()` / `buildLightTheme()`. If a widget is
/// ever built outside that tree (e.g. a widget test that pumps a bare
/// `MaterialApp` with no theme), the getters fall back to the dark palette —
/// the app's default look — rather than throwing.
extension AppThemeX on BuildContext {
  /// Semantic color tokens for the active theme.
  AppColors get colors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.dark;

  /// Typographic styles for the active theme.
  AppTypography get typo =>
      Theme.of(this).extension<AppTypography>() ?? AppTypography.defaultDark;
}
