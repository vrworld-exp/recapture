// lib/presentation/widgets/step_checklist_row.dart
//
// One row of a vertical step checklist — the Dev Tools smoke-card look
// (lib/dev/dev_probe/dev_tools_section.dart) promoted into a shared production
// widget: leading state icon (○ pending / spinner running / ✓ done / ✗ failed /
// — cancelled), a label, an optional trailing widget (badge/counter), a chevron
// when expandable detail exists, and the expanded detail block beneath.
//
// Pure presentation: no providers, no upload types — callers map their own
// state onto [StepRowStatus] and pass fully-built detail content.
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';

/// The visual state of one checklist row.
enum StepRowStatus { pending, running, done, failed, cancelled }

class StepChecklistRow extends StatelessWidget {
  const StepChecklistRow({
    super.key,
    required this.status,
    required this.label,
    this.trailing,
    this.expanded = false,
    this.onToggle,
    this.detail,
  });

  final StepRowStatus status;
  final String label;

  /// Rendered between the label and the chevron (e.g. a paused badge).
  final Widget? trailing;

  /// Whether [detail] is currently shown. Meaningful only when [detail] is
  /// non-null (which is also what renders the chevron).
  final bool expanded;
  final VoidCallback? onToggle;

  /// The expandable detail content, indented under the row when [expanded].
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final hasDetail = detail != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: hasDetail ? onToggle : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: [
                _icon(),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _labelColor(),
                        ),
                  ),
                ),
                if (trailing != null) trailing!,
                if (hasDetail) ...[
                  const SizedBox(width: AppSpacing.xs),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (expanded && hasDetail)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(
                left: AppSpacing.xl, bottom: AppSpacing.sm),
            padding: const EdgeInsets.all(AppSpacing.sm),
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(AppRadius.xs),
            ),
            child: SingleChildScrollView(child: detail),
          ),
      ],
    );
  }

  Color _labelColor() => switch (status) {
        StepRowStatus.failed => AppColors.error,
        StepRowStatus.cancelled || StepRowStatus.pending => AppColors.textMuted,
        _ => AppColors.textSecondary,
      };

  Widget _icon() => switch (status) {
        StepRowStatus.pending => const Icon(Icons.circle_outlined,
            size: 14, color: AppColors.textMuted),
        StepRowStatus.running => const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.warning,
            ),
          ),
        StepRowStatus.done =>
          const Icon(Icons.check_circle, size: 14, color: AppColors.success),
        StepRowStatus.failed =>
          const Icon(Icons.cancel, size: 14, color: AppColors.error),
        StepRowStatus.cancelled => const Icon(Icons.remove_circle_outline,
            size: 14, color: AppColors.textMuted),
      };
}
