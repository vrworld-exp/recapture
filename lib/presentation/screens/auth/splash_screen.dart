// lib/presentation/screens/auth/splash_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../application/auth/auth_notifier.dart';
import '../../../app/routes/app_router.dart';
import '../../../domain/entities/auth_state.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../../utils/platform_name.dart';

/// Screen 0 — entry/splash. Shows the brand mark while a fully-offline
/// bootstrap check decides whether to route to the Auth flow or the Projects
/// Hub. Minimum display 1200ms (brand never flashes), hard ceiling 3000ms
/// (never stuck on splash).
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  /// Brand mark stays on screen at least this long even on instant init.
  static const Duration _minDisplay = Duration(milliseconds: 1200);

  /// Hard ceiling on the bootstrap check; on timeout we fall back to login.
  static const Duration _maxBootstrap = Duration(milliseconds: 3000);

  /// Guards against double-navigation if the widget rebuilds or the app is
  /// backgrounded/resumed mid-init.
  bool _hasNavigated = false;

  bool _showTagline = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => _showTagline = true);
    });
    _runBootstrap();
  }

  Future<void> _runBootstrap() async {
    // Time only the real restore work, not the artificial minimum-display delay.
    final stopwatch = Stopwatch()..start();
    final settleFuture = _awaitAuthSettled().then((state) {
      stopwatch.stop();
      return state;
    });

    // Wait for both the auth restore and the minimum display window. Future.wait
    // completes only once the slower of the two finishes, so the splash is
    // shown for at least _minDisplay and at most ~_maxBootstrap.
    await Future.wait<void>([
      settleFuture,
      Future<void>.delayed(_minDisplay),
    ]);

    final state = await settleFuture;
    _navigate(state, stopwatch.elapsedMilliseconds);
  }

  /// Waits for [authProvider] to leave [AuthRestoring]. The notifier restores
  /// from secure storage (and may refresh an expired token) on build; we just
  /// observe the settled result. Falls back to the current (possibly still
  /// restoring) state on timeout so the splash never hangs.
  Future<AuthState> _awaitAuthSettled() async {
    final current = ref.read(authProvider);
    if (current is! AuthRestoring) return current;

    final completer = Completer<AuthState>();
    final sub = ref.listenManual<AuthState>(authProvider, (_, next) {
      if (next is! AuthRestoring && !completer.isCompleted) {
        completer.complete(next);
      }
    });
    try {
      return await completer.future.timeout(_maxBootstrap);
    } on TimeoutException {
      return ref.read(authProvider);
    } finally {
      sub.close();
    }
  }

  void _navigate(AuthState state, int initDurationMs) {
    if (!mounted || _hasNavigated) return;
    _hasNavigated = true;

    final authed = state.isAuthenticated;
    Analytics.logEvent('app_launch', {
      'auth_status': authed ? 'authenticated' : 'unauthenticated',
      'init_duration_ms': initDurationMs,
      'platform': appPlatformName,
    });

    // The router's guard reads the same auth source via the bridged listenable,
    // so it already agrees with this decision; this navigation just leaves the
    // splash (which the guard deliberately never intercepts).
    context.goNamed(
      authed ? AppRouteNames.projects : AppRouteNames.auth,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.bgPrimary,
        body: DecoratedBox(
          // Subtle radial depth, per theme spec. Shader-light — no animation.
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 0.9,
              colors: [AppColors.surface1, AppColors.bgPrimary],
            ),
          ),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Brand mark — placeholder icon mark used app-wide until
                      // a real branding asset is supplied (see Assumptions).
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AppColors.mirageRed,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: const Icon(Icons.videocam,
                            color: Colors.white, size: 32),
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      Text(
                        'ReCapture',
                        style: Theme.of(context).textTheme.displayLarge,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      AnimatedOpacity(
                        opacity: _showTagline ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 400),
                        child: Text(
                          'Preparing capture tools…',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.huge),
                child: AppLoadingIndicator(size: 24),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
