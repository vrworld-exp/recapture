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
// SAVING IS THE ONE GENUINE PLATFORM SPLIT on this surface: a share sheet on a
// phone, a blob download in a browser. One repository method fetches the bytes;
// `catalog_qr_service.dart` decides what happens to them.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../application/catalog/catalog_qr_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/publish_link_actions.dart';

/// The QR is square and must stay scannable; past this it is just a big square.
const double kQrMaxRenderSize = 320;

class CatalogQrScreen extends ConsumerWidget {
  const CatalogQrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(catalogQrProvider);
    final catalog = ref.watch(catalogProvider).valueOrNull;

    ref.listen<CatalogQrState>(catalogQrProvider, (previous, next) {
      final message = next.failure?.message ?? next.notice;
      if (message == null ||
          message == (previous?.failure?.message ?? previous?.notice)) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
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
                data: (image) => _QrBody(
                  image: image,
                  publicUrl: catalog?.publicUrl,
                  state: state,
                  onSave: (format) =>
                      ref.read(catalogQrProvider.notifier).save(format),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QrBody extends StatelessWidget {
  const _QrBody({
    required this.image,
    required this.publicUrl,
    required this.state,
    required this.onSave,
  });

  final CatalogQrImage image;
  final String? publicUrl;
  final CatalogQrState state;
  final ValueChanged<CatalogQrFormat> onSave;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // WHITE, always, and not a theme token. A QR scanner needs dark modules
        // on a light field; rendering this on the app's near-black surface
        // would produce a code that looks right on screen and cannot be read
        // off it — which is exactly the failure that only shows up in a
        // restaurant, at the table, with a customer waiting.
        Center(
          child: Container(
            constraints: const BoxConstraints(
              maxWidth: kQrMaxRenderSize,
              maxHeight: kQrMaxRenderSize,
            ),
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Image.memory(
              image.bytes,
              key: const ValueKey('qr_image'),
              fit: BoxFit.contain,
              // The server renders far above display size so a browser print
              // and a sticker press both have pixels to work with. Let the
              // engine downscale smoothly rather than nearest-neighbour it into
              // a moiré.
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.broken_image_outlined,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text(
          'Customers scan this to open your catalog.',
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          // Feature 32, said out loud: this is the promise that makes printing
          // worth the money.
          'This code never changes. Print it once — renaming your catalog, '
          'adding products or taking it offline will not break it.',
          textAlign: TextAlign.center,
          style: textTheme.bodySmall
              ?.copyWith(color: AppColors.textSecondary, height: 1.4),
        ),
        if (publicUrl != null && publicUrl!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          SelectableText(
            publicUrl!,
            key: const ValueKey('qr_public_url'),
            textAlign: TextAlign.center,
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          Center(child: PublishLinkActions(url: publicUrl!)),
        ],
        const SizedBox(height: AppSpacing.xl),
        AppButton(
          key: const ValueKey('qr_save_png'),
          label: 'Save PNG',
          icon: Icons.image_outlined,
          isLoading: state.isSaving(CatalogQrFormat.png),
          onPressed: state.savingFormat != null
              ? null
              : () => onSave(CatalogQrFormat.png),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton.secondary(
          key: const ValueKey('qr_save_pdf'),
          label: 'Save PDF for printing',
          icon: Icons.picture_as_pdf_outlined,
          isLoading: state.isSaving(CatalogQrFormat.pdf),
          onPressed: state.savingFormat != null
              ? null
              : () => onSave(CatalogQrFormat.pdf),
        ),
      ],
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
