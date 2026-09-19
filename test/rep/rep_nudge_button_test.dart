// test/rep/rep_nudge_button_test.dart
//
// The rep's "Notify owner to pay" button on the Subscription card (Door 2's
// nudge, stage-04).
//
// What this file exists to catch:
//   • A COOLDOWN THAT NEEDS A REFRESH. After a send the server says when the
//     next one is allowed; the button must show "Sent · again in Nh" from
//     that answer alone — no re-read of the subscription.
//   • A BUTTON OFFERED TO A PAID-UP OWNER. ACTIVE with 30 days left is
//     hidden, not disabled: tapping would only earn a 409.
//   • A 429 OR A 409 SHOWN AS A CRASH, OR AS THE SERVER'S PROSE. Our sentence
//     for each, and the 429 also lands the cooldown on the button.
//   • A NUDGE SENT OFFLINE. Disabled with a reason, nothing queued.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/qr_download_file.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/data/repositories/payments_repository.dart';
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/catalog_subscription.dart';
import 'package:recapture/domain/entities/product_food_type.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/domain/entities/subscription_nudge.dart';
import 'package:recapture/presentation/widgets/rep/rep_subscription_card.dart';
import 'package:recapture/utils/analytics.dart';

import '../catalog/catalog_entities_test.dart' as golden;
import '../catalog/payments_fakes.dart';
import '../catalog/subscription_entity_test.dart' show subscriptionPayload;
import 'rep_repo_catalog_defaults.dart';

const kCatalogId = 'c1';

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// A repository whose subscription is scripted per test, and whose nudge
/// answers whatever the test set — recording every call.
class _FakeRepo with RepRepoCatalogDefaults implements RepRepository {
  _FakeRepo({
    this.status = 'GRACE',
    this.daysLeft = 5,
    this.nudgeNextAllowedAt,
    this.nudgeAnswer,
    this.nudgeThrows,
  });

  String status;
  int? daysLeft;

  /// What the GET reports — a cooldown already in force.
  DateTime? nudgeNextAllowedAt;
  NudgeResult? nudgeAnswer;
  CatalogFailure? nudgeThrows;

  int subscriptionReads = 0;
  int nudgeCalls = 0;

  @override
  Future<List<RepCatalogSummary>> catalogs() async => const [];

  @override
  Future<Catalog> catalog(String catalogId) async =>
      Catalog.fromMap({...golden.catalogGolden(), 'id': catalogId});

  @override
  Future<CatalogSubscription> subscription(String catalogId) async {
    subscriptionReads++;
    return CatalogSubscription.fromMap(
      subscriptionPayload(
        status: status,
        daysLeft: daysLeft,
        trialAvailable: false,
        isEntitledTo3D: status != 'PAUSED',
      ),
      nudgeNextAllowedAt: nudgeNextAllowedAt,
    );
  }

  @override
  Future<NudgeResult> notifyOwner(String catalogId) async {
    nudgeCalls++;
    if (nudgeThrows != null) throw nudgeThrows!;
    return nudgeAnswer ??
        const NudgeSent(
          channels: [NudgeChannel.sms, NudgeChannel.inApp],
          nextAllowedAt: null,
        );
  }

  // ── The rest of the seam, not exercised here ──────────────────────────────

  @override
  Future<QrCodePreflight> preflight(String code) async =>
      throw UnimplementedError();

  @override
  Future<RepActivation> activate(RepActivationRequest request) async =>
      throw UnimplementedError();

  @override
  Future<List<CatalogProduct>> products(String catalogId) async => const [];

  @override
  Future<List<RepStandee>> standees() async => const [];

  @override
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
    int? size,
  }) async =>
      throw UnimplementedError();

  @override
  Future<PublishRequestResult> publish(
    String catalogId, {
    String? idempotencyKey,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> attachCode(String catalogId, String code) async =>
      throw UnimplementedError();

  @override
  Future<void> retireCode(String code) async => throw UnimplementedError();

  @override
  Future<CatalogProduct> createProduct(
    String catalogId, {
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? sourceModelId,
    String? imageKey,
    String? categoryId,
    ProductFoodType? foodType,
  }) async =>
      throw UnimplementedError();

  @override
  Future<String> uploadImageBytes(
    String catalogId,
    Uint8List bytes, {
    required String contentType,
    String? productId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ProductImageSlot> createImageSlot(
    String catalogId, {
    required String contentType,
    String? productId,
  }) async =>
      throw UnimplementedError();
}

Widget _harness(_FakeRepo repo, {bool online = true}) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        repRepositoryProvider.overrideWithValue(repo),
        paymentsRepositoryProvider.overrideWithValue(FakePaymentsRepository()),
        isOnlineProvider.overrideWithValue(online),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: RepSubscriptionCard(
            catalogId: kCatalogId,
            restaurantName: 'Blue Cafe',
          ),
        ),
      ),
    );

final _button = find.byKey(const ValueKey('rep_notify_owner'));

/// The label the button is showing, whatever widget renders it.
String _buttonLabel(WidgetTester tester) {
  final texts = find.descendant(of: _button, matching: find.byType(Text));
  return tester.widgetList<Text>(texts).map((t) => t.data ?? '').join();
}

Future<void> _tapNotify(WidgetTester tester) async {
  await tester.tap(_button);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => Analytics.testSink = null);

  testWidgets('is offered on an overdue restaurant and sends on one tap',
      (tester) async {
    final events = <String>[];
    Analytics.testSink = (name, _) => events.add(name);
    final repo = _FakeRepo(status: 'GRACE', daysLeft: 5);
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    expect(_button, findsOneWidget);
    expect(_buttonLabel(tester), 'Notify owner to pay');

    await _tapNotify(tester);

    expect(repo.nudgeCalls, 1);
    expect(events, contains('rep_nudge_tapped'));
    expect(find.text('Sent to the owner by SMS and in-app.'), findsOneWidget);
    // Room left in the window: the button is back, not on cooldown.
    expect(_buttonLabel(tester), 'Notify owner to pay');
    // A nudge is not a payment: nothing about the card needed re-reading.
    expect(repo.subscriptionReads, 1);
  });

  testWidgets(
      'shows the cooldown after a send WITHOUT a refresh, from the server\'s '
      'nextAllowedAt', (tester) async {
    final repo = _FakeRepo(
      status: 'GRACE',
      nudgeAnswer: NudgeSent(
        channels: const [NudgeChannel.sms, NudgeChannel.inApp],
        nextAllowedAt: DateTime.now().add(const Duration(hours: 23)),
      ),
    );
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    await _tapNotify(tester);

    expect(_buttonLabel(tester), 'Sent · again in 23h');
    expect(repo.subscriptionReads, 1);
    // Disabled: a second tap sends nothing.
    await tester.tap(_button, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(repo.nudgeCalls, 1);
  });

  testWidgets('a 429 lands the cooldown on the button and says so',
      (tester) async {
    final repo = _FakeRepo(
      status: 'PAUSED',
      daysLeft: null,
      nudgeAnswer: NudgeCooldown(
        nextAllowedAt: DateTime.now().add(const Duration(hours: 2)),
      ),
    );
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    await _tapNotify(tester);

    expect(find.textContaining('Already sent'), findsOneWidget);
    expect(find.textContaining('again in 2h'), findsWidgets);
    expect(_buttonLabel(tester), 'Sent · again in 2h');
  });

  testWidgets('a cooldown the GET reports is shown before any tap',
      (tester) async {
    final repo = _FakeRepo(
      status: 'TRIAL',
      daysLeft: 3,
      nudgeNextAllowedAt: DateTime.now().add(const Duration(minutes: 40)),
    );
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    expect(_buttonLabel(tester), 'Sent · again in 40m');
    await tester.tap(_button, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(repo.nudgeCalls, 0);
  });

  testWidgets('is HIDDEN for a paid-up owner (ACTIVE, 30 days left) and a comp',
      (tester) async {
    await tester
        .pumpWidget(_harness(_FakeRepo(status: 'ACTIVE', daysLeft: 30)));
    await tester.pumpAndSettle();
    expect(_button, findsNothing);
    // The rest of the card is intact.
    expect(find.byKey(const ValueKey('rep_record_cash')), findsOneWidget);

    await tester
        .pumpWidget(_harness(_FakeRepo(status: 'COMPED', daysLeft: 200)));
    await tester.pumpAndSettle();
    expect(_button, findsNothing);
  });

  testWidgets('is offered on an ACTIVE plan inside its last week',
      (tester) async {
    await tester.pumpWidget(_harness(_FakeRepo(status: 'ACTIVE', daysLeft: 6)));
    await tester.pumpAndSettle();
    expect(_button, findsOneWidget);
  });

  testWidgets('a 409 for a legacy owner shows OUR sentence, not the server\'s',
      (tester) async {
    final repo = _FakeRepo(
      status: 'GRACE',
      nudgeAnswer: const NudgeRefused(NudgeRefusal.ownerUnreachable),
    );
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    await _tapNotify(tester);

    expect(
      find.text('This owner has no phone number on file — ask an admin.'),
      findsOneWidget,
    );
    expect(_buttonLabel(tester), 'Notify owner to pay');
  });

  testWidgets('a NOT_NEEDED refusal re-reads the card (the owner just paid)',
      (tester) async {
    final repo = _FakeRepo(
      status: 'GRACE',
      nudgeAnswer: const NudgeRefused(NudgeRefusal.notNeeded),
    );
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    // The truth moved under the card: the next read says ACTIVE, 30 days.
    repo
      ..status = 'ACTIVE'
      ..daysLeft = 30;
    await _tapNotify(tester);

    expect(find.textContaining('paid up'), findsOneWidget);
    expect(repo.subscriptionReads, 2);
    expect(_button, findsNothing);
  });

  testWidgets('a transport failure is a toast, and the button survives',
      (tester) async {
    final repo = _FakeRepo(
      status: 'GRACE',
      nudgeThrows: const CatalogFailure(
        code: 'OFFLINE',
        message: 'upstream prose that must not be shown',
        isOffline: true,
      ),
    );
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    await _tapNotify(tester);

    expect(find.textContaining('upstream prose'), findsNothing);
    expect(
        find.textContaining('The owner could not be notified'), findsOneWidget);
    expect(_buttonLabel(tester), 'Notify owner to pay');
  });

  testWidgets('offline: disabled with a reason, nothing sent', (tester) async {
    final repo = _FakeRepo(status: 'GRACE');
    await tester.pumpWidget(_harness(repo, online: false));
    await tester.pumpAndSettle();

    expect(_buttonLabel(tester), 'Needs a connection');
    await tester.tap(_button, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(repo.nudgeCalls, 0);
  });

  group('the pure rules', () {
    test('nudgeWaitText never says 0h', () {
      final now = DateTime(2026, 9, 19, 12);
      expect(
          nudgeWaitText(now.add(const Duration(hours: 23, minutes: 59)), now),
          '24h');
      expect(nudgeWaitText(now.add(const Duration(hours: 1)), now), '1h');
      expect(nudgeWaitText(now.add(const Duration(minutes: 59)), now), '59m');
      expect(nudgeWaitText(now.add(const Duration(seconds: 10)), now), '1m');
    });

    test('nudgeResultSentence covers every answer', () {
      expect(
        nudgeResultSentence(const NudgeSent(
          channels: [NudgeChannel.inApp],
          nextAllowedAt: null,
        )),
        'Sent to the owner in-app — the SMS could not be sent.',
      );
      final now = DateTime(2026, 9, 19, 12);
      expect(
        nudgeResultSentence(
          NudgeCooldown(nextAllowedAt: now.add(const Duration(hours: 5))),
          now: now,
        ),
        'Already sent — the owner can be reminded again in 5h.',
      );
      expect(
        nudgeResultSentence(const NudgeRefused(NudgeRefusal.notNeeded)),
        'This restaurant is paid up — no reminder needed.',
      );
    });
  });
}
