// lib/app/theme/app_typography.dart
import 'package:flutter/material.dart';
import 'app_colors.dart';

/// ReCapture type scale — sourced from PRD design tokens.
///
/// Font size scale:
///   Display   34 / Semibold  → displayLarge
///   Title     22 / Semibold  → titleLarge
///   Headline  17 / Semibold  → headlineMedium
///   Body      15 / Regular   → bodyLarge
///   Body Sec  15 / Regular   → bodyMedium   (textSecondary color)
///   Caption   13 / Regular   → bodySmall
///   Label     12 / Medium    → labelSmall
///
/// Line height multipliers (Flutter `height` = lineHeight / fontSize):
///   Tight  1.25 → used for large display text
///   Normal 1.35 → used for titles and headlines
///   Loose  1.40 → used for body and caption text
///
/// RULE: Never hardcode a font size outside this file. Always reference
/// AppTypography.size* constants or use the TextTheme roles above.
abstract final class AppTypography {
  // Font size constants — reference these when constructing one-off TextStyles
  static const double sizeDisplay = 34;
  static const double sizeTitle = 22;
  static const double sizeHeadline = 17;
  static const double sizeBody = 15;
  static const double sizeCaption = 13;
  static const double sizeLabel = 12;

  // Line height multipliers
  static const double lineHeightTight = 1.25;
  static const double lineHeightNormal = 1.35;
  static const double lineHeightLoose = 1.40;

  /// Full Material 3 TextTheme mapped to the PRD type scale.
  /// Apply via ThemeData(textTheme: AppTypography.textTheme).
  static const TextTheme textTheme = TextTheme(
    // Display — 34 / Semibold / tight line height
    displayLarge: TextStyle(
      fontSize: sizeDisplay,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
      height: lineHeightTight,
    ),

    // Title — 22 / Semibold / normal line height
    titleLarge: TextStyle(
      fontSize: sizeTitle,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
      height: lineHeightNormal,
    ),

    // Headline — 17 / Semibold / normal line height
    headlineMedium: TextStyle(
      fontSize: sizeHeadline,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
      height: lineHeightNormal,
    ),

    // Body primary — 15 / Regular / loose line height
    bodyLarge: TextStyle(
      fontSize: sizeBody,
      fontWeight: FontWeight.w400,
      color: AppColors.textPrimary,
      height: lineHeightLoose,
    ),

    // Body secondary — 15 / Regular / loose line height (textSecondary color)
    bodyMedium: TextStyle(
      fontSize: sizeBody,
      fontWeight: FontWeight.w400,
      color: AppColors.textSecondary,
      height: lineHeightLoose,
    ),

    // Caption — 13 / Regular / normal line height
    bodySmall: TextStyle(
      fontSize: sizeCaption,
      fontWeight: FontWeight.w400,
      color: AppColors.textSecondary,
      height: lineHeightNormal,
    ),

    // Label — 12 / Medium / normal line height
    labelSmall: TextStyle(
      fontSize: sizeLabel,
      fontWeight: FontWeight.w500,
      color: AppColors.textSecondary,
      height: lineHeightNormal,
    ),

    // Unused Material 3 slots — set to neutral values so they don't render
    // with unexpected Material defaults if accidentally referenced
    displayMedium: TextStyle(
      fontSize: sizeTitle,
      fontWeight: FontWeight.w400,
      color: AppColors.textSecondary,
    ),
    displaySmall: TextStyle(
      fontSize: sizeHeadline,
      fontWeight: FontWeight.w400,
      color: AppColors.textSecondary,
    ),
    headlineLarge: TextStyle(
      fontSize: sizeTitle,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
    ),
    headlineSmall: TextStyle(
      fontSize: sizeBody,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
    ),
    titleMedium: TextStyle(
      fontSize: sizeBody,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
    ),
    titleSmall: TextStyle(
      fontSize: sizeCaption,
      fontWeight: FontWeight.w600,
      color: AppColors.textSecondary,
    ),
    labelLarge: TextStyle(
      fontSize: sizeBody,
      fontWeight: FontWeight.w500,
      color: AppColors.textPrimary,
    ),
    labelMedium: TextStyle(
      fontSize: sizeCaption,
      fontWeight: FontWeight.w500,
      color: AppColors.textSecondary,
    ),
  );
}
