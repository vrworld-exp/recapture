import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
  static const captureSummary = '/capture/summary';
  static const uploading = '/upload';
  static const processing = '/processing';
  static const modelReady = '/model';
  static const arPreview = '/model/ar';
}

Widget _placeholder(String name) => Scaffold(
      body: Center(
        child: Text(name, style: const TextStyle(color: Colors.white)),
      ),
    );

final appRouter = GoRouter(
  initialLocation: AppRoutes.splash,
  routes: [
    GoRoute(path: AppRoutes.splash, builder: (_, __) => _placeholder('Splash')),
    GoRoute(path: AppRoutes.auth, builder: (_, __) => _placeholder('Auth')),
    GoRoute(path: AppRoutes.otpVerify, builder: (_, __) => _placeholder('OTP Verify')),
    GoRoute(path: AppRoutes.projects, builder: (_, __) => _placeholder('Projects')),
    GoRoute(path: AppRoutes.createProject, builder: (_, __) => _placeholder('Create Project')),
    GoRoute(path: AppRoutes.preCapture, builder: (_, __) => _placeholder('Pre-Capture')),
    GoRoute(path: AppRoutes.permissions, builder: (_, __) => _placeholder('Permissions')),
    GoRoute(path: AppRoutes.levelAIntro, builder: (_, __) => _placeholder('Level A Intro')),
    GoRoute(path: AppRoutes.levelACapture, builder: (_, __) => _placeholder('Level A Capture')),
    GoRoute(path: AppRoutes.levelAReview, builder: (_, __) => _placeholder('Level A Review')),
    GoRoute(path: AppRoutes.levelBIntro, builder: (_, __) => _placeholder('Level B Intro')),
    GoRoute(path: AppRoutes.levelBCapture, builder: (_, __) => _placeholder('Level B Capture')),
    GoRoute(path: AppRoutes.levelBReview, builder: (_, __) => _placeholder('Level B Review')),
    GoRoute(path: AppRoutes.levelCIntro, builder: (_, __) => _placeholder('Level C Intro')),
    GoRoute(path: AppRoutes.levelCCapture, builder: (_, __) => _placeholder('Level C Capture')),
    GoRoute(path: AppRoutes.levelCReview, builder: (_, __) => _placeholder('Level C Review')),
    GoRoute(path: AppRoutes.captureSummary, builder: (_, __) => _placeholder('Capture Summary')),
    GoRoute(path: AppRoutes.uploading, builder: (_, __) => _placeholder('Uploading')),
    GoRoute(path: AppRoutes.processing, builder: (_, __) => _placeholder('Processing')),
    GoRoute(path: AppRoutes.modelReady, builder: (_, __) => _placeholder('Model Ready')),
    GoRoute(path: AppRoutes.arPreview, builder: (_, __) => _placeholder('AR Preview')),
  ],
);
