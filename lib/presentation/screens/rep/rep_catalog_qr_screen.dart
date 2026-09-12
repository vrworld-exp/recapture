// lib/presentation/screens/rep/rep_catalog_qr_screen.dart
//
// `/rep/catalogs/:id/qr` — the restaurant's own code, shown by the rep who put
// the menu online.
//
// THE OWNER'S QR SCREEN, FOR SOMEBODY ELSE'S RESTAURANT. It draws the same
// square through the same [QrCodePanel], saves through the same deliverer seam,
// and shows the same frozen `publicUrl` verbatim — because it IS the same
// object. The server renders both surfaces from the one stored URL through the
// one renderer, so a rep holding up their phone and an owner printing at home
// are looking at identical bytes.
//
// NOT THE STANDEE SHEET. `/rep/standees` hands over the printed artwork for a
// code in the rep's stock, with the eight characters on it that a rep reads
// aloud while activating. This is the menu's code, for a restaurant that is
// ALREADY live, and it is what gets reprinted when the table sticker gets wet.
// Two different pieces of paper, two different moments in a visit.
//
// THE URL COMES FROM THE CATALOG DOCUMENT, not from the row that was tapped.
// A rep can land here on a browser reload with no list in memory, and a screen
// that could only render when it was pushed from somewhere would be a screen
// that breaks on refresh.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/rep/rep_catalog_qr_notifier.dart';
import '../../../application/rep/rep_restaurant_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/qr_code_panel.dart';

class RepCatalogQrScreen extends ConsumerWidget {
  const RepCatalogQrScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(repCatalogQrProvider(catalogId));
    final restaurant =
        ref.watch(repCatalogDocumentProvider(catalogId)).valueOrNull;

    ref.listen<RepCatalogQrState>(repCatalogQrProvider(catalogId),
        (previous, next) {
      final failure = next.failure;
      final changed = failure?.code != previous?.failure?.code ||
          next.notice != previous?.notice;
      if (!changed) return;

      final messenger = CatalogFeedback.of(context);
      if (failure != null) {
        CatalogFeedback.failure(
          messenger,
          failure,
          subject: 'That QR code could not be saved',
        );
      } else if (next.notice != null) {
        CatalogFeedback.confirm(messenger, next.notice!);
      }
    });

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('QR code')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: state.image.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.huge),
                  child: AppLoadingIndicator(),
                ),
                error: (error, _) => _QrUnavailable(
                  failure: error is CatalogFailure ? error : null,
                  onRetry: () =>
                      ref.read(repCatalogQrProvider(catalogId).notifier).load(),
                ),
                data: (image) => QrCodePanel(
                  bytes: image.bytes,
                  publicUrl: restaurant?.publicUrl,
                  savingFormat: state.savingFormat,
                  onSave: (format) => ref
                      .read(repCatalogQrProvider(catalogId).notifier)
                      .save(format),
                  // Second person, aimed at the RESTAURANT — the rep is holding
                  // the phone, but the sentence is what they say out loud while
                  // handing it over.
                  scanCaption:
                      'Customers scan this to open this restaurant\u2019s menu.',
                  // Renaming is deliberately NOT promised \u2014 see the owner's
                  // QR screen: the link is the restaurant's name.
                  permanenceNote:
                      'Print it once \u2014 adding dishes or taking the menu '
                      'offline will not break it. Renaming the restaurant '
                      'changes the link, so reprint after a rename.',
                  shareSubject: restaurant?.displayName,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// No QR yet, the delegation is gone, or the fetch failed.
///
/// THREE STATES, THREE SENTENCES, and they are not interchangeable. "Publish
/// the menu" is an instruction a rep can act on at the table; "this restaurant
/// is no longer yours" is a fact they need to stop trying; "try again" is an
/// apology for us.
class _QrUnavailable extends StatelessWidget {
  const _QrUnavailable({required this.failure, required this.onRetry});

  final CatalogFailure? failure;
  final VoidCallback onRetry;

  /// The backend's code for "there is no public URL yet, because this
  /// restaurant has never been published".
  static const _notPublished = 'CATALOG_NOT_PUBLISHED';

  @override
  Widget build(BuildContext context) {
    final notPublished = failure?.code == _notPublished;
    final gone = failure != null && isDelegationGone(failure!);

    if (gone) {
      return const CatalogMessage(
        fillsViewport: false,
        icon: Icons.person_off_outlined,
        title: 'This restaurant is no longer assigned to you',
        body: 'Go back to your restaurants to see what is.',
      );
    }

    return CatalogMessage(
      fillsViewport: false,
      icon: notPublished ? Icons.qr_code_2 : Icons.cloud_off_outlined,
      title: notPublished
          ? 'The QR code is created when the menu goes live'
          : "We couldn't load this QR code",
      body: notPublished
          // Explains WHY there is nothing here, which is the difference between
          // a missing feature and a step not taken yet.
          ? 'Publishing gives this restaurant a permanent link, and this code '
              'points at it. The link never changes after that, so the code '
              'printed today keeps working.'
          : failure?.message ?? 'Something went wrong. Please try again.',
      actionLabel: notPublished ? null : 'Try again',
      onAction: notPublished ? null : onRetry,
    );
  }
}
