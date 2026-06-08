// lib/app/app.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'routes/app_router.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';

/// Root application widget for ReCapture.
///
/// Dark theme only — MVP. ThemeMode.dark is hardcoded.
/// No light theme, no system theme detection, no theme toggle.
/// Theme switching is a post-MVP feature.
class ReCapture extends ConsumerWidget {
  const ReCapture({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Force dark status bar icons + transparent status bar globally.
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: AppColors.bgPrimary,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    return MaterialApp.router(
      title: 'ReCapture',
      debugShowCheckedModeBanner: false,

      // Force dark theme regardless of system setting — MVP constraint.
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,

      // Navigation
      routerConfig: appRouter,
    );
  }
}
