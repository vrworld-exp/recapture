// lib/presentation/widgets/catalog/qr_code_panel.dart
//
// The QR code, as a thing on a screen: the white square, the link under it, and
// the two ways to save it.
//
// ONE WIDGET, TWO READERS — the owner's `/catalog/qr` and the rep's
// `/rep/catalogs/:id/qr`. They are looking at the SAME physical object: the
// server renders both from the same frozen `publicUrl` through the same
// renderer, so a rep and a restaurant owner cannot end up printing two
// different squares. Having drawn it in two places would have made that true
// of the bytes and false of everything around them — a padding, a caption or a
// save button that drifted on one surface only.
//
// WHAT IS PARAMETERISED IS THE SENTENCES, and nothing else. A rep is told about
// "this menu"; an owner is told about "your catalog". The geometry, the white
// field and the keys are fixed here on purpose.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../data/repositories/catalog_repository.dart'
    show CatalogQrFormat;
import '../app_button.dart';
import 'publish_link_actions.dart';

/// The QR is square and must stay scannable; past this it is just a big square.
const double kQrMaxRenderSize = 320;

class QrCodePanel extends StatelessWidget {
  const QrCodePanel({
    super.key,
    required this.bytes,
    required this.publicUrl,
    required this.savingFormat,
    required this.onSave,
    required this.scanCaption,
    required this.permanenceNote,
    this.shareSubject,
  });

  /// The rendered PNG, exactly as the server sent it.
  final Uint8List bytes;

  /// `catalog.publicUrl`, VERBATIM — never composed, shortened or re-cased.
  final String? publicUrl;

  /// Which format is saving right now, so one button spins and the other only
  /// goes disabled.
  final CatalogQrFormat? savingFormat;

  final ValueChanged<CatalogQrFormat> onSave;

  /// "Customers scan this to open your catalog." — who is being told what.
  final String scanCaption;

  /// The promise that makes printing worth the money (feature 32), said in the
  /// second person that fits the reader.
  final String permanenceNote;

  /// Subject line for a share sheet. Null takes [PublishLinkActions]' own.
  final String? shareSubject;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final url = publicUrl;

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
              bytes,
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
          scanCaption,
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          permanenceNote,
          textAlign: TextAlign.center,
          style: textTheme.bodySmall
              ?.copyWith(color: AppColors.textSecondary, height: 1.4),
        ),
        if (url != null && url.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          SelectableText(
            url,
            key: const ValueKey('qr_public_url'),
            textAlign: TextAlign.center,
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: PublishLinkActions(url: url, shareSubject: shareSubject),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        AppButton(
          key: const ValueKey('qr_save_png'),
          label: 'Save PNG',
          icon: Icons.image_outlined,
          isLoading: savingFormat == CatalogQrFormat.png,
          onPressed:
              savingFormat != null ? null : () => onSave(CatalogQrFormat.png),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton.secondary(
          key: const ValueKey('qr_save_pdf'),
          label: 'Save PDF for printing',
          icon: Icons.picture_as_pdf_outlined,
          isLoading: savingFormat == CatalogQrFormat.pdf,
          onPressed:
              savingFormat != null ? null : () => onSave(CatalogQrFormat.pdf),
        ),
      ],
    );
  }
}
