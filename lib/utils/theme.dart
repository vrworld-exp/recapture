import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  static const Color background = Color(0xFF0B0B0E);
  static const Color surface = Color(0xFF151518);
  static const Color primaryText = Color(0xFFF5F5F7);
  static const Color secondaryText = Color(0xFFB3B3B8);
  static const Color accentRed = Color(0xFFE10600);
  static const Color accentGold = Color(0xFFC9A24D);
  static const Color disabled = Color(0xFF5C5C61);
}

class AppTheme {
  AppTheme._();

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: const ColorScheme.dark(
          surface: AppColors.background,
          primary: AppColors.accentRed,
          onPrimary: AppColors.primaryText,
          onSurface: AppColors.primaryText,
        ),
        useMaterial3: true,
      );
}
