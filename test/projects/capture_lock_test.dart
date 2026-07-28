// test/projects/capture_lock_test.dart
//
// The capture lock: while a 3D model is being built, you cannot START a new
// capture — and, just as importantly, a capture already under way is never
// interrupted.
//
// THE LOAD-BEARING TEST here is the last group. `redirect` runs on EVERY
// navigation, including moves inside the capture flow, so a lock that gated any
// route beyond the two entrances would throw a user who is thirty photos into a
// ring back to Projects the instant an unrelated generation started. Their
// photos survive on disk and the session resumes, but it reads as data loss.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/generation_tracker_notifier.dart';
import 'package:recapture/application/projects/live_projects_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/projects/projects_screen.dart';
import 'package:recapture/utils/analytics.dart';

// ── The pure decision ───────────────────────────────────────────────────────

void main() {
  tearDown(() => Analytics.testSink = null);

  group('captureLockRedirectFor (pure)', () {
    test('unlocked never redirects, whatever the destination', () {
      for (final loc in [
        AppRoutes.preCapture,
        AppRoutes.createProject,
        AppRoutes.levelACapture,
        AppRoutes.projects,
      ]) {
        expect(
          captureLockRedirectFor(location: loc, isLocked: false),
          isNull,
          reason: '$loc must be reachable when nothing is running',
        );
      }
    });

    test('locked blocks the two capture ENTRANCES', () {
      expect(
        captureLockRedirectFor(
          location: AppRoutes.preCapture,
          isLocked: true,
        ),
        AppRoutes.projects,
      );
      expect(
        captureLockRedirectFor(
          location: AppRoutes.createProject,
          isLocked: true,
        ),
        AppRoutes.projects,
      );
    });

    // The regression guard, as a pure assertion over every route the app has.
    test('locked blocks NOTHING else — no in-flow route is gated', () {
      const insideOrAfterCapture = [
        AppRoutes.permissions,
        AppRoutes.levelAIntro,
        AppRoutes.levelACapture,
        AppRoutes.levelAReview,
        AppRoutes.levelAComplete,
        AppRoutes.levelBIntro,
        AppRoutes.levelBCapture,
        AppRoutes.levelBReview,
        AppRoutes.levelBComplete,
        AppRoutes.levelCIntro,
        AppRoutes.levelCCapture,
        AppRoutes.levelCReview,
        AppRoutes.levelCComplete,
        AppRoutes.captureSummary,
        AppRoutes.uploading,
        AppRoutes.uploadFailed,
        AppRoutes.processing,
        AppRoutes.modelReady,
        AppRoutes.arPreview,
        AppRoutes.projects,
        AppRoutes.splash,
      ];
      for (final loc in insideOrAfterCapture) {
        expect(
          captureLockRedirectFor(location: loc, isLocked: true),
          isNull,
          reason: '$loc must NOT be gated — see the file header',
        );
      }
    });

    test('the gated set is exactly the two entrances', () {
      expect(
        kCaptureEntryLocations,
        unorderedEquals([AppRoutes.preCapture, AppRoutes.createProject]),
      );
    });
  });

  // ── The redirect, through a live router ───────────────────────────────────
  //
  // A real GoRouter running the app's REAL top-level redirect
  // ([appRedirectFor]) over labelled stub screens. Stubs rather than the app's
  // own builders because this is a routing test: building the real capture
  // screen would drag in the camera and its platform channels without telling
  // us anything more about where a navigation lands.
  group('appRedirectFor through a live router', () {
    final refProvider = Provider<Ref>((ref) => ref);

    Widget stub(String label) => Scaffold(body: Text(label));

    Future<GoRouter> pumpRouter(
      WidgetTester tester, {
      required bool locked,
      required String initialLocation,
    }) async {
      final container = ProviderContainer(overrides: [
        captureLockedProvider.overrideWithValue(locked),
      ]);
      addTearDown(container.dispose);
      final ref = container.read(refProvider);

      final router = GoRouter(
        initialLocation: initialLocation,
        redirect: (_, state) => appRedirectFor(
          location: state.matchedLocation,
          isAuthenticated: true,
          ref: ref,
        ),
        routes: [
          for (final (path, label) in const [
            (AppRoutes.projects, 'PROJECTS'),
            (AppRoutes.preCapture, 'PRE_CAPTURE'),
            (AppRoutes.createProject, 'CREATE_PROJECT'),
            (AppRoutes.levelACapture, 'LEVEL_A_CAPTURE'),
            (AppRoutes.levelAReview, 'LEVEL_A_REVIEW'),
            (AppRoutes.levelBCapture, 'LEVEL_B_CAPTURE'),
            (AppRoutes.captureSummary, 'CAPTURE_SUMMARY'),
            (AppRoutes.uploading, 'UPLOADING'),
            (AppRoutes.processing, 'PROCESSING'),
          ])
            GoRoute(path: path, builder: (_, __) => stub(label)),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('locked: pre-capture lands on Projects', (tester) async {
      await pumpRouter(
        tester,
        locked: true,
        initialLocation: AppRoutes.preCapture,
      );
      expect(find.text('PROJECTS'), findsOneWidget);
      expect(find.text('PRE_CAPTURE'), findsNothing);
    });

    testWidgets('locked: create-project lands on Projects', (tester) async {
      await pumpRouter(
        tester,
        locked: true,
        initialLocation: AppRoutes.createProject,
      );
      expect(find.text('PROJECTS'), findsOneWidget);
    });

    testWidgets('unlocked: both entrances open normally', (tester) async {
      final router = await pumpRouter(
        tester,
        locked: false,
        initialLocation: AppRoutes.preCapture,
      );
      expect(find.text('PRE_CAPTURE'), findsOneWidget);

      router.go(AppRoutes.createProject);
      await tester.pumpAndSettle();
      expect(find.text('CREATE_PROJECT'), findsOneWidget);
    });

    // NON-NEGOTIABLE REGRESSION. A generation starting elsewhere must never
    // throw a user out of a capture they are in the middle of.
    testWidgets('a user inside /capture/level-a is NOT redirected when locked',
        (tester) async {
      final router = await pumpRouter(
        tester,
        locked: true,
        initialLocation: AppRoutes.levelACapture,
      );
      expect(find.text('LEVEL_A_CAPTURE'), findsOneWidget);
      expect(find.text('PROJECTS'), findsNothing);

      // …and every onward move INSIDE the flow still works while locked.
      for (final (path, label) in const [
        (AppRoutes.levelAReview, 'LEVEL_A_REVIEW'),
        (AppRoutes.levelBCapture, 'LEVEL_B_CAPTURE'),
        (AppRoutes.captureSummary, 'CAPTURE_SUMMARY'),
        (AppRoutes.uploading, 'UPLOADING'),
        (AppRoutes.processing, 'PROCESSING'),
      ]) {
        router.go(path);
        await tester.pumpAndSettle();
        expect(
          find.text(label),
          findsOneWidget,
          reason: 'the lock must never interrupt a capture in progress',
        );
      }
    });

    testWidgets('a blocked entry is reported with the entrance',
        (tester) async {
      final events = <Map<String, Object?>>[];
      Analytics.testSink = (name, props) {
        if (name == 'capture_blocked_by_generation') events.add(props);
      };

      final router = await pumpRouter(
        tester,
        locked: true,
        initialLocation: AppRoutes.preCapture,
      );
      router.go(AppRoutes.createProject);
      await tester.pumpAndSettle();

      expect(events.map((e) => e['entry']), contains('pre_capture'));
      expect(events.map((e) => e['entry']), contains('create_project'));
    });
  });

  group('appRedirectFor (guard chain)', () {
    test('a null ref never blocks — the standalone-test escape hatch', () {
      // The escape hatch every other guard here has: a router built without
      // provider access must behave exactly as it did before this feature.
      expect(
        appRedirectFor(location: AppRoutes.preCapture, isAuthenticated: true),
        isNull,
      );
    });

    test('auth wins over the capture lock', () {
      // A signed-out user belongs on the auth screen, not on Projects — even
      // when a generation is running.
      final container = ProviderContainer(overrides: [
        captureLockedProvider.overrideWithValue(true),
      ]);
      addTearDown(container.dispose);
      final refProvider = Provider<Ref>((ref) => ref);

      expect(
        appRedirectFor(
          location: AppRoutes.preCapture,
          isAuthenticated: false,
          ref: container.read(refProvider),
        ),
        AppRoutes.auth,
      );
    });

    test('splash is never intercepted', () {
      expect(
        appRedirectFor(location: AppRoutes.splash, isAuthenticated: false),
        isNull,
      );
    });
  });

  // ── The UI affordance ─────────────────────────────────────────────────────

  group('ProjectsScreen capture CTAs', () {
    Widget app({required bool locked, bool empty = false}) {
      return ProviderScope(
        overrides: [
          captureLockedProvider.overrideWithValue(locked),
          projectsProvider
              .overrideWith(() => _FakeProjectsNotifier(empty: empty)),
          liveProjectsProvider.overrideWith(_FakeLiveProjectsNotifier.new),
          isStaffProvider.overrideWithValue(false),
          isAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: ProjectsScreen()),
      );
    }

    /// The draft card renders an indeterminate spinner, so pumpAndSettle would
    /// never settle — pump fixed frames instead.
    Future<void> pumpFrames(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('unlocked: create + resume are live, no notice',
        (tester) async {
      await tester.pumpWidget(app(locked: false));
      await pumpFrames(tester);

      expect(
        find.byKey(const Key('projects_capture_locked_notice')),
        findsNothing,
      );
      expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNotNull,
      );
      final resume = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Resume'),
      );
      expect(resume.onPressed, isNotNull);
    });

    testWidgets(
        'locked: both are DISABLED, not hidden, and the reason is shown',
        (tester) async {
      await tester.pumpWidget(app(locked: true));
      await pumpFrames(tester);

      // A silently dead button is the worst version of this — the explanation
      // is part of the feature.
      expect(
        find.text(
            'You can start a new capture once your 3D model is finished.'),
        findsOneWidget,
      );

      // Still present…
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Resume'), findsOneWidget);
      // …and inert.
      expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Resume'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('locked: the empty-state CTA is disabled too', (tester) async {
      // A first-time user whose only route into capture is this button must
      // not be left tapping a dead control with no explanation either.
      await tester.pumpWidget(app(locked: true, empty: true));
      await pumpFrames(tester);

      expect(
        find.text(
            'You can start a new capture once your 3D model is finished.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Start your first capture'),
            )
            .onPressed,
        isNull,
      );
    });
  });
}

/// Serves one resumable draft (or none) without repositories or Hive.
class _FakeProjectsNotifier extends ProjectsNotifier {
  _FakeProjectsNotifier({this.empty = false});
  final bool empty;

  @override
  Future<List<Project>> build() async => empty
      ? const []
      : [
          Project(
            id: 'p1',
            name: 'My vase',
            status: ProjectStatus.draft,
            updatedAt: DateTime(2026, 7, 27),
            totalPhotos: 12,
          ),
        ];
}

class _FakeLiveProjectsNotifier extends LiveProjectsNotifier {
  @override
  Future<LiveProjectsState> build() async =>
      const LiveProjectsState(items: [], nextCursor: null);
}
