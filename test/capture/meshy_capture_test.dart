// test/capture/meshy_capture_test.dart
//
// Pure unit tests for the MESHY single-ring capture shape (see the prompt
// recapture-api/docs/prompts/meshy-single-ring-6shot-capture.md, Section 4).
//
// Meshy is ONE Eye ring of 6 shots taken ~60° apart in yaw, with camera tilt
// anywhere in [90,180) (eye-level → top-down), a HARD tilt gate, MANUAL shutter,
// and a 100% coverage floor (all 6 required). These tests pin the parts of that
// shape that the whole client + upload path derives from — the fixed
// [CaptureConfig.meshy], the mode-aware level list, the tilt gate, and the
// manifest/job stamp — so a regression in any one surfaces here rather than on a
// device.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/progression/level_progression_builder.dart';
import 'package:recapture/application/capture/progression/level_segment_machines.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/capture/capture_mode.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_photo_metadata.dart';
import 'package:recapture/domain/entities/capture_pitch_guide.dart';
import 'package:recapture/domain/upload/capture_manifest.dart';

void main() {
  // ── 1. The Meshy CaptureConfig is a single Eye ring of 6, floor 100 ──────────
  group('CaptureConfig.meshy shape', () {
    const config = CaptureConfig.meshy;

    test('is exactly one band: id "mid", tilt [90,180), 6 segments', () {
      expect(config.pitchBands, hasLength(1));
      final band = config.pitchBands.single;
      // Reuses the Eye-Ring / Level-A band id 'mid' on purpose (A → mid → EYE),
      // so every level→band→ring consumer keeps working with zero branching.
      expect(band.id, 'mid');
      expect(band.minDegrees, 90); // eye level — inclusive
      expect(band.maxDegrees, 180); // top-down — exclusive
      expect(band.segments, 6);
    });

    test('totals 6 capture positions (drives the 6-image bundle)', () {
      // The full bundle is these 6 images + 1 manifest = expectedFilesCount 7 on
      // POST /jobs (the orchestrator's bundle.totalImages + 1).
      expect(config.totalSegments, 6);
      expect(config.eyeRingSegments, 6);
    });

    test('coverage floor is 100 — every slot required', () {
      expect(config.thresholds.minCoveragePct, 100);
    });

    test('both gates demand 6 accepted shots on Level A', () {
      // Completion gate (soft) and upload gate (hard) both pinned to 6 so a
      // session cannot finish OR upload until all 6 slots are filled.
      expect(config.completionThresholds.minAcceptedFramesFor('A'), 6);
      expect(config.uploadMinShots.minShotsFor('A'), 6);
    });

    test('carries the distinct Meshy config-version sentinel', () {
      expect(config.version, CaptureConfig.meshyConfigVersion);
    });

    test('effectiveSegmentsFor resolves 6 for BOTH variants (variant-less)', () {
      // variantSegments pins mid=6 for both keys so the resolver never falls
      // through to the 16 bundled default.
      expect(
        effectiveSegmentsFor(config, CaptureFlowVariant.withBottom, 'mid'),
        6,
      );
      expect(
        effectiveSegmentsFor(config, CaptureFlowVariant.withoutBottom, 'mid'),
        6,
      );
    });
  });

  // ── 2. Meshy yields a SINGLE level (A) regardless of variant ────────────────
  group('activeCaptureLevels under Meshy mode', () {
    test('meshy → [A] for both variants (no B/C ever)', () {
      expect(
        activeCaptureLevels(CaptureFlowVariant.withBottom, CaptureMode.meshy),
        const [CaptureLevel.a],
      );
      expect(
        activeCaptureLevels(
            CaptureFlowVariant.withoutBottom, CaptureMode.meshy),
        const [CaptureLevel.a],
      );
    });

    test('full mode is UNCHANGED — defers to the variant level list', () {
      expect(
        activeCaptureLevels(CaptureFlowVariant.withBottom, CaptureMode.full),
        CaptureFlowVariant.withBottom.levels,
      );
      expect(
        activeCaptureLevels(
            CaptureFlowVariant.withoutBottom, CaptureMode.full),
        CaptureFlowVariant.withoutBottom.levels,
      );
    });
  });

  // ── 3. Progression / segment machines are a single level of 6 ───────────────
  group('progression from the Meshy config', () {
    test('one level (A / mid / 6 segments, floor 100)', () {
      final progression = initialProgressionFromConfig(
        CaptureConfig.meshy,
        variant: CaptureFlowVariant.withBottom,
        mode: CaptureMode.meshy,
      );
      expect(progression.levels, hasLength(1));
      final level = progression.levels.single;
      expect(level.levelCode, 'A');
      expect(level.levelId, 'mid');
      expect(level.segmentCount, 6);
      expect(level.minCoveragePct, 100);
    });

    test('segment machines produce a single 6-slot machine', () {
      final machines = levelSegmentMachinesFromConfig(
        CaptureConfig.meshy,
        variant: CaptureFlowVariant.withoutBottom,
        mode: CaptureMode.meshy,
      );
      expect(machines, hasLength(1));
      expect(machines.single.segmentCount, 6);
    });
  });

  // ── 4. HARD tilt gate: a shot below 90° does not count ──────────────────────
  group('Meshy tilt gate (the shared shutter/auto membership gate)', () {
    final band = CaptureConfig.meshy.pitchBands.single;

    test('below eye level (< 90°) is REJECTED', () {
      // 0 = sky, 90 = eye level, 180 = ground/top-down. Below 90 aims BELOW eye
      // level — the classic sign-error case the gate must reject.
      expect(CapturePitchGuide.isInBand(band, 0), isFalse);
      expect(CapturePitchGuide.isInBand(band, 45), isFalse);
      expect(CapturePitchGuide.isInBand(band, 89.999), isFalse);
    });

    test('eye level up to (not including) 180° is ACCEPTED', () {
      expect(CapturePitchGuide.isInBand(band, 90), isTrue); // inclusive min
      expect(CapturePitchGuide.isInBand(band, 135), isTrue);
      expect(CapturePitchGuide.isInBand(band, 179.999), isTrue);
    });

    test('exactly 180° is outside (max is exclusive)', () {
      expect(CapturePitchGuide.isInBand(band, 180), isFalse);
    });

    test('a broken sensor read (NaN) never counts as in-band', () {
      expect(CapturePitchGuide.isInBand(band, double.nan), isFalse);
    });
  });

  // ── 5. Manifest / job payload carry captureMode: 'meshy' ────────────────────
  group('captureMode on the wire', () {
    const session = ManifestSession(
      projectId: 'proj1',
      jobId: 'job1',
      captureSessionId: 'sess1',
      objectSize: 'MEDIUM',
    );
    const device = ManifestDevice(
      platform: 'android',
      manufacturer: 'Samsung',
      model: 'SM-A536E',
      osVersion: '13',
      appVersion: '1.0.3',
      intrinsics: CaptureIntrinsics(focalLengthMm: 4.7),
    );
    const levelA = ManifestLevel(
      levelCode: 'A',
      levelId: 'mid',
      segmentCount: 6,
      filledCount: 6,
      coveragePct: 100,
      complete: true,
    );

    test('a Meshy manifest stamps captureMode: "meshy"', () {
      final m = buildCaptureManifest(
        session: session,
        device: device,
        config: CaptureConfig.meshy,
        levels: const [levelA],
        photos: const [],
        captureModeId: 'meshy',
      );
      expect(m['captureMode'], 'meshy');
    });

    test('the default stays "full" (every pre-Meshy caller, untouched)', () {
      final m = buildCaptureManifest(
        session: session,
        device: device,
        config: CaptureConfig.bundledDefault,
        levels: const [levelA],
        photos: const [],
      );
      expect(m['captureMode'], 'full');
    });
  });

  // ── 6. CaptureMode id / parse round-trips (the wire value) ─────────────
  group('CaptureMode wire id', () {
    test('ids match the backend enum and round-trip', () {
      expect(CaptureMode.meshy.id, 'meshy');
      expect(CaptureMode.full.id, 'full');
      // The winning design discriminates by BEHAVIOUR getters rather than the
      // old `isMeshy` flag — meshy is the shutter-only mode, full runs the loop.
      expect(CaptureMode.meshy.usesAutoCapture, isFalse);
      expect(CaptureMode.full.usesAutoCapture, isTrue);
    });

    test('fromId is tolerant — unknown/null → full', () {
      expect(CaptureMode.fromId('meshy'), CaptureMode.meshy);
      expect(CaptureMode.fromId('full'), CaptureMode.full);
      expect(CaptureMode.fromId(null), CaptureMode.full);
      expect(CaptureMode.fromId('bogus'), CaptureMode.full);
    });
  });
}
