// lib/app/routes/app_router.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../application/capture/analytics/capture_level_events.dart';
import '../../application/capture/analytics/capture_level_session.dart';
import '../../application/capture/capture_flow_variant_provider.dart';
import '../../application/capture/capture_shape_mode_provider.dart';
import '../../application/capture/completion_gate_provider.dart';
import '../../domain/entities/capture_config.dart';
import '../../domain/capture/capture_flow_variant.dart';
import '../../domain/capture/completion_gate.dart';
import '../../domain/entities/level_a_summary.dart';
import '../../domain/entities/retake_request.dart';
import '../../domain/upload/upload_failure.dart';
import '../../presentation/screens/auth/splash_screen.dart';
import '../../presentation/screens/auth/auth_screen.dart';
import '../../presentation/screens/auth/otp_screen.dart';
import '../../presentation/screens/projects/projects_screen.dart';
import '../../presentation/screens/projects/create_project_screen.dart';
import '../../presentation/screens/projects/preview_gallery_screen.dart';
import '../../presentation/screens/capture/pre_capture_screen.dart';
import '../../presentation/screens/capture/permissions_screen.dart';
import '../../presentation/screens/capture/level_a_intro_screen.dart';
import '../../presentation/screens/capture/level_b_intro_screen.dart';
import '../../presentation/screens/capture/level_c_intro_screen.dart';
import '../../presentation/screens/capture/capture_screen.dart';
import '../../presentation/screens/capture/level_review_grid_screen.dart';
import '../../presentation/screens/capture/level_a_complete_screen.dart';
import '../../presentation/screens/capture/level_complete_screen.dart';
import '../../presentation/screens/capture/capture_summary_screen.dart';
import '../../presentation/screens/capture/uploading_screen.dart';
import '../../presentation/screens/capture/upload_failed_screen.dart';
import '../../presentation/screens/capture/processing_screen.dart';
import '../../presentation/screens/capture/model_ready_screen.dart';
import '../../presentation/screens/capture/ar_preview_screen.dart';
import 'auth_router_notifier.dart';
import 'flow_back.dart';
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

  /// Staff-only per-project Preview gallery. `:id` = the project id.
  static const previewGallery = '/admin/projects/:id/preview';
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
  static const uploadFailed = '/upload/failed';
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
  static const previewGallery = 'previewGallery';
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
  static const uploadFailed = 'uploadFailed';
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
GoRouter createAppRouter(AuthRouterNotifier authNotifier, [Ref? ref]) {
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
        builder: (_, __) => const FlowBackScope(child: OtpScreen()),
      ),
      GoRoute(
        path: AppRoutes.projects,
        name: AppRouteNames.projects,
        builder: (_, __) => const ProjectsScreen(),
      ),
      GoRoute(
        path: AppRoutes.createProject,
        name: AppRouteNames.createProject,
        builder: (_, __) => const FlowBackScope(child: CreateProjectScreen()),
      ),
      // Staff-only per-project Preview gallery. Reached via push (hardware back
      // pops to Projects); FlowBackScope + the screen's AppBar arrow both funnel
      // through navigateBack so a go()-replaced entry can't exit the app either.
      GoRoute(
        path: AppRoutes.previewGallery,
        name: AppRouteNames.previewGallery,
        builder: (context, state) => FlowBackScope(
          child: PreviewGalleryScreen(
            projectId: state.pathParameters['id'] ?? '',
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.preCapture,
        name: AppRouteNames.preCapture,
        builder: (_, __) => const FlowBackScope(child: PreCaptureScreen()),
      ),
      GoRoute(
        path: AppRoutes.permissions,
        name: AppRouteNames.permissions,
        builder: (_, __) => const FlowBackScope(child: PermissionsScreen()),
      ),
      // Level A — dedicated Eye Ring intro (animation + rules + Begin/Skip).
      GoRoute(
        path: AppRoutes.levelAIntro,
        name: AppRouteNames.levelAIntro,
        builder: (_, __) => const FlowBackScope(child: LevelAIntroScreen()),
      ),
      GoRoute(
        path: AppRoutes.levelACapture,
        name: AppRouteNames.levelACapture,
        // Optionally entered in RETAKE mode: Review passes a [RetakeRequest] via
        // `extra` to force the active target to one segment. A normal entry has
        // no extra (null → standard guided capture).
        builder: (context, state) => CaptureScreen(
          levelLabel: 'A',
          levelName: 'Eye Ring',
          nextRoute: AppRoutes.levelAReview,
          retakeRequest: state.extra is RetakeRequest
              ? state.extra! as RetakeRequest
              : null,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelAReview,
        name: AppRouteNames.levelAReview,
        builder: (_, __) => const LevelReviewGridScreen(
          levelLabel: 'A',
          levelName: 'Eye Ring',
          nextRoute: AppRoutes.levelAComplete,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelAComplete,
        name: AppRouteNames.levelAComplete,
        // TODO(capture): supply the REAL summary from the aggregated Level A
        // result (same source as the in-capture progress meter / ring map).
        // accepted/coveragePct/rejected are placeholders until the
        // completion-summary aggregation lands; the TARGET comes from the real
        // config × variant resolver so the copy always names the true count.
        builder: (context, _) => FlowBackScope(
          child: Consumer(
            builder: (context, ref, _) {
              final isMeshy = ref.watch(captureShapeModeProvider).isMeshy;
              final target = effectiveSegmentsFor(
                ref.watch(effectiveCaptureConfigProvider),
                ref.watch(captureFlowVariantProvider),
                'mid',
              );
              // Meshy is a SINGLE ring: Level A is the whole capture, so its CTA
              // continues to the Summary (whose gate still guards it), not to a
              // Level B that does not exist in this mode.
              return LevelACompleteScreen(
                summary: LevelASummary(
                  accepted: target - 2,
                  target: target,
                  coveragePct: 92,
                  rejected: 1,
                ),
                nextLabel: isMeshy ? 'Continue' : null,
                onStartLevelB: () => context.go(
                  isMeshy ? AppRoutes.captureSummary : AppRoutes.levelBIntro,
                ),
                onReview: () => context.push(AppRoutes.levelAReview),
                onDoneExit: () => context.go(AppRoutes.projects),
              );
            },
          ),
        ),
      ),
      // Level B — dedicated Top Ring intro (tilt-down rule + Begin/Skip),
      // mirroring the Level A intro pattern.
      GoRoute(
        path: AppRoutes.levelBIntro,
        name: AppRouteNames.levelBIntro,
        redirect: (_, __) => _postLevelAGuardRedirect(ref, isLevelC: false),
        builder: (_, __) => const FlowBackScope(child: LevelBIntroScreen()),
      ),
      GoRoute(
        path: AppRoutes.levelBCapture,
        name: AppRouteNames.levelBCapture,
        redirect: (_, __) => _postLevelAGuardRedirect(ref, isLevelC: false),
        // Reuses the Level A capture screen (6A), driven by Level B's label +
        // tuned top-ring instruction copy. Analytics `level` is derived from
        // levelLabel ('B'), so the capture funnel is tagged level=B automatically.
        // Optionally entered in RETAKE mode from Review (RetakeRequest via `extra`).
        builder: (context, state) => CaptureScreen(
          levelLabel: 'B',
          levelName: 'Top Ring',
          nextRoute: AppRoutes.levelBReview,
          instructions: kLevelBCaptureInstructions,
          retakeRequest:
              state.extra is RetakeRequest ? state.extra! as RetakeRequest : null,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelBReview,
        name: AppRouteNames.levelBReview,
        redirect: (_, __) => _postLevelAGuardRedirect(ref, isLevelC: false),
        builder: (_, __) => const LevelReviewGridScreen(
          levelLabel: 'B',
          levelName: 'Top Ring',
          nextRoute: AppRoutes.levelBComplete,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelBComplete,
        name: AppRouteNames.levelBComplete,
        redirect: (_, __) => _postLevelAGuardRedirect(ref, isLevelC: false),
        // FLOW-VARIANT FORK: with_bottom continues to Level C; without_bottom
        // is a 2-ring flow, so Level B is the FINAL ring — its CTA goes to the
        // Capture Summary (which the summary gate still guards) and its copy
        // must not promise a next ring. Built per-navigation so the live
        // variant decides; a null ref (standalone test router) keeps the
        // legacy 3-ring wiring.
        builder: (_, __) {
          final variant = ref == null
              ? CaptureFlowVariant.withBottom
              : ref.read(captureFlowVariantProvider);
          final nextRoute = levelBCompleteNextRoute(variant);
          return FlowBackScope(
            child: LevelCompleteScreen(
              levelLabel: 'B',
              levelName: 'Top Ring',
              photosAccepted: 32,
              coveragePercent: 87,
              warningsCount: 1,
              nextRoute: nextRoute,
              nextLabel: nextRoute == AppRoutes.captureSummary
                  ? 'Continue'
                  : 'Start Level C',
              reviewRoute: AppRoutes.levelBReview,
            ),
          );
        },
      ),
      // Level C — dedicated Low Ring intro (lower-phone/tilt-up rule), reusing
      // the SAME shared LevelIntroScaffold as Level B (config-driven).
      // Every Level C route is UNREACHABLE in the without_bottom variant: the
      // guard bounces to the Capture Summary, whose own gate redirect then
      // routes an incomplete session to the first incomplete level's review —
      // so a stale link/deep-link can never open a ring the flow doesn't have.
      GoRoute(
        path: AppRoutes.levelCIntro,
        name: AppRouteNames.levelCIntro,
        redirect: (_, __) => _postLevelAGuardRedirect(ref, isLevelC: true),
        builder: (_, __) => const FlowBackScope(child: LevelCIntroScreen()),
      ),
      GoRoute(
        path: AppRoutes.levelCCapture,
        name: AppRouteNames.levelCCapture,
        redirect: (_, __) => _postLevelAGuardRedirect(ref, isLevelC: true),
        // Reuses the shared capture screen (6A/6B), driven by Level C's label +
        // tuned low-ring instruction copy. Analytics `level` is derived from
        // levelLabel ('C'), so the capture funnel is tagged level=C automatically.
        // The pitch band (Bottom Ring 'low') is selected per-level via
        // pitchBandIdForLevel — the tilt meter + shutter gate already target it.
        // Optionally entered in RETAKE mode from Review (RetakeRequest via `extra`).
        builder: (context, state) => CaptureScreen(
          levelLabel: 'C',
          levelName: 'Low Ring',
          nextRoute: AppRoutes.levelCReview,
          instructions: kLevelCCaptureInstructions,
          retakeRequest:
              state.extra is RetakeRequest ? state.extra! as RetakeRequest : null,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelCReview,
        name: AppRouteNames.levelCReview,
        redirect: (_, __) => _postLevelAGuardRedirect(ref, isLevelC: true),
        builder: (_, __) => const LevelReviewGridScreen(
          levelLabel: 'C',
          levelName: 'Low Ring',
          nextRoute: AppRoutes.levelCComplete,
        ),
      ),
      GoRoute(
        path: AppRoutes.levelCComplete,
        name: AppRouteNames.levelCComplete,
        redirect: (_, __) => _postLevelAGuardRedirect(ref, isLevelC: true),
        builder: (_, __) => const FlowBackScope(
          child: LevelCompleteScreen(
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
      ),
      GoRoute(
        path: AppRoutes.captureSummary,
        name: AppRouteNames.captureSummary,
        // The final completion gate: Summary is reachable ONLY when every
        // configured level is complete. A locked attempt is bounced to the first
        // incomplete level's review (and reports which levels remain) rather than
        // crashing or silently advancing. `ref` is absent in tests that build the
        // router standalone → the gate is not enforced there (each screen still
        // gates its own Continue).
        redirect: (context, state) =>
            _summaryGateRedirect(ref, state.matchedLocation),
        builder: (_, __) => const CaptureSummaryScreen(),
      ),
      GoRoute(
        path: AppRoutes.uploading,
        name: AppRouteNames.uploading,
        builder: (_, __) => const UploadingScreen(),
      ),
      GoRoute(
        path: AppRoutes.uploadFailed,
        name: AppRouteNames.uploadFailed,
        // Screen 9F — the upload-failure destination. The classified failure rides
        // in via `extra`; a null/garbled extra (deep-link / refresh) degrades to
        // the safe generic `unknown` state (see UploadFailedScreen).
        builder: (context, state) => UploadFailedScreen(
          failure: state.extra is UploadErrorCategory
              ? state.extra! as UploadErrorCategory
              : UploadErrorCategory.unknown,
        ),
      ),
      GoRoute(
        path: AppRoutes.processing,
        name: AppRouteNames.processing,
        builder: (_, __) => const FlowBackScope(child: ProcessingScreen()),
      ),
      GoRoute(
        path: AppRoutes.modelReady,
        name: AppRouteNames.modelReady,
        builder: (_, __) => const FlowBackScope(child: ModelReadyScreen()),
      ),
      GoRoute(
        path: AppRoutes.arPreview,
        name: AppRouteNames.arPreview,
        builder: (_, __) => const FlowBackScope(child: ArPreviewScreen()),
      ),
    ],
  );
}

/// The pure no-Level-C decision for a flow [variant]: without_bottom has no
/// Bottom Ring, so every Level C route bounces to the Capture Summary (whose
/// own gate redirect sends an incomplete session on to the first incomplete
/// level's review). with_bottom → null (allow). Side-effect-free — directly
/// unit-testable, mirroring [summaryGateRedirectTarget].
String? levelCRedirectForVariant(CaptureFlowVariant variant) =>
    variant == CaptureFlowVariant.withoutBottom
        ? AppRoutes.captureSummary
        : null;

/// The pure Level-B-complete fork for a flow [variant]: with_bottom continues
/// to the Level C intro; without_bottom ends guided capture at B and continues
/// to the Capture Summary.
String levelBCompleteNextRoute(CaptureFlowVariant variant) =>
    variant == CaptureFlowVariant.withoutBottom
        ? AppRoutes.captureSummary
        : AppRoutes.levelCIntro;

/// Router guard for a ring AFTER Level A (Level B or C). Meshy is a SINGLE Eye
/// ring, so ANY Level B/C route bounces to the Summary (whose own gate redirect
/// then routes an incomplete session to the first incomplete level's review);
/// otherwise the Level-C-only rule applies (Level B is always reachable in the
/// full flow). A null [ref] (router built without provider access, e.g. a focused
/// test) never blocks — same policy as the summary gate.
String? _postLevelAGuardRedirect(Ref? ref, {required bool isLevelC}) {
  if (ref == null) return null;
  if (ref.read(captureShapeModeProvider).isMeshy) {
    return AppRoutes.captureSummary;
  }
  return isLevelC
      ? levelCRedirectForVariant(ref.read(captureFlowVariantProvider))
      : null;
}

/// Enforces the final completion gate at the Summary entry. Returns null (allow)
/// when the gate is unlocked — emitting the once-per-transition unlock milestone —
/// or the first incomplete level's review route (block) after logging the blocked
/// attempt with the remaining levels. A null [ref] (router built without provider
/// access, e.g. a focused test) never blocks.
String? _summaryGateRedirect(Ref? ref, String matchedLocation) {
  if (ref == null || matchedLocation != AppRoutes.captureSummary) return null;
  final gate = ref.read(completionGateProvider);
  final sessionId = ref.read(captureLevelSessionProvider)?.sessionId ?? '';
  final analytics = ref.read(summaryGateAnalyticsProvider.notifier);
  if (gate.isUnlocked) {
    analytics.syncUnlockMilestone(gate, sessionId: sessionId);
  } else {
    analytics.logBlockedAttempt(gate, sessionId: sessionId);
  }
  return summaryGateRedirectTarget(gate);
}

/// The pure redirect decision for the Summary route: null (allow) when the gate
/// is unlocked, else the first still-incomplete level's review route (the
/// appropriate step to send the user back to). Falls back to Projects if the gate
/// somehow reports no levels. Side-effect-free — the analytics live in the router
/// closure — so it is directly unit-testable.
String? summaryGateRedirectTarget(SummaryGate gate) {
  if (gate.isUnlocked) return null;
  final firstIncomplete = gate.incompleteLevelCodes.isEmpty
      ? null
      : captureLevelFromLabel(gate.incompleteLevelCodes.first);
  return firstIncomplete == null
      ? AppRoutes.projects
      : _reviewRouteForLevelCode(firstIncomplete);
}

/// The review grid route for a guided-capture level — the gate's bounce target.
String _reviewRouteForLevelCode(CaptureLevel level) => switch (level) {
      CaptureLevel.a => AppRoutes.levelAReview,
      CaptureLevel.b => AppRoutes.levelBReview,
      CaptureLevel.c => AppRoutes.levelCReview,
    };

/// The app router, rebuilt whenever the auth notifier instance changes.
/// `refreshListenable` handles intra-session auth changes without a rebuild.
final appRouterProvider = Provider<GoRouter>((ref) {
  final notifier = ref.watch(authRouterNotifierProvider);
  final router = createAppRouter(notifier, ref);
  ref.onDispose(router.dispose);
  return router;
});
