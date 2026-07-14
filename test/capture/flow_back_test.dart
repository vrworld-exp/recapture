// test/capture/flow_back_test.dart
//
// The guided flow's BACK behavior (lib/app/routes/flow_back.dart). Flow
// navigation uses context.go(), which replaces the page stack — so the system
// back key/gesture and the AppBar arrows must resolve an EXPLICIT previous
// screen instead of popping (there is nothing to pop; a "successful" pop
// would exit the app mid-flow):
//   - flowBackRouteFor: the pure location → previous-screen map;
//   - navigateBack: pop a genuinely pushed route when one exists, else go()
//     to the mapped screen;
//   - FlowBackScope: routes the system back key through navigateBack.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/app/routes/flow_back.dart';

void main() {
  group('flowBackRouteFor (pure map)', () {
    test('walks the guided flow backwards, one screen at a time', () {
      expect(flowBackRouteFor(AppRoutes.preCapture), AppRoutes.projects);
      expect(flowBackRouteFor(AppRoutes.permissions), AppRoutes.preCapture);
      expect(flowBackRouteFor(AppRoutes.levelAIntro), AppRoutes.permissions);
      expect(flowBackRouteFor(AppRoutes.levelAReview), AppRoutes.levelACapture);
      expect(
          flowBackRouteFor(AppRoutes.levelAComplete), AppRoutes.levelAReview);
      expect(flowBackRouteFor(AppRoutes.levelBIntro), AppRoutes.levelAComplete);
      expect(flowBackRouteFor(AppRoutes.levelBReview), AppRoutes.levelBCapture);
      expect(
          flowBackRouteFor(AppRoutes.levelBComplete), AppRoutes.levelBReview);
      expect(flowBackRouteFor(AppRoutes.levelCIntro), AppRoutes.levelBComplete);
      expect(flowBackRouteFor(AppRoutes.levelCReview), AppRoutes.levelCCapture);
      expect(
          flowBackRouteFor(AppRoutes.levelCComplete), AppRoutes.levelCReview);
      expect(flowBackRouteFor(AppRoutes.otpVerify), AppRoutes.auth);
      expect(flowBackRouteFor(AppRoutes.createProject), AppRoutes.projects);
      expect(flowBackRouteFor(AppRoutes.arPreview), AppRoutes.modelReady);
    });

    test('home/terminal screens have no mapping (platform default = leave app)',
        () {
      expect(flowBackRouteFor(AppRoutes.projects), isNull);
      expect(flowBackRouteFor(AppRoutes.auth), isNull);
      expect(flowBackRouteFor(AppRoutes.splash), isNull);
    });

    test('capture + own-PopScope screens are deliberately unmapped', () {
      // Capture: Save & Exit owns back. Summary/upload: their guards own it.
      expect(flowBackRouteFor(AppRoutes.levelACapture), isNull);
      expect(flowBackRouteFor(AppRoutes.levelBCapture), isNull);
      expect(flowBackRouteFor(AppRoutes.levelCCapture), isNull);
      expect(flowBackRouteFor(AppRoutes.captureSummary), isNull);
      expect(flowBackRouteFor(AppRoutes.uploading), isNull);
      expect(flowBackRouteFor(AppRoutes.uploadFailed), isNull);
    });
  });

  group('FlowBackScope + navigateBack (routed)', () {
    // A minimal router over real AppRoutes paths: every screen is a labeled
    // stub; the screen under test is wrapped exactly as createAppRouter does.
    GoRouter buildRouter(String initialLocation) {
      Widget stub(String label) => Scaffold(body: Text(label));
      return GoRouter(
        initialLocation: initialLocation,
        routes: [
          GoRoute(
            path: AppRoutes.projects,
            builder: (_, __) => stub('PROJECTS'),
          ),
          GoRoute(
            path: AppRoutes.preCapture,
            builder: (_, __) => const FlowBackScope(
              child: Scaffold(body: Text('PRE_CAPTURE')),
            ),
          ),
          GoRoute(
            path: AppRoutes.permissions,
            builder: (_, __) => FlowBackScope(
              child: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => navigateBack(context),
                    child: const Text('PERMISSIONS_BACK_ARROW'),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.levelAReview,
            builder: (_, __) => const FlowBackScope(
              child: Scaffold(body: Text('REVIEW_A')),
            ),
          ),
          GoRoute(
            path: AppRoutes.levelACapture,
            builder: (_, __) => stub('CAPTURE_A'),
          ),
        ],
      );
    }

    Future<GoRouter> pump(WidgetTester tester, String initialLocation) async {
      final router = buildRouter(initialLocation);
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      return router;
    }

    /// The system back key/gesture as the engine delivers it.
    Future<void> systemBack(WidgetTester tester) async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    testWidgets(
        'system back on a go()-navigated flow screen lands on the mapped '
        'previous screen instead of exiting the app', (tester) async {
      await pump(tester, AppRoutes.preCapture);
      expect(find.text('PRE_CAPTURE'), findsOneWidget);

      await systemBack(tester);

      expect(find.text('PROJECTS'), findsOneWidget);
      expect(find.text('PRE_CAPTURE'), findsNothing);
    });

    testWidgets('review → system back lands on the level capture screen',
        (tester) async {
      await pump(tester, AppRoutes.levelAReview);
      await systemBack(tester);
      expect(find.text('CAPTURE_A'), findsOneWidget);
    });

    testWidgets('AppBar-arrow path (navigateBack) uses the same mapping',
        (tester) async {
      await pump(tester, AppRoutes.permissions);

      await tester.tap(find.text('PERMISSIONS_BACK_ARROW'));
      await tester.pumpAndSettle();

      expect(find.text('PRE_CAPTURE'), findsOneWidget);
    });

    testWidgets('a genuinely pushed route pops instead of using the map',
        (tester) async {
      final router = await pump(tester, AppRoutes.preCapture);

      // Push review ON TOP of pre-capture (like retake pushes capture).
      router.push(AppRoutes.levelAReview);
      await tester.pumpAndSettle();
      expect(find.text('REVIEW_A'), findsOneWidget);

      await systemBack(tester);

      // Popped back to what pushed it — NOT go()'d to the mapped capture.
      expect(find.text('PRE_CAPTURE'), findsOneWidget);
      expect(find.text('CAPTURE_A'), findsNothing);
    });

    testWidgets('navigateBack without a GoRouter degrades to Navigator pop',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => navigateBack(context),
                      child: const Text('BACK'),
                    ),
                  ),
                ),
              )),
              child: const Text('PUSH'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('PUSH'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('BACK'));
      await tester.pumpAndSettle();

      expect(find.text('PUSH'), findsOneWidget);
    });
  });
}
