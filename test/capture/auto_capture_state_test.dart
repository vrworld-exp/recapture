// test/capture/auto_capture_state_test.dart
//
// Pure unit tests for the auto-capture state: isOn, armed/countdown ignored when
// OFF, countdown clamped 0..1 (NaN → null), and value equality.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/auto_capture_state.dart';

void main() {
  test('isOn reflects the mode', () {
    expect(const AutoCaptureState(mode: AutoCaptureMode.on).isOn, isTrue);
    expect(const AutoCaptureState().isOn, isFalse); // default OFF
  });

  group('armed/countdown ignored when OFF', () {
    test('effectiveArmed is false when OFF even if armed=true', () {
      const s = AutoCaptureState(mode: AutoCaptureMode.off, armed: true);
      expect(s.effectiveArmed, isFalse);
    });

    test('effectiveCountdown is null when OFF even if countdown supplied', () {
      const s = AutoCaptureState(mode: AutoCaptureMode.off, countdown: 0.5);
      expect(s.effectiveCountdown, isNull);
    });
  });

  group('countdown clamping (ON)', () {
    test('in-range passes through', () {
      expect(
        const AutoCaptureState(mode: AutoCaptureMode.on, countdown: 0.4)
            .effectiveCountdown,
        closeTo(0.4, 1e-9),
      );
    });

    test('out-of-range clamps to 0..1', () {
      expect(
        const AutoCaptureState(mode: AutoCaptureMode.on, countdown: 1.7)
            .effectiveCountdown,
        1.0,
      );
      expect(
        const AutoCaptureState(mode: AutoCaptureMode.on, countdown: -2.0)
            .effectiveCountdown,
        0.0,
      );
    });

    test('NaN → null (no overflow)', () {
      expect(
        const AutoCaptureState(mode: AutoCaptureMode.on, countdown: double.nan)
            .effectiveCountdown,
        isNull,
      );
    });

    test('effectiveArmed true when ON and armed', () {
      expect(
        const AutoCaptureState(mode: AutoCaptureMode.on, armed: true)
            .effectiveArmed,
        isTrue,
      );
    });
  });

  test('value equality', () {
    expect(
      const AutoCaptureState(mode: AutoCaptureMode.on, countdown: 0.5),
      const AutoCaptureState(mode: AutoCaptureMode.on, countdown: 0.5),
    );
    expect(
      const AutoCaptureState(mode: AutoCaptureMode.on) ==
          const AutoCaptureState(mode: AutoCaptureMode.off),
      isFalse,
    );
  });
}
