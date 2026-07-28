// lib/app/app.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/config/config_notifier.dart';
import '../application/offline/offline_queue_notifier.dart';
import '../application/projects/generation_tracker_notifier.dart';
import '../application/warmup/backend_warmup.dart';
import '../presentation/widgets/generation_status_bar.dart';
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

    // Eager-init the backend warm-up: fire-and-forget GET /health now and on
    // every foreground resume, so the Render instance is awake before the
    // user's first real request. Read, not watch — nothing to rebuild on.
    ref.read(backendWarmupProvider);

    // Eager-init the 3D-model generation tracker and START it, so it restores
    // anything that was still building when the app was last killed and re-asks
    // the server about it immediately. `start()` (rather than mere construction)
    // is what turns on its Hive persistence — screens construct this notifier
    // just to read the capture lock, and that must never touch the disk. Read,
    // not watch — the status bar below watches it directly, and the shell must
    // not rebuild on every poll.
    ref.read(generationTrackerProvider.notifier).start();

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

      // The app-wide "your 3D model is building" bar. Mounted HERE, above the
      // navigator, so one bar serves every route and pushes content down rather
      // than covering an AppBar. It renders nothing at all — returning its child
      // untouched — whenever no generation is being tracked, which is almost
      // always.
      builder: (context, child) =>
          GenerationStatusBar(child: child ?? const SizedBox.shrink()),
    );
  }
}
