// lib/presentation/screens/catalog/catalog_qr_screen.dart
//
// `/catalog/qr` — the code that goes on the table (features 31-35).
//
// THE LINK IS SHOWN VERBATIM AND COMPOSED BY NOBODY. `catalog.publicUrl` is
// minted server-side at provisioning and frozen from that moment: it is what
// every sticker a business has printed resolves through, so this screen never
// shortens it, never re-cases it, never strips a trailing slash and never
// rebuilds it from parts. The QR itself is rendered SERVER-side from the same
// string, which is what makes "a printed sticker keeps working" a property of
// the system rather than a rule somebody has to remember.
//
// BEFORE THE FIRST PUBLISH THERE IS NO CODE, and the screen says exactly that.
// The backend answers 409 CATALOG_NOT_PUBLISHED rather than inventing a URL,
// because a QR that resolves to nothing is worse than no QR — it might get
// printed.
//
// VIEW-ONLY. The owner prints through "Download in A4" — the counted standee
// download, drawn from the plan's allowance (`owner_standee_dialog.dart`) and
// offered only while the catalog is live. There is no free PNG/PDF save here,
// the square is drawn small ([kOwnerQrViewSize]), and on Android the window
// is FLAG_SECURE while this screen is open ([SecureScreen]) so a screenshot
// comes out blank. iOS and the browser cannot block one; there, the small
// square is the only friction.
//
// THE SQUARE ITSELF IS DRAWN BY [QrCodePanel], which the rep's
// `/rep/catalogs/:id/qr` also uses. The two surfaces show the same physical
// object — the server renders both from the same frozen URL — so they draw it
// with the same widget rather than with two copies that could drift.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../data/repositories/menu_extras_repository.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../application/catalog/catalog_qr_notifier.dart';
import '../../../application/catalog/owner_standee_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog_status.dart';
import '../../../platform/secure_screen.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/owner_standee_dialog.dart';
import '../../widgets/catalog/qr_code_panel.dart';

class CatalogQrScreen extends ConsumerStatefulWidget {
  const CatalogQrScreen({super.key});

  @override
  ConsumerState<CatalogQrScreen> createState() => _CatalogQrScreenState();
}

class _CatalogQrScreenState extends ConsumerState<CatalogQrScreen> {
  @override
  void initState() {
    super.initState();
    SecureScreen.enable();
  }

  @override
  void dispose() {
    SecureScreen.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(catalogQrProvider);
    final catalog = ref.watch(catalogProvider).valueOrNull;
    final isLive = catalog?.status.isLive ?? false;
    final downloading = ref.watch(ownerStandeeProvider).busy;
    listenOwnerStandee(context, ref);

    ref.listen<CatalogQrState>(catalogQrProvider, (previous, next) {
      final failure = next.failure;
      final changed = failure?.code != previous?.failure?.code ||
          next.notice != previous?.notice;
      if (!changed) return;

      final messenger = CatalogFeedback.of(context);
      if (failure != null) {
        CatalogFeedback.failure(messenger, failure, subject: 'That did not work');
      } else if (next.notice != null) {
        CatalogFeedback.confirm(messenger, next.notice!);
      }
    });

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => navigateBack(context),
        ),
        title: Text('QR code', style: Theme.of(context).textTheme.titleLarge),
        actions: [
          // Stage 7: colours, the logo in the centre, frame text, standee template.
          if (ref.watch(customizationVisibleProvider))
          IconButton(
            key: const Key('qr_open_style'),
            tooltip: 'QR style',
            icon: const Icon(Icons.palette_outlined),
            onPressed: () => context.pushNamed(AppRouteNames.catalogQrStyle),
          ),
        ],
      ),
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
                  onRetry: () => ref.read(catalogQrProvider.notifier).load(),
                ),
                data: (image) => QrCodePanel(
                  bytes: image.bytes,
                  publicUrl: catalog?.publicUrl,
                  renderSize: kOwnerQrViewSize,
                  footer: isLive
                      ? AppButton(
                          key: const ValueKey('qr_download_a4'),
                          label: 'Download in A4 size',
                          icon: Icons.picture_as_pdf_outlined,
                          isLoading: downloading,
                          onPressed: downloading
                              ? null
                              : () => startOwnerStandeeDownload(context, ref),
                        )
                      : Text(
                          'You can download your QR code as A4 standees '
                          'once your catalog is live.',
                          key: const ValueKey('qr_download_needs_live'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                  scanCaption: 'Customers scan this to open your catalog.',
                  // Feature 32, said out loud: this is the promise that makes
                  // printing worth the money. RENAMING IS NOT ON THE LIST any
                  // more: the link is the catalog's NAME on the public host
                  // (services/customerUrl.ts), so a rename is the one edit
                  // that does move it. Promising otherwise here would be the
                  // lie a printed sticker finds out.
                  permanenceNote:
                      'Print it once — adding products or taking the catalog '
                      'offline will not break it. Renaming the catalog changes '
                      'the link, so reprint after a rename.',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// No QR yet, or the fetch failed.
///
/// The two read differently and must: "publish first" is an instruction, and
/// "try again" is an apology.
class _QrUnavailable extends StatelessWidget {
  const _QrUnavailable({required this.failure, required this.onRetry});

  final CatalogFailure? failure;
  final VoidCallback onRetry;

  /// The backend's code for "there is no public URL yet, because nothing has
  /// been published".
  static const _notPublished = 'CATALOG_NOT_PUBLISHED';

  @override
  Widget build(BuildContext context) {
    final notPublished = failure?.code == _notPublished;

    return CatalogMessage(
      fillsViewport: false,
      icon: notPublished ? Icons.qr_code_2 : Icons.cloud_off_outlined,
      title: notPublished
          ? 'Your QR code is created when you publish'
          : "We couldn't load your QR code",
      body: notPublished
          // Explains WHY there is nothing here, which is the difference between
          // a missing feature and a step not taken yet.
          ? 'Publishing gives your catalog a permanent link, and this code '
              'points at it. The link never changes after that, so the code '
              'you print today keeps working.'
          : failure?.message ?? 'Something went wrong. Please try again.',
      actionLabel: notPublished ? null : 'Try again',
      onAction: notPublished ? null : onRetry,
    );
  }
}
