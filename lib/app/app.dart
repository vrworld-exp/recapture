// lib/app/app.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/config/config_notifier.dart';
import '../application/offline/offline_queue_notifier.dart';
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
    // Eager-init capture config so its non-blocking bootstrap (cache → remote)
    // kicks off at startup. Read (not watch) — the app shell must not rebuild on
    // background config updates; consumers watch captureConfigProvider directly.
    // (Hive is already initialized in main() before runApp, so the cache read
    // is ready.)
    ref.read(captureConfigProvider);

    // Eager-init the offline action queue so it restores persisted actions and
    // starts listening for connectivity (to auto-drain on reconnect) and for
    // logout (to clear). Read, not watch — the shell must not rebuild on queue
    // changes; consumers watch offlineQueueProvider directly.
    ref.read(offlineQueueProvider);

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

      // Navigation — router carries the auth guard (refreshListenable).
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
