// test/capture/auto_capture_trigger_test.dart
//
// Pure unit tests for the auto-capture DECISION (shouldCapture) + band
// membership/hysteresis + the WARN/REJECT fill policy. No async/UI.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/auto_capture_trigger.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';

void main() {
  // Level A 'mid' band: [30, 60) degrees.
  const band = PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 10);
  final t0 = DateTime(2024, 1, 1, 12, 0, 0);

  // All-conditions-satisfied baseline; individual tests flip one arg.
  bool decide({
    double pitch = 45,
    bool stable = true,
    bool filled = false,
    DateTime? last,
    DateTime? now,
    bool capturing = false,
    Duration min = const Duration(milliseconds: 500),
    double hysteresis = 0,
    bool wasInBand = false,
  }) =>
      shouldCapture(
        currentTilt: pitch,
        pitchBand: band,
        isStable: stable,
        isCurrentFilled: filled,
        lastCaptureAt: last,
        now: now ?? t0,
        isCapturing: capturing,
        minInterval: min,
        bandHysteresisDeg: hysteresis,
        wasInBand: wasInBand,
      );

  group('the conjunction', () {
    test('all conditions true → fire', () {
      expect(decide(), isTrue);
    });

    test('flipping each single condition false → no fire (proves the AND)', () {
      expect(decide(pitch: 75), isFalse, reason: 'out of band');
      expect(decide(stable: false), isFalse, reason: 'not stable');
      expect(decide(filled: true), isFalse, reason: 'segment already filled');
      expect(decide(capturing: true), isFalse, reason: 'in-flight');
      expect(
        decide(last: t0.subtract(const Duration(milliseconds: 100)), now: t0),
        isFalse,
        reason: 'cooldown not elapsed',
      );
    });
  });

  group('in-flight guard', () {
    test('capturing blocks even when everything else holds', () {
      expect(decide(capturing: true), isFalse);
    });
  });

  group('cooldown (500ms from last capture)', () {
    test('first capture (no prior) is allowed immediately', () {
      expect(decide(last: null), isTrue);
    });

    test('boundary: just under 500ms false, exactly/over 500ms true', () {
      final last = t0;
      expect(
        decide(last: last, now: last.add(const Duration(milliseconds: 499))),
        isFalse,
      );
      expect(
        decide(last: last, now: last.add(const Duration(milliseconds: 500))),
        isTrue,
      );
      expect(
        decide(last: last, now: last.add(const Duration(milliseconds: 700))),
        isTrue,
      );
    });
  });

  group('segment filled', () {
    test('unfilled → fire; filled → no fire', () {
      expect(decide(filled: false), isTrue);
      expect(decide(filled: true), isFalse);
    });
  });

  group('pitch band membership (range check, no wraparound)', () {
    test('inside fires, outside does not', () {
      expect(decide(pitch: 45), isTrue);
      expect(decide(pitch: 20), isFalse); // below
      expect(decide(pitch: 75), isFalse); // above
    });

    test('edge inclusivity: min inclusive, max exclusive', () {
      expect(decide(pitch: 30), isTrue, reason: 'min inclusive');
      expect(decide(pitch: 60), isFalse, reason: 'max exclusive');
      expect(decide(pitch: 59.999), isTrue);
    });

    test('NaN/Infinity pitch never in band', () {
      expect(decide(pitch: double.nan), isFalse);
      expect(decide(pitch: double.infinity), isFalse);
    });
  });

  group('isPitchInBand hysteresis', () {
    test('off (0) → strict membership', () {
      expect(isPitchInBand(band, 60), isFalse);
      expect(isPitchInBand(band, 60, hysteresisDeg: 0, wasInBand: true), isFalse);
    });

    test('on + wasInBand → small dither past the edge holds in band', () {
      // 62 is past max (60) but within the 5° dead-band while already inside.
      expect(isPitchInBand(band, 62, hysteresisDeg: 5, wasInBand: true), isTrue);
      expect(isPitchInBand(band, 66, hysteresisDeg: 5, wasInBand: true), isFalse);
    });

    test('entry is always strict (hysteresis only widens once inside)', () {
      expect(isPitchInBand(band, 62, hysteresisDeg: 5, wasInBand: false), isFalse);
      expect(isPitchInBand(band, 28, hysteresisDeg: 5, wasInBand: false), isFalse);
      // re-entry while latched: 28 is within min-h while wasInBand
      expect(isPitchInBand(band, 28, hysteresisDeg: 5, wasInBand: true), isTrue);
    });
  });

  group('AutoCaptureConfig', () {
    test('defaults', () {
      final c = AutoCaptureConfig();
      expect(c.minInterval, const Duration(milliseconds: 500));
      expect(c.pitchEdgeHysteresisDeg, 0);
      expect(c.fillOnWarn, isTrue);
    });

    test('guards negative interval and invalid hysteresis', () {
      final c = AutoCaptureConfig(
        minInterval: const Duration(milliseconds: -10),
        pitchEdgeHysteresisDeg: double.nan,
      );
      expect(c.minInterval, Duration.zero);
      expect(c.pitchEdgeHysteresisDeg, 0);
    });

    test('verdictFills: accept fills, reject never, warn per fillOnWarn', () {
      final fillWarn = AutoCaptureConfig(fillOnWarn: true);
      final dropWarn = AutoCaptureConfig(fillOnWarn: false);
      expect(fillWarn.verdictFills(CaptureVerdict.accepted), isTrue);
      expect(fillWarn.verdictFills(CaptureVerdict.reject), isFalse);
      expect(fillWarn.verdictFills(CaptureVerdict.warn), isTrue);
      expect(dropWarn.verdictFills(CaptureVerdict.warn), isFalse);
    });
  });
}
