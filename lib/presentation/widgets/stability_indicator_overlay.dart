// lib/presentation/widgets/stability_indicator_overlay.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../application/capture/stability_provider.dart';
import '../../utils/analytics.dart';

/// Level A stability indicator: a small status dot + label telling the user
/// whether the device is steady enough for a sharp frame ("Stable") or moving
/// too much ("Hold steady"). State comes from [stabilityProvider] — the EXISTING
/// native stability gate (already smoothed + hysteresis + dwell-debounced), so
/// the dot matches the decision that gates auto-capture.
///
/// Guidance-only and hit-test transparent ([IgnorePointer]): it triggers NO
/// captures. Degrades gracefully when the sensor is unavailable (grey/unknown).
/// Small and unobtrusive — it complements the tilt meter and never obscures the
/// placement box or capture controls.
class StabilityIndicatorOverlay extends ConsumerStatefulWidget {
  const StabilityIndicatorOverlay({
    super.key,
    this.holdToEmit = const Duration(milliseconds: 1500),
  });

  /// How long the device must stay UNSTABLE before the throttled
  /// `capture_hold_steady` analytics event fires. Exposed for deterministic
  /// tests; production uses 1.5s.
  final Duration holdToEmit;

  @override
  ConsumerState<StabilityIndicatorOverlay> createState() =>
      _StabilityIndicatorOverlayState();
}

class _StabilityIndicatorOverlayState
    extends ConsumerState<StabilityIndicatorOverlay>
    with SingleTickerProviderStateMixin {
  Stability _stability = Stability.unknown;
  bool _supported = true;

  late final AnimationController _pulse;
  Timer? _holdTimer; // fires once a sustained-unstable stretch passes

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0.85,
      upperBound: 1.0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse(); // reduce-motion (MediaQuery) available here
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  void _onSample(StabilitySample sample) {
    final nextStability =
        sample.sensorSupported ? sample.stability : Stability.unknown;
    if (nextStability != _stability || _supported != sample.sensorSupported) {
      setState(() {
        _stability = nextStability;
        _supported = sample.sensorSupported;
      });
      _syncPulse();
      _syncHoldTimer();
    }
  }

  /// Pulse only while UNSTABLE and motion is allowed; otherwise rest at full
  /// size (the dot still changes colour/text without it).
  void _syncPulse() {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final shouldPulse = _stability == Stability.unstable && !reduceMotion;
    if (shouldPulse) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else if (_pulse.isAnimating || _pulse.value != _pulse.upperBound) {
      _pulse
        ..stop()
        ..value = _pulse.upperBound;
    }
  }

  /// Arms a one-shot timer on entering UNSTABLE; emits `capture_hold_steady`
  /// only if still unstable when it fires (sustained). Any non-unstable state
  /// cancels it, so a brief jolt never emits.
  void _syncHoldTimer() {
    if (_stability == Stability.unstable) {
      _holdTimer ??= Timer(widget.holdToEmit, () {
        _holdTimer = null;
        if (!mounted || _stability != Stability.unstable) return;
        Analytics.logEvent(AnalyticsEvents.captureHoldSteady, {
          'device_type':
              defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
        });
      });
    } else {
      _holdTimer?.cancel();
      _holdTimer = null;
    }
  }

  ({Color color, String text}) get _style => switch (_stability) {
        Stability.stable => (color: AppColors.success, text: 'Stable'),
        Stability.unstable => (color: AppColors.mirageRed, text: 'Hold steady'),
        Stability.unknown => (color: AppColors.disabled, text: 'Hold steady'),
      };

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<StabilitySample>>(stabilityProvider, (_, next) {
      final s = next.asData?.value;
      if (s != null) _onSample(s);
    });

    final style = _style;

    return Positioned(
      left: AppSpacing.lg,
      bottom: 108,
      child: IgnorePointer(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: _pulse,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: style.color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              style.text,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
