import 'package:flutter/material.dart';
import 'app_colors.dart';

abstract final class AppTypography {
  // Font size scale (from PRD design tokens)
  static const double sizeDisplay = 34;
  static const double sizeTitle = 22;
  static const double sizeHeadline = 17;
  static const double sizeBody = 15;
  static const double sizeCaption = 13;
  static const double sizeLabel = 12;

  // Line height multipliers (1.25–1.4 per PRD)
  static const double lineHeightTight = 1.25;
  static const double lineHeightNormal = 1.35;
  static const double lineHeightLoose = 1.4;

  static TextTheme get textTheme => const TextTheme(
        // Display — 34 / Semibold
        displayLarge: TextStyle(
          fontSize: sizeDisplay,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
          height: lineHeightTight,
        ),
        // Title — 22 / Semibold
        titleLarge: TextStyle(
          fontSize: sizeTitle,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
          height: lineHeightNormal,
        ),
        // Headline — 17 / Semibold
        headlineMedium: TextStyle(
          fontSize: sizeHeadline,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
          height: lineHeightNormal,
        ),
        // Body — 15 / Regular
        bodyLarge: TextStyle(
          fontSize: sizeBody,
          fontWeight: FontWeight.w400,
          color: AppColors.textPrimary,
          height: lineHeightLoose,
        ),
        // Body secondary (use textSecondary color manually where needed)
        bodyMedium: TextStyle(
          fontSize: sizeBody,
          fontWeight: FontWeight.w400,
          color: AppColors.textSecondary,
          height: lineHeightLoose,
        ),
        // Caption — 13 / Regular
        bodySmall: TextStyle(
          fontSize: sizeCaption,
          fontWeight: FontWeight.w400,
          color: AppColors.textSecondary,
          height: lineHeightNormal,
        ),
        // Label — 12 / Medium
        labelSmall: TextStyle(
          fontSize: sizeLabel,
          fontWeight: FontWeight.w500,
          color: AppColors.textSecondary,
          height: lineHeightNormal,
        ),
      );
}
