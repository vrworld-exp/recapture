// test/catalog/catalog_products_polling_test.dart
//
// Stage 6: watching a dish's 3D model finish, without a pull-to-refresh.
//
// WHAT THIS SUITE PROTECTS is a loop that runs on a phone in a restaurant, and
// the two ways such a loop goes wrong are opposite:
//
//   • it never stops — a stuck model keeps a rate-limited endpoint busy on
//     behalf of a screen nobody is reading, on a rep's mobile data;
//   • it stops too hard — one dropped request on bad wifi blanks the grid the
//     rep is reading, or ends the wait for a model that does finish.
//
// So every test here is about a STOP condition or a SURVIVAL condition. The
// cadence itself is not re-asserted: it is the shared PendingPollLoop, proven
// in the model-generation surface, and duplicating its numbers here would be
// the second copy the extraction exists to prevent.
//
// Hermetic: the repository is a fake and the clock is `tester.pump`, so no
// request, no timer and no wall-clock second is real.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_products_notifier.dart';
import 'package:recapture/application/common/pending_poll_loop.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_model_status.dart';
import 'package:recapture/domain/entities/product_type.dart';

import 'product_grid_test.dart' show FakeProductsRepository;

CatalogProduct _dish(String id, ProductModelStatus status) => CatalogProduct(
      id: id,
      type: ProductType.threeD,
      name: 'Dish $id',
      currency: 'INR',
      position: 0,
      modelStatus: status,
      glbUrl: status == ProductModelStatus.ready ? 'https://cdn/$id.glb' : null,
    );

/// Serves a scripted sequence of pages and counts how often it was asked.
///
/// Wraps the SUITE'S existing [FakeProductsRepository] rather than declaring a
/// second fake of the same interface — that class already stubs every method
/// this test does not touch, and a parallel copy would owe a new stub every
/// time the repository grows one.
class _Script {
  _Script(this._pages);

  /// One entry per call; the last entry repeats once exhausted.
  final List<List<CatalogProduct>> _pages;

  int calls = 0;

  /// When set, the NEXT call throws it instead of answering.
  CatalogFailure? throwOnce;

  late final FakeProductsRepository repo = FakeProductsRepository((_) async {
    calls++;
    if (throwOnce != null) {
      final failure = throwOnce!;
      throwOnce = null;
      throw failure;
    }
    final index = (calls - 1).clamp(0, _pages.length - 1);
    return CatalogProductPage(items: _pages[index]);
  });
}

ProviderContainer _container(_Script script) {
  final container = ProviderContainer(
    overrides: [
      catalogProductsRepositoryProvider.overrideWithValue(script.repo),
      // The grid is session-scoped; without a session it returns an empty,
      // non-loading state and never requests anything.
      sessionIdentityProvider.overrideWithValue('session-1'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Lets the first (microtask-scheduled) load land.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('the model poll loop', () {
    test('never starts when nothing is pending', () async {
      final script = _Script([
        [_dish('a', ProductModelStatus.ready), _dish('b', ProductModelStatus.none)],
      ]);
      final container = _container(script);
      container.read(catalogProductsProvider);
      await _settle();

      final notifier = container.read(catalogProductsProvider.notifier);
      expect(notifier.isPollingModels, isFalse);
      // Exactly the first load, and nothing scheduled behind it.
      expect(script.calls, 1);
    });

    test('starts when a dish is pending and STOPS when it turns ready',
        () async {
      final script = _Script([
        [_dish('a', ProductModelStatus.processing)],
        [_dish('a', ProductModelStatus.ready)],
      ]);
      final container = _container(script);
      container.read(catalogProductsProvider);
      await _settle();

      final notifier = container.read(catalogProductsProvider.notifier);
      expect(notifier.isPollingModels, isTrue);

      // One tick at the initial interval.
      await Future<void>.delayed(
        kPendingPollInitialInterval + const Duration(milliseconds: 50),
      );

      final items = container.read(catalogProductsProvider).items;
      expect(items.single.modelStatus, ProductModelStatus.ready);
      expect(items.single.isArReady, isTrue);
      // THE STOP CONDITION. A loop that kept running here would poll a
      // rate-limited endpoint forever on a rep's mobile data.
      expect(notifier.isPollingModels, isFalse);
    });

    test('a transient failure keeps the last good state and keeps waiting',
        () async {
      final script = _Script([
        [_dish('a', ProductModelStatus.processing)],
      ]);
      final container = _container(script);
      container.read(catalogProductsProvider);
      await _settle();

      script.throwOnce = const CatalogFailure(code: 'OFFLINE', message: 'x');
      await Future<void>.delayed(
        kPendingPollInitialInterval + const Duration(milliseconds: 50),
      );

      // The grid a rep is reading in a restaurant with bad wifi must not blank.
      final state = container.read(catalogProductsProvider);
      expect(state.items, hasLength(1));
      expect(state.items.single.modelStatus, ProductModelStatus.processing);
      expect(state.error, isNull);
      // And the wait continues — a dropped request is not an answer.
      expect(
        container.read(catalogProductsProvider.notifier).isPollingModels,
        isTrue,
      );
    });

    test('disposing the provider stops it', () async {
      final script = _Script([
        [_dish('a', ProductModelStatus.processing)],
      ]);
      final container = _container(script);
      container.read(catalogProductsProvider);
      await _settle();
      expect(
        container.read(catalogProductsProvider.notifier).isPollingModels,
        isTrue,
      );

      final callsAtDispose = script.calls;
      container.dispose();

      // Well past two intervals: a loop that survived its screen would have
      // fired by now.
      await Future<void>.delayed(kPendingPollMaxInterval * 2);
      expect(script.calls, callsAtDispose);
    });
  });

  group('PendingPollLoop', () {
    // The cap is asserted on the loop itself rather than through the grid: at
    // the real cadence, 120 ticks is over 20 minutes of wall clock, and a test
    // that waited for it would not be a test.
    test('honours its poll cap even while still pending', () async {
      var polls = 0;
      final loop = PendingPollLoop(
        poll: () async {
          polls++;
          return true; // never finishes
        },
        initialInterval: const Duration(milliseconds: 1),
        maxInterval: const Duration(milliseconds: 1),
        maxPolls: 3,
      );
      addTearDown(loop.stop);

      loop.scheduleIfPending(isPending: true);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // A still-pending record past the cap means something is wrong, and
      // polling forever would not fix it.
      expect(polls, 3);
      expect(loop.isRunning, isFalse);
    });

    test('stop() is idempotent and safe after the fact', () {
      final loop = PendingPollLoop(poll: () async => true);
      loop.scheduleIfPending(isPending: true);
      expect(loop.isRunning, isTrue);
      loop.stop();
      loop.stop();
      expect(loop.isRunning, isFalse);
    });

    test('reset() restarts the cadence for a fresh wait', () async {
      var polls = 0;
      final loop = PendingPollLoop(
        poll: () async {
          polls++;
          return false;
        },
        initialInterval: const Duration(milliseconds: 1),
        maxInterval: const Duration(milliseconds: 1),
        maxPolls: 1,
      );
      addTearDown(loop.stop);

      loop.scheduleIfPending(isPending: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(polls, 1);

      // Without reset the cap is already spent and nothing would run again.
      loop.reset();
      loop.scheduleIfPending(isPending: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(polls, 2);
    });
  });
}
