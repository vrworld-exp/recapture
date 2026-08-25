// lib/presentation/widgets/roll_warning_overlay.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../application/capture/analytics/capture_level_events.dart';
import '../../application/capture/analytics/capture_level_session.dart';
import '../../application/capture/roll_warning_provider.dart';
import '../../utils/analytics.dart';

/// Guided Capture (Levels B & C) roll advisory: a small non-blocking chip that
/// appears when the device rolls past ±15° off level ("Keep the phone level")
/// and hides once it returns within tolerance. State + hysteresis come from
/// [rollWarningProvider]; this widget only renders it and emits the rising-edge
/// analytics.
///
/// ADVISORY ONLY: hit-test transparent ([IgnorePointer]) and never a modal — it
/// captures no taps, pauses nothing, and is NOT read by any capture-progression
/// code. Frames keep capturing and the ring keeps advancing while it shows.
/// Degrades to hidden when the sensor is unavailable (no false warning).
class RollWarningOverlay extends ConsumerStatefulWidget {
  const RollWarningOverlay({
    super.key,
    required this.level,
    this.message = 'Keep the phone level',
  });

  /// The capture level this advisory belongs to (B or C). Carried into the
  /// `guided_capture_roll_warning_shown` analytics as `level`.
  final CaptureLevel level;

  /// Advisory copy. Defaulted; exposed for tests.
  final String message;

  @override
  ConsumerState<RollWarningOverlay> createState() => _RollWarningOverlayState();
}

class _RollWarningOverlayState extends ConsumerState<RollWarningOverlay> {
  /// Previous advisory-active state — drives the rising-edge analytics (fire on
  /// inactive→active only, never per frame while it stays active).
  bool _active = false;

  void _onSample(RollWarningSample sample) {
    final nextActive = sample.sensorSupported && sample.active;
    if (nextActive == _active) return;
    // Rising edge → one analytics emission per excursion.
    if (nextActive && !_active) {
      _logShown(sample.rollDegrees);
    }
    setState(() => _active = nextActive);
  }

  /// Emits `guided_capture_roll_warning_shown` with the SIGNED roll at the moment
  /// the warning was raised. The capture session id links it to the funnel.
  void _logShown(double rollDegrees) {
    final session = ref.read(captureLevelSessionProvider);
    Analytics.logEvent(AnalyticsEvents.guidedCaptureRollWarningShown, {
      'level': widget.level.code,
      'capture_session_id': session?.sessionId ?? '',
      'roll_degrees': rollDegrees,
      'device_type':
          defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<RollWarningSample>>(rollWarningProvider, (_, next) {
      final s = next.asData?.value;
      if (s != null) _onSample(s);
    });

    return Positioned(
      top: 96,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: AnimatedOpacity(
            opacity: _active ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: AppColors.surface1.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.warning),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.screen_rotation_alt,
                    color: AppColors.warning,
                    size: 16,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    widget.message,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: AppColors.textPrimary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
