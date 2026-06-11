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
  static const levelAComplete = '/capture/level-a/complete';
  static const levelBIntro = '/capture/level-b/intro';
  static const levelBCapture = '/capture/level-b';
  static const levelBReview = '/capture/level-b/review';
  static const levelBComplete = '/capture/level-b/complete';
  static const levelCIntro = '/capture/level-c/intro';
  static const levelCCapture = '/capture/level-c';
  static const levelCReview = '/capture/level-c/review';
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
        icon: Icons.remove_red_eye_outlined,
        angleHint: 'Hold phone at eye level',
        rules: [
          'Keep the object fully inside the box',
          'Move slowly in a clockwise circle',
          'Overlap shots for complete coverage',
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
        nextLabel: 'Start Level B',
        nextRoute: AppRoutes.levelBIntro,
        reviewRoute: AppRoutes.levelAReview,
      ),
    ),

    // Level B
    GoRoute(
      path: AppRoutes.levelBIntro,
      builder: (_, __) => const LevelIntroScreen(
        levelLabel: 'B',
        levelName: 'Top Ring',
        icon: Icons.north,
        angleHint: 'Tilt phone downward 30–60°',
        rules: [
          'Tilt down more to reveal the top surface',
          'Keep the object fully visible — step back if needed',
          'Continue clockwise around the object',
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
        nextLabel: 'Start Level C',
        nextRoute: AppRoutes.levelCIntro,
        reviewRoute: AppRoutes.levelBReview,
      ),
    ),

    // Level C
    GoRoute(
      path: AppRoutes.levelCIntro,
      builder: (_, __) => const LevelIntroScreen(
        levelLabel: 'C',
        levelName: 'Low Ring',
        icon: Icons.south,
        angleHint: 'Lower phone, tilt upward 10–30°',
        rules: [
          'Lower your phone and tilt slightly upward',
          'Capture the base edges without cutting off',
          'Complete the final clockwise ring',
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
        nextLabel: 'Continue',
        nextRoute: AppRoutes.captureSummary,
        reviewRoute: AppRoutes.levelCReview,
      ),
    ),

    // End flow
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
