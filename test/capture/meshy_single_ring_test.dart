// test/capture/meshy_single_ring_test.dart
//
// The Meshy reshape: ONE eye ring of 6, variant-independent, eye→top [60,180),
// with a HARD tilt gate. These tests pin the reshape's invariants — that Meshy
// runs a single Level A (never B/C), sizes it to 6 (never full's 16), remaps the
// eye band to the hard window, and blocks a shot outside it even without sensors.
// Full mode is asserted UNCHANGED alongside each Meshy assertion.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/capture_mode_provider.dart';
import 'package:recapture/application/capture/effective_capture_config_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/progression/level_progression_builder.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/capture/capture_mode.dart';
import 'package:recapture/domain/capture/level_completion.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_pitch_guide.dart';
import 'package:recapture/domain/entities/capture_readiness.dart' as readiness;

void main() {
  const config = CaptureConfig.bundledDefault;

  group('active levels — Meshy is Level A alone', () {
    test('both variants collapse to a single Level A in Meshy', () {
      expect(
        activeCaptureLevels(CaptureFlowVariant.withBottom, CaptureMode.meshy),
        [CaptureLevel.a],
      );
      expect(
        activeCaptureLevels(CaptureFlowVariant.withoutBottom, CaptureMode.meshy),
        [CaptureLevel.a],
      );
    });

    test('full mode is unchanged — the variant still shapes the levels', () {
      expect(
        activeCaptureLevels(CaptureFlowVariant.withBottom, CaptureMode.full),
        [CaptureLevel.a, CaptureLevel.b, CaptureLevel.c],
      );
      expect(
        activeCaptureLevels(CaptureFlowVariant.withoutBottom, CaptureMode.full),
        [CaptureLevel.a, CaptureLevel.b],
      );
    });
  });

  group('shape counts', () {
    test('effectiveSegmentsFor: the eye ring is 6 in Meshy, 16 in full', () {
      expect(
        effectiveSegmentsFor(config, CaptureFlowVariant.withBottom, 'mid',
            mode: CaptureMode.meshy),
        6,
      );
      expect(
        effectiveSegmentsFor(config, CaptureFlowVariant.withBottom, 'mid'),
        16,
      );
    });

    test('expectedPhotoTotalFor == 6 for either variant in Meshy', () {
      for (final v in CaptureFlowVariant.values) {
        expect(
          expectedPhotoTotalFor(config, v, mode: CaptureMode.meshy),
          6,
        );
      }
      // Full is untouched.
      expect(
        expectedPhotoTotalFor(config, CaptureFlowVariant.withBottom),
        48,
      );
    });
  });

  group('progression / upload snapshot', () {
    CapturedPhotoRecord rec(int? segment) => CapturedPhotoRecord(
          segmentIndex: segment,
          framePath: 'p$segment.jpg',
          blurScore: 120,
          meanLuminance: 128,
          yawDegrees: 0,
          pitchDegrees: 0,
          sensorTimestampNs: 1,
        );

    test('Meshy progression has ONE level of 6, not three of 16', () {
      final states = levelStatesFromConfig(
        config,
        variant: CaptureFlowVariant.withBottom,
        mode: CaptureMode.meshy,
      );
      expect(states, hasLength(1));
      expect(states.single.levelId, 'mid');
      expect(states.single.segmentCount, 6);
    });

    test('progressionFromLedger with mode reports 6, not 16', () {
      final registry = LevelCaptureLedgerRegistry();
      for (var i = 0; i < 6; i++) {
        registry.ledgerFor('mid').recordAccepted(rec(i));
      }
      final p = progressionFromLedger(
        config,
        variant: CaptureFlowVariant.withBottom,
        registry: registry,
        mode: CaptureMode.meshy,
      );
      expect(p.levels.map((l) => l.levelId).toList(), ['mid']);
      final mid = p.stateForId('mid')!;
      expect(mid.segmentCount, 6);
      expect(mid.filledCount, 6);
      expect(mid.isComplete, isTrue); // all 6 filled
      expect(p.overallComplete, isTrue);
    });
  });

  group('coverage floor — Meshy finishes one slot short (5 of 6)', () {
    test('minCoveragePctForMode: meshy is the explicit 80, full is the global', () {
      expect(
        minCoveragePctForMode(CaptureMode.meshy, config.thresholds),
        kMeshyMinCoveragePct,
      );
      expect(kMeshyMinCoveragePct, 80);
      // Full defers to the tunable global (bundled default 80 here).
      expect(
        minCoveragePctForMode(CaptureMode.full, config.thresholds),
        config.thresholds.minCoveragePct,
      );
    });

    test('the eye ring auto-advances at 5 of 6, but not at 4', () {
      final pct = minCoveragePctForMode(CaptureMode.meshy, config.thresholds);
      // 5 filled of 6 clears the floor; the ring is done one slot short.
      expect(
        evaluateLevelA(
          filledCount: 5,
          segmentCount: 6,
          acceptedCount: 5,
          minAcceptedCount: 1,
          minCoveragePct: pct,
        ).isComplete,
        isTrue,
      );
      // 4 of 6 is still short — two slots missing does not finish the ring.
      expect(
        evaluateLevelA(
          filledCount: 4,
          segmentCount: 6,
          acceptedCount: 4,
          minAcceptedCount: 1,
          minCoveragePct: pct,
        ).isComplete,
        isFalse,
      );
    });
  });

  group('effective config — the Meshy eye→top band', () {
    PitchBand midBandFor(CaptureMode mode) {
      final container = ProviderContainer(overrides: [
        // Pin the config to the bundled default so the notifier never runs its
        // Hive-backed bootstrap (there is no Hive host in a pure unit test).
        captureConfigProvider.overrideWith(_StubConfig.new),
        captureModeProvider.overrideWith(() => _StubMode(mode)),
      ]);
      addTearDown(container.dispose);
      final cfg = container.read(effectiveCaptureConfigProvider);
      return cfg.pitchBands.firstWhere((b) => b.id == 'mid');
    }

    test('Meshy remaps mid to [60,180); full keeps the bundled [40,110)', () {
      final meshyMid = midBandFor(CaptureMode.meshy);
      expect(meshyMid.minDegrees, 60);
      expect(meshyMid.maxDegrees, 180);
      expect(meshyMid.segments, 6);

      final fullMid = midBandFor(CaptureMode.full);
      expect(fullMid.minDegrees, 40);
      expect(fullMid.maxDegrees, 110);
    });

    test('band membership: 45 is out, 90 and 150 are in, 180 is out', () {
      final band = midBandFor(CaptureMode.meshy);
      expect(CapturePitchGuide.isInBand(band, 45), isFalse); // tipped up
      expect(CapturePitchGuide.isInBand(band, 90), isTrue); // eye level
      expect(CapturePitchGuide.isInBand(band, 150), isTrue); // looking down
      expect(CapturePitchGuide.isInBand(band, 180), isFalse); // max exclusive
    });
  });

  group('hard tilt gate — the shutter readiness', () {
    test('Meshy blocks an out-of-band shot even with sensors unavailable', () {
      // hardGate disables the fail-open: no sensors + not in band → blocked.
      const r = readiness.CaptureReadiness(
        mode: readiness.CaptureMode.guided,
        inBand: false,
        stable: false,
        sensorSupported: false,
        hardGate: true,
      );
      expect(r.canCapture, isFalse);
      expect(r.primaryBlockReason, readiness.BlockReason.outOfBand);
    });

    test('Meshy allows an in-band, stable shot', () {
      const r = readiness.CaptureReadiness(
        mode: readiness.CaptureMode.guided,
        inBand: true,
        stable: true,
        sensorSupported: true,
        hardGate: true,
      );
      expect(r.canCapture, isTrue);
    });

    test('FULL mode still fails OPEN when sensors are unavailable', () {
      // The regression guard: hardGate defaults false, so full mode is untouched.
      const r = readiness.CaptureReadiness(
        mode: readiness.CaptureMode.guided,
        inBand: false,
        stable: false,
        sensorSupported: false,
      );
      expect(r.canCapture, isTrue);
    });
  });
}

/// Minimal stub notifier to pin the capture mode in a ProviderContainer.
class _StubMode extends CaptureModeController {
  _StubMode(this._mode);
  final CaptureMode _mode;
  @override
  CaptureMode build() => _mode;
}

/// Pins the capture config to the bundled default, skipping the Hive bootstrap
/// [ConfigNotifier.build] would otherwise run.
class _StubConfig extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}
