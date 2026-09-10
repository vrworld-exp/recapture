// lib/presentation/screens/projects/project_owner_sheet.dart
//
// "Created by …" — the ADMIN-only sheet behind the owner label on a live
// project card. Picture, name, role, and the RAW email/phone, so an admin
// looking at a bad capture can reach the person who made it.
//
// ⚠ THIS IS THE ONLY SURFACE IN THE APP THAT SHOWS AN UNMASKED CONTACT
// IDENTIFIER. Everywhere else — the Profile screen, the standee roster — shows
// a mask (`+91 ••••• ••210`). The exception is bounded on both sides: the
// backend refuses the route below ADMIN, meters it and audits every read; this
// sheet fetches on OPEN and drops the data on CLOSE (see
// [projectOwnerProvider], autoDispose without a keepAlive). Nothing here is
// logged, persisted, or handed to analytics.
//
// It takes the SUMMARY the list already has and fetches the detail itself,
// rather than making the caller fetch first. That is what lets the header —
// picture and name — paint immediately while the contact rows resolve, so the
// sheet opens onto the person the admin tapped instead of onto a spinner.
//
// The picture comes from bytes ([projectOwnerAvatarProvider]), not a URL, which
// is why it renders on the WEB build as well as the apk — see that provider.
import 'package:flutter/material.dart';
// Also the source of Uint8List here — flutter/services re-exports dart:typed_data.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/projects/project_owner_notifier.dart';
import '../../../data/repositories/live_projects_repository.dart';
import '../../../domain/entities/project_owner.dart';
import '../../../domain/entities/user_role.dart';
import '../../widgets/app_button.dart';

/// Opens the owner sheet for [owner] — the summary carried on the project row.
///
/// Resolves when the sheet closes; it returns nothing because it decides
/// nothing. Unlike `showAssignStandeeSheet`, which hands a CHOICE back to its
/// caller, this sheet is purely informational — there is no action for the
/// caller to perform and therefore nothing to report.
Future<void> showProjectOwnerSheet(
  BuildContext context, {
  required ProjectOwnerSummary owner,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface1,
    isScrollControlled: true,
    showDragHandle: true,
    barrierColor: AppColors.scrim,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (_) => _OwnerSheet(summary: owner),
  );
}

class _OwnerSheet extends ConsumerWidget {
  const _OwnerSheet({required this.summary});

  /// What the list already knew — enough to paint the header before the
  /// detail call lands.
  final ProjectOwnerSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(projectOwnerProvider(summary.id));

    return SafeArea(
      child: ConstrainedBox(
        // Capped like the standee picker: a sheet with four rows in it must not
        // become a full-height wall, and a large text scale scrolls instead.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            0,
            AppSpacing.xl,
            AppSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Created by',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Header from the SUMMARY, so it is already correct on the first
              // frame. The detail call only ever adds to what is shown here —
              // it never contradicts it.
              Row(
                children: [
                  OwnerAvatar(owner: summary, size: 56),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          summary.displayLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (!summary.hasDisplayName) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'This account has not set a name.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppColors.textMuted),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),

              detail.when(
                loading: () => const _DetailSkeleton(),
                error: (error, _) => _DetailError(
                  error: error,
                  onRetry: () =>
                      ref.invalidate(projectOwnerProvider(summary.id)),
                ),
                data: (owner) => _DetailBody(owner: owner),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The contact block — the part that waits on the network.
class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.owner});

  final ProjectOwnerDetail owner;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!owner.hasAnyContact)
          // Two empty rows would read as a broken sheet; one sentence says the
          // true thing. It happens: an account can exist on a verified channel
          // that was later cleared.
          Text(
            'No contact details on this account.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.textMuted),
          )
        else ...[
          if (owner.phone != null) ...[
            _ContactRow(
              icon: Icons.phone_outlined,
              label: 'Phone',
              value: owner.phone!,
              verified: owner.phoneVerified,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (owner.email != null) ...[
            _ContactRow(
              icon: Icons.mail_outline,
              label: 'Email',
              value: owner.email!,
              verified: owner.emailVerified,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
        const SizedBox(height: AppSpacing.xs),
        const Divider(color: AppColors.disabled, thickness: 0.5, height: 1),
        const SizedBox(height: AppSpacing.md),
        _MetaRow(label: 'Role', value: _roleLabel(owner.role)),
        const SizedBox(height: AppSpacing.sm),
        _MetaRow(label: 'Member since', value: _formatMemberSince(owner.createdAt)),
      ],
    );
  }
}

/// One contact identifier, with the control that makes it useful.
///
/// COPY rather than "call" or "email": a tap-to-dial would hand the number to
/// whatever app the OS picks, which does nothing at all on the web build. Copy
/// works identically on both, and an admin pastes it wherever they actually
/// work.
class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.verified,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: AppColors.textSecondary),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
                  if (verified) ...[
                    const SizedBox(width: AppSpacing.xs),
                    const Icon(Icons.verified_outlined,
                        size: 12, color: AppColors.success),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              // SelectableText so a desktop/web admin can grab part of it
              // without the copy button, which is how people actually use a
              // number on a large screen.
              SelectableText(
                value,
                maxLines: 2,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        IconButton(
          key: ValueKey('owner_copy_$label'),
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          color: AppColors.textMuted,
          tooltip: 'Copy $label',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              // The VALUE is deliberately not echoed in the snackbar: a
              // confirmation that repeats a phone number lands it in the
              // screenshot of whatever the admin was doing next.
              ..showSnackBar(SnackBar(content: Text('$label copied.')));
          },
        ),
      ],
    );
  }
}

/// A plain label/value line for the non-contact facts.
class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Both sides flex — same reasoning as the Profile screen's _InfoRow: two
    // unconstrained Texts in a spaceBetween Row overflow at a large text scale.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style:
                theme.textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// The owner's picture, or their initials, or a person glyph — in that order.
///
/// Public because the CARD draws the same thing at a smaller size, and two
/// copies of this fallback chain would be two chances for the label and the
/// sheet to disagree about the same person.
///
/// Loading and failure both resolve to initials: an avatar that will not load
/// must never leave a hole where the label was.
class OwnerAvatar extends ConsumerWidget {
  const OwnerAvatar({super.key, required this.owner, this.size = 28});

  final ProjectOwnerSummary owner;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Not even asked for when the account has no picture — that is what the
    // `hasAvatar` boolean on the list row buys.
    final bytes = owner.hasAvatar
        ? ref.watch(projectOwnerAvatarProvider(owner.id)).valueOrNull
        : null;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.royalGold, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes != null && bytes.isNotEmpty
          ? _picture(bytes)
          : Center(child: _fallback(context)),
    );
  }

  Widget _picture(Uint8List bytes) {
    return Image.memory(
      bytes,
      width: size,
      height: size,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      // Undecodable bytes degrade to initials, never to a broken-image glyph.
      errorBuilder: (context, _, __) => Center(child: _fallback(context)),
    );
  }

  Widget _fallback(BuildContext context) {
    final initials = owner.initials;
    if (initials == null) {
      return Icon(
        Icons.person_outline,
        size: size * 0.55,
        color: AppColors.textMuted,
      );
    }
    return Text(
      initials,
      style: TextStyle(
        color: AppColors.royalGold,
        fontSize: size * 0.36,
        fontWeight: FontWeight.w600,
        height: 1,
      ),
    );
  }
}

/// Placeholder for the contact block while the detail call is in flight —
/// the sheet keeps its shape rather than jumping when the rows land.
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SkeletonBox(width: 180, height: 14),
        SizedBox(height: AppSpacing.lg),
        _SkeletonBox(width: 220, height: 14),
        SizedBox(height: AppSpacing.lg),
        _SkeletonBox(width: 140, height: 14),
      ],
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
    );
  }
}

/// MAPPED-ONLY failure copy, same rule as the Live-projects list: no raw codes,
/// no URLs, and never the thing we failed to fetch.
class _DetailError extends StatelessWidget {
  const _DetailError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = switch (error) {
      LiveProjectsException(failure: LiveProjectsFailure.forbidden) =>
        'Your account no longer has admin access.',
      LiveProjectsException(failure: LiveProjectsFailure.notFound) =>
        'This account no longer exists.',
      LiveProjectsException(
        failure: LiveProjectsFailure.rateLimited,
        retryAfterSeconds: final retry
      ) =>
        retry == null
            ? 'Too many lookups — try again later.'
            : 'Too many lookups — try again in ${_friendlyWait(retry)}.',
      LiveProjectsException(failure: LiveProjectsFailure.network) =>
        'You’re offline — check your connection and try again.',
      _ => 'Couldn’t load these details. Please try again.',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          label: 'Retry',
          icon: Icons.refresh,
          isFullWidth: false,
          onPressed: onRetry,
        ),
      ],
    );
  }
}

String _friendlyWait(int seconds) {
  if (seconds < 90) return '$seconds seconds';
  return '${(seconds / 60).ceil()} minutes';
}

String _roleLabel(UserRole role) => switch (role) {
      UserRole.admin => 'Admin',
      UserRole.modelArtist => 'Model artist',
      UserRole.salesRep => 'Sales rep',
      UserRole.user => 'User',
    };

/// 'March 2026'. Local-time month/year — no l10n framework in this repo, so the
/// month names are resolved in Dart (the existing convention).
String _formatMemberSince(DateTime utc) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final local = utc.toLocal();
  return '${months[local.month - 1]} ${local.year}';
}
