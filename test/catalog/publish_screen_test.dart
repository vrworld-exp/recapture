// test/catalog/publish_screen_test.dart
//
// Publish (features 36-39, 52, 53, 68, 69).
//
// What this file exists to catch, in order of how badly the alternative goes:
//   • MIRAGE PROSE ON A RESTAURANT OWNER'S SCREEN. The status payload carries a
//     `message` beside every failure code, and the client must never render it.
//     Pinned by a fake that returns unmistakable upstream text and asserting it
//     is nowhere on screen.
//   • A POLL LOOP THAT OUTLIVES THE SCREEN. A timer that keeps firing after the
//     user has left keeps a phone's radio busy for a run nobody is watching,
//     and nothing about it is visible in a screenshot.
//   • A PARTIAL RUN REPORTED AS A SUCCESS. Three products missing from a live
//     menu, with a green tick above them, is the failure this whole screen is
//     shaped around.
//   • A SECOND PRESS TREATED AS AN ERROR. The server's 409 carries the id of
//     the run the user actually wanted; showing a red message and asking them
//     to press again is worse than useless.
//   • A PUBLISH BUTTON THAT FIRES INTO A GUARANTEED 422.
//
// Hermetic: the repository, the link actions and connectivity are all faked. No
// HTTP, no plugins, no timers left running.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_link_service.dart';
import 'package:recapture/application/catalog/publish_notifier.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/presentation/screens/catalog/publish_screen.dart';

import 'publish_fakes.dart';

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

Widget harness(
  FakePublishRepository repo, {
  bool online = true,
  FakeLinkActions? links,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(repo),
        isOnlineProvider.overrideWithValue(online),
        catalogLinkActionsProvider
            .overrideWithValue(links ?? FakeLinkActions()),
      ],
      child: const MaterialApp(home: PublishScreen()),
    );

/// The notifier behind the screen currently on `tester`.
PublishNotifier notifierOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PublishScreen)))
        .read(publishProvider.notifier);

void main() {
  group('no raw upstream text', () {
    // The one assertion that cannot be replaced by a code review.
    const miragePose =
        'E11000 duplicate key error collection: mirage.items index: name_1';

    testWidgets('a failure renders OUR sentence, never the server message',
        (tester) async {
      final repo = FakePublishRepository(
        status: statusPayload(
          status: 'PUBLISHED',
          publicUrl: 'https://menu.example.com/abc',
          lastPublishedAt: '2026-08-23T09:00:00.000Z',
          run: runPayload(state: 'PARTIAL', total: 2, synced: 1, failed: 1),
          products: [
            productPayload(id: 'p1', name: 'Soup'),
            productPayload(
              id: 'p2',
              name: 'Steak',
              syncStatus: 'FAILED',
              code: 'PUBLISH_DUPLICATE_NAME',
              // The thing that must never reach a user.
              message: miragePose,
            ),
          ],
        ),
      );

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining(miragePose), findsNothing);
      expect(find.textContaining('E11000'), findsNothing);
      expect(
        find.textContaining('already uses this name'),
        findsOneWidget,
      );
      // ...and the next action, which the raw message would never have carried.
      expect(find.textContaining('Rename it, then publish again'),
          findsOneWidget);
    });

    testWidgets('an UNKNOWN code degrades to a generic sentence',
        (tester) async {
      final repo = FakePublishRepository(
        status: statusPayload(
          run: runPayload(state: 'PARTIAL', total: 1, synced: 0, failed: 1),
          products: [
            productPayload(
              id: 'p1',
              name: 'Soup',
              syncStatus: 'FAILED',
              // A code from a server one deploy ahead of this build.
              code: 'PUBLISH_SOMETHING_NEW',
              message: miragePose,
            ),
          ],
        ),
      );

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining(miragePose), findsNothing);
      expect(
        find.textContaining('did not succeed'),
        findsOneWidget,
      );
    });
  });

  group('the gate checklist', () {
    testWidgets('blocks Publish and lists every blocker', (tester) async {
      final repo = FakePublishRepository(
        status: statusPayload(
          gates: [
            gatePayload(
              code: 'PRODUCT_ASSET_MISSING',
              message: '"Chair" has no 3D model yet.',
              productId: 'p1',
              productName: 'Chair',
            ),
            gatePayload(
              code: 'CATALOG_NAME_MISSING',
              message: 'Give your catalog a name before publishing.',
            ),
          ],
        ),
      );

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('publish_gate_checklist')),
          findsOneWidget);
      expect(find.textContaining('"Chair" has no 3D model yet'), findsOneWidget);
      expect(find.textContaining('Give your catalog a name'), findsOneWidget);

      // The button exists but cannot fire — never a press into a certain 422.
      final cta = tester.widget<ElevatedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('publish_cta')),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(cta.onPressed, isNull);
      expect(repo.publishCalls, 0);
    });

    testWidgets('a gate that only TIME can clear offers no fix button',
        (tester) async {
      final repo = FakePublishRepository(
        status: statusPayload(
          gates: [
            gatePayload(
              code: 'PRODUCT_THUMBNAIL_MISSING',
              message: '"Chair" is still generating its preview image.',
              productId: 'p1',
              productName: 'Chair',
            ),
          ],
        ),
      );

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      // Sending someone to an editor where nothing they can do will help is
      // worse than telling them to wait.
      expect(find.widgetWithText(TextButton, 'Open product'), findsNothing);
      expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
    });

    testWidgets('deep-links into the preview, where the warnings sit on the '
        'products they are about', (tester) async {
      final repo = FakePublishRepository(
        status: statusPayload(
          gates: [
            gatePayload(
              code: 'PRODUCT_ASSET_MISSING',
              message: '"Chair" has no 3D model yet.',
              productId: 'p1',
            ),
          ],
        ),
      );

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('publish_open_preview')), findsOneWidget);
    });
  });

  group('the poll loop', () {
    Map<String, dynamic> inFlight({int synced = 0}) => statusPayload(
          activeRunId: 'run-1',
          run: runPayload(state: 'RUNNING', total: 10, synced: synced),
          products: const [],
        );

    testWidgets('polls a run in flight, with a backoff', (tester) async {
      final repo = FakePublishRepository(status: inFlight());

      await tester.pumpWidget(harness(repo));
      await tester.pump(); // first load
      expect(repo.statusCalls, 1);

      // 1s, then 2s, then 3s — front-loaded, so the first seconds of a run are
      // responsive and the middle of a multi-minute one is not hammered.
      await tester.pump(const Duration(seconds: 1));
      expect(repo.statusCalls, 2);
      await tester.pump(const Duration(seconds: 1));
      expect(repo.statusCalls, 2, reason: 'the second gap is longer');
      await tester.pump(const Duration(seconds: 1));
      expect(repo.statusCalls, 3);

      // Let it finish, so no timer survives the test.
      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        publicUrl: 'https://menu.example.com/abc',
        run: runPayload(state: 'SUCCEEDED', total: 10, synced: 10),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('stops on a terminal state', (tester) async {
      final repo = FakePublishRepository(status: inFlight());

      await tester.pumpWidget(harness(repo));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        publicUrl: 'https://menu.example.com/abc',
        run: runPayload(state: 'SUCCEEDED', total: 10, synced: 10),
      ));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      final settled = repo.statusCalls;
      await tester.pump(const Duration(minutes: 2));
      expect(repo.statusCalls, settled,
          reason: 'a finished run must not keep being polled');
    });

    testWidgets('stops when the screen is disposed', (tester) async {
      final repo = FakePublishRepository(status: inFlight());

      await tester.pumpWidget(harness(repo));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final beforeLeaving = repo.statusCalls;

      // Leave the screen. autoDispose drops the provider, which cancels the
      // timer — a loop that survived this would keep polling behind whatever
      // the user opened next.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump(const Duration(minutes: 2));

      expect(repo.statusCalls, beforeLeaving);
    });

    testWidgets('coming back to a run mid-flight watches it, never restarts it',
        (tester) async {
      // The app was backgrounded, or the tab was closed, while a run was going.
      // Nothing is lost — the run belongs to the server — and the one thing the
      // client must NOT do on return is press Publish again on the user's
      // behalf.
      final repo = FakePublishRepository(status: inFlight(synced: 3));

      await tester.pumpWidget(harness(repo));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      await tester.pumpWidget(harness(repo));
      await tester.pump();

      expect(find.text('3 of 10 published'), findsOneWidget);
      expect(repo.publishCalls, 0);

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 10, synced: 10),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('pauses while the tab is hidden and catches up on show',
        (tester) async {
      final repo = FakePublishRepository(status: inFlight());

      await tester.pumpWidget(harness(repo));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final beforeHiding = repo.statusCalls;

      notifierOf(tester).debugSetHidden(true);
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      expect(repo.statusCalls, beforeHiding,
          reason: 'a hidden tab must not keep polling');

      // ...and the screen says the numbers are old rather than showing old ones
      // as though they were current.
      expect(find.byKey(const ValueKey('publish_paused_note')), findsOneWidget);

      notifierOf(tester).debugSetHidden(false);
      await tester.pump();
      // An IMMEDIATE catch-up, not a wait for the next backoff step.
      expect(repo.statusCalls, beforeHiding + 1);

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 10, synced: 10),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('a dropped poll keeps the run on screen and keeps polling',
        (tester) async {
      final repo = FakePublishRepository(status: inFlight(synced: 4));

      await tester.pumpWidget(harness(repo));
      await tester.pump();
      expect(find.text('4 of 10 published'), findsOneWidget);

      repo.statusFailure =
          const CatalogFailure(code: 'OFFLINE', message: 'offline', isOffline: true);
      await tester.pump(const Duration(seconds: 1));

      // The progress the user was watching survives one dropped request during
      // a run that legitimately takes minutes.
      expect(find.text('4 of 10 published'), findsOneWidget);

      repo.statusFailure = null;
      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 10, synced: 10),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });
  });

  group('partial failure', () {
    FakePublishRepository partial() => FakePublishRepository(
          status: statusPayload(
            status: 'PUBLISHED',
            publicUrl: 'https://menu.example.com/abc',
            lastPublishedAt: '2026-08-23T09:00:00.000Z',
            run: runPayload(state: 'PARTIAL', total: 10, synced: 7, failed: 3),
            products: [
              for (var i = 0; i < 7; i++)
                productPayload(id: 'ok$i', name: 'Fine $i'),
              for (var i = 0; i < 3; i++)
                productPayload(
                  id: 'bad$i',
                  name: 'Broken $i',
                  syncStatus: 'FAILED',
                  code: 'PUBLISH_UPSTREAM_TIMEOUT',
                ),
            ],
          ),
        );

    testWidgets('shows the counts, the reasons, and a working retry',
        (tester) async {
      final repo = partial();
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('7 of 10 published · 3 failed'), findsOneWidget);
      expect(find.textContaining('timed out'), findsWidgets);
      // A partial run is NOT a success — no green "Live on Mirage" card above
      // three products that are missing from the menu.
      expect(find.text('Live on Mirage'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('publish_retry_failed')));
      await tester.pumpAndSettle();

      expect(repo.retryCalls, 1);
    });

    testWidgets('every product failing is stated honestly', (tester) async {
      final repo = FakePublishRepository(
        status: statusPayload(
          run: runPayload(state: 'FAILED', total: 2, synced: 0, failed: 2),
          products: [
            productPayload(
              id: 'p1',
              name: 'Soup',
              syncStatus: 'FAILED',
              code: 'PUBLISH_UPSTREAM_UNAVAILABLE',
            ),
            productPayload(
              id: 'p2',
              name: 'Steak',
              syncStatus: 'FAILED',
              code: 'PUBLISH_UPSTREAM_UNAVAILABLE',
            ),
          ],
        ),
      );

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nothing was published'), findsOneWidget);
      expect(find.byKey(const ValueKey('publish_retry_failed')), findsOneWidget);
      expect(find.text('Live on Mirage'), findsNothing);
    });

    testWidgets('a retry with nothing left says so instead of erroring',
        (tester) async {
      final repo = partial()..publishResult = const PublishNothingToRetry();

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('publish_retry_failed')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nothing left to retry'), findsOneWidget);
    });
  });

  group('pressing Publish', () {
    FakePublishRepository ready() => FakePublishRepository(
          status: statusPayload(
            products: [productPayload(id: 'p1', name: 'Soup')],
          ),
        );

    testWidgets('a second press gets 409 and shows the run, not an error',
        (tester) async {
      final repo = ready()..publishResult = const PublishAlreadyRunning('run-9');

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      // The run the 409 named is already going; the next status read is what
      // the screen switches to watching.
      repo.setStatus(statusPayload(
        activeRunId: 'run-9',
        run: runPayload(state: 'RUNNING', total: 1, synced: 0),
      ));

      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pump();
      await tester.pump();

      expect(find.text('Publishing…'), findsWidgets);
      // Nothing red. A 409 here is the state the user asked for.
      expect(find.textContaining('already running'), findsNothing);

      repo.setStatus(statusPayload(
        status: 'PUBLISHED',
        run: runPayload(state: 'SUCCEEDED', total: 1, synced: 1),
      ));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('REUSES its idempotency key after a lost response',
        (tester) async {
      // The case this exists for: the run WAS enqueued and the 202 never
      // arrived. Pressing again with a fresh key would start a second run
      // racing the first against the same catalog.
      final repo = ready()
        ..publishFailure = const CatalogFailure(
          code: 'OFFLINE',
          message: 'offline',
          isOffline: true,
        );

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pumpAndSettle();

      repo.publishFailure = null;
      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pumpAndSettle();

      expect(repo.idempotencyKeys, hasLength(2));
      expect(repo.idempotencyKeys.first, isNotNull);
      expect(repo.idempotencyKeys.first, repo.idempotencyKeys.last);
    });

    testWidgets('a NEW key once an attempt got a definitive answer',
        (tester) async {
      final repo = ready();
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pumpAndSettle();

      expect(repo.idempotencyKeys, hasLength(2));
      expect(repo.idempotencyKeys.first,
          isNot(repo.idempotencyKeys.last),
          reason: 'the first run was accepted; the second is a new request');
    });

    testWidgets('a taken name offers the suggestion as one tap', (tester) async {
      final repo = ready()
        ..publishResult = const PublishNameTaken('Cafe Mocha 2');

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('publish_cta')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('publish_name_taken')), findsOneWidget);
      expect(find.textContaining('Cafe Mocha 2'), findsWidgets);

      repo.publishResult = const PublishQueued(runId: 'run-1');
      await tester
          .tap(find.byKey(const ValueKey('publish_accept_suggested_name')));
      await tester.pumpAndSettle();

      expect(repo.catalog?.name, 'Cafe Mocha 2');
      expect(repo.publishCalls, 2);
    });

    testWidgets('offline disables it with an explanation, not a failed request',
        (tester) async {
      final repo = ready();
      await tester.pumpWidget(harness(repo, online: false));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('publish_offline_banner')),
          findsOneWidget);
      final cta = tester.widget<ElevatedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('publish_cta')),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(cta.onPressed, isNull);
      expect(repo.publishCalls, 0);
    });
  });

  group('success and unpublish', () {
    FakePublishRepository live() => FakePublishRepository(
          status: statusPayload(
            status: 'PUBLISHED',
            hasDraftChanges: false,
            publicUrl: 'https://menu.example.com/abc',
            lastPublishedAt: '2026-08-23T09:00:00.000Z',
            run: runPayload(state: 'SUCCEEDED', total: 1, synced: 1),
            products: [productPayload(id: 'p1', name: 'Soup')],
          ),
        );

    testWidgets('shows the link VERBATIM with copy and share', (tester) async {
      final links = FakeLinkActions(canShare: true, canOpen: false);
      await tester.pumpWidget(harness(live(), links: links));
      await tester.pumpAndSettle();

      expect(find.text('Live on Mirage'), findsOneWidget);
      // Character for character — every printed QR resolves through it.
      expect(find.text('https://menu.example.com/abc'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('link_copy')));
      await tester.pumpAndSettle();
      expect(links.copied.single, 'https://menu.example.com/abc');
      expect(find.text('Link copied.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('link_share')));
      await tester.pumpAndSettle();
      expect(links.shared.single, 'https://menu.example.com/abc');
    });

    testWidgets('offers Open instead of Share where that is what exists',
        (tester) async {
      // The web shape: a new tab, no share sheet. Decided by the platform's
      // reported CAPABILITIES, never by a kIsWeb branch in the widget.
      final links = FakeLinkActions(canShare: false, canOpen: true);
      await tester.pumpWidget(harness(live(), links: links));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('link_share')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('link_open')));
      await tester.pumpAndSettle();
      expect(links.opened.single, 'https://menu.example.com/abc');
    });

    testWidgets('a refused clipboard is admitted, not swallowed',
        (tester) async {
      final links = FakeLinkActions()..failure = StateError('no clipboard');
      await tester.pumpWidget(harness(live(), links: links));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('link_copy')));
      await tester.pumpAndSettle();

      expect(find.textContaining('copy it by hand'), findsOneWidget);
    });

    testWidgets('the draft badge appears again once the draft moves',
        (tester) async {
      final repo = FakePublishRepository(
        status: statusPayload(
          status: 'PUBLISHED',
          hasDraftChanges: true,
          publicUrl: 'https://menu.example.com/abc',
          lastPublishedAt: '2026-08-23T09:00:00.000Z',
          run: runPayload(state: 'SUCCEEDED', total: 1, synced: 1),
          products: [productPayload(id: 'p1', name: 'Soup')],
        ),
      );

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('Draft changes not yet live'), findsOneWidget);
    });

    testWidgets('unpublish confirms, and promises the QR keeps working',
        (tester) async {
      final repo = live();
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('publish_unpublish')));
      await tester.pumpAndSettle();

      // THE sentence. A business that paid to print stickers cannot press this
      // without it.
      expect(
        find.textContaining('QR code and link keep working'),
        findsOneWidget,
      );
      expect(repo.unpublishCalls, 0, reason: 'not until it is confirmed');

      await tester.tap(find.byKey(const ValueKey('publish_unpublish_confirm')));
      await tester.pumpAndSettle();

      expect(repo.unpublishCalls, 1);
    });

    testWidgets('cancelling the confirmation changes nothing', (tester) async {
      final repo = live();
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('publish_unpublish')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep it live'));
      await tester.pumpAndSettle();

      expect(repo.unpublishCalls, 0);
    });
  });
}
