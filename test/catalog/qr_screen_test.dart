// test/catalog/qr_screen_test.dart
//
// The QR screen (features 31-35, 52).
//
// What this file exists to catch, in order of how badly the alternative goes:
//   • A LINK THE CLIENT TOUCHED. `publicUrl` is frozen server-side and every
//     printed sticker resolves through it. A client that shortened, re-cased or
//     rebuilt it would break codes already on tables, and nothing in the app
//     would show it.
//   • A DOWNLOAD THAT ONLY WORKS ON ONE PLATFORM. One repository method fetches
//     the bytes; the delivery is a seam. The tests drive both sides of it.
//   • THE PRE-PUBLISH STATE READ AS A BUG. Before the first publish the backend
//     answers 409, and "publish first" is an instruction, not an apology.
//
// Hermetic: repository, deliverer and link actions are all faked.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_link_service.dart';
import 'package:recapture/application/catalog/catalog_qr_service.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/presentation/screens/catalog/catalog_qr_screen.dart';

import 'publish_fakes.dart';

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

Widget harness(
  FakePublishRepository repo, {
  FakeQrDeliverer? deliverer,
  FakeLinkActions? links,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(repo),
        qrDelivererProvider.overrideWithValue(deliverer ?? FakeQrDeliverer()),
        catalogLinkActionsProvider
            .overrideWithValue(links ?? FakeLinkActions()),
      ],
      child: const MaterialApp(home: CatalogQrScreen()),
    );

void main() {
  testWidgets('renders the code and the link, verbatim', (tester) async {
    final repo = FakePublishRepository();
    await tester.pumpWidget(harness(repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('qr_image')), findsOneWidget);
    // The golden catalog's URL, character for character.
    expect(
      find.text('https://menu.example.com/6a83dd464aea89d1d2d28d51'),
      findsOneWidget,
    );
    // The promise that makes printing worth the money (feature 32).
    expect(find.textContaining('This code never changes'), findsOneWidget);
    // Asked for at print resolution, not display resolution.
    expect(repo.qrCalls, [CatalogQrFormat.png]);
  });

  testWidgets('saving a PNG reuses the bytes already on screen',
      (tester) async {
    final repo = FakePublishRepository();
    final deliverer = FakeQrDeliverer();

    await tester.pumpWidget(harness(repo, deliverer: deliverer));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('qr_save_png')));
    await tester.pumpAndSettle();

    // ONE fetch, not two: the endpoint is rate-limited and the bytes are a pure
    // function of a URL that never changes.
    expect(repo.qrCalls, [CatalogQrFormat.png]);
    expect(deliverer.delivered, hasLength(1));
    expect(
      utf8.decode(deliverer.delivered.single.bytes),
      'qr-bytes-png',
    );
    // The SERVER's filename, so the saved file is named after the catalog.
    expect(deliverer.delivered.single.fileName, 'cafe-mocha-qr.png');
    expect(deliverer.delivered.single.mimeType, 'image/png');
    expect(find.text('QR code saved.'), findsOneWidget);
  });

  testWidgets('saving a PDF fetches the print render', (tester) async {
    final repo = FakePublishRepository();
    final deliverer = FakeQrDeliverer();

    await tester.pumpWidget(harness(repo, deliverer: deliverer));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('qr_save_pdf')));
    await tester.pumpAndSettle();

    // A different render, so it IS fetched.
    expect(repo.qrCalls, [CatalogQrFormat.png, CatalogQrFormat.pdf]);
    expect(deliverer.delivered.single.mimeType, 'application/pdf');
  });

  testWidgets('a delivery that fails is reported, not swallowed',
      (tester) async {
    // A dismissed share sheet on a phone, a browser that refused the download.
    final deliverer = FakeQrDeliverer()..failure = StateError('no');

    await tester.pumpWidget(
      harness(FakePublishRepository(), deliverer: deliverer),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('qr_save_png')));
    await tester.pumpAndSettle();

    // QR_SAVE_FAILED is a CLIENT sentinel — there is no envelope behind a
    // dismissed share sheet — and it reaches the user through the same mapped
    // table as every backend code. It was missing from that table until this
    // assertion was written.
    expect(find.textContaining('cancelled or blocked'), findsOneWidget);
    expect(find.textContaining('photograph the code'), findsOneWidget);
    // The code is still on screen — a failed save must not take away a QR the
    // user can photograph off the display.
    expect(find.byKey(const ValueKey('qr_image')), findsOneWidget);
  });

  testWidgets('before the first publish it explains, it does not apologise',
      (tester) async {
    final repo = FakePublishRepository()
      ..qrFailure = const CatalogFailure(
        code: 'CATALOG_NOT_PUBLISHED',
        message: 'Publish your catalog first.',
        statusCode: 409,
      );

    await tester.pumpWidget(harness(repo));
    await tester.pumpAndSettle();

    expect(
      find.text('Your QR code is created when you publish'),
      findsOneWidget,
    );
    expect(find.textContaining('permanent link'), findsOneWidget);
    // Nothing to retry — the fix is to publish, not to press again.
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('any other failure keeps a retry', (tester) async {
    final repo = FakePublishRepository()
      ..qrFailure = const CatalogFailure(
        code: 'OFFLINE',
        message: "You're offline — check your connection and try again.",
        isOffline: true,
      );

    await tester.pumpWidget(harness(repo));
    await tester.pumpAndSettle();

    expect(find.text("We couldn't load your QR code"), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(repo.qrCalls, hasLength(2));
  });

  testWidgets('copy works here too, with a visible confirmation',
      (tester) async {
    final links = FakeLinkActions();
    await tester.pumpWidget(harness(FakePublishRepository(), links: links));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('link_copy')));
    await tester.pumpAndSettle();

    expect(
      links.copied.single,
      'https://menu.example.com/6a83dd464aea89d1d2d28d51',
    );
    // A copy with no acknowledgement reads as a dead button.
    expect(find.text('Link copied.'), findsOneWidget);
  });

  testWidgets('one save at a time — the other button goes dead meanwhile',
      (tester) async {
    // A user who taps PNG and then PDF while the first is still going would
    // otherwise get two share sheets, or two downloads, from one intention.
    final deliverer = FakeQrDeliverer()..gate = Completer<void>();
    final repo = FakePublishRepository();

    await tester.pumpWidget(harness(repo, deliverer: deliverer));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('qr_save_png')));
    await tester.pump();

    final pdf = tester.widget<OutlinedButton>(
      find.descendant(
        of: find.byKey(const ValueKey('qr_save_pdf')),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(pdf.onPressed, isNull);

    deliverer.gate!.complete();
    await tester.pumpAndSettle();

    expect(deliverer.delivered, hasLength(1));
    expect(repo.qrCalls, [CatalogQrFormat.png]);
  });
}
