// test/capture/precapture_analytics_test.dart
//
// Pins the two pre-capture funnel analytics events wired into the canonical
// Analytics layer:
//   - precapture_checklist_started — REACH metric, once per screen ENTRY
//     (initState), never on rebuilds; re-entry fires again.
//   - precapture_tip_opened — once per genuine tip open, carrying item_id and
//     the platform-derived presentation; reopen fires again; the no-stacking
//     guard collapses a rapid double-tap into one event.
//
// Events are captured via Analytics.testSink (the production sink is a debug
// no-op). Fire-and-forget is proven by a throwing sink that must not break the
// screen or the tip interaction.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/domain/entities/checklist_item.dart';
import 'package:recapture/presentation/screens/capture/pre_capture_screen.dart';
import 'package:recapture/presentation/widgets/checklist_tooltip_sheet.dart';
import 'package:recapture/utils/analytics.dart';

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

/// One captured emission.
typedef _Event = ({String name, Map<String, Object?> props});

void main() {
  late List<_Event> events;

  setUp(() {
    debugResetChecklistTooltipGuard(); // process-global no-stacking guard
    events = <_Event>[];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });

  tearDown(() {
    Analytics.testSink = null;
  });

  List<_Event> only(String name) =>
      events.where((e) => e.name == name).toList(growable: false);

  Future<void> pumpScreen(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark.copyWith(platform: platform),
      home: const PreCaptureScreen(items: _items),
    ));
    await tester.pumpAndSettle();
  }

  group('precapture_checklist_started', () {
    testWidgets('fires exactly once on screen entry', (tester) async {
      await pumpScreen(tester);
      expect(only(AnalyticsEvents.precaptureChecklistStarted), hasLength(1));
    });

    testWidgets('does NOT re-fire on rebuild (setState / checkbox toggle)',
        (tester) async {
      await pumpScreen(tester);
      expect(only(AnalyticsEvents.precaptureChecklistStarted), hasLength(1));

      // Toggling a checkbox rebuilds the screen via setState.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      // …and a forced re-pump (e.g. rotation) of the same State.
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: const PreCaptureScreen(items: _items),
      ));
      await tester.pumpAndSettle();

      expect(only(AnalyticsEvents.precaptureChecklistStarted), hasLength(1),
          reason: 'rebuild/rotation must not re-emit the reach event');
    });

    testWidgets('re-entering the screen fires again (per-entry reach)',
        (tester) async {
      await pumpScreen(tester);
      expect(only(AnalyticsEvents.precaptureChecklistStarted), hasLength(1));

      // Leave (dispose the State) then return (a fresh State → new entry).
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: Text('ELSEWHERE')),
      ));
      await tester.pumpAndSettle();
      await pumpScreen(tester);

      expect(only(AnalyticsEvents.precaptureChecklistStarted), hasLength(2));
    });

    testWidgets('carries no raw PII (no user_id / phone / email keys)',
        (tester) async {
      await pumpScreen(tester);
      final e = only(AnalyticsEvents.precaptureChecklistStarted).single;
      expect(e.props.keys, isNot(contains('user_id')));
      expect(e.props.keys, isNot(contains('phone')));
      expect(e.props.keys, isNot(contains('email')));
    });
  });

  group('precapture_tip_opened', () {
    testWidgets('opening an item tip fires once with its item_id + presentation',
        (tester) async {
      await pumpScreen(tester); // android → bottom_sheet
      await tester.tap(find.byIcon(Icons.info_outline).first); // item X
      await tester.pumpAndSettle();

      final tips = only(AnalyticsEvents.precaptureTipOpened);
      expect(tips, hasLength(1));
      expect(tips.single.props['item_id'], 'x');
      expect(tips.single.props['presentation'], 'bottom_sheet');
    });

    testWidgets('iOS presentation is reported as popover', (tester) async {
      await pumpScreen(tester, platform: TargetPlatform.iOS);
      await tester.tap(find.byIcon(Icons.info_outline).first);
      await tester.pumpAndSettle();

      final tips = only(AnalyticsEvents.precaptureTipOpened);
      expect(tips.single.props['presentation'], 'popover');
    });

    testWidgets('dismiss + reopen the same item fires twice (open count)',
        (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.info_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close)); // dismiss
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.info_outline).first); // reopen
      await tester.pumpAndSettle();

      final tips = only(AnalyticsEvents.precaptureTipOpened);
      expect(tips, hasLength(2));
      expect(tips.every((e) => e.props['item_id'] == 'x'), isTrue);
    });

    testWidgets('rapid double-tap opens one tip and fires one event',
        (tester) async {
      await pumpScreen(tester);
      final info = find.byIcon(Icons.info_outline).first;
      await tester.tap(info);
      // The first tap's sheet now covers the icon, so the second tap "misses" —
      // exactly the rapid double-tap the no-stacking guard must collapse to one.
      await tester.tap(info, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(only(AnalyticsEvents.precaptureTipOpened), hasLength(1));
    });

    testWidgets('distinct items report their own item_id', (tester) async {
      await pumpScreen(tester);
      await tester.tap(find.byIcon(Icons.info_outline).at(1)); // item Y
      await tester.pumpAndSettle();
      expect(only(AnalyticsEvents.precaptureTipOpened).single.props['item_id'], 'y');
    });
  });

  group('fire-and-forget resilience', () {
    testWidgets('a throwing analytics sink never breaks the screen or the tip',
        (tester) async {
      Analytics.testSink = (_, __) => throw StateError('analytics down');

      await pumpScreen(tester); // started emit throws internally → swallowed
      expect(tester.takeException(), isNull);
      expect(find.byType(PreCaptureScreen), findsOneWidget);

      await tester.tap(find.byIcon(Icons.info_outline).first);
      await tester.pumpAndSettle();
      // The tip still opened despite the throwing sink.
      expect(tester.takeException(), isNull);
      expect(find.text('Extended guidance for X.'), findsOneWidget);
    });
  });
}
