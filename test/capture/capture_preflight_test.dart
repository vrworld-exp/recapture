// test/capture/capture_preflight_test.dart
//
// The preflight report's decision logic — the part that decides whether a user
// is sent into a capture that cannot finish.
//
// The browser probe itself needs a browser, so what is pinned here is the rule
// it feeds: which missing capabilities BLOCK and which merely DEGRADE. The
// asymmetry between the modes is the whole point, and it is the app's existing
// rule (`CaptureMode.meshy.usesHardTiltGate`) surfaced early rather than a new
// opinion — so it is asserted against that flag, not against a literal.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/capture_mode.dart';
import 'package:recapture/platform/capture_ports/capture_preflight.dart';
import 'package:recapture/presentation/screens/capture/capture_preflight_gate.dart';

CaptureCapabilityResult _result(
  CaptureCapability capability, {
  required bool available,
  required bool required_,
}) =>
    CaptureCapabilityResult(
      capability: capability,
      available: available,
      required_: required_,
    );

void main() {
  group('CapturePreflightReport', () {
    test('all-clear allows capture and lists nothing', () {
      expect(CapturePreflightReport.allClear.canCapture, isTrue);
      expect(CapturePreflightReport.allClear.blockers, isEmpty);
      expect(CapturePreflightReport.allClear.degradations, isEmpty);
    });

    test('every capability present allows capture', () {
      final report = CapturePreflightReport(<CaptureCapabilityResult>[
        for (final c in CaptureCapability.values)
          _result(c, available: true, required_: true),
      ]);
      expect(report.canCapture, isTrue);
    });

    test('a missing REQUIRED capability blocks and is named', () {
      final report = CapturePreflightReport(<CaptureCapabilityResult>[
        _result(CaptureCapability.secureContext,
            available: true, required_: true),
        _result(CaptureCapability.camera, available: false, required_: true),
      ]);
      expect(report.canCapture, isFalse);
      expect(report.blockers.single.capability, CaptureCapability.camera);
      // The screen names the capability rather than saying "unavailable".
      expect(report.blockers.single.capability.label, isNotEmpty);
    });

    test('a missing OPTIONAL capability degrades without blocking', () {
      final report = CapturePreflightReport(<CaptureCapabilityResult>[
        _result(CaptureCapability.camera, available: true, required_: true),
        _result(CaptureCapability.motionSensors,
            available: false, required_: false),
      ]);
      expect(report.canCapture, isTrue);
      expect(report.degradations.single.capability,
          CaptureCapability.motionSensors);
      expect(report.blockers, isEmpty);
    });

    test('blockers keep declaration order so the root cause is named first',
        () {
      // Secure context is the cause of the other two, not a peer of them.
      final report = CapturePreflightReport(<CaptureCapabilityResult>[
        _result(CaptureCapability.secureContext,
            available: false, required_: true),
        _result(CaptureCapability.camera, available: false, required_: true),
      ]);
      expect(
        report.blockers.map((b) => b.capability),
        <CaptureCapability>[
          CaptureCapability.secureContext,
          CaptureCapability.camera,
        ],
      );
    });
  });

  group('motion is required exactly where the mode hard-gates', () {
    // Written against the mode flag, not a literal, so relaxing the hard gate
    // to "fix" the web Maya shutter fails here too.
    CaptureCapabilityResult motionFor(CaptureMode mode,
            {required bool granted}) =>
        _result(
          CaptureCapability.motionSensors,
          available: granted,
          required_: mode.usesHardTiltGate,
        );

    test('meshy without motion is BLOCKED', () {
      final report = CapturePreflightReport(<CaptureCapabilityResult>[
        motionFor(CaptureMode.meshy, granted: false),
      ]);
      expect(report.canCapture, isFalse);
      expect(
          report.blockers.single.capability, CaptureCapability.motionSensors);
    });

    test('full without motion is DEGRADED, never blocked', () {
      final report = CapturePreflightReport(<CaptureCapabilityResult>[
        motionFor(CaptureMode.full, granted: false),
      ]);
      expect(report.canCapture, isTrue);
      expect(report.degradations, hasLength(1));
    });

    test('meshy with motion granted proceeds', () {
      final report = CapturePreflightReport(<CaptureCapabilityResult>[
        motionFor(CaptureMode.meshy, granted: true),
      ]);
      expect(report.canCapture, isTrue);
    });
  });

  group('every capability has a user-facing name', () {
    test('no label is blank or a raw enum name', () {
      for (final c in CaptureCapability.values) {
        expect(c.label.trim(), isNotEmpty, reason: '$c');
        expect(c.label, isNot(contains('CaptureCapability')), reason: '$c');
      }
    });
  });

  group('the quota estimate is sized to the job about to start', () {
    test('the mode photo counts are the published, unchanged totals', () {
      expect(expectedPhotoCountFor(CaptureMode.meshy), 6);
      expect(expectedPhotoCountFor(CaptureMode.full), 48);
    });
  });

  group('native builds are unaffected', () {
    test('the probe reports all-clear on the VM (the dart:io branch)',
        () async {
      final report = await runCapturePreflight(
        mode: CaptureMode.meshy,
        expectedPhotoCount: 6,
      );
      expect(report.canCapture, isTrue);
      expect(report.results, isEmpty);
    });
  });
}
