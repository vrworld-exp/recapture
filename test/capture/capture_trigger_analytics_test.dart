// test/capture/capture_trigger_analytics_test.dart
//
// Unit coverage for the two trigger events + the single-call-site helper: exact
// names/typed schemas (incl. null ring_index), the was_blocked_override derivation
// (manual only), the shared attempt_number on the session, fire-and-forget, and a
// privacy sweep.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/analytics/capture_level_session.dart';
import 'package:recapture/application/capture/analytics/capture_trigger_analytics.dart';
import 'package:recapture/utils/analytics.dart';

void main() {
  group('event schema', () {
    test('manual_capture_triggered', () {
      const e = CaptureManualTriggered(
        level: CaptureLevel.a,
        projectId: 'p',
        sessionId: 's',
        attemptNumber: 3,
        ringIndex: 5,
        inBand: true,
        stable: true,
        sensorSupported: true,
        wasBlockedOverride: false,
        deviceType: 'android',
      );
      expect(e.name, 'manual_capture_triggered');
      expect(e.properties, {
        'level': 'A',
        'project_id': 'p',
        'session_id': 's',
        'attempt_number': 3,
        'ring_index': 5,
        'in_band': true,
        'stable': true,
        'sensor_supported': true,
        'was_blocked_override': false,
        'device_type': 'android',
      });
    });

    test('autocapture_triggered', () {
      const e = CaptureAutoTriggered(
        level: CaptureLevel.b,
        projectId: 'p',
        sessionId: 's',
        attemptNumber: 9,
        ringIndex: null,
        inBand: true,
        stable: true,
        sensorSupported: true,
        deviceType: 'ios',
      );
      expect(e.name, 'autocapture_triggered');
      expect(e.properties['level'], 'B');
      expect(e.properties['ring_index'], isNull); // null serializes safely
      expect(e.properties.containsKey('was_blocked_override'), isFalse);
    });
  });

  group('CaptureTriggerAnalytics.manual — was_blocked_override', () {
    late List<(String, Map<String, Object?>)> events;
    setUp(() {
      events = [];
      Analytics.testSink = (n, p) => events.add((n, p));
    });
    tearDown(() => Analytics.testSink = null);

    bool override() => events
        .firstWhere((e) => e.$1 == AnalyticsEvents.manualCaptureTriggered)
        .$2['was_blocked_override'] as bool;

    test('false when all gates satisfied', () {
      CaptureTriggerAnalytics.manual(
        level: CaptureLevel.a,
        projectId: 'p',
        sessionId: 's',
        attemptNumber: 1,
        ringIndex: 0,
        inBand: true,
        stable: true,
        sensorSupported: true,
        deviceType: 'android',
      );
      expect(override(), isFalse);
    });

    test('true on fail-open (sensors off), readiness recorded as actual', () {
      CaptureTriggerAnalytics.manual(
        level: CaptureLevel.a,
        projectId: 'p',
        sessionId: 's',
        attemptNumber: 1,
        ringIndex: null,
        inBand: false,
        stable: false,
        sensorSupported: false,
        deviceType: 'android',
      );
      final e = events.single.$2;
      expect(e['was_blocked_override'], isTrue);
      expect(e['in_band'], isFalse);
      expect(e['stable'], isFalse);
      expect(e['sensor_supported'], isFalse);
    });

    test('true when sensors on but not in band/stable (manual-mode override)', () {
      CaptureTriggerAnalytics.manual(
        level: CaptureLevel.a,
        projectId: 'p',
        sessionId: 's',
        attemptNumber: 1,
        ringIndex: 0,
        inBand: false,
        stable: true,
        sensorSupported: true,
        deviceType: 'android',
      );
      expect(override(), isTrue);
    });
  });

  group('shared attempt_number', () {
    test('increments coherently across manual + auto in one session', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(captureLevelSessionProvider.notifier);
      notifier.start(level: CaptureLevel.a, projectId: 'p', sessionId: 's');

      expect(notifier.nextAttempt(), 1); // manual
      expect(notifier.nextAttempt(), 2); // auto
      expect(notifier.nextAttempt(), 3); // manual

      // A new session restarts the sequence.
      notifier.start(level: CaptureLevel.a, projectId: 'p', sessionId: 's2');
      expect(notifier.nextAttempt(), 1);
    });
  });

  group('privacy + fire-and-forget', () {
    tearDown(() => Analytics.testSink = null);

    test('no payload key looks like PII / token / path', () {
      final events = <CaptureLevelEvent>[
        const CaptureManualTriggered(
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          attemptNumber: 1,
          ringIndex: null,
          inBand: false,
          stable: false,
          sensorSupported: false,
          wasBlockedOverride: true,
          deviceType: 'android',
        ),
        const CaptureAutoTriggered(
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          attemptNumber: 1,
          ringIndex: 0,
          inBand: true,
          stable: true,
          sensorSupported: true,
          deviceType: 'android',
        ),
      ];
      const banned = ['email', 'phone', 'name', 'token', 'path', 'image', 'lat',
        'lng', 'location'];
      for (final e in events) {
        for (final k in e.properties.keys) {
          for (final b in banned) {
            expect(k.toLowerCase().contains(b), isFalse, reason: '$k ~ $b');
          }
        }
      }
    });

    test('a throwing dispatcher does not propagate', () {
      Analytics.testSink = (_, __) => throw StateError('boom');
      expect(
        () => CaptureTriggerAnalytics.auto(
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          attemptNumber: 1,
          ringIndex: 0,
          inBand: true,
          stable: true,
          sensorSupported: true,
          deviceType: 'android',
        ),
        returnsNormally,
      );
    });
  });
}
