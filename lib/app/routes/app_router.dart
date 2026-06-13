// lib/app/routes/app_router.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../presentation/screens/auth/splash_screen.dart';
import '../../presentation/screens/auth/auth_screen.dart';
import '../../presentation/screens/auth/otp_screen.dart';
import '../../presentation/screens/projects/projects_screen.dart';
import '../../presentation/screens/projects/create_project_screen.dart';
import '../../presentation/screens/capture/pre_capture_screen.dart';
import '../../presentation/screens/capture/permissions_screen.dart';
import '../../presentation/screens/capture/level_intro_screen.dart';
import '../../presentation/screens/capture/capture_screen.dart';
import '../../presentation/screens/capture/review_screen.dart';
import '../../presentation/screens/capture/level_complete_screen.dart';
import '../../presentation/screens/capture/capture_summary_screen.dart';
import '../../presentation/screens/capture/uploading_screen.dart';
import '../../presentation/screens/capture/processing_screen.dart';
import '../../presentation/screens/capture/model_ready_screen.dart';
import '../../presentation/screens/capture/ar_preview_screen.dart';
import '../theme/app_colors.dart';
import 'auth_router_notifier.dart';
import 'route_error_screen.dart';

/// Named route paths for the ReCapture app.
/// No route string should exist anywhere else in the codebase — always
/// reference AppRoutes.* (paths) or AppRouteNames.* (names) constants.
abstract final class AppRoutes {
  static const splash = '/';
  static const auth = '/auth';
  static const otpVerify = '/auth/otp';
  static const projects = '/projects';
  static const createProject = '/projects/new';
  static const preCapture = '/capture/pre';
  static const permissions = '/capture/permissions';
  static const levelAIntro = '/capture/level-a/intro';
  static const levelACapture = '/capture/level-a';
  static const levelAReview = '/capture/level-a/review';
  static const levelBIntro = '/capture/level-b/intro';
  static const levelBCapture = '/capture/level-b';
  static const levelBReview = '/capture/level-b/review';
  static const levelCIntro = '/capture/level-c/intro';
  static const levelCCapture = '/capture/level-c';
  static const levelCReview = '/capture/level-c/review';
  static const levelAComplete = '/capture/level-a/complete';
  static const levelBComplete = '/capture/level-b/complete';
  static const levelCComplete = '/capture/level-c/complete';
  static const captureSummary = '/capture/summary';
  static const uploading = '/upload';
  static const processing = '/processing';
  static const modelReady = '/model';
  static const arPreview = '/model/ar';
}

/// Symbolic route names for `context.goNamed` / `context.pushNamed`. Each maps
/// 1:1 to an [AppRoutes] path so navigation never hard-codes a path string.
abstract final class AppRouteNames {
  static const splash = 'splash';
  static const auth = 'auth';
  static const otpVerify = 'otpVerify';
  static const projects = 'projects';
  static const createProject = 'createProject';
  static const preCapture = 'preCapture';
  static const permissions = 'permissions';
  static const levelAIntro = 'levelAIntro';
  static const levelACapture = 'levelACapture';
  static const levelAReview = 'levelAReview';
  static const levelBIntro = 'levelBIntro';
  static const levelBCapture = 'levelBCapture';
  static const levelBReview = 'levelBReview';
  static const levelCIntro = 'levelCIntro';
  static const levelCCapture = 'levelCCapture';
  static const levelCReview = 'levelCReview';
  static const levelAComplete = 'levelAComplete';
  static const levelBComplete = 'levelBComplete';
  static const levelCComplete = 'levelCComplete';
  static const captureSummary = 'captureSummary';
  static const uploading = 'uploading';
  static const processing = 'processing';
  static const modelReady = 'modelReady';
  static const arPreview = 'arPreview';
}

/// Auth routes the guard treats as "public". Everything else is protected.
const Set<String> _authLocations = {
  AppRoutes.auth,
  AppRoutes.otpVerify,
};

/// Builds the app's [GoRouter] with auth guards driven by [authNotifier].
///
/// Guard contract (single source of truth — screens must not re-check auth):
///   - Splash (`/`) runs its own bootstrap navigation and is never intercepted.
///   - Unauthenticated + protected route  → redirect to [AppRoutes.auth].
///   - Authenticated + auth route          → redirect to [AppRoutes.projects].
/// `refreshListenable` re-runs the guard on every sign-in / sign-out.
GoRouter createAppRouter(AuthRouterNotifier authNotifier) {
  return GoRouter(
    initialLocation: AppRoutes.splash,
    refreshListenable: authNotifier,
    redirect: (context, state) {
      final loc = state.matchedLocation;

      // The splash owns the initial decision (and clears expired tokens before
      // setting auth state) — let it run without interference.
      if (loc == AppRoutes.splash) return null;

      final loggedIn = authNotifier.isAuthenticated;
      final goingToAuth = _authLocations.contains(loc);

      // Block protected content for signed-out users — no flash, hard redirect.
      if (!loggedIn && !goingToAuth) return AppRoutes.auth;
      // Keep signed-in users out of the auth flow.
      if (loggedIn && goingToAuth) return AppRoutes.projects;
      return null;
    },
    errorBuilder: (context, state) => RouteErrorScreen(
      onGoHome: () => context.go(
        authNotifier.isAuthenticated ? AppRoutes.projects : AppRoutes.auth,
      ),
    ),
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        name: AppRouteNames.splash,
        builder: (_, __) => const SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.auth,
        name: AppRouteNames.auth,
        builder: (_, __) => const AuthScreen(),
      ),
      GoRoute(
        path: AppRoutes.otpVerify,
        name: AppRouteNames.otpVerify,
        builder: (_, __) => const OtpScreen(),
      ),
      GoRoute(
        path: AppRoutes.projects,
        name: AppRouteNames.projects,
        builder: (_, __) => const ProjectsScreen(),
      ),
      GoRoute(
        path: AppRoutes.createProject,
        name: AppRouteNames.createProject,
        builder: (_, __) => const CreateProjectScreen(),
      ),
      GoRoute(
        path: AppRoutes.preCapture,
        name: AppRouteNames.preCapture,
        builder: (_, __) => const PreCaptureScreen(),
      ),
      GoRoute(
        path: AppRoutes.permissions,
        name: AppRouteNames.permissions,
        builder: (_, __) => const PermissionsScreen(),
      ),
      // Level A
      GoRoute(
        path: AppRoutes.levelAIntro,
        name: AppRouteNames.levelAIntro,
        builder: (_, __) => const LevelIntroScreen(
          levelLabel: 'A',
          levelName: 'Eye Ring',
          levelColor: AppColors.mirageRed,
          icon: Icons.remove_red_eye_outlined,
          rules: [
            'Keep the object inside the box',
            'Move slowly in a circle',
            'Overlap shots for best results',
          ],
          nextRoute: AppRoutes.levelACapture,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelACapture,
        name: AppRouteNames.levelACapture,
        builder: (_, __) => const CaptureScreen(
          levelLabel: 'A',
          levelName: 'Eye Ring',
          nextRoute: AppRoutes.levelAReview,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelAReview,
        name: AppRouteNames.levelAReview,
        builder: (_, __) => const ReviewScreen(
          levelLabel: 'A',
          levelName: 'Eye Ring',
          nextRoute: AppRoutes.levelAComplete,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelAComplete,
        name: AppRouteNames.levelAComplete,
        builder: (_, __) => const LevelCompleteScreen(
          levelLabel: 'A',
          levelName: 'Eye Ring',
          photosAccepted: 34,
          coveragePercent: 92,
          warningsCount: 1,
          nextRoute: AppRoutes.levelBIntro,
          nextLabel: 'Start Level B',
          reviewRoute: AppRoutes.levelAReview,
        ),
      ),
      // Level B
      GoRoute(
        path: AppRoutes.levelBIntro,
        name: AppRouteNames.levelBIntro,
        builder: (_, __) => const LevelIntroScreen(
          levelLabel: 'B',
          levelName: 'Top Ring',
          levelColor: AppColors.royalGold,
          icon: Icons.arrow_upward,
          rules: [
            'Tilt camera slightly downward',
            'Keep same circular motion',
            'Ensure top surface is visible',
          ],
          nextRoute: AppRoutes.levelBCapture,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelBCapture,
        name: AppRouteNames.levelBCapture,
        builder: (_, __) => const CaptureScreen(
          levelLabel: 'B',
          levelName: 'Top Ring',
          nextRoute: AppRoutes.levelBReview,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelBReview,
        name: AppRouteNames.levelBReview,
        builder: (_, __) => const ReviewScreen(
          levelLabel: 'B',
          levelName: 'Top Ring',
          nextRoute: AppRoutes.levelBComplete,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelBComplete,
        name: AppRouteNames.levelBComplete,
        builder: (_, __) => const LevelCompleteScreen(
          levelLabel: 'B',
          levelName: 'Top Ring',
          photosAccepted: 32,
          coveragePercent: 87,
          warningsCount: 1,
          nextRoute: AppRoutes.levelCIntro,
          nextLabel: 'Start Level C',
          reviewRoute: AppRoutes.levelBReview,
        ),
      ),
      // Level C
      GoRoute(
        path: AppRoutes.levelCIntro,
        name: AppRouteNames.levelCIntro,
        builder: (_, __) => const LevelIntroScreen(
          levelLabel: 'C',
          levelName: 'Low Ring',
          levelColor: AppColors.textSecondary,
          icon: Icons.arrow_downward,
          rules: [
            'Tilt camera slightly upward',
            'Capture bottom and base detail',
            'Move slowly for sharp shots',
          ],
          nextRoute: AppRoutes.levelCCapture,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelCCapture,
        name: AppRouteNames.levelCCapture,
        builder: (_, __) => const CaptureScreen(
          levelLabel: 'C',
          levelName: 'Low Ring',
          nextRoute: AppRoutes.levelCReview,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelCReview,
        name: AppRouteNames.levelCReview,
        builder: (_, __) => const ReviewScreen(
          levelLabel: 'C',
          levelName: 'Low Ring',
          nextRoute: AppRoutes.levelCComplete,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelCComplete,
        name: AppRouteNames.levelCComplete,
        builder: (_, __) => const LevelCompleteScreen(
          levelLabel: 'C',
          levelName: 'Low Ring',
          photosAccepted: 30,
          coveragePercent: 78,
          warningsCount: 2,
          nextRoute: AppRoutes.captureSummary,
          nextLabel: 'Continue',
          reviewRoute: AppRoutes.levelCReview,
        ),
      ),
      GoRoute(
        path: AppRoutes.captureSummary,
        name: AppRouteNames.captureSummary,
        builder: (_, __) => const CaptureSummaryScreen(),
      ),
      GoRoute(
        path: AppRoutes.uploading,
        name: AppRouteNames.uploading,
        builder: (_, __) => const UploadingScreen(),
      ),
      GoRoute(
        path: AppRoutes.processing,
        name: AppRouteNames.processing,
        builder: (_, __) => const ProcessingScreen(),
      ),
      GoRoute(
        path: AppRoutes.modelReady,
        name: AppRouteNames.modelReady,
        builder: (_, __) => const ModelReadyScreen(),
      ),
      GoRoute(
        path: AppRoutes.arPreview,
        name: AppRouteNames.arPreview,
        builder: (_, __) => const ArPreviewScreen(),
      ),
    ],
  );
}

/// The app router, rebuilt whenever the auth notifier instance changes.
/// `refreshListenable` handles intra-session auth changes without a rebuild.
final appRouterProvider = Provider<GoRouter>((ref) {
  final notifier = ref.watch(authRouterNotifierProvider);
  final router = createAppRouter(notifier);
  ref.onDispose(router.dispose);
  return router;
});
