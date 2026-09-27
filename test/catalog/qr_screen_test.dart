// test/catalog/qr_screen_test.dart
//
// The QR screen (features 31-35, 52).
//
// What this file exists to catch, in order of how badly the alternative goes:
//   • A LINK THE CLIENT TOUCHED. `publicUrl` is frozen server-side and every
//     printed sticker resolves through it. A client that shortened, re-cased or
//     rebuilt it would break codes already on tables, and nothing in the app
//     would show it.
//   • A FREE PRINT FILE. The owner's screen is view-only; printing is the
//     counted standee download, capped at what the plan has left, and a save
//     that fails after the count is re-saved, never paid for twice.
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
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/presentation/screens/catalog/catalog_qr_screen.dart';
import 'package:recapture/presentation/widgets/catalog/qr_code_panel.dart';

import 'catalog_entities_test.dart' as golden;
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
    expect(find.textContaining('Print it once'), findsOneWidget);
    // Asked for at print resolution, not display resolution.
    expect(repo.qrCalls, [CatalogQrFormat.png]);
  });

  testWidgets('view-only: no free save, the square is small, A4 is offered',
      (tester) async {
    await tester.pumpWidget(harness(FakePublishRepository()));
    await tester.pumpAndSettle();

    // The print file is the COUNTED download; a free save would be the way
    // round the plan's allowance.
    expect(find.byKey(const ValueKey('qr_save_png')), findsNothing);
    expect(find.byKey(const ValueKey('qr_save_pdf')), findsNothing);
    expect(find.byKey(const ValueKey('qr_download_a4')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('qr_image'))).width,
      lessThanOrEqualTo(kOwnerQrViewSize),
    );
  });

  testWidgets('Download in A4 asks how many, capped at what is left',
      (tester) async {
    final repo = FakePublishRepository()
      ..standeeQuota = const StandeeQuota(
        included: 10,
        issued: 7,
        remaining: 3,
        canDownload: true,
        isLive: true,
      );
    final deliverer = FakeQrDeliverer();

    await tester.pumpWidget(harness(repo, deliverer: deliverer));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('qr_download_a4')));
    await tester.pumpAndSettle();

    expect(find.text('3 of 10 standees left on your plan.'), findsOneWidget);

    TextButton download() => tester.widget<TextButton>(
        find.byKey(const ValueKey('owner_standee_download')));

    // Past what is left: the field says so and the button will not go.
    await tester.enterText(
        find.byKey(const ValueKey('owner_standee_field')), '4');
    await tester.pump();
    expect(download().onPressed, isNull);
    expect(find.text('Enter a number from 1 to 3.'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('owner_standee_field')), '2');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('owner_standee_download')));
    await tester.pumpAndSettle();

    expect(repo.standeeDownloads, [2]);
    expect(deliverer.delivered.single.fileName, 'cafe-mocha-standees-x2.pdf');
    expect(deliverer.delivered.single.mimeType, 'application/pdf');
    expect(find.text('2 standees saved. 1 left on your plan.'), findsOneWidget);
  });

  testWidgets('with nothing left it says so and offers no download',
      (tester) async {
    final repo = FakePublishRepository()
      ..standeeQuota = const StandeeQuota(
        included: 10,
        issued: 10,
        remaining: 0,
        canDownload: false,
        isLive: true,
      );

    await tester.pumpWidget(harness(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('qr_download_a4')));
    await tester.pumpAndSettle();

    expect(find.textContaining('downloaded all 10 standees'), findsOneWidget);
    expect(find.byKey(const ValueKey('owner_standee_download')), findsNothing);
    expect(repo.standeeDownloads, isEmpty);
  });

  testWidgets('a refusal from the server is explained, not retried',
      (tester) async {
    // Another phone took the last standees between the dialog and the press.
    final repo = FakePublishRepository()
      ..standeeFailure = const CatalogFailure(
        code: 'STANDEE_LIMIT_REACHED',
        message: 'You can download 0 more standees on your plan.',
        statusCode: 409,
      );

    await tester.pumpWidget(harness(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('qr_download_a4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('owner_standee_download')));
    await tester.pumpAndSettle();

    expect(find.textContaining('more standees than your plan has left'),
        findsOneWidget);
    expect(find.text('Save again'), findsNothing);
  });

  testWidgets('a save that fails is re-saved without spending again',
      (tester) async {
    // A dismissed share sheet AFTER the server counted the standees.
    final repo = FakePublishRepository();
    final deliverer = FakeQrDeliverer()..failure = StateError('no');

    await tester.pumpWidget(harness(repo, deliverer: deliverer));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('qr_download_a4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('owner_standee_download')));
    await tester.pumpAndSettle();

    expect(find.textContaining('cancelled or blocked'), findsOneWidget);
    deliverer.failure = null;
    await tester.tap(find.text('Save again'));
    await tester.pumpAndSettle();

    expect(deliverer.delivered, hasLength(1));
    // ONE download: the retry re-delivered the bytes it already had.
    expect(repo.standeeDownloads, [1]);
  });

  testWidgets('a catalog that is not live gets no A4 download',
      (tester) async {
    final repo = FakePublishRepository(
      catalog: Catalog.fromMap(
        golden.catalogGolden()..['status'] = 'UNPUBLISHED',
      ),
    );

    await tester.pumpWidget(harness(repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('qr_image')), findsOneWidget);
    expect(find.byKey(const ValueKey('qr_download_a4')), findsNothing);
    expect(
        find.byKey(const ValueKey('qr_download_needs_live')), findsOneWidget);
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
}
