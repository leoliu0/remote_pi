import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:app/ui/core/themes/app_colors.dart';
import 'package:app/ui/core/themes/app_font_family.dart';
/// Monospace font family — used for code, terminal-style chrome, and most of
/// the app's UI text (the product's "coding agent" identity).
///
/// **To swap the app font, change this one line.** Bundle a real font in
/// Monospace font family — JetBrains Mono is the default app font.
const String kMonoFamily = 'JetBrains Mono';
/// Sans family for body/system text. `null` → the platform default sans.
const String? kSansFamily = null;

/// Brand wordmark style — the "Remote Pi" marca. **Always Inter** (the
/// wireframe's `RP_SANS`: `screens.jsx` renders the title in `RP_SANS` bold),
/// served via the `google_fonts` package so it renders identically on iOS and
/// Android. This is the ONE font that must stay constant everywhere the product
/// name appears (Home title, onboarding, splash) — never substitute the
/// mono/system font for it.
///
/// **To change the brand font, change this one call** (e.g. `GoogleFonts.x`).
///
/// Returns a runtime [TextStyle] (Google Fonts can't be `const`); pass the
/// brightness-appropriate [color] from `context.colors.text`.
TextStyle brandTextStyle({
  required double fontSize,
  FontWeight fontWeight = FontWeight.w700,
  Color? color,
  double? letterSpacing,
  double? height,
}) {
  return GoogleFonts.inter(
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// Typographic styles for the app, themed per brightness (colors baked in so
/// the common case — `context.typo.mono` — is correct without a `.copyWith`).
///
/// This is the SINGLE source of truth for text styles. Widgets read
/// `context.typo.<style>` and `.copyWith(...)` only for one-off size/weight
/// tweaks — never re-declaring `fontFamily`.
///
/// Registered on [ThemeData.extensions]; resolve via
/// `Theme.of(context).extension<AppTypography>()`.
@immutable
class AppTypography extends ThemeExtension<AppTypography> {
  const AppTypography({
    required this.mono,
    required this.monoSmall,
    required this.sansBody,
    this.fontFamily = AppFontFamily.system,
  });

  /// Active font family configuration.
  final AppFontFamily fontFamily;

  /// Primary monospace style (chat code, terminal chrome). Was `kMonoStyle`.
  final TextStyle mono;

  /// Small monospace style (captions, metadata). Was `kMonoSmall`.
  final TextStyle monoSmall;

  /// Sans body text. Was `kSansBody`.
  final TextStyle sansBody;

  /// Build the style set for a given color palette so text colors track the
  /// active theme. [monoColor] is the resting mono text color (was the
  /// hardcoded `0xFFE6E6E6` in dark).
  factory AppTypography.fromColors(
    AppColors c, {
    required Color monoColor,
    AppFontFamily fontFamily = AppFontFamily.system,
  }) {
    return AppTypography(
      fontFamily: fontFamily,
      mono: fontFamily.textStyle(
        fontSize: 14.5,
        color: monoColor,
        height: 1.5,
        letterSpacing: 0,
      ),
      monoSmall: fontFamily.textStyle(
        fontSize: 12.0,
        color: c.muted2,
        height: 1.4,
      ),
      sansBody: TextStyle(
        fontFamily: kSansFamily,
        fontSize: 15.0,
        color: c.text,
        height: 1.35,
        letterSpacing: -0.1,
      ),
    );
  }

  /// Default dark typography with system font.
  static final AppTypography defaultDark = AppTypography.dark();

  /// Default light typography with system font.
  static final AppTypography defaultLight = AppTypography.light();

  /// Dark typography — mono text matches the original `0xFFE6E6E6`.
  static AppTypography dark({AppFontFamily fontFamily = AppFontFamily.system}) =>
      AppTypography.fromColors(
        AppColors.dark,
        monoColor: const Color(0xFFE6E6E6),
        fontFamily: fontFamily,
      );

  /// Light typography — mono text is a near-black for contrast on white.
  static AppTypography light({AppFontFamily fontFamily = AppFontFamily.system}) =>
      AppTypography.fromColors(
        AppColors.light,
        monoColor: const Color(0xFF1A1A1A),
        fontFamily: fontFamily,
      );

  @override
  AppTypography copyWith({
    TextStyle? mono,
    TextStyle? monoSmall,
    TextStyle? sansBody,
    AppFontFamily? fontFamily,
  }) {
    return AppTypography(
      mono: mono ?? this.mono,
      monoSmall: monoSmall ?? this.monoSmall,
      sansBody: sansBody ?? this.sansBody,
      fontFamily: fontFamily ?? this.fontFamily,
    );
  }

  @override
  AppTypography lerp(ThemeExtension<AppTypography>? other, double t) {
    if (other is! AppTypography) return this;
    return AppTypography(
      mono: TextStyle.lerp(mono, other.mono, t)!,
      monoSmall: TextStyle.lerp(monoSmall, other.monoSmall, t)!,
      sansBody: TextStyle.lerp(sansBody, other.sansBody, t)!,
      fontFamily: t < 0.5 ? fontFamily : other.fontFamily,
    );
  }
}

