// lib/presentation/screens/auth/splash_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/bootstrap/app_bootstrap_service.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_loading_indicator.dart';

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
    final service = ref.read(appBootstrapServiceProvider);

    // Time only the real init work, not the artificial minimum-display delay.
    final stopwatch = Stopwatch()..start();
    final resolveFuture = _resolve(service).then((result) {
      stopwatch.stop();
      return result;
    });

    // Wait for both the resolve and the minimum display window. Future.wait
    // completes only once the slower of the two finishes, so the splash is
    // shown for at least _minDisplay and at most ~_maxBootstrap.
    await Future.wait<void>([
      resolveFuture,
      Future<void>.delayed(_minDisplay),
    ]);

    final result = await resolveFuture;
    _navigate(result, stopwatch.elapsedMilliseconds);
  }

  Future<BootstrapResult> _resolve(AppBootstrapService service) async {
    try {
      return await service.resolveInitialRoute().timeout(_maxBootstrap);
    } catch (_) {
      // Timeout or any unexpected failure → safe fallback to login.
      return const BootstrapResult(AppInitRoute.login, 'error');
    }
  }

  void _navigate(BootstrapResult result, int initDurationMs) {
    if (!mounted || _hasNavigated) return;
    _hasNavigated = true;

    Analytics.logEvent('app_launch', {
      'auth_status': result.authStatus,
      'init_duration_ms': initDurationMs,
      'platform':
          defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    });

    final route = switch (result.route) {
      AppInitRoute.projectsHub => AppRoutes.projects,
      AppInitRoute.login => AppRoutes.auth,
    };
    context.go(route);
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
                        child:
                            const Icon(Icons.videocam, color: Colors.white, size: 32),
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
