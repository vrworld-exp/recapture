// lib/presentation/widgets/app_status_pill.dart
import 'package:flutter/material.dart';
import '../../domain/entities/product_sync_status.dart';
import '../../domain/entities/project_status.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// Status badge for ReCapture project cards.
///
/// Displays the human-readable label and semantic color for a ProjectStatus,
/// plus a small leading affordance:
///   - in-progress (capturing/uploading/processing) → a lightweight pulsing dot
///   - completed                                     → a check icon
///   - failed                                        → an alert icon
///   - draft / unknown                               → none
///
/// Color and label are driven entirely by the ProjectStatusDisplay extension —
/// no color values are hardcoded here. The animated dot is isolated in its own
/// widget so only it repaints on each tick (never the whole card), keeping long
/// lists of in-progress badges cheap.
class AppStatusPill extends StatelessWidget {
  const AppStatusPill({
    super.key,
    required this.status,
  });

  final ProjectStatus status;

  @override
  Widget build(BuildContext context) => _Pill(
        label: status.label,
        color: status.color,
        affordance: _affordance(status.color),
      );

  /// The leading affordance for [status], or null when none applies.
  Widget? _affordance(Color color) {
    if (status.isInProgress) return _PulsingDot(color: color);
    return switch (status) {
      ProjectStatus.completed => Icon(Icons.check_circle, size: 11, color: color),
      ProjectStatus.failed => Icon(Icons.error, size: 11, color: color),
      _ => null,
    };
  }
}

/// Status badge for a catalog product or category's standing against the LIVE
/// Mirage catalog (feature 52).
///
/// Same pill as [AppStatusPill] by construction, not by resemblance — both build
/// [_Pill], so a change to the badge shape lands on the project card and the
/// product card at once. What differs is only what the two enums mean, and they
/// mean genuinely different things: a project status is about a capture, this is
/// about whether the public catalog has caught up.
///
/// `never` is DELIBERATELY not rendered by default: a catalog nobody has
/// published yet would otherwise show "Not published" on every card, which is
/// noise, not information. Pass [showWhenNeverPublished] where the absence
/// itself is the point (the publish screen's per-product list).
class SyncStatusPill extends StatelessWidget {
  const SyncStatusPill({
    super.key,
    required this.status,
    this.showWhenNeverPublished = false,
  });

  final ProductSyncStatus status;
  final bool showWhenNeverPublished;

  @override
  Widget build(BuildContext context) {
    if (status == ProductSyncStatus.never && !showWhenNeverPublished) {
      return const SizedBox.shrink();
    }
    if (status == ProductSyncStatus.unknown) return const SizedBox.shrink();

    final color = status.pillColor;
    return _Pill(
      label: status.label,
      color: color,
      affordance: switch (status) {
        ProductSyncStatus.pending => _PulsingDot(color: color),
        ProductSyncStatus.synced =>
          Icon(Icons.check_circle, size: 11, color: color),
        ProductSyncStatus.failed => Icon(Icons.error, size: 11, color: color),
        _ => null,
      },
    );
  }
}

/// Semantic colour for a sync status — theme tokens only, never a hex.
///
/// Lives here rather than on the entity because the catalog entities are pure
/// Dart with no Flutter import, and are kept that way on purpose (they are
/// hand-synced with the backend DTOs and parsed in tests that never build a
/// widget).
extension ProductSyncStatusColor on ProductSyncStatus {
  Color get pillColor => switch (this) {
        ProductSyncStatus.synced => AppColors.success,
        ProductSyncStatus.pending => AppColors.royalGold,
        ProductSyncStatus.failed => AppColors.error,
        ProductSyncStatus.never => AppColors.textMuted,
        ProductSyncStatus.unknown => AppColors.textMuted,
      };
}

/// The pill itself: a tinted capsule, an optional leading affordance, a label.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color, this.affordance});

  final String label;
  final Color color;
  final Widget? affordance;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(
          color: color.withValues(alpha: 0.35),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (affordance != null) ...[
            affordance!,
            const SizedBox(width: AppSpacing.xs),
          ],
          // Flexible, so a pill handed a narrow slot (a product card in a
          // two-column phone grid) ellipsizes its label instead of overflowing.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypography.sizeLabel,
                fontWeight: FontWeight.w500,
                color: color,
                height: 1.0,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small dot that gently pulses its opacity to signal a live/in-progress
/// state. Self-contained: owns a single repeating controller and rebuilds only
/// itself via [FadeTransition], so it never repaints the surrounding card.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});

  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(
    begin: 0.35,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
