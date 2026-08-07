// lib/presentation/widgets/model_row.dart
//
// One row of a project's 3D-model history, shared by the STAFF history screen
// and the OWNER one.
//
// Shared rather than duplicated because the row renders no staff-only ACTION:
// its only affordances are "open this" and "optimize this", and both are
// owner-safe. Everything that differs between the two audiences differs because
// the PAYLOAD differs — the owner DTO simply carries no `selectedKeys` and no
// progress phase, so those terms drop out of the detail line on their own. A
// second copy of this widget would only drift.
//
// The one deliberate switch is [showSourceBadge]: staff already know where a
// model came from (they are looking at the pipeline that made it), while an
// owner needs "Created by Maya AI" attached to the row. It defaults to OFF so
// the staff surface is byte-for-byte what it was.
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/project_model.dart';

/// One generation attempt: when it ran, how it ended, what it was built from.
class ModelRow extends StatefulWidget {
  const ModelRow({
    super.key,
    required this.model,
    this.onTap,
    this.onOptimize,
    this.showSourceBadge = false,
  });

  final ProjectModelView model;

  /// Null for a record with nothing to open — a FAILED one, a pending one, or a
  /// SUCCEEDED one whose GLB is somehow missing. A null onTap is what makes the
  /// row inert; the chevron follows it so the affordance can't lie.
  final VoidCallback? onTap;

  /// Runs the Optimize request. Only ever called from the trailing button,
  /// which only exists when [ProjectModelView.canOptimize] — the SERVER's
  /// verdict, never a rule re-derived here.
  final Future<void> Function()? onOptimize;

  /// Whether to render [ModelSource.badgeLabel] on the row. See the file header.
  final bool showSourceBadge;

  @override
  State<ModelRow> createState() => _ModelRowState();
}

class _ModelRowState extends State<ModelRow> {
  /// True between the tap and the response. The button goes disabled and shows
  /// a spinner: the request is not free (it enqueues real CPU work), and a
  /// second tap before the first lands would only produce a replay the user
  /// cannot distinguish from a bug.
  bool _optimizing = false;

  Future<void> _handleOptimize() async {
    final callback = widget.onOptimize;
    if (callback == null || _optimizing) return;
    setState(() => _optimizing = true);
    try {
      await callback();
    } finally {
      // The list rebuilds after a successful request, so this row may already
      // be gone — guard before touching state.
      if (mounted) setState(() => _optimizing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final onTap = widget.onTap;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    final detail = _detail(model);
    final origin = widget.showSourceBadge ? model.source.badgeLabel : null;
    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              _RowThumbnail(model: model),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '${_stamp(model.createdAt)} · ${_statusLabel(model.status)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium,
                          ),
                        ),
                        if (model.isOptimized) ...[
                          const SizedBox(width: AppSpacing.sm),
                          // Flexible because an OPT record CAN also be
                          // approved: "OPT · 21.4 MB (−68%)" plus the Approved
                          // chip plus a timestamp does not fit a 360dp phone,
                          // and the badge shrinking is better than an overflow.
                          Flexible(child: _OptBadge(model: model)),
                        ],
                        if (model.approved) ...[
                          const SizedBox(width: AppSpacing.sm),
                          const _ApprovedBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    // The origin badge rides the SECOND line, not the title
                    // row: that row can already carry a timestamp, the OPT
                    // chip and the Approved chip, and a fourth item overflows
                    // a 360dp phone. Wrap so the two can also stack.
                    if (origin != null)
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: [
                          _SourceBadge(label: origin),
                          if (detail.isNotEmpty)
                            Text(detail, maxLines: 2, style: muted),
                        ],
                      )
                    else
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // Exactly ONE trailing affordance, in this order: the work
              // indicator wins over everything, then the action, then the
              // "you can open this" chevron.
              if (model.status.isPending)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.textMuted,
                  ),
                )
              // `canOptimize` is the SERVER's verdict. The client never
              // re-derives it from the size, so the button and the endpoint
              // cannot disagree.
              else if (model.canOptimize && widget.onOptimize != null)
                _OptimizeButton(
                  busy: _optimizing,
                  onPressed: _handleOptimize,
                )
              else if (onTap != null)
                const Icon(Icons.chevron_right,
                    color: AppColors.textMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// The secondary line: why it failed, what it is doing, or what it was built
  /// from plus how big it is — the photo count is the main thing that differs
  /// between attempts, and the size is what the Optimize decision hangs on.
  ///
  /// Every term degrades to nothing when its field is absent, which is what
  /// lets the OWNER payload (no selectedKeys, no progress phase) reuse this
  /// unchanged rather than needing a parallel implementation.
  static String _detail(ProjectModelView model) {
    if (model.error case final error?) return error.message;
    if (model.status.isPending) {
      // A pending OPT record runs through the SAME progress phases as a
      // generation (the backend reuses the vocabulary on purpose), so the
      // phase alone cannot tell the two apart — the source can. Generation
      // copy on an optimization would promise a new model that is not coming.
      if (model.isOptimized) {
        return 'Optimizing — shrinking textures and geometry…';
      }
      // Surface the worker's live phase when the backend reports one. Owners
      // never get a phase name (their DTO carries only a percent), so they
      // fall through to the generic line below.
      return switch (model.progress?.phase) {
        ModelProgressPhase.preparing => 'Preparing photos…',
        ModelProgressPhase.generating =>
          'Generating 3D model · ${model.progress!.percent}%',
        ModelProgressPhase.finalizing => 'Saving the model…',
        ModelProgressPhase.unknown ||
        null =>
          'Generating — this takes a few minutes.',
      };
    }
    final parts = [
      if (model.selectedKeys.length case final n when n > 0)
        n == 1 ? '1 photo' : '$n photos',
      // Only when KNOWN. A null size renders nothing at all — see
      // ProjectModelView.sizeBytes: absent means unknown, never zero.
      if (formatBytes(model.sizeBytes) case final size?) size,
    ];
    return parts.join(' · ');
  }

  static String _statusLabel(ModelStatus status) => switch (status) {
        ModelStatus.queued => 'Queued',
        ModelStatus.processing => 'Processing…',
        ModelStatus.succeeded => 'Succeeded',
        ModelStatus.failed => 'Failed',
        ModelStatus.unknown => 'Unknown',
      };

  /// Compact local "Jul 17, 11:42". Hand-rolled: the app has no `intl`
  /// dependency, and one date format does not justify adding it.
  static String _stamp(DateTime? at) {
    if (at == null) return 'Unknown date';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = at.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${months[local.month - 1]} ${local.day}, $hh:$mm';
  }
}

/// The Meshy preview image we re-hosted, when the attempt got far enough to
/// produce one; otherwise a neutral placeholder so every row is the same shape.
class _RowThumbnail extends StatelessWidget {
  const _RowThumbnail({required this.model});

  final ProjectModelView model;

  @override
  Widget build(BuildContext context) {
    final url = model.previewUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: SizedBox(
        width: 44,
        height: 44,
        child: url == null
            ? const _ThumbPlaceholder()
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const _ThumbPlaceholder(),
              ),
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

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

/// Human-readable size, or null when the size is UNKNOWN.
///
/// Uses the BINARY divisor (1024), which is the same one
/// MODEL_OPTIMIZE_THRESHOLD_BYTES is expressed in on the backend. That is not
/// cosmetic: mix the two and an 8,200,000-byte model reads "8.2 MB" while the
/// server, measuring against 8 MiB = 8,388,608, still calls it below threshold
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
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.label});

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
class _OptBadge extends StatelessWidget {
  const _OptBadge({required this.model});

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

/// The Optimize action — unmistakably a BUTTON, and unmistakably not the badge.
///
/// It sits where the chevron would be, is outlined rather than filled, and
/// carries a leading compress icon. While [busy] it goes disabled and swaps the
/// icon for a spinner, so a second tap cannot fire before the first lands.
class _OptimizeButton extends StatelessWidget {
  const _OptimizeButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      key: const ValueKey('model_optimize_button'),
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.textMuted,
              ),
            )
          : const Icon(Icons.compress, size: 16),
      label: const Text('Optimize'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        visualDensity: VisualDensity.compact,
        textStyle: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _ApprovedBadge extends StatelessWidget {
  const _ApprovedBadge();

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
