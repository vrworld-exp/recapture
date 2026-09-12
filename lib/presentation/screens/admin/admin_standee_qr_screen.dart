// lib/presentation/screens/admin/admin_standee_qr_screen.dart
//
// `/admin/standees/:batchId/codes/:code/qr` — what a standee in use turned
// into: the restaurant's QR, its link, and the rep who activated it.
//
// THE BATCH LIST SAID "IN USE" AND STOPPED THERE. An admin could see a code
// had been claimed and not which restaurant now answers to it, so "is this
// the menu I think it is?" meant scanning the physical standee. This screen
// is the QR page the rep and the owner already have — the same [QrCodePanel],
// the same Mirage link, copy, open and save — reached from the admin's row,
// so all three roles look at the identical square.
//
// AND UNDER IT, WHO STOOD AT THE TABLE. The "Activated by" block is the
// reason an admin opens this rather than the rep's screen: when the menu is
// wrong, the person to ring is the one who activated the standee. Picture and
// name come with the document; the RAW phone or email is fetched through
// `projectOwnerProvider` — `GET /admin/users/:id`, the ONE unmasked-contact
// path, ADMIN-only, metered and audited server-side — on open, and dropped on
// close. Nothing here is logged, persisted or handed to analytics, and the
// copy buttons confirm without echoing the value, exactly as the "Created by"
// sheet does. The route is behind the `/admin/standees` gate, which is
// `isAdminProvider`, so only an admin can reach this screen at all.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/admin/admin_standee_activation_notifier.dart';
import '../../../application/projects/project_owner_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/project_owner.dart';
import '../../../domain/entities/standee_activation.dart';
import '../../../utils/extensions.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/qr_code_panel.dart';
import '../projects/project_owner_sheet.dart' show OwnerAvatar, OwnerContactRow;

class AdminStandeeQrScreen extends ConsumerWidget {
  const AdminStandeeQrScreen({super.key, required this.code});

  /// The standee's printed code.
  final String code;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activation = ref.watch(adminStandeeActivationProvider(code));
    final qr = ref.watch(adminStandeeQrProvider(code));

    ref.listen<AdminStandeeQrState>(adminStandeeQrProvider(code),
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
              child: activation.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.huge),
                  child: AppLoadingIndicator(),
                ),
                error: (error, _) => _ActivationUnavailable(
                  failure: error is CatalogFailure ? error : null,
                  onRetry: () =>
                      ref.invalidate(adminStandeeActivationProvider(code)),
                ),
                data: (activation) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RestaurantHeader(activation: activation),
                    const SizedBox(height: AppSpacing.xl),
                    qr.image.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.all(AppSpacing.huge),
                        child: AppLoadingIndicator(),
                      ),
                      error: (error, _) => _QrUnavailable(
                        failure: error is CatalogFailure ? error : null,
                        onRetry: () => ref
                            .read(adminStandeeQrProvider(code).notifier)
                            .load(),
                      ),
                      data: (image) => QrCodePanel(
                        bytes: image.bytes,
                        publicUrl: activation.catalog.publicUrl,
                        savingFormat: qr.savingFormat,
                        onSave: (format) => ref
                            .read(adminStandeeQrProvider(code).notifier)
                            .save(format),
                        // Third person: the admin is neither the restaurant
                        // nor the customer, and the sentence says whose menu
                        // this is.
                        scanCaption:
                            'Customers scan this to open this restaurant’s '
                            'menu.',
                        permanenceNote:
                            'This is the same code the restaurant and the rep '
                            'see. Adding dishes or taking the menu offline '
                            'will not break it.',
                        shareSubject: activation.catalog.displayName,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxl),
                    _ActivatedBy(activation: activation),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Which restaurant this standee became, and the code it became it from.
class _RestaurantHeader extends StatelessWidget {
  const _RestaurantHeader({required this.activation});

  final StandeeActivation activation;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          activation.catalog.displayName,
          key: const ValueKey('admin_activation_restaurant'),
          style: const TextStyle(
            fontSize: AppTypography.sizeTitle,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Standee ${activation.code}'
          '${activation.activatedAt == null ? '' : ' · activated ${activation.activatedAt!.timeAgo}'}',
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// The rep who activated the standee — picture, name, and the raw contact.
///
/// The document already knows the person; the contact is a second, bounded
/// read (see the file header). The header paints from the summary on the
/// first frame and the contact rows fill in under it, so the block opens onto
/// a person rather than a spinner.
class _ActivatedBy extends ConsumerWidget {
  const _ActivatedBy({required this.activation});

  final StandeeActivation activation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final who = activation.activatedBy;

    return Container(
      key: const ValueKey('admin_activated_by'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Activated by',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          if (who == null)
            // The audit field outlived the account. Say so rather than draw
            // an empty person.
            Text(
              'The account that activated this standee no longer exists.',
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            )
          else ...[
            Row(
              children: [
                OwnerAvatar(owner: who, size: 48),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        who.displayLabel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium,
                      ),
                      if (!who.hasDisplayName)
                        Text(
                          'This account has not set a name.',
                          style: textTheme.bodySmall
                              ?.copyWith(color: AppColors.textMuted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            _Contact(owner: who),
          ],
        ],
      ),
    );
  }
}

/// The contact rows — the part that waits on the bounded read.
class _Contact extends ConsumerWidget {
  const _Contact({required this.owner});

  final ProjectOwnerSummary owner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final detail = ref.watch(projectOwnerProvider(owner.id));

    return detail.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Center(child: AppLoadingIndicator()),
      ),
      error: (_, __) => Row(
        children: [
          Expanded(
            child: Text(
              "Couldn't load this person's contact details.",
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => ref.invalidate(projectOwnerProvider(owner.id)),
            child: const Text('Try again'),
          ),
        ],
      ),
      data: (person) => person.hasAnyContact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (person.phone != null) ...[
                  OwnerContactRow(
                    icon: Icons.phone_outlined,
                    label: 'Phone',
                    value: person.phone!,
                    verified: person.phoneVerified,
                  ),
                  if (person.email != null)
                    const SizedBox(height: AppSpacing.md),
                ],
                if (person.email != null)
                  OwnerContactRow(
                    icon: Icons.mail_outline,
                    label: 'Email',
                    value: person.email!,
                    verified: person.emailVerified,
                  ),
              ],
            )
          : Text(
              'No contact details on this account.',
              style:
                  textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
    );
  }
}

/// The document could not be read: the standee is not in use, or the fetch
/// failed. Two sentences, because one is a fact and the other an apology.
class _ActivationUnavailable extends StatelessWidget {
  const _ActivationUnavailable({required this.failure, required this.onRetry});

  final CatalogFailure? failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final notInUse = failure?.code == 'NOT_FOUND';
    return CatalogMessage(
      fillsViewport: false,
      icon: notInUse ? Icons.qr_code_2 : Icons.cloud_off_outlined,
      title: notInUse
          ? 'This standee is not in use'
          : "We couldn't load this standee",
      body: notInUse
          ? 'No restaurant has been activated with this code, or the one that '
              'was has since been deleted.'
          : failure?.message ?? 'Something went wrong. Please try again.',
      actionLabel: notInUse ? null : 'Try again',
      onAction: notInUse ? null : onRetry,
    );
  }
}

/// The square could not be drawn — most often because the restaurant has been
/// activated but never published, which is a normal state, not a fault.
class _QrUnavailable extends StatelessWidget {
  const _QrUnavailable({required this.failure, required this.onRetry});

  final CatalogFailure? failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final notPublished = failure?.code == 'CATALOG_NOT_PUBLISHED';
    return CatalogMessage(
      fillsViewport: false,
      icon: notPublished ? Icons.qr_code_2 : Icons.cloud_off_outlined,
      title: notPublished
          ? 'The QR code is created when the menu goes live'
          : "We couldn't load this QR code",
      body: notPublished
          ? 'This restaurant has been activated but not published yet. The '
              'code and its link appear once the rep publishes the menu.'
          : failure?.message ?? 'Something went wrong. Please try again.',
      actionLabel: notPublished ? null : 'Try again',
      onAction: notPublished ? null : onRetry,
    );
  }
}
