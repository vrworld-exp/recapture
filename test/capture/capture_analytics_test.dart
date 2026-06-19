// test/capture/capture_analytics_test.dart
//
// Unit tests for the capture-decision analytics event layer
// (lib/application/capture/). Grounded on the real types — there is no
// `PitchLevel`, `SensorFrame`, or injected `AnalyticsSink`; emission goes through
// the existing [Analytics.logEvent] seam and is asserted via [Analytics.testSink]
// (the same pattern the permission_* / precapture_* event tests use).
//
// Covers the 27 cases from the feature brief, remapped onto the grounded schema:
// shared-property serialisation, per-event names + property maps, emit dispatch
// counts, exception-safety, and the independent-exposure-warning invariant.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/capture_analytics.dart';
import 'package:recapture/application/capture/capture_analytics_event.dart';
import 'package:recapture/application/capture/capture_event_properties.dart';
import 'package:recapture/platform/blur_policy.dart';
import 'package:recapture/platform/exposure_policy.dart';
import 'package:recapture/utils/analytics.dart';

/// Records every emission forwarded through [Analytics.testSink].
class _RecordingSink {
  final List<({String name, Map<String, Object?> properties})> calls = [];
  void call(String name, Map<String, Object?> properties) =>
      calls.add((name: name, properties: properties));
  void reset() => calls.clear();
}

// `const`-constructible shared fixture (proves CaptureEventProperties is const).
const kTestProps = CaptureEventProperties(
  pitchBandId: 'mid',
  pitchDegrees: 0.0,
  stabilityScore: 0.85,
  gyroMag: 0.1,
  linAccelMag: 0.05,
  sensorTimestampNs: 1000000,
  deviceModel: 'Test Device',
  platform: 'android',
);

const _sharedKeys = {
  'pitch_band',
  'pitch_degrees',
  'stability_score',
  'gyro_mag',
  'lin_accel_mag',
  'sensor_timestamp_ns',
  'device_model',
  'platform',
};

void main() {
  group('CaptureEventProperties.toMap()', () {
    test('1. includes exactly the 8 shared keys', () {
      expect(kTestProps.toMap().keys.toSet(), _sharedKeys);
    });

    test('2. pitch_band serialises to the active PitchBand id', () {
      expect(kTestProps.toMap()['pitch_band'], 'mid');
    });

    test('3. a null active band serialises pitch_band as null (outside all bands)',
        () {
      const p = CaptureEventProperties(
        pitchBandId: null,
        pitchDegrees: 95.0,
        stabilityScore: 0.0,
        gyroMag: 0,
        linAccelMag: 0,
        sensorTimestampNs: 0,
        deviceModel: 'd',
        platform: 'ios',
      );
      expect(p.toMap().containsKey('pitch_band'), isTrue);
      expect(p.toMap()['pitch_band'], isNull);
    });
  });

  group('PhotoCapturedEvent', () {
    const event = PhotoCapturedEvent(
      properties: kTestProps,
      blurScore: 42.5,
      blurBand: BlurBand.accept,
      meanLuminance: 130.0,
      exposureBand: ExposureBand.ok,
      framePath: '/recapture/p/j/images/0/000000.jpg',
    );

    test('4. name is photo_captured', () {
      expect(event.name, 'photo_captured');
      expect(event.name, AnalyticsEvents.photoCaptured);
    });

    test('5. toMap has all shared keys plus the 5 event-specific keys', () {
      final map = event.toMap();
      expect(map.keys.toSet().containsAll(_sharedKeys), isTrue);
      expect(
        map.keys.toSet().containsAll(
            {'blur_score', 'blur_band', 'mean_luminance', 'exposure_band', 'frame_path'}),
        isTrue,
      );
    });

    test('6. blur_score and mean_luminance are preserved exactly', () {
      expect(event.toMap()['blur_score'], 42.5);
      expect(event.toMap()['mean_luminance'], 130.0);
      expect(event.toMap()['blur_band'], 'accept');
      expect(event.toMap()['frame_path'], '/recapture/p/j/images/0/000000.jpg');
    });
  });

  group('PhotoRejectedBlurEvent', () {
    const event = PhotoRejectedBlurEvent(
      properties: kTestProps,
      blurScore: 12.0,
      blurRejectBelow: BlurThresholdPolicy.defaultRejectBelow, // 40 — a real const
    );

    test('7. name is photo_rejected_blur', () {
      expect(event.name, 'photo_rejected_blur');
    });

    test('8. toMap has blur_score and blur_reject_below alongside shared keys', () {
      final map = event.toMap();
      expect(map.keys.toSet().containsAll(_sharedKeys), isTrue);
      expect(map.containsKey('blur_score'), isTrue);
      expect(map.containsKey('blur_reject_below'), isTrue);
    });

    test('9. blur_reject_below carries the real threshold (40), never 0.0', () {
      expect(event.toMap()['blur_reject_below'], 40.0);
      // The rejected score is below the threshold (the rejection invariant).
      expect((event.toMap()['blur_score'] as double) <
          (event.toMap()['blur_reject_below'] as double), isTrue);
    });
  });

  group('PhotoRejectedMotionEvent', () {
    const event = PhotoRejectedMotionEvent(
      properties: kTestProps,
      stabilityScoreAtRejection: 0.3,
      gyroThreshRadS: 0.8,
      accelThreshG: 0.15,
    );

    test('10. name is photo_rejected_motion', () {
      expect(event.name, 'photo_rejected_motion');
    });

    test('11. toMap has the gate thresholds; motion magnitudes come from shared',
        () {
      final map = event.toMap();
      expect(
        map.keys.toSet().containsAll(
            {'stability_score_at_rejection', 'gyro_thresh_rad_s', 'accel_thresh_g'}),
        isTrue,
      );
      // gyro_mag / lin_accel_mag (the motion quantifiers) are shared properties.
      expect(map['gyro_mag'], 0.1);
      expect(map['lin_accel_mag'], 0.05);
    });

    test('12. score_at_rejection is low and the gate thresholds are preserved', () {
      final map = event.toMap();
      expect(map['stability_score_at_rejection'], 0.3);
      expect(map['gyro_thresh_rad_s'], 0.8);
      expect(map['accel_thresh_g'], 0.15);
    });
  });

  group('PhotoWarnedExposureEvent', () {
    const dark = PhotoWarnedExposureEvent(
      properties: kTestProps,
      exposureBand: ExposureBand.dark,
      meanLuminance: 12.0,
      darkBelow: ExposureThresholdPolicy.defaultDarkBelow,
      brightAbove: ExposureThresholdPolicy.defaultBrightAbove,
    );
    const bright = PhotoWarnedExposureEvent(
      properties: kTestProps,
      exposureBand: ExposureBand.bright,
      meanLuminance: 240.0,
      darkBelow: ExposureThresholdPolicy.defaultDarkBelow,
      brightAbove: ExposureThresholdPolicy.defaultBrightAbove,
    );

    test('13. name is photo_warned_exposure', () {
      expect(dark.name, 'photo_warned_exposure');
    });

    test('14. toMap has exposure flags, band, mean and thresholds', () {
      final map = dark.toMap();
      expect(
        map.keys.toSet().containsAll(
            {'exposure_band', 'is_underexposed', 'is_overexposed', 'mean_luminance', 'dark_below', 'bright_above'}),
        isTrue,
      );
    });

    test('15. dark band → is_underexposed true, is_overexposed false', () {
      expect(dark.toMap()['is_underexposed'], true);
      expect(dark.toMap()['is_overexposed'], false);
      expect(dark.toMap()['exposure_band'], 'dark');
    });

    test('16. bright band → is_overexposed true, is_underexposed false', () {
      expect(bright.toMap()['is_overexposed'], true);
      expect(bright.toMap()['is_underexposed'], false);
      expect(bright.toMap()['exposure_band'], 'bright');
    });
  });

  group('CaptureAnalytics.emit()', () {
    late _RecordingSink sink;

    setUp(() {
      sink = _RecordingSink();
      Analytics.testSink = sink.call;
    });
    tearDown(() => Analytics.testSink = null);

    CaptureAnalyticsEvent captured() => const PhotoCapturedEvent(
          properties: kTestProps,
          blurScore: 90,
          blurBand: BlurBand.accept,
          meanLuminance: 120,
          exposureBand: ExposureBand.ok,
          framePath: '/x.jpg',
        );

    test('17. emit(PhotoCapturedEvent) tracks photo_captured', () {
      CaptureAnalytics.emit(captured());
      expect(sink.calls.last.name, 'photo_captured');
    });

    test('18. emit(PhotoRejectedBlurEvent) tracks photo_rejected_blur', () {
      CaptureAnalytics.emit(const PhotoRejectedBlurEvent(
          properties: kTestProps, blurScore: 5, blurRejectBelow: 40));
      expect(sink.calls.last.name, 'photo_rejected_blur');
    });

    test('19. emit(PhotoRejectedMotionEvent) tracks photo_rejected_motion', () {
      CaptureAnalytics.emit(const PhotoRejectedMotionEvent(
          properties: kTestProps,
          stabilityScoreAtRejection: 0.2,
          gyroThreshRadS: 0.8,
          accelThreshG: 0.15));
      expect(sink.calls.last.name, 'photo_rejected_motion');
    });

    test('20. emit(PhotoWarnedExposureEvent) tracks photo_warned_exposure', () {
      CaptureAnalytics.emit(const PhotoWarnedExposureEvent(
          properties: kTestProps,
          exposureBand: ExposureBand.bright,
          meanLuminance: 240,
          darkBelow: 40,
          brightAbove: 220));
      expect(sink.calls.last.name, 'photo_warned_exposure');
    });

    test('21. a throwing sink does not propagate out of emit()', () {
      Analytics.testSink = (_, __) => throw Exception('sink down');
      // Analytics.logEvent swallows observer errors — emit must complete.
      expect(() => CaptureAnalytics.emit(captured()), returnsNormally);
    });

    test('22. emit is one tracked call per capture decision', () {
      CaptureAnalytics.emit(captured());
      expect(sink.calls.length, 1);
    });

    test(
        '23. the emitter does NOT enforce mutual exclusivity (call site does)',
        () {
      // INVARIANT: call sites must never emit both photo_captured AND a rejection
      // event for the same attempt. This test documents that the EMITTER imposes
      // no such guard — emitting two events simply records two calls; the (future)
      // capture-decision wiring is responsible for the exclusivity.
      CaptureAnalytics.emit(captured());
      CaptureAnalytics.emit(const PhotoRejectedBlurEvent(
          properties: kTestProps, blurScore: 5, blurRejectBelow: 40));
      expect(sink.calls.length, 2);
    });

    test('24. exposure warning fires independently of the capture outcome', () {
      CaptureAnalytics.emit(const PhotoWarnedExposureEvent(
          properties: kTestProps,
          exposureBand: ExposureBand.dark,
          meanLuminance: 10,
          darkBelow: 40,
          brightAbove: 220));
      CaptureAnalytics.emit(captured());
      expect(sink.calls.length, 2);
      expect(sink.calls[0].name, 'photo_warned_exposure');
      expect(sink.calls[1].name, 'photo_captured');
    });

    test('25. every event type carries all shared property keys', () {
      final events = <CaptureAnalyticsEvent>[
        captured(),
        const PhotoRejectedBlurEvent(
            properties: kTestProps, blurScore: 5, blurRejectBelow: 40),
        const PhotoRejectedMotionEvent(
            properties: kTestProps,
            stabilityScoreAtRejection: 0.2,
            gyroThreshRadS: 0.8,
            accelThreshG: 0.15),
        const PhotoWarnedExposureEvent(
            properties: kTestProps,
            exposureBand: ExposureBand.dark,
            meanLuminance: 10,
            darkBelow: 40,
            brightAbove: 220),
      ];
      for (final e in events) {
        expect(e.toMap().keys.toSet().containsAll(_sharedKeys), isTrue,
            reason: '${e.name} missing a shared key');
      }
    });
  });

  group('CaptureEventProperties — value pass-through', () {
    test('26. platform is stored as-is (call site owns validation)', () {
      // NOTE: the value type does not validate platform; 'windows' passes through.
      const p = CaptureEventProperties(
        pitchBandId: 'low',
        pitchDegrees: 0,
        stabilityScore: 0.5,
        gyroMag: 0,
        linAccelMag: 0,
        sensorTimestampNs: 0,
        deviceModel: 'd',
        platform: 'windows',
      );
      expect(p.toMap()['platform'], 'windows');
    });

    test('27. stabilityScore outside [0,1] is stored without clamping', () {
      // NOTE: clamping is the native stability gate's responsibility, not this
      // value type's.
      const p = CaptureEventProperties(
        pitchBandId: 'low',
        pitchDegrees: 0,
        stabilityScore: 1.5,
        gyroMag: 0,
        linAccelMag: 0,
        sensorTimestampNs: 0,
        deviceModel: 'd',
        platform: 'android',
      );
      expect(p.toMap()['stability_score'], 1.5);
    });
  });
}
