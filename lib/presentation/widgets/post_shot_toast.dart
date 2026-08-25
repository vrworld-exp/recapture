// lib/presentation/widgets/post_shot_toast.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/capture_evaluation.dart';
import '../../platform/haptics.dart';
import '../../utils/analytics.dart';
import 'post_shot_messages.dart';

/// Post-shot feedback toast for Level A: right after a capture it tells the user
/// whether the shot was accepted, accepted-with-a-warning, or rejected, and (for
/// warn/reject) offers a Retake CTA.
///
/// Display + intent only: it renders a supplied [CaptureEvaluation] and fires
/// [onRetake]. It does NOT evaluate quality, discard frames, or mutate the
/// capture set/ring progress — the parent owns all of that.
///
/// Single instance, latest-wins: a new evaluation (different `captureId`)
/// crossfade-replaces any current toast — toasts never stack or queue. The
/// animation, haptic, and analytics fire only on a changed `captureId`; an
/// identical re-emit is a no-op. Verdict drives the colour/icon/haptic and the
/// auto-dismiss policy (accepted short, warn longer, reject sticky).
class PostShotToast extends StatefulWidget {
  const PostShotToast({
    super.key,
    required this.evaluation,
    required this.onRetake,
    this.acceptedDuration = const Duration(milliseconds: 900),
    this.warnDuration = const Duration(seconds: 3),
    this.rejectDuration,
    this.crossfade = const Duration(milliseconds: 200),
  });

  /// The capture to give feedback on, or null to hide the toast.
  final CaptureEvaluation? evaluation;

  /// Retake intent. The parent discards the shot and re-arms capture.
  final VoidCallback onRetake;

  /// Auto-dismiss timeout for an accepted toast (short).
  final Duration acceptedDuration;

  /// Auto-dismiss timeout for a warn toast (longer; the user may keep reading).
  final Duration warnDuration;

  /// Optional safety timeout for a reject toast. Null (default) = sticky: it
  /// stays until Retake is tapped or a new result replaces it.
  final Duration? rejectDuration;

  /// Crossfade duration for a changed result (ignored under reduce-motion).
  final Duration crossfade;

  @override
  State<PostShotToast> createState() => _PostShotToastState();
}

class _PostShotToastState extends State<PostShotToast> {
  /// The evaluation currently rendered (null = hidden). May be cleared by the
  /// auto-dismiss timer even though [widget.evaluation] still holds the same id.
  CaptureEvaluation? _displayed;

  /// The last `captureId` we acted on (showed + hapticked + logged). Compared
  /// against incoming so an identical re-emit — or a re-emit after auto-dismiss —
  /// never re-triggers.
  String? _handledId;

  /// Per-toast guard so a double-tapped Retake fires [onRetake] only once.
  bool _retakeFired = false;

  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    final e = widget.evaluation;
    if (e != null) {
      _displayed = e;
      _handledId = e.captureId;
      // Defer side effects (haptic/timer/analytics) off the build/init pass.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onShown(e);
      });
    }
  }

  @override
  void didUpdateWidget(PostShotToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.evaluation;

    // Parent cleared the result → fade out (keep _handledId so the same id can't
    // immediately re-show).
    if (incoming == null) {
      if (_displayed != null) {
        _dismissTimer?.cancel();
        setState(() => _displayed = null);
      }
      return;
    }

    // Same shot → no re-animation/haptic. Apply a content restyle (e.g. issues
    // refined) instantly only if it's still on screen.
    if (incoming.captureId == _handledId) {
      if (_displayed != null && incoming != _displayed) {
        setState(() => _displayed = incoming);
      }
      return;
    }

    // New shot → replace (latest-wins).
    _dismissTimer?.cancel();
    _retakeFired = false;
    _handledId = incoming.captureId;
    setState(() => _displayed = incoming);
    _onShown(incoming);
  }

  /// Side effects for a freshly shown result: haptic, analytics, auto-dismiss.
  void _onShown(CaptureEvaluation e) {
    _fireHaptic(e.verdict);
    Analytics.logEvent(AnalyticsEvents.postShotResult, {
      'verdict': e.verdict.name,
      'issues': e.issues.map((i) => i.name).toList(),
      'device_type': _deviceType,
    });
    final timeout = _autoDismissFor(e.verdict);
    if (timeout != null) {
      _dismissTimer = Timer(timeout, () {
        if (mounted) setState(() => _displayed = null);
      });
    }
  }

  Duration? _autoDismissFor(CaptureVerdict v) {
    switch (v) {
      case CaptureVerdict.accepted:
        return widget.acceptedDuration;
      case CaptureVerdict.warn:
        return widget.warnDuration;
      case CaptureVerdict.reject:
        return widget.rejectDuration; // null = sticky
    }
  }

  void _fireHaptic(CaptureVerdict v) {
    switch (v) {
      case CaptureVerdict.accepted:
        Haptics.postShotAccepted();
      case CaptureVerdict.warn:
        Haptics.postShotWarning();
      case CaptureVerdict.reject:
        Haptics.postShotReject();
    }
  }

  void _onRetakeTap() {
    if (_retakeFired) return;
    _retakeFired = true;
    _dismissTimer?.cancel();
    final shown = _displayed;
    if (shown != null) {
      Analytics.logEvent(AnalyticsEvents.postShotRetake, {
        'verdict': shown.verdict.name,
        'capture_id': shown.captureId,
      });
    }
    widget.onRetake();
    setState(() => _displayed = null);
  }

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final displayed = _displayed;

    // A distinct band above the shutter (bottom bar) and the instruction banner
    // (lower third), centred and clear of the lower-left ring map.
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.sizeOf(context).height * 0.30,
      child: SafeArea(
        child: Center(
          child: AnimatedSwitcher(
            duration: reduceMotion ? Duration.zero : widget.crossfade,
            child: displayed == null
                ? const SizedBox.shrink(key: ValueKey<String>('__none__'))
                : _ToastCard(
                    // Key by id so the switcher only transitions on a real change.
                    key: ValueKey<String>(displayed.captureId),
                    evaluation: displayed,
                    onRetake: _onRetakeTap,
                  ),
          ),
        ),
      ),
    );
  }
}

/// The toast surface: verdict-coloured border + icon, a terse primary line, an
/// optional status sub-label, and (for warn/reject) a Retake CTA kept clear of
/// the shutter. Width-constrained so long copy wraps to at most two lines.
class _ToastCard extends StatelessWidget {
  const _ToastCard({
    super.key,
    required this.evaluation,
    required this.onRetake,
  });

  final CaptureEvaluation evaluation;
  final VoidCallback onRetake;

  Color get _accent {
    switch (evaluation.verdict) {
      case CaptureVerdict.accepted:
        return AppColors.success;
      case CaptureVerdict.warn:
        return AppColors.warning;
      case CaptureVerdict.reject:
        return AppColors.mirageRed;
    }
  }

  IconData get _icon {
    switch (evaluation.verdict) {
      case CaptureVerdict.accepted:
        return Icons.check_circle;
      case CaptureVerdict.warn:
        return Icons.warning_amber_rounded;
      case CaptureVerdict.reject:
        return Icons.error_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = _accent;
    final title = PostShotMessages.primaryMessage(evaluation);
    final status = PostShotMessages.statusLabel(evaluation.verdict);
    final maxWidth = MediaQuery.sizeOf(context).width * 0.86;
    final isReject = evaluation.verdict == CaptureVerdict.reject;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface1.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: accent, width: isReject ? 2 : 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, color: accent, size: 22),
            const SizedBox(width: AppSpacing.sm),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (status != null)
                    Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: AppColors.textSecondary),
                    ),
                ],
              ),
            ),
            if (evaluation.retakeOffered) ...[
              const SizedBox(width: AppSpacing.md),
              _RetakeButton(accent: accent, onTap: onRetake, prominent: isReject),
            ],
          ],
        ),
      ),
    );
  }
}

/// The Retake CTA — a ≥44px tap target. Reject styles it as a filled, prominent
/// button; warn as a lighter tonal one. Semantics-labelled.
class _RetakeButton extends StatelessWidget {
  const _RetakeButton({
    required this.accent,
    required this.onTap,
    required this.prominent,
  });

  final Color accent;
  final VoidCallback onTap;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: 'Retake',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 64),
        child: Material(
          color: prominent ? accent : accent.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Center(
                widthFactor: 1,
                child: Text(
                  'Retake',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: prominent ? AppColors.bgPrimary : accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
