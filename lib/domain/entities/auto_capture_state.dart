// lib/domain/entities/auto_capture_state.dart
//
// Pure Dart — NO Flutter imports. Whether Level A auto-capture is ON/OFF and,
// optionally, whether a shot is imminent (armed / counting down). The PARENT
// owns this state and the auto-capture loop; the pill renders it and requests
// toggles. The auto-capture FIRE logic is a separate task.

enum AutoCaptureMode { off, on }

class AutoCaptureState {
  const AutoCaptureState({
    this.mode = AutoCaptureMode.off,
    this.armed = false,
    this.countdown,
  });

  final AutoCaptureMode mode;

  /// ON and conditions met / about to fire. Only meaningful when [isOn].
  final bool armed;

  /// 0..1 progress of an imminent auto-shot, if used.
  final double? countdown;

  bool get isOn => mode == AutoCaptureMode.on;

  /// Armed only when ON — an `armed` flag while OFF is inconsistent input and is
  /// ignored.
  bool get effectiveArmed => isOn && armed;

  /// Countdown clamped to 0..1, or null when OFF / absent / NaN — so the progress
  /// affordance never overflows or renders an invalid value.
  double? get effectiveCountdown {
    if (!isOn) return null;
    final c = countdown;
    if (c == null || c.isNaN) return null;
    return c.clamp(0.0, 1.0);
  }

  @override
  bool operator ==(Object other) =>
      other is AutoCaptureState &&
      other.mode == mode &&
      other.armed == armed &&
      other.countdown == countdown;

  @override
  int get hashCode => Object.hash(mode, armed, countdown);
}
