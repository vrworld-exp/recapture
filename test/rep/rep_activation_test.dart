// test/rep/rep_activation_test.dart
//
// Stage 6: the activation flow a rep drives standing at a table.
//
// TWO ASSERTIONS HERE CARRY THE SUITE.
//
// The first is the PHONE CONFIRMATION STEP. A mistyped number does not fail
// anywhere — it creates a real account for a number nobody owns, permanently
// holding the catalog slot the real restaurant needs, and the restaurant then
// signs in on their correct number to find an empty second account. Nothing on
// the rep's screen would ever report it. So the test that matters is that
// filling in the form does NOT submit, and only a deliberate second tap does.
//
// The second is that NO BACKEND SENTENCE REACHES A REP. The failure path is fed
// a message that looks like upstream prose and the rendered screen is checked
// for any trace of it.
//
// Hermetic: the repository is a fake, so there is no Dio, no network and no
// platform channel anywhere in here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/rep/qr_scan_capability.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/domain/rep/qr_code_input.dart';
import 'package:recapture/presentation/screens/rep/rep_activation_screen.dart';

/// Records what it was asked to do and answers with whatever the test scripted.
class _FakeRepRepository implements RepRepository {
  _FakeRepRepository({this.preflightResult, this.activateThrows});

  QrCodePreflight? preflightResult;
  CatalogFailure? activateThrows;

  final List<String> preflighted = [];
  final List<RepActivationRequest> activated = [];

  @override
  Future<QrCodePreflight> preflight(String code) async {
    preflighted.add(code);
    return preflightResult ??
        QrCodePreflight(code: code, state: 'UNASSIGNED', isAvailable: true);
  }

  @override
  Future<RepActivation> activate(RepActivationRequest request) async {
    activated.add(request);
    if (activateThrows != null) throw activateThrows!;
    return const RepActivation(
      outcome: RepActivationOutcome.activated,
      catalogId: 'cat-1',
      publicUrl: 'https://scan.test/r/ABCD2345',
    );
  }

  @override
  Future<List<RepCatalogSummary>> catalogs() async => const [];

  @override
  Future<List<CatalogProduct>> products(String catalogId) async => const [];

  @override
  Future<void> attachCode(String catalogId, String code) async {}

  @override
  Future<void> retireCode(String code) async {}
}

Widget _app(_FakeRepRepository repo, {bool canScan = false}) => ProviderScope(
      overrides: [
        repRepositoryProvider.overrideWithValue(repo),
        qrScanCapabilityProvider
            .overrideWithValue(QrScanCapability(canScan: canScan)),
      ],
      child: const MaterialApp(home: RepActivationScreen()),
    );

/// Walks the flow as far as the confirmation step.
Future<void> _fillIn(WidgetTester tester, {String phone = '9876543210'}) async {
  await tester.enterText(find.byKey(const ValueKey('rep_code_field')), 'ABCD2345');
  await tester.tap(find.byKey(const ValueKey('rep_code_continue')));
  await tester.pumpAndSettle();

  // Deliberately NOT the field's hint text ('Blue Cafe'), so a find for it can
  // only match the value the rep typed.
  await tester.enterText(
    find.byKey(const ValueKey('rep_name_field')),
    'Green Chilli Kitchen',
  );
  await tester.enterText(find.byKey(const ValueKey('rep_phone_field')), phone);
  await tester.tap(find.byKey(const ValueKey('rep_details_continue')));
  await tester.pumpAndSettle();
}

void main() {
  // ── Code normalisation ────────────────────────────────────────────────────

  group('QrCodeInput.normalize', () {
    test('accepts every form a rep can produce', () {
      // Typed lowercase, read off a hyphenated sticker, spaced for legibility,
      // and pasted whole out of the OS camera's browser tab.
      expect(QrCodeInput.normalize('abcd-2345'), 'ABCD2345');
      expect(QrCodeInput.normalize('ABCD 2345'), 'ABCD2345');
      expect(QrCodeInput.normalize('abcd2345'), 'ABCD2345');
      expect(QrCodeInput.normalize('  ABCD2345  '), 'ABCD2345');
      expect(
        QrCodeInput.normalize('https://scan.example/r/abcd2345'),
        'ABCD2345',
      );
      expect(
        QrCodeInput.normalize('https://scan.example/r/ABCD2345?utm=x'),
        'ABCD2345',
      );
    });

    test('rejects what could never be a code, so it never becomes a request', () {
      expect(QrCodeInput.normalize('ABCD234'), isNull);
      expect(QrCodeInput.normalize('ABCD23456'), isNull);
      expect(QrCodeInput.normalize(''), isNull);
      // I, L, O and U are not in the alphabet — and are deliberately NOT mapped
      // to 1/0, which would make two printed codes normalise to the same one.
      expect(QrCodeInput.normalize('ABCDI234'), isNull);
      expect(QrCodeInput.normalize('ABCDO234'), isNull);
    });
  });

  // ── The confirmation step ─────────────────────────────────────────────────

  group('the phone confirmation', () {
    testWidgets('filling in the form does NOT activate', (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(_app(repo));
      await _fillIn(tester);

      // THE ASSERTION THAT MATTERS. The rep has typed everything and the
      // request has still not been sent — the confirmation is a gate, not a
      // summary screen on the way past.
      expect(repo.activated, isEmpty);
      expect(find.byKey(const ValueKey('rep_confirm_activate')), findsOneWidget);
    });

    testWidgets('shows the number in the form the restaurant will type',
        (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(_app(repo));
      await _fillIn(tester);

      // E.164, dial code included — byte-identical to what the OTP screen will
      // send when the owner signs in. A rep reading anything else back to a
      // restaurant owner is checking the wrong string.
      final shown = tester.widget<Text>(
        find.byKey(const ValueKey('rep_confirm_phone')),
      );
      expect(shown.data, '+919876543210');
    });

    testWidgets('the explicit tap is what sends it', (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(_app(repo));
      await _fillIn(tester);

      await tester.tap(find.byKey(const ValueKey('rep_confirm_activate')));
      await tester.pumpAndSettle();

      expect(repo.activated, hasLength(1));
      expect(repo.activated.single.restaurantPhone, '+919876543210');
      expect(repo.activated.single.code, 'ABCD2345');
      expect(find.text('This standee is live'), findsOneWidget);
    });

    testWidgets('"Change details" goes back with the typed values intact',
        (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(_app(repo));
      await _fillIn(tester);

      await tester.tap(find.byKey(const ValueKey('rep_confirm_edit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('rep_name_field')), findsOneWidget);
      expect(find.text('Green Chilli Kitchen'), findsOneWidget);
      expect(repo.activated, isEmpty);
    });

    testWidgets('a rejected phone never reaches the confirmation step',
        (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(_app(repo));
      // Nine digits — the sign-in screen's own validator refuses it, and this
      // screen uses that validator rather than one of its own.
      await _fillIn(tester, phone: '987654321');

      expect(find.byKey(const ValueKey('rep_confirm_activate')), findsNothing);
      expect(repo.activated, isEmpty);
    });
  });

  // ── Failures ──────────────────────────────────────────────────────────────

  group('failures', () {
    testWidgets('a 409 renders the "already in use" copy, not the server text',
        (tester) async {
      const upstream = 'Error: E11000 duplicate key at QrCode.claim (stack…)';
      final repo = _FakeRepRepository(
        activateThrows: const CatalogFailure(
          code: RepErrorCodes.codeUnavailable,
          message: upstream,
          statusCode: 409,
        ),
      );
      await tester.pumpWidget(_app(repo));
      await _fillIn(tester);
      await tester.tap(find.byKey(const ValueKey('rep_confirm_activate')));
      await tester.pumpAndSettle();

      expect(find.text('That code is already in use.'), findsOneWidget);
      expect(find.text('Use another standee.'), findsOneWidget);
      // NOT ONE CHARACTER of the upstream message on screen.
      expect(find.textContaining('E11000'), findsNothing);
      expect(find.textContaining('stack'), findsNothing);
      // And a way out that does not mean retyping the restaurant's details.
      expect(
        find.byKey(const ValueKey('rep_confirm_another_code')),
        findsOneWidget,
      );
    });

    testWidgets('a taken code is caught at preflight, before the form',
        (tester) async {
      final repo = _FakeRepRepository(
        preflightResult: const QrCodePreflight(
          code: 'ABCD2345',
          state: 'ACTIVE',
          isAvailable: false,
        ),
      );
      await tester.pumpWidget(_app(repo));
      await tester.enterText(
        find.byKey(const ValueKey('rep_code_field')),
        'ABCD2345',
      );
      await tester.tap(find.byKey(const ValueKey('rep_code_continue')));
      await tester.pumpAndSettle();

      // The whole point of the preflight: the rep never typed a restaurant's
      // profile against a standee that was never going to work.
      expect(find.byKey(const ValueKey('rep_name_field')), findsNothing);
      expect(find.text('That code is already in use.'), findsOneWidget);
    });

    testWidgets('a malformed code never becomes a request', (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(_app(repo));
      await tester.enterText(
        find.byKey(const ValueKey('rep_code_field')),
        'ABC',
      );
      await tester.tap(find.byKey(const ValueKey('rep_code_continue')));
      await tester.pumpAndSettle();

      expect(repo.preflighted, isEmpty);
      expect(find.byKey(const ValueKey('rep_name_field')), findsNothing);
    });
  });

  // ── The scan affordance ───────────────────────────────────────────────────

  group('the scan affordance', () {
    // Both platforms asserted from ONE `flutter test` run, because the
    // capability is a provider rather than a kIsWeb branch. A branch on a
    // compile-time constant could not be tested at all — the untaken half is
    // not in the test binary.
    testWidgets('is offered where the build can scan', (tester) async {
      await tester.pumpWidget(_app(_FakeRepRepository(), canScan: true));
      expect(find.byKey(const ValueKey('rep_scan_button')), findsOneWidget);
      expect(find.byKey(const ValueKey('rep_code_field')), findsOneWidget);
    });

    testWidgets('is HIDDEN, not disabled, where it cannot', (tester) async {
      await tester.pumpWidget(_app(_FakeRepRepository(), canScan: false));
      // Hidden: a disabled button in a browser is a promise the platform can
      // never keep, and it invites a rep to keep tapping it.
      expect(find.byKey(const ValueKey('rep_scan_button')), findsNothing);
      // Manual entry is on every target, so the screen still works.
      expect(find.byKey(const ValueKey('rep_code_field')), findsOneWidget);
    });
  });
}
