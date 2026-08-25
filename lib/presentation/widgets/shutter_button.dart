// lib/presentation/widgets/shutter_button.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../domain/entities/capture_readiness.dart';
import '../../platform/haptics.dart';
import '../../utils/analytics.dart';

/// Level A guided-capture shutter. Renders readiness and triggers a capture via
/// the injected [onCapture]; it does NOT run the camera, compute tilt/stability,
/// or save frames. In guided mode it is enabled only when [CaptureReadiness.canCapture]
/// (in-band + stable [+ placed], or failing open when sensors are unavailable).
///
/// States: ready (Mirage Red + gold ring, tappable), blocked (muted, a tap nudges
/// instead of capturing), capturing (spinner, disabled). A single in-flight
/// capture at a time (double-tap guarded). Haptics fire via the shared [Haptics]
/// helper; reduce-motion drops the in-flight scale (haptics still fire).
class ShutterButton extends StatefulWidget {
  const ShutterButton({
    super.key,
    required this.readiness,
    required this.onCapture,
    this.label,
    this.onTriggered,
    this.onBlockedTap,
    this.blockedTapCooldown = const Duration(seconds: 2),
  });

  final CaptureReadiness readiness;

  /// Short word printed on the button's core naming what the shutter does in
  /// the active capture mode ("Auto" in full capture, "Click" in Meshy — see
  /// `CaptureMode.shutterLabel`). Null renders the plain core (no text). It is
  /// hidden while a capture is in flight, where the spinner owns the core.
  final String? label;

  /// Performs the actual capture (parent's `takePicture`); completes on success,
  /// throws on a real failure. The button reflects in-flight/success/error only.
  final Future<void> Function() onCapture;

  /// Fired at capture INITIATION — once per non-blocked tap, BEFORE [onCapture]
  /// runs (so a later capture failure never suppresses it) and never on a blocked
  /// tap. The parent emits `manual_capture_triggered` here with full context; the
  /// button just signals "a manual capture is starting now" with its [readiness].
  final void Function(CaptureReadiness readiness)? onTriggered;

  /// Optional nudge when a blocked shutter is tapped (e.g. emphasize the HUD cue).
  final VoidCallback? onBlockedTap;

  /// Throttle for the `level_a_blocked_shutter_tap` analytics event.
  final Duration blockedTapCooldown;

  @override
  State<ShutterButton> createState() => _ShutterButtonState();
}

enum _ShutterVisual { ready, blocked, capturing }

class _ShutterButtonState extends State<ShutterButton> {
  bool _capturing = false;
  DateTime? _lastBlockedLog;

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  String get _modeLabel =>
      widget.readiness.mode == CaptureMode.guided ? 'guided' : 'manual';

  Future<void> _onTap() async {
    if (_capturing) return; // in-flight guard — never double-fire
    if (!widget.readiness.canCapture) {
      _onBlockedTap();
      return;
    }
    await _capture();
  }

  void _onBlockedTap() {
    unawaited(Haptics.blockedTap());
    widget.onBlockedTap?.call();
    _logBlocked();
  }

  void _logBlocked() {
    final reason = widget.readiness.primaryBlockReason;
    if (reason == null) return;
    final now = DateTime.now();
    if (_lastBlockedLog != null &&
        now.difference(_lastBlockedLog!) < widget.blockedTapCooldown) {
      return; // throttled
    }
    _lastBlockedLog = now;
    Analytics.logEvent(AnalyticsEvents.levelABlockedShutterTap, {
      'reason': switch (reason) {
        BlockReason.outOfBand => 'out_of_band',
        BlockReason.unstable => 'unstable',
        BlockReason.notPlaced => 'not_placed',
        BlockReason.alreadyCaptured => 'already_captured',
        BlockReason.sensorUnavailable || BlockReason.capturing => 'unknown',
      },
    });
  }

  Future<void> _capture() async {
    setState(() => _capturing = true);
    unawaited(Haptics.captureTap());

    // Trigger-time instrumentation: fired once at INITIATION, before the capture
    // runs — so the attempt is recorded even if onCapture later throws.
    widget.onTriggered?.call(widget.readiness);

    var result = 'success';
    try {
      await widget.onCapture();
    } catch (_) {
      result = 'error';
    }

    // Feedback + analytics reflect the outcome regardless of mount state.
    unawaited(
      result == 'success' ? Haptics.captureSuccess() : Haptics.captureError(),
    );
    Analytics.logEvent(AnalyticsEvents.levelACaptureTriggered, {
      'result': result,
      'mode': _modeLabel,
      'sensor_supported': widget.readiness.sensorSupported,
      'device_type': _deviceType,
    });

    if (mounted) setState(() => _capturing = false);
  }

  _ShutterVisual get _visual {
    if (_capturing) return _ShutterVisual.capturing;
    return widget.readiness.canCapture
        ? _ShutterVisual.ready
        : _ShutterVisual.blocked;
  }

  String get _semanticsLabel {
    if (_capturing) return 'Capturing';
    if (widget.readiness.canCapture) return 'Capture, ready';
    return switch (widget.readiness.primaryBlockReason) {
      BlockReason.notPlaced => 'Capture, blocked: place the object',
      BlockReason.alreadyCaptured =>
        'Capture, blocked: already captured this angle',
      BlockReason.outOfBand => 'Capture, blocked: adjust tilt',
      BlockReason.unstable => 'Capture, blocked: hold steady',
      _ => 'Capture, blocked',
    };
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final visual = _visual;

    final ringColor = switch (visual) {
      _ShutterVisual.ready || _ShutterVisual.capturing => AppColors.royalGold,
      _ShutterVisual.blocked => AppColors.disabled,
    };
    final coreColor = switch (visual) {
      _ShutterVisual.ready => AppColors.mirageRed,
      _ShutterVisual.capturing => AppColors.mirageRed.withValues(alpha: 0.6),
      _ShutterVisual.blocked => AppColors.disabled,
    };
    final blocked = visual == _ShutterVisual.blocked;

    return Semantics(
      button: true,
      enabled: widget.readiness.canCapture && !_capturing,
      label: _semanticsLabel,
      child: GestureDetector(
        onTap: _onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          // ≥ minimum accessible tap target.
          width: 72,
          height: 72,
          child: Opacity(
            opacity: blocked ? 0.5 : 1.0,
            child: AnimatedScale(
              scale: _capturing ? 0.9 : 1.0,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              child: Center(
                child: Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: ringColor, width: 3),
                  ),
                  child: Center(
                    child: SizedBox(
                      width: 58,
                      height: 58,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: coreColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          // Mode word ("Auto" / "Click"). Excluded from
                          // semantics: the button's own label already says what
                          // a tap does, so announcing the word again would just
                          // repeat it.
                          if (widget.label != null && !_capturing)
                            ExcludeSemantics(
                              child: Text(
                                widget.label!,
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                              ),
                            ),
                          if (_capturing)
                            const SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            ),
                        ],
                      ),
                    ),
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
