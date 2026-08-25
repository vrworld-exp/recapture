// test/capture/review_grid_filter_chips_test.dart
//
// Widget tests for ReviewGridFilterChips: label/count rendering, selection state,
// the warned-chip disabled-when-empty rule, tap → filter writes, and reactive
// updates. Levels are PitchBand.id strings (eye = "mid").
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/review_grid_providers.dart';
import 'package:recapture/domain/entities/review_grid_filter.dart';
import 'package:recapture/presentation/widgets/review_grid_filter_chips.dart';

import 'level_capture_ledger_test.dart' show makeAccepted, makeWarned;

const eye = 'mid';

final _allKey = const Key('review_grid_filter_chip_all');
final _warnedKey = const Key('review_grid_filter_chip_warned');

/// A registry whose [eye] ledger holds [accepted] accepted photos, the first
/// [warned] of which also carry a matching warning (warned ≤ accepted).
LevelCaptureLedgerRegistry seeded({int accepted = 0, int warned = 0}) {
  final r = LevelCaptureLedgerRegistry();
  final ledger = r.ledgerFor(eye);
  for (var i = 0; i < accepted; i++) {
    ledger.recordAccepted(makeAccepted(framePath: 'frame_$i.jpg', segmentIndex: i));
  }
  for (var i = 0; i < warned; i++) {
    ledger.recordWarned(makeWarned(framePath: 'frame_$i.jpg'));
  }
  return r;
}

/// Pumps the chips with [registry] overridden and an optional [initialFilter].
/// Returns the container so tests can read filter state after taps.
Future<ProviderContainer> pumpChips(
  WidgetTester tester, {
  required LevelCaptureLedgerRegistry registry,
  ReviewGridFilter? initialFilter,
}) async {
  final container = ProviderContainer(overrides: [
    levelCaptureLedgerRegistryProvider.overrideWithValue(registry),
  ]);
  addTearDown(container.dispose);
  if (initialFilter != null) {
    container.read(reviewGridFilterProvider(eye).notifier).state = initialFilter;
  }
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(body: ReviewGridFilterChips(levelId: eye)),
    ),
  ));
  return container;
}

ChoiceChip _chip(WidgetTester tester, Key key) =>
    tester.widget<ChoiceChip>(find.byKey(key));

void main() {
  group('ReviewGridFilterChips — rendering', () {
    testWidgets('13. renders both chips with correct count labels',
        (tester) async {
      await pumpChips(tester, registry: seeded(accepted: 3, warned: 1));
      expect(find.text('All (3)'), findsOneWidget);
      expect(find.text('Warned (1)'), findsOneWidget);
    });

    testWidgets('14. All chip is selected by default', (tester) async {
      await pumpChips(tester, registry: seeded(accepted: 3, warned: 1));
      expect(_chip(tester, _allKey).selected, isTrue);
      expect(_chip(tester, _warnedKey).selected, isFalse);
    });

    testWidgets('15. Warned chip is selected after filter set to warned',
        (tester) async {
      await pumpChips(
        tester,
        registry: seeded(accepted: 2, warned: 1),
        initialFilter: ReviewGridFilter.warned,
      );
      expect(_chip(tester, _warnedKey).selected, isTrue);
      expect(_chip(tester, _allKey).selected, isFalse);
    });

    testWidgets('16. Warned chip is disabled when warnedCount == 0',
        (tester) async {
      await pumpChips(tester, registry: seeded(accepted: 2, warned: 0));
      expect(_chip(tester, _warnedKey).onSelected, isNull);
      // The All chip stays enabled.
      expect(_chip(tester, _allKey).onSelected, isNotNull);
    });
  });

  group('ReviewGridFilterChips — tap interactions', () {
    testWidgets('17. tapping All sets the filter to all', (tester) async {
      final c = await pumpChips(
        tester,
        registry: seeded(accepted: 2, warned: 1),
        initialFilter: ReviewGridFilter.warned,
      );
      await tester.tap(find.byKey(_allKey));
      await tester.pump();
      expect(c.read(reviewGridFilterProvider(eye)), ReviewGridFilter.all);
    });

    testWidgets('18. tapping Warned (enabled) sets the filter to warned',
        (tester) async {
      final c = await pumpChips(tester, registry: seeded(accepted: 2, warned: 1));
      await tester.tap(find.byKey(_warnedKey));
      await tester.pump();
      expect(c.read(reviewGridFilterProvider(eye)), ReviewGridFilter.warned);
    });

    testWidgets('19. tapping disabled Warned (0 warned) does not change state',
        (tester) async {
      final c = await pumpChips(tester, registry: seeded(accepted: 2, warned: 0));
      await tester.tap(find.byKey(_warnedKey), warnIfMissed: false);
      await tester.pump();
      expect(c.read(reviewGridFilterProvider(eye)), ReviewGridFilter.all);
    });

    testWidgets('20. chip row updates reactively when the seed changes',
        (tester) async {
      // First: no warned photos → disabled, "Warned (0)".
      await pumpChips(tester, registry: seeded(accepted: 2, warned: 0));
      expect(find.text('Warned (0)'), findsOneWidget);
      expect(_chip(tester, _warnedKey).onSelected, isNull);

      // Re-pump with a registry that now has a warned photo.
      await pumpChips(tester, registry: seeded(accepted: 2, warned: 1));
      expect(find.text('Warned (1)'), findsOneWidget);
      expect(_chip(tester, _warnedKey).onSelected, isNotNull);
    });
  });
}
