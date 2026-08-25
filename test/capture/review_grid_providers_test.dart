// test/capture/review_grid_providers_test.dart
//
// Unit tests for the Screen 7A review-grid filter providers. Pure provider tests
// via ProviderContainer (no widget pump). The registry is keyed by PitchBand.id
// string (the repo has no PitchLevel enum), so levels are: eye = "mid",
// overhead = "high", table = "low".
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/review_grid_providers.dart';
import 'package:recapture/domain/entities/review_grid_filter.dart';

// Reuse the canonical ledger fixture builders rather than redefining them.
import 'level_capture_ledger_test.dart' show makeAccepted, makeWarned;

const eye = 'mid';
const overhead = 'high';
const table = 'low';

void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('reviewGridFilteredPhotosProvider', () {
    test('1. filter = all returns every accepted photo', () {
      final c = makeContainer();
      final ledger = c.read(levelCaptureLedgerRegistryProvider).ledgerFor(eye)
        ..recordAccepted(makeAccepted(framePath: 'a.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'b.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'c.jpg'))
        ..recordWarned(makeWarned(framePath: 'b.jpg'));
      expect(ledger.accepted.length, 3); // sanity

      expect(c.read(reviewGridFilteredPhotosProvider(eye)).length, 3);
    });

    test('2. filter = warned returns only photos with a matching warned path',
        () {
      final c = makeContainer();
      c.read(levelCaptureLedgerRegistryProvider).ledgerFor(eye)
        ..recordAccepted(makeAccepted(framePath: 'a.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'b.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'c.jpg'))
        ..recordWarned(makeWarned(framePath: 'b.jpg'));
      c.read(reviewGridFilterProvider(eye).notifier).state =
          ReviewGridFilter.warned;

      final result = c.read(reviewGridFilteredPhotosProvider(eye));
      expect(result.length, 1);
      expect(result.single.framePath, 'b.jpg');
    });

    test('3. filter = warned returns empty when no photos are warned', () {
      final c = makeContainer();
      c.read(levelCaptureLedgerRegistryProvider).ledgerFor(eye)
        ..recordAccepted(makeAccepted(framePath: 'a.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'b.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'c.jpg'));
      c.read(reviewGridFilterProvider(eye).notifier).state =
          ReviewGridFilter.warned;

      expect(c.read(reviewGridFilteredPhotosProvider(eye)), isEmpty);
    });

    test('4. filter = all returns empty when no photos are accepted', () {
      final c = makeContainer();
      // never seed the ledger
      expect(c.read(reviewGridFilteredPhotosProvider(eye)), isEmpty);
    });

    test('5. warned filter excludes accepted photos with no matching warning',
        () {
      final c = makeContainer();
      // 2 accepted, 1 warned whose path matches NEITHER accepted photo
      // (a warning for a frame that was ultimately rejected, not accepted).
      c.read(levelCaptureLedgerRegistryProvider).ledgerFor(eye)
        ..recordAccepted(makeAccepted(framePath: 'a.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'b.jpg'))
        ..recordWarned(makeWarned(framePath: 'c.jpg'));
      c.read(reviewGridFilterProvider(eye).notifier).state =
          ReviewGridFilter.warned;

      expect(c.read(reviewGridFilteredPhotosProvider(eye)), isEmpty);
    });

    test('6. different level keys produce independent filtered results', () {
      final c = makeContainer();
      final registry = c.read(levelCaptureLedgerRegistryProvider);
      registry.ledgerFor(eye)
        ..recordAccepted(makeAccepted(framePath: 'e1.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'e2.jpg'));
      registry.ledgerFor(overhead)
          .recordAccepted(makeAccepted(framePath: 'o1.jpg'));

      expect(c.read(reviewGridFilteredPhotosProvider(eye)).length, 2);
      expect(c.read(reviewGridFilteredPhotosProvider(overhead)).length, 1);
    });

    test('7. provider reflects ledger mutation only after invalidation', () {
      final c = makeContainer();
      // Empty initially.
      expect(c.read(reviewGridFilteredPhotosProvider(eye)), isEmpty);

      // Mutate the plain-Dart ledger directly — no Riverpod notification.
      c
          .read(levelCaptureLedgerRegistryProvider)
          .ledgerFor(eye)
          .recordAccepted(makeAccepted(framePath: 'a.jpg'));

      // Still the cached empty result (documents the manual-invalidation rule).
      expect(c.read(reviewGridFilteredPhotosProvider(eye)), isEmpty);

      c.invalidate(reviewGridFilteredPhotosProvider(eye));
      expect(c.read(reviewGridFilteredPhotosProvider(eye)).length, 1);
    });
  });

  group('reviewGridFilterProvider', () {
    test('8. defaults to ReviewGridFilter.all', () {
      final c = makeContainer();
      expect(c.read(reviewGridFilterProvider(eye)), ReviewGridFilter.all);
    });

    test('9. setting one level does not affect another level', () {
      final c = makeContainer();
      c.read(reviewGridFilterProvider(eye).notifier).state =
          ReviewGridFilter.warned;
      expect(c.read(reviewGridFilterProvider(eye)), ReviewGridFilter.warned);
      expect(
          c.read(reviewGridFilterProvider(overhead)), ReviewGridFilter.all);
    });
  });

  group('reviewGridWarnedCountProvider / reviewGridTotalCountProvider', () {
    test('10. warnedCount returns correct count for a mixed seed', () {
      final c = makeContainer();
      c.read(levelCaptureLedgerRegistryProvider).ledgerFor(eye)
        ..recordAccepted(makeAccepted(framePath: 'a.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'b.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'c.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'd.jpg'))
        ..recordWarned(makeWarned(framePath: 'a.jpg'))
        ..recordWarned(makeWarned(framePath: 'c.jpg'));

      expect(c.read(reviewGridWarnedCountProvider(eye)), 2);
    });

    test('11. totalCount returns accepted count regardless of filter', () {
      final c = makeContainer();
      c.read(levelCaptureLedgerRegistryProvider).ledgerFor(eye)
        ..recordAccepted(makeAccepted(framePath: 'a.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'b.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'c.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'd.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'e.jpg'));

      expect(c.read(reviewGridTotalCountProvider(eye)), 5);
      c.read(reviewGridFilterProvider(eye).notifier).state =
          ReviewGridFilter.warned;
      expect(c.read(reviewGridTotalCountProvider(eye)), 5);
    });

    test('12. warnedCount returns 0 for a level with no ledger created yet', () {
      final c = makeContainer();
      // `table` was never seeded — ledgerFor lazily creates an empty ledger.
      expect(c.read(reviewGridWarnedCountProvider(table)), 0);
    });
  });
}
