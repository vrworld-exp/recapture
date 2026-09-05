// test/rep/rep_web_parity_test.dart
//
// Stage 10, behavioural half: the rep surface renders correctly for BOTH
// targets, asserted from the one `flutter test` run CI does.
//
// THE POINT OF DRIVING A PROVIDER RATHER THAN `kIsWeb`. A branch on a
// compile-time constant cannot be tested at all — the untaken half is not
// compiled into the test binary — so the other platform's rendering would be
// unverifiable. Overriding `repCapabilitiesProvider` makes both renderings
// reachable from a VM test, which is the entire argument for the seam.
//
// HIDDEN, NOT DISABLED, is asserted with `findsNothing` on purpose. A disabled
// control in a browser is a promise the platform can never keep, and it invites
// a rep to keep tapping it; `findsNothing` is the only assertion that tells the
// two apart.
//
// Hermetic: the repository is a fake. No Dio, no network, no platform channel.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/rep/rep_capabilities.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show ProductImageSlot;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/rep/rep_activation_screen.dart';

class _FakeRepRepository implements RepRepository {
  final List<RepActivationRequest> activated = [];

  @override
  Future<QrCodePreflight> preflight(String code) async =>
      QrCodePreflight(code: code, state: 'UNASSIGNED', isAvailable: true);

  @override
  Future<RepActivation> activate(RepActivationRequest request) async {
    activated.add(request);
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
  Future<CatalogProduct> createProduct(
    String catalogId, {
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? sourceModelId,
    String? imageKey,
  }) async =>
      throw UnimplementedError();

  @override
  Future<String> uploadImageBytes(
    String catalogId,
    Uint8List bytes, {
    required String contentType,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ProductImageSlot> createImageSlot(
    String catalogId, {
    required String contentType,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> attachCode(String catalogId, String code) async {}

  @override
  Future<void> retireCode(String code) async {}
}

Widget _app(
  _FakeRepRepository repo, {
  required RepCapabilities caps,
  String? initialCode,
}) =>
    ProviderScope(
      overrides: [
        repRepositoryProvider.overrideWithValue(repo),
        repCapabilitiesProvider.overrideWithValue(caps),
      ],
      child: MaterialApp(
        home: RepActivationScreen(initialCode: initialCode),
      ),
    );

// BOTH REAL TARGETS NOW ANSWER TRUE TO BOTH. That is the point of the scanner
// and web-capture stages, and it is why these two constants are no longer
// opposites — the asymmetry this file was written to pin has been removed, and
// the file's job changed from "prove the gap is handled" to "prove the gap is
// gone and stays gone".
const _mobile = RepCapabilities(canScan: true, canCaptureDish: true);
const _web = RepCapabilities(canScan: true, canCaptureDish: true);

/// The third target: neither `dart:io` nor `dart:js_interop`, so
/// `rep_capabilities_stub.dart` answers false to everything.
///
/// Kept as a fixture even though no shipping target reports it, because the
/// HIDDEN-NOT-DISABLED rule below is a claim about the renderer, not about a
/// platform — and it is the rule that has to survive the next capability that
/// starts out false.
const _fallback = RepCapabilities(canScan: false, canCaptureDish: false);

void main() {
  group('the scan affordance', () {
    for (final (name, caps) in [('mobile', _mobile), ('web', _web)]) {
      testWidgets('$name offers BOTH scan and manual entry', (tester) async {
        await tester.pumpWidget(_app(_FakeRepRepository(), caps: caps));

        expect(find.byKey(const ValueKey('rep_scan_button')), findsOneWidget);
        // Manual entry is not the fallback for the OTHER platform — it is
        // present on every target, because a damaged or badly-lit sticker needs
        // it even where a scanner exists.
        expect(find.byKey(const ValueKey('rep_code_field')), findsOneWidget);
      });
    }

    testWidgets('a build that cannot scan is missing the button ENTIRELY',
        (tester) async {
      await tester.pumpWidget(_app(_FakeRepRepository(), caps: _fallback));

      // findsNothing, not "is disabled". THE assertion of this file.
      expect(find.byKey(const ValueKey('rep_scan_button')), findsNothing);
      expect(find.byKey(const ValueKey('rep_code_field')), findsOneWidget);
    });
  });

  group('parity — both targets reach a real activation', () {
    /// The claim the stage actually makes: the missing scanner costs a rep
    /// typing, not the ability to activate a restaurant.
    for (final (name, caps) in [('mobile', _mobile), ('web', _web)]) {
      testWidgets('$name activates through manual entry', (tester) async {
        final repo = _FakeRepRepository();
        await tester.pumpWidget(_app(repo, caps: caps));

        await tester.enterText(
          find.byKey(const ValueKey('rep_code_field')),
          'ABCD2345',
        );
        await tester.tap(find.byKey(const ValueKey('rep_code_continue')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const ValueKey('rep_name_field')),
          'Green Chilli Kitchen',
        );
        await tester.enterText(
          find.byKey(const ValueKey('rep_phone_field')),
          '9876543210',
        );
        await tester.tap(find.byKey(const ValueKey('rep_details_continue')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('rep_confirm_activate')));
        await tester.pumpAndSettle();

        expect(repo.activated, hasLength(1));
        expect(repo.activated.single.code, 'ABCD2345');
        expect(find.text('This standee is live'), findsOneWidget);
      });
    }
  });

  group('the ?code= deep link', () {
    testWidgets('prefills the field on both targets', (tester) async {
      for (final caps in [_mobile, _web]) {
        await tester.pumpWidget(
          _app(_FakeRepRepository(), caps: caps, initialCode: 'abcd-2345'),
        );
        await tester.pumpAndSettle();

        // Normalised on the way in: a hyphenated or lowercase scan prefills as
        // the stored form, which is what the sticker shows.
        final field = tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(const ValueKey('rep_code_field')),
            matching: find.byType(EditableText),
          ),
        );
        expect(field.controller.text, 'ABCD2345');
      }
    });

    testWidgets('a full scanned URL prefills as the bare code', (tester) async {
      await tester.pumpWidget(
        _app(
          _FakeRepRepository(),
          caps: _web,
          initialCode: 'https://scan.example/r/abcd2345',
        ),
      );
      await tester.pumpAndSettle();

      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('rep_code_field')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.controller.text, 'ABCD2345');
    });

    testWidgets('does NOT activate on arrival', (tester) async {
      final repo = _FakeRepRepository();
      await tester.pumpWidget(
        _app(repo, caps: _web, initialCode: 'ABCD2345'),
      );
      await tester.pumpAndSettle();

      // A prefill, not a command. A mis-scan must never start a one-shot,
      // irreversible action with no human in the loop.
      expect(repo.activated, isEmpty);
      expect(find.byKey(const ValueKey('rep_code_continue')), findsOneWidget);
    });

    testWidgets('an unparseable code is dropped, not shown', (tester) async {
      await tester.pumpWidget(
        _app(_FakeRepRepository(), caps: _web, initialCode: 'not-a-code!!'),
      );
      await tester.pumpAndSettle();

      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('rep_code_field')),
          matching: find.byType(EditableText),
        ),
      );
      // Empty, not the garbage — it could only produce an error the rep did
      // not cause and cannot fix.
      expect(field.controller.text, isEmpty);
    });
  });
}
