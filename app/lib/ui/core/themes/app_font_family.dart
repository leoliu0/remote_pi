import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// User-selectable font family for the app UI and monospace text.
enum AppFontFamily {
  system('System (Courier)'),
  jetbrainsMono('JetBrains Mono'),
  firaCode('Fira Code'),
  sourceCodePro('Source Code Pro'),
  ibmPlexMono('IBM Plex Mono'),
  robotoMono('Roboto Mono'),
  inconsolata('Inconsolata'),
  inter('Inter');

  const AppFontFamily(this.label);

  /// Label shown in Settings.
  final String label;

  /// Returns a [TextStyle] for this font family.
  TextStyle textStyle({
    required double fontSize,
    Color? color,
    FontWeight? fontWeight,
    double? height,
    double? letterSpacing,
  }) {
    switch (this) {
      case AppFontFamily.system:
        return TextStyle(
          fontFamily: 'Courier',
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
          height: height,
          letterSpacing: letterSpacing,
        );
      case AppFontFamily.jetbrainsMono:
        return GoogleFonts.jetBrainsMono(
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
          height: height,
          letterSpacing: letterSpacing,
        );
      case AppFontFamily.firaCode:
        return GoogleFonts.firaCode(
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
          height: height,
          letterSpacing: letterSpacing,
        );
      case AppFontFamily.sourceCodePro:
        return GoogleFonts.sourceCodePro(
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
          height: height,
          letterSpacing: letterSpacing,
        );
      case AppFontFamily.ibmPlexMono:
        return GoogleFonts.ibmPlexMono(
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
          height: height,
          letterSpacing: letterSpacing,
        );
      case AppFontFamily.robotoMono:
        return GoogleFonts.robotoMono(
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
          height: height,
          letterSpacing: letterSpacing,
        );
      case AppFontFamily.inconsolata:
        return GoogleFonts.inconsolata(
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
          height: height,
          letterSpacing: letterSpacing,
        );
      case AppFontFamily.inter:
        return GoogleFonts.inter(
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
          height: height,
          letterSpacing: letterSpacing,
        );
    }
  }

  /// Returns the font family name string for ThemeData or TextStyle.
  String? get fontFamilyName {
    switch (this) {
      case AppFontFamily.system:
        return 'Courier';
      case AppFontFamily.jetbrainsMono:
        return GoogleFonts.jetBrainsMono().fontFamily;
      case AppFontFamily.firaCode:
        return GoogleFonts.firaCode().fontFamily;
      case AppFontFamily.sourceCodePro:
        return GoogleFonts.sourceCodePro().fontFamily;
      case AppFontFamily.ibmPlexMono:
        return GoogleFonts.ibmPlexMono().fontFamily;
      case AppFontFamily.robotoMono:
        return GoogleFonts.robotoMono().fontFamily;
      case AppFontFamily.inconsolata:
        return GoogleFonts.inconsolata().fontFamily;
      case AppFontFamily.inter:
        return GoogleFonts.inter().fontFamily;
    }
  }

  /// Parse a persisted value. Unknown/missing falls back to [system].
  static AppFontFamily fromName(String? raw) {
    for (final v in AppFontFamily.values) {
      if (v.name == raw) return v;
    }
    return AppFontFamily.system;
  }
}
