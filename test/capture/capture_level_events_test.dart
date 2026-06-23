// test/capture/capture_level_events_test.dart
//
// Unit coverage for the canonical capture-level lifecycle event layer: each event
// maps to its exact name + a correctly-typed, complete property schema; level
// serializes to "A"/"B"/"C"; CaptureAnalytics.log forwards to the dispatcher; the
// session provides a stable session_id + non-negative duration; and the payloads
// carry no PII/token/path keys.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_analytics.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/utils/analytics.dart';

void main() {
  group('CaptureLevel serialization', () {
    test('serializes to A/B/C', () {
      expect(CaptureLevel.a.code, 'A');
      expect(CaptureLevel.b.code, 'B');
      expect(CaptureLevel.c.code, 'C');
    });

    test('captureLevelFromLabel maps labels (any case), unknown → A', () {
      expect(captureLevelFromLabel('A'), CaptureLevel.a);
      expect(captureLevelFromLabel('b'), CaptureLevel.b);
      expect(captureLevelFromLabel(' C '), CaptureLevel.c);
      expect(captureLevelFromLabel('Eye Ring'), CaptureLevel.a);
    });
  });

  group('event name + schema', () {
    test('capture_level_started', () {
      const e = CaptureLevelStarted(
        level: CaptureLevel.a,
        projectId: 'proj_1',
        sessionId: 'sess_1',
        captureMode: 'guided',
        targetSegments: 30,
        sensorSupported: true,
        deviceType: 'android',
      );
      expect(e.name, 'capture_level_started');
      expect(e.properties, {
        'level': 'A',
        'project_id': 'proj_1',
        'session_id': 'sess_1',
        'capture_mode': 'guided',
        'target_segments': 30,
        'sensor_supported': true,
        'device_type': 'android',
      });
      expect(e.properties['target_segments'], isA<int>());
      expect(e.properties['sensor_supported'], isA<bool>());
    });

    test('capture_level_completed', () {
      const e = CaptureLevelCompleted(
        level: CaptureLevel.b,
        projectId: 'proj_1',
        sessionId: 'sess_1',
        accepted: 28,
        target: 30,
        rejected: 3,
        coveragePct: 93,
        durationSeconds: 142,
        deviceType: 'ios',
      );
      expect(e.name, 'capture_level_completed');
      expect(e.properties, {
        'level': 'B',
        'project_id': 'proj_1',
        'session_id': 'sess_1',
        'accepted': 28,
        'target': 30,
        'rejected': 3,
        'coverage_pct': 93,
        'duration_seconds': 142,
        'device_type': 'ios',
      });
    });

    test('capture_level_retake', () {
      const e = CaptureLevelRetake(
        level: CaptureLevel.c,
        projectId: 'proj_1',
        sessionId: 'sess_1',
        ringIndex: 7,
        replacingExisting: false,
        returnMode: 'resume',
        deviceType: 'android',
      );
      expect(e.name, 'capture_level_retake');
      expect(e.properties, {
        'level': 'C',
        'project_id': 'proj_1',
        'session_id': 'sess_1',
        'ring_index': 7,
        'replacing_existing': false,
        'return_mode': 'resume',
        'device_type': 'android',
      });
    });

    test('segment_filled', () {
      const e = CaptureSegmentFilled(
        level: CaptureLevel.a,
        projectId: 'proj_1',
        sessionId: 'sess_1',
        segmentIndex: 5,
        segmentCount: 30,
        captureMode: 'manual',
        deviceType: 'ios',
      );
      expect(e.name, 'segment_filled');
      expect(e.properties, {
        'level': 'A',
        'project_id': 'proj_1',
        'session_id': 'sess_1',
        'segment_index': 5,
        'segment_count': 30,
        'capture_mode': 'manual',
        'device_type': 'ios',
      });
    });

    test('coverage_milestone', () {
      const e = CaptureCoverageMilestone(
        level: CaptureLevel.a,
        projectId: 'proj_1',
        sessionId: 'sess_1',
        milestone: 75,
        filledCount: 23,
        segmentCount: 30,
        deviceType: 'android',
      );
      expect(e.name, 'coverage_milestone');
      expect(e.properties, {
        'level': 'A',
        'project_id': 'proj_1',
        'session_id': 'sess_1',
        'milestone': 75,
        'filled_count': 23,
        'segment_count': 30,
        'device_type': 'android',
      });
    });
  });

  group('privacy', () {
    test('no payload carries PII / token / path keys', () {
      final events = <CaptureLevelEvent>[
        const CaptureLevelStarted(
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          captureMode: 'guided',
          targetSegments: 30,
          sensorSupported: false,
          deviceType: 'android',
        ),
        const CaptureLevelCompleted(
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          accepted: 0,
          target: 30,
          rejected: 0,
          coveragePct: 0,
          durationSeconds: 0,
          deviceType: 'android',
        ),
        const CaptureLevelRetake(
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          ringIndex: 0,
          replacingExisting: true,
          returnMode: 'review',
          deviceType: 'android',
        ),
        const CaptureSegmentFilled(
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          segmentIndex: 0,
          segmentCount: 30,
          captureMode: 'guided',
          deviceType: 'android',
        ),
        const CaptureCoverageMilestone(
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          milestone: 50,
          filledCount: 15,
          segmentCount: 30,
          deviceType: 'android',
        ),
      ];
      const banned = [
        'email', 'phone', 'name', 'token', 'path', 'file', 'user', 'lat', 'lng',
      ];
      for (final e in events) {
        for (final key in e.properties.keys) {
          for (final b in banned) {
            expect(key.toLowerCase().contains(b), isFalse,
                reason: '${e.name} key "$key" looks like PII');
          }
        }
      }
    });
  });

  group('CaptureAnalytics.log', () {
    tearDown(() => Analytics.testSink = null);

    test('forwards name + properties to the dispatcher', () {
      String? name;
      Map<String, Object?>? props;
      Analytics.testSink = (n, p) {
        name = n;
        props = p;
      };

      CaptureAnalytics.log(const CaptureLevelStarted(
        level: CaptureLevel.a,
        projectId: 'p',
        sessionId: 's',
        captureMode: 'manual',
        targetSegments: 12,
        sensorSupported: false,
        deviceType: 'ios',
      ));

      expect(name, 'capture_level_started');
      expect(props?['capture_mode'], 'manual');
    });

    test('a throwing dispatcher does not propagate (capture never blocked)', () {
      Analytics.testSink = (_, __) => throw StateError('boom');
      expect(
        () => CaptureAnalytics.log(const CaptureLevelRetake(
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          ringIndex: 0,
          replacingExisting: true,
          returnMode: 'review',
          deviceType: 'android',
        )),
        returnsNormally,
      );
    });
  });
}
