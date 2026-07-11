// lib/application/warmup/backend_warmup.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/backend_warmup_service.dart';

/// The warm-up service seam — override in tests to avoid real network.
final backendWarmupServiceProvider = Provider<BackendWarmupService>((ref) {
  return BackendWarmupService();
});

/// Eager-init from the app shell (ref.read in [ReCapture.build], same pattern
/// as captureConfigProvider): pings /health once at startup, then again every
/// time the app returns to the foreground. The service throttles, so rapid
/// pause/resume cycles cost one request at most per minute.
final backendWarmupProvider = Provider<void>((ref) {
  final service = ref.watch(backendWarmupServiceProvider);

  // App open — fire immediately (AppLifecycleListener only reports
  // TRANSITIONS to resumed, so launch itself needs this explicit ping).
  service.warmUp();

  // App resumed from background — the mobile equivalent of a page reload.
  final listener = AppLifecycleListener(onResume: service.warmUp);
  ref.onDispose(listener.dispose);
});
