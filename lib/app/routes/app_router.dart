// lib/app/routes/app_router.dart
import 'package:flutter/material.dart';
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

/// Named route constants for the ReCapture app.
/// No route string should exist anywhere else in the codebase — always
/// reference AppRoutes.* constants.
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

final appRouter = GoRouter(
  initialLocation: AppRoutes.splash,
  routes: [
    GoRoute(
      path: AppRoutes.splash,
      builder: (_, __) => const SplashScreen(),
    ),
    GoRoute(
      path: AppRoutes.auth,
      builder: (_, __) => const AuthScreen(),
    ),
    GoRoute(
      path: AppRoutes.otpVerify,
      builder: (_, __) => const OtpScreen(),
    ),
    GoRoute(
      path: AppRoutes.projects,
      builder: (_, __) => const ProjectsScreen(),
    ),
    GoRoute(
      path: AppRoutes.createProject,
      builder: (_, __) => const CreateProjectScreen(),
    ),
    GoRoute(
      path: AppRoutes.preCapture,
      builder: (_, __) => const PreCaptureScreen(),
    ),
    GoRoute(
      path: AppRoutes.permissions,
      builder: (_, __) => const PermissionsScreen(),
    ),
    // Level A
    GoRoute(
      path: AppRoutes.levelAIntro,
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
      builder: (_, __) => const CaptureScreen(
        levelLabel: 'A',
        levelName: 'Eye Ring',
        nextRoute: AppRoutes.levelAReview,
      ),
    ),
    GoRoute(
      path: AppRoutes.levelAReview,
      builder: (_, __) => const ReviewScreen(
        levelLabel: 'A',
        levelName: 'Eye Ring',
        nextRoute: AppRoutes.levelAComplete,
      ),
    ),
    GoRoute(
      path: AppRoutes.levelAComplete,
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
      builder: (_, __) => const CaptureScreen(
        levelLabel: 'B',
        levelName: 'Top Ring',
        nextRoute: AppRoutes.levelBReview,
      ),
    ),
    GoRoute(
      path: AppRoutes.levelBReview,
      builder: (_, __) => const ReviewScreen(
        levelLabel: 'B',
        levelName: 'Top Ring',
        nextRoute: AppRoutes.levelBComplete,
      ),
    ),
    GoRoute(
      path: AppRoutes.levelBComplete,
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
      builder: (_, __) => const CaptureScreen(
        levelLabel: 'C',
        levelName: 'Low Ring',
        nextRoute: AppRoutes.levelCReview,
      ),
    ),
    GoRoute(
      path: AppRoutes.levelCReview,
      builder: (_, __) => const ReviewScreen(
        levelLabel: 'C',
        levelName: 'Low Ring',
        nextRoute: AppRoutes.levelCComplete,
      ),
    ),
    GoRoute(
      path: AppRoutes.levelCComplete,
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
      builder: (_, __) => const CaptureSummaryScreen(),
    ),
    GoRoute(
      path: AppRoutes.uploading,
      builder: (_, __) => const UploadingScreen(),
    ),
    GoRoute(
      path: AppRoutes.processing,
      builder: (_, __) => const ProcessingScreen(),
    ),
    GoRoute(
      path: AppRoutes.modelReady,
      builder: (_, __) => const ModelReadyScreen(),
    ),
    GoRoute(
      path: AppRoutes.arPreview,
      builder: (_, __) => const ArPreviewScreen(),
    ),
  ],
);
