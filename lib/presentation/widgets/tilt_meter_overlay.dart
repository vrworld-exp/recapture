// lib/presentation/widgets/tilt_meter_overlay.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../application/capture/current_pitch_provider.dart';
import '../../application/config/config_notifier.dart';
import '../../domain/entities/capture_config.dart';
import '../../domain/entities/tilt_target.dart';
import '../../utils/analytics.dart';

/// Level A (Eye Ring) tilt meter: a vertical gauge over the camera preview that
/// shows the device's smoothed current pitch (a needle) against the target pitch
/// band (a highlighted zone), so the user holds the phone at the correct
/// vertical angle while ringing the object.
///
/// Pitch comes from [currentPitchProvider] (smoothed; SmoothedOrientation
/// convention) and the target band from [captureConfigProvider] — the SAME
/// coordinate frame, so the needle and band line up. Pitch-vs-band drives a
/// hysteresis state machine ([tiltStateWithHysteresis]) into `inBand` /
/// `aboveBand` ("tilt down") / `belowBand` ("tilt up"), with a directional hint.
///
/// Guidance-only and hit-test transparent ([IgnorePointer]): it triggers NO
/// captures and never gates the flow. Degrades gracefully when the sensor is
/// unavailable (shows a disabled fallback; capture stays usable).
class TiltMeterOverlay extends ConsumerStatefulWidget {
  const TiltMeterOverlay({
    super.key,
    this.levelBandId = 'mid',
    this.gaugeMinDeg = -30,
    this.gaugeMaxDeg = 120,
    this.hysteresisDeg = 2.0,
    this.outSustain = const Duration(seconds: 2),
    this.outCooldown = const Duration(seconds: 3),
  });

  /// The config band id this level targets. Level A "Eye Ring" ≈ the `mid`
  /// (eye-level) band; resolved by id with a safe fallback, so retuning config
  /// moves the meter zone.
  final String levelBandId;

  /// Displayable gauge range (degrees), clamped. The needle never overflows it.
  final double gaugeMinDeg;
  final double gaugeMaxDeg;

  /// Hysteresis margin (degrees) on the in/out-of-band decision.
  final double hysteresisDeg;

  /// How long the device must stay out-of-band before the throttled
  /// `tilt_meter_out_of_band` analytics event fires, and the minimum gap between
  /// emissions. Exposed for deterministic tests; production uses 2s / 3s.
  final Duration outSustain;
  final Duration outCooldown;

  @override
  ConsumerState<TiltMeterOverlay> createState() => _TiltMeterOverlayState();
}

class _TiltMeterOverlayState extends ConsumerState<TiltMeterOverlay> {
  double? _pitch; // last smoothed pitch (null until first valid sample)
  bool _supported = true; // assume supported until told otherwise
  TiltState? _state; // last hysteresis state (drives colour + hint)

  // Out-of-band analytics throttle.
  DateTime? _outSince; // when the current out-of-band stretch began
  DateTime? _lastEmit; // last emission (cooldown anchor)

  TiltTarget _resolveTarget(CaptureConfig config) {
    for (final b in config.pitchBands) {
      if (b.id == widget.levelBandId) return TiltTarget.fromBand(b);
    }
    if (config.pitchBands.isNotEmpty) {
      return TiltTarget.fromBand(config.pitchBands.first);
    }
    return const TiltTarget(minDegrees: 30, maxDegrees: 60, bandId: 'mid');
  }

  void _onSample(PitchSample sample) {
    if (!sample.sensorSupported) {
      if (_supported || _state != null) {
        setState(() {
          _supported = false;
          _state = null;
        });
      }
      return;
    }
    final target = _resolveTarget(ref.read(captureConfigProvider));
    final next = tiltStateWithHysteresis(
      _state,
      sample.pitchDegrees,
      target,
      marginDegrees: widget.hysteresisDeg,
    );
    _maybeEmitOutOfBand(next, target);
    if (!_supported || _state != next || _pitch != sample.pitchDegrees) {
      setState(() {
        _supported = true;
        _state = next;
        _pitch = sample.pitchDegrees;
      });
    }
  }

  void _maybeEmitOutOfBand(TiltState state, TiltTarget target) {
    final now = DateTime.now();
    if (state == TiltState.inBand) {
      _outSince = null;
      return;
    }
    _outSince ??= now;
    final sustained = now.difference(_outSince!) >= widget.outSustain;
    final cooled =
        _lastEmit == null || now.difference(_lastEmit!) >= widget.outCooldown;
    if (sustained && cooled) {
      _lastEmit = now;
      Analytics.logEvent(AnalyticsEvents.tiltMeterOutOfBand, {
        'direction': state == TiltState.aboveBand ? 'above' : 'below',
        'target_band_id': target.bandId,
        'device_type':
            defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Fold each new sample into local hysteresis/analytics state (kept out of
    // build so the decision is stateful and not recomputed per rebuild).
    ref.listen<AsyncValue<PitchSample>>(currentPitchProvider, (_, next) {
      final s = next.asData?.value;
      if (s != null) _onSample(s);
    });

    final target = _resolveTarget(ref.watch(captureConfigProvider));
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Positioned(
      right: AppSpacing.lg,
      top: 150,
      child: IgnorePointer(
        child: _supported
            ? _TiltGauge(
                target: target,
                pitch: _pitch,
                state: _state,
                gaugeMinDeg: widget.gaugeMinDeg,
                gaugeMaxDeg: widget.gaugeMaxDeg,
                reduceMotion: reduceMotion,
              )
            : const _TiltFallback(),
      ),
    );
  }
}

/// Non-blocking fallback shown when the motion sensor is unavailable: a muted,
/// needle-less gauge with a short note. Capture remains fully usable.
class _TiltFallback extends StatelessWidget {
  const _TiltFallback();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.screen_rotation_outlined,
            size: 18, color: AppColors.textMuted),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          width: 90,
          child: Text(
            'Tilt guidance unavailable',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }
}

class _TiltGauge extends StatelessWidget {
  const _TiltGauge({
    required this.target,
    required this.pitch,
    required this.state,
    required this.gaugeMinDeg,
    required this.gaugeMaxDeg,
    required this.reduceMotion,
  });

  final TiltTarget target;
  final double? pitch;
  final TiltState? state;
  final double gaugeMinDeg;
  final double gaugeMaxDeg;
  final bool reduceMotion;

  static const double _gaugeWidth = 16;
  static const double _gaugeHeight = 168;

  Color get _needleColor =>
      state == TiltState.inBand ? AppColors.success : AppColors.mirageRed;

  ({String text, IconData? icon, Color color}) get _hint => switch (state) {
        TiltState.inBand => (
            text: 'Hold steady',
            icon: null,
            color: AppColors.success
          ),
        TiltState.aboveBand => (
            text: 'Tilt down',
            icon: Icons.keyboard_arrow_down,
            color: AppColors.mirageRed
          ),
        TiltState.belowBand => (
            text: 'Tilt up',
            icon: Icons.keyboard_arrow_up,
            color: AppColors.mirageRed
          ),
        null => (
            text: 'Find the band',
            icon: null,
            color: AppColors.textSecondary
          ),
      };

  @override
  Widget build(BuildContext context) {
    final hint = _hint;
    // Clamp the needle to the displayable range, so an extreme/out-of-range
    // pitch parks at the gauge end instead of overflowing or going NaN.
    final hasNeedle = pitch != null;
    final clampedPitch =
        hasNeedle ? pitch!.clamp(gaugeMinDeg, gaugeMaxDeg).toDouble() : null;
    final inBandGlow = state == TiltState.inBand && !reduceMotion;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Tilt',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.xs),
        RepaintBoundary(
          child: SizedBox(
            width: _gaugeWidth,
            height: _gaugeHeight,
            // Implicit ease toward each (already-filtered) needle position;
            // reduce-motion drops the tween so the needle still tracks but the
            // motion is instant (and the glow below is disabled).
            child: TweenAnimationBuilder<double>(
              tween: Tween(
                begin: clampedPitch ?? target.center,
                end: clampedPitch ?? target.center,
              ),
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              builder: (context, animatedPitch, _) => CustomPaint(
                painter: _TiltGaugePainter(
                  gaugeMinDeg: gaugeMinDeg,
                  gaugeMaxDeg: gaugeMaxDeg,
                  bandMinDeg: target.minDegrees,
                  bandMaxDeg: target.maxDegrees,
                  needlePitch: hasNeedle ? animatedPitch : null,
                  needleColor: _needleColor,
                  glow: inBandGlow,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: AppColors.bgPrimary.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hint.icon != null) ...[
                Icon(hint.icon, size: 14, color: hint.color),
                const SizedBox(width: 2),
              ],
              Text(
                hint.text,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: hint.color),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TiltGaugePainter extends CustomPainter {
  _TiltGaugePainter({
    required this.gaugeMinDeg,
    required this.gaugeMaxDeg,
    required this.bandMinDeg,
    required this.bandMaxDeg,
    required this.needlePitch,
    required this.needleColor,
    required this.glow,
  });

  final double gaugeMinDeg;
  final double gaugeMaxDeg;
  final double bandMinDeg;
  final double bandMaxDeg;
  final double? needlePitch; // null → no needle (loading)
  final Color needleColor;
  final bool glow;

  /// Maps a pitch to a y on the track: gaugeMax at the top, gaugeMin at the
  /// bottom (higher pitch = needle higher = "tilt down" to lower it). Clamped.
  double _yFor(double pitch, double height) {
    final span = (gaugeMaxDeg - gaugeMinDeg);
    if (span == 0) return height; // degenerate config → park at bottom
    final frac = ((gaugeMaxDeg - pitch) / span).clamp(0.0, 1.0);
    return frac * height;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final trackRRect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(8),
    );

    // Track.
    canvas.drawRRect(trackRRect, Paint()..color = AppColors.surface1);

    // Target band zone (the goal): success fill + a thin royal-gold border.
    final bandTop = _yFor(bandMaxDeg, size.height);
    final bandBottom = _yFor(bandMinDeg, size.height);
    final bandRect = Rect.fromLTRB(0, bandTop, size.width, bandBottom);
    canvas.save();
    canvas.clipRRect(trackRRect);
    canvas.drawRect(
      bandRect,
      Paint()..color = AppColors.success.withValues(alpha: glow ? 0.45 : 0.30),
    );
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        bandRect.deflate(0.5),
        const Radius.circular(4),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = AppColors.royalGold.withValues(alpha: 0.9),
    );

    if (needlePitch == null) return; // loading → band only, no needle

    final y = _yFor(needlePitch!, size.height);

    // Soft glow behind the needle when in-band (decorative — off for reduce
    // motion via [glow] == false).
    if (glow) {
      canvas.drawLine(
        Offset(-2, y),
        Offset(size.width + 2, y),
        Paint()
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..color = needleColor.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }

    // Needle: a full-width bar plus a left-pointing marker triangle.
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = needleColor,
    );
    final marker = Path()
      ..moveTo(size.width, y - 5)
      ..lineTo(size.width, y + 5)
      ..lineTo(size.width - 6, y)
      ..close();
    canvas.drawPath(marker, Paint()..color = needleColor);
  }

  @override
  bool shouldRepaint(covariant _TiltGaugePainter old) =>
      old.needlePitch != needlePitch ||
      old.needleColor != needleColor ||
      old.glow != glow ||
      old.bandMinDeg != bandMinDeg ||
      old.bandMaxDeg != bandMaxDeg ||
      old.gaugeMinDeg != gaugeMinDeg ||
      old.gaugeMaxDeg != gaugeMaxDeg;
}
