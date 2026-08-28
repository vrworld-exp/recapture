// lib/presentation/widgets/model_presentation.dart
//
// The shared VISUAL VOCABULARY for one 3D-model record: its thumbnail, its
// timestamp, its status word, and the chips that qualify it (`OPT`, the origin
// badge, Approved).
//
// Extracted out of [ModelRow] rather than copied, because a second surface now
// renders the same facts with a different AFFORDANCE: the model history row
// opens a model, while [ModelChoiceTile] selects one. Only the layout and the
// trailing control differ — every term inside them is identical, and two copies
// of "how big is it, when was it made, where did it come from" is exactly how
// the picker starts disagreeing with the history it is picking from.
//
// Nothing here takes a repository, a provider or a callback: these are pure
// presentation of a [ProjectModelView]. The widget keys are part of the
// contract — the existing model-row tests find the badges by them.
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/project_model.dart';

/// The Meshy preview image we re-hosted, when the attempt got far enough to
/// produce one; otherwise a neutral placeholder so every row is the same shape.
///
/// `previewUrl` is a CloudFront URL and behaves identically on web and native,
/// but a 403/404 (a purged artifact, an expired object) must degrade to the
/// placeholder rather than a broken-image box — hence the [errorBuilder].
class ModelThumbnail extends StatelessWidget {
  const ModelThumbnail({super.key, required this.model, this.size = 44});

  final ProjectModelView model;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = model.previewUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? const ModelThumbnailPlaceholder()
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ModelThumbnailPlaceholder(),
              ),
      ),
    );
  }
}

class ModelThumbnailPlaceholder extends StatelessWidget {
  const ModelThumbnailPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface2,
      alignment: Alignment.center,
      child: const Icon(Icons.view_in_ar_outlined,
          color: AppColors.textMuted, size: 20),
    );
  }
}

/// Compact local "Jul 17, 11:42". Hand-rolled: the app has no `intl`
/// dependency, and one date format does not justify adding it.
///
/// A null [at] is a real case — [ProjectModelView.createdAt] parses a malformed
/// stamp to null rather than throwing — and reads "Unknown date". An undated
/// record is still a perfectly selectable model; only its LABEL is unknown.
String modelStamp(DateTime? at) {
  if (at == null) return 'Unknown date';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = at.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${months[local.month - 1]} ${local.day}, $hh:$mm';
}

String modelStatusLabel(ModelStatus status) => switch (status) {
      ModelStatus.queued => 'Queued',
      ModelStatus.processing => 'Processing…',
      ModelStatus.succeeded => 'Succeeded',
      ModelStatus.failed => 'Failed',
      ModelStatus.unknown => 'Unknown',
    };

/// Human-readable size, or null when the size is UNKNOWN.
///
/// Uses the BINARY divisor (1024), which is the same one
/// MODEL_OPTIMIZE_THRESHOLD_BYTES is expressed in on the backend. That is not
/// cosmetic: mix the two and a 5,100,000-byte model reads "5.1 MB" while the
/// server, measuring against 5 MiB = 5,242,880, still calls it below threshold
/// and shows no button — a display that contradicts the affordance next to it.
///
/// Returns null rather than "0 B" for an absent size: absent means unknown.
String? formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return null;
  const kb = 1024;
  const mb = kb * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// Where the model came from — the owner-facing origin label.
///
/// An outline chip, deliberately unlike both the filled `OPT` pill and the
/// red Approved mark: it is neither a result nor a sign-off, just provenance.
class ModelSourceBadge extends StatelessWidget {
  const ModelSourceBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('model_source_badge'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.textMuted),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: AppColors.textMuted),
      ),
    );
  }
}

/// The `OPT` chip — a STATE LABEL, not an action.
///
/// Everything about it is chosen to keep it from reading as a button: it is a
/// filled pill with no ripple, no border, no chevron and no tap target. Its
/// colour is deliberately NOT [AppColors.mirageRed] — that already means
/// "Approved" one chip along this same row, and two different facts wearing the
/// same colour is how a row starts lying.
class ModelOptBadge extends StatelessWidget {
  const ModelOptBadge({super.key, required this.model});

  final ProjectModelView model;

  @override
  Widget build(BuildContext context) {
    final saving = model.optimizationSavingPercent;
    final size = formatBytes(model.sizeBytes);
    // "OPT · 6.8 MB (−68%)" when everything is known, degrading term by term.
    final label = [
      'OPT',
      if (size != null) size,
    ].join(' · ');
    return Container(
      key: const ValueKey('model_opt_badge'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.success,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        saving == null ? label : '$label (−$saving%)',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              // On the light-green fill, the app's dark background is the
              // readable foreground.
              color: AppColors.bgPrimary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class ModelApprovedBadge extends StatelessWidget {
  const ModelApprovedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, size: 13, color: AppColors.mirageRed),
        const SizedBox(width: AppSpacing.xs),
        Text(
          'Approved',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.mirageRed),
        ),
      ],
    );
  }
}
