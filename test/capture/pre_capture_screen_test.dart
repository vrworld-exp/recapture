// test/capture/pre_capture_screen_test.dart
//
// Widget tests for the Pre-Capture Checklist screen (Screen 4). The screen +
// its pieces (ChecklistItem model, ChecklistItemTile with an info affordance,
// the tooltip bottom sheet, acknowledgement gating, sticky Start CTA) already
// existed; these tests pin its behaviour against the acceptance criteria:
// render-all-items, tap-opens-the-correct-tooltip, gating, and navigate-once.
//
// The screen is ACKNOWLEDGEMENT-GATED (the app's chosen design): Start is
// disabled until every required item is checked. There is no l10n in this repo
// (no lib/l10n) and no raster/SVG asset pipeline — illustrations are Material
// IconData — so the "missing asset" case has no failure mode to exercise.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/checklist_item.dart';
import 'package:recapture/presentation/screens/capture/pre_capture_screen.dart';
import 'package:recapture/presentation/widgets/checklist_item_tile.dart';
import 'package:recapture/presentation/widgets/checklist_tooltip_sheet.dart';

// A small, explicit list so "renders the list it is given" is unambiguous.
const _items = <ChecklistItem>[
  ChecklistItem(
    id: 'x',
    icon: Icons.star,
    title: 'Title X',
    shortDescription: 'Desc X',
    tooltipContent: 'Extended guidance for X.',
  ),
  ChecklistItem(
    id: 'y',
    icon: Icons.bolt,
    title: 'Title Y',
    shortDescription: 'Desc Y',
    tooltipContent: 'Extended guidance for Y.',
    isRequired: false,
  ),
];

/// No-Hive [ActiveSessionBox]: the test host has no initialized Hive, and a
/// real box open poisons the test zone with Hive's internal unlistened future.
class _FakeSessionBox extends ActiveSessionBox {
  @override
  Future<ActiveSession?> read() async => null;
}

/// Pumps the screen on its own (no router) — fine for everything except the
/// Start-navigation tests.
Future<void> _pumpPlain(WidgetTester tester, {List<ChecklistItem>? items}) async {
  // ProviderScope: the screen reads the flow-variant provider (Riverpod).
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: AppTheme.dark,
      home: items == null
          ? PreCaptureScreen(sessionBox: _FakeSessionBox())
          : PreCaptureScreen(items: items, sessionBox: _FakeSessionBox()),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Counts route pushes so "navigates exactly once" can be proven (a `go()` to
/// the same location is a no-op → no extra push; a stray `push()` would show up).
class _PushSpy extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

/// Pumps the screen inside a minimal GoRouter with a stub `permissions` route,
/// so tapping Start performs real navigation. Returns the push spy.
Future<_PushSpy> _pumpRouter(WidgetTester tester) async {
  final spy = _PushSpy();
  final router = GoRouter(
    initialLocation: AppRoutes.preCapture,
    observers: [spy],
    routes: [
      GoRoute(
        path: AppRoutes.preCapture,
        name: AppRouteNames.preCapture,
        builder: (_, __) => PreCaptureScreen(sessionBox: _FakeSessionBox()),
      ),
      GoRoute(
        path: AppRoutes.permissions,
        name: AppRouteNames.permissions,
        builder: (_, __) => const Scaffold(body: Text('PERMISSIONS')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp.router(theme: AppTheme.dark, routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return spy;
}

/// Checks every checkbox on screen (acknowledges all items) and settles.
Future<void> _acknowledgeAll(WidgetTester tester) async {
  final boxes = find.byType(Checkbox);
  for (var i = 0; i < boxes.evaluate().length; i++) {
    await tester.tap(boxes.at(i));
  }
  await tester.pumpAndSettle();
}

ElevatedButton _startButton(WidgetTester tester) =>
    tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Start Capture'));

void main() {
  // The tip surface's no-stacking guard is process-global; reset it so an
  // undismissed tip in one test can't block the next.
  setUp(debugResetChecklistTooltipGuard);

  group('rendering (content-driven)', () {
    testWidgets('renders every provided item: title + short description', (tester) async {
      await _pumpPlain(tester, items: _items);

      expect(find.byType(ChecklistItemTile), findsNWidgets(2));
      for (final item in _items) {
        expect(find.text(item.title), findsOneWidget);
        expect(find.text(item.shortDescription), findsOneWidget);
      }
    });

    testWidgets('renders the default checklist when no items are injected', (tester) async {
      await _pumpPlain(tester);
      expect(find.byType(ChecklistItemTile), findsNWidgets(defaultChecklistItems.length));
      expect(find.text(defaultChecklistItems.first.title), findsOneWidget);
    });

    testWidgets('empty list renders gracefully and leaves Start enabled (no crash)', (tester) async {
      await _pumpPlain(tester, items: const []);
      expect(tester.takeException(), isNull);
      expect(find.byType(ChecklistItemTile), findsNothing);
      // No required items → gate is vacuously satisfied → CTA usable.
      expect(_startButton(tester).onPressed, isNotNull);
    });
  });

  group('tooltip bottom sheet', () {
    testWidgets('tapping an item info affordance opens the sheet with THAT item content',
        (tester) async {
      await _pumpPlain(tester, items: _items);

      // Tooltip content is not on the tile…
      expect(find.text('Extended guidance for X.'), findsNothing);

      await tester.tap(find.byIcon(Icons.info_outline).first); // item X
      await tester.pumpAndSettle();

      // …it appears in the opened sheet, and it's X's content, not Y's.
      expect(find.text('Extended guidance for X.'), findsOneWidget);
      expect(find.text('Extended guidance for Y.'), findsNothing);
    });

    testWidgets('the sheet dismisses cleanly via its close button', (tester) async {
      await _pumpPlain(tester, items: _items);
      await tester.tap(find.byIcon(Icons.info_outline).first);
      await tester.pumpAndSettle();
      expect(find.text('Extended guidance for X.'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('Extended guidance for X.'), findsNothing);
    });
  });

  group('acknowledgement gating', () {
    testWidgets('Start is disabled until all required items are acknowledged', (tester) async {
      await _pumpPlain(tester); // 4 required default items
      expect(_startButton(tester).onPressed, isNull);

      await _acknowledgeAll(tester);
      expect(_startButton(tester).onPressed, isNotNull);
    });

    testWidgets('an optional item does not block the gate', (tester) async {
      // X required, Y optional. Acknowledging only X must enable Start.
      await _pumpPlain(tester, items: _items);
      expect(_startButton(tester).onPressed, isNull);

      await tester.tap(find.byType(Checkbox).first); // check X (required)
      await tester.pumpAndSettle();
      expect(_startButton(tester).onPressed, isNotNull);
    });
  });

  group('Start CTA navigation', () {
    testWidgets('disabled Start does not navigate', (tester) async {
      final spy = await _pumpRouter(tester);
      final before = spy.pushes;

      await tester.tap(find.text('Start Capture')); // disabled → no-op
      await tester.pumpAndSettle();

      expect(spy.pushes - before, 0);
      expect(find.text('PERMISSIONS'), findsNothing);
    });

    testWidgets('acknowledged Start navigates to permissions exactly once, even on double-tap',
        (tester) async {
      final spy = await _pumpRouter(tester);
      await _acknowledgeAll(tester);
      final before = spy.pushes;

      // Two rapid taps before settling — must still navigate just once.
      await tester.tap(find.text('Start Capture'));
      await tester.tap(find.text('Start Capture'));
      await tester.pumpAndSettle();

      expect(find.text('PERMISSIONS'), findsOneWidget);
      expect(spy.pushes - before, 1);
    });
  });

  group('accessibility & resilience', () {
    testWidgets('info affordance and close affordance expose tooltips', (tester) async {
      await _pumpPlain(tester, items: _items);
      expect(find.byTooltip('More info'), findsNWidgets(2)); // one per item
      await tester.tap(find.byIcon(Icons.info_outline).first);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close'), findsOneWidget);
    });

    testWidgets('no overflow under a large text scale', (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: PreCaptureScreen(sessionBox: _FakeSessionBox()),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
