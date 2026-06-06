import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_colors.dart';
import 'app_typography.dart';
import 'app_spacing.dart';

abstract final class AppTheme {
  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bgPrimary,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.mirageRed,
          onPrimary: AppColors.textPrimary,
          secondary: AppColors.royalGold,
          onSecondary: AppColors.bgPrimary,
          surface: AppColors.surface1,
          onSurface: AppColors.textPrimary,
          error: AppColors.error,
          onError: AppColors.textPrimary,
        ),
        textTheme: AppTypography.textTheme,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.bgPrimary,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle.light,
        ),
        cardTheme: CardThemeData(
          color: AppColors.surface1,
          elevation: AppElevation.e1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.mirageRed,
            foregroundColor: AppColors.textPrimary,
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            textStyle: const TextStyle(
              fontSize: AppTypography.sizeBody,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textPrimary,
            side: const BorderSide(color: AppColors.textMuted),
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.surface1,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            borderSide: const BorderSide(color: AppColors.disabled),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            borderSide: const BorderSide(color: AppColors.disabled),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            borderSide: const BorderSide(color: AppColors.mirageRed, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            borderSide: const BorderSide(color: AppColors.error),
          ),
          labelStyle: const TextStyle(color: AppColors.textSecondary),
          hintStyle: const TextStyle(color: AppColors.textMuted),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: AppColors.surface1,
          modalBackgroundColor: AppColors.surface1,
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.disabled,
          thickness: 0.5,
        ),
        chipTheme: ChipThemeData(
          backgroundColor: AppColors.surface2,
          labelStyle: const TextStyle(color: AppColors.textSecondary),
          selectedColor: AppColors.mirageRed,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
        ),
      );
}
