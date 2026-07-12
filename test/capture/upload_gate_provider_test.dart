// test/capture/upload_gate_provider_test.dart
//
// The reactive hard upload gate: reads live per-level accepted counts from the
// ledger (same source as the completion gate — no duplicated counting) against
// BOTH per-level floors — the config-driven absolute shot minimum
// (CaptureConfig.uploadMinShots) AND the ring-coverage completion floor
// (minCoveragePct of the variant's segment count: bundled with_bottom =
// ceil(80% × 12) = 10 distinct segments per level — the same floor the
// backend's POST /jobs range enforces). Verifies config-driven thresholds,
// coverage enforcement (duplicates don't count), default fallback, fail-safe
// on empty data, reactivity, and the passed/blocked analytics.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/review_grid_items_provider.dart';
import 'package:recapture/application/capture/upload_gate_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/utils/analytics.dart';

/// The bundled-default coverage floor per level: with_bottom rings carry 12
/// segments each, so 80% coverage demands ceil(0.8 × 12) = 10 filled segments.
const int kCoverageFloor = 10;

/// Bundled default → every level's absolute shot minimum is the default (1);
/// the coverage floor is [kCoverageFloor].
class _DefaultConfig extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

/// Per-level shot-minimum override ABOVE the coverage floor, so the shot axis
/// is testable on its own: A demands 12 accepted shots.
class _OverrideConfig extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault.copyWith(
        uploadMinShots: const UploadMinShots(
          perLevelMinShots: {'A': 12},
        ),
      );
}

CapturedPhotoRecord _shot(int seg, String path) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 0,
      sensorTimestampNs: seg * 1000 + 1,
    );

/// Records [n] accepted shots per band, each on its OWN segment (0..n-1) —
/// n shots ⇒ n filled segments.
LevelCaptureLedgerRegistry _registry(Map<String, int> framesPerBand) {
  final reg = LevelCaptureLedgerRegistry();
  framesPerBand.forEach((band, n) {
    final ledger = reg.ledgerFor(band);
    for (var i = 0; i < n; i++) {
      ledger.recordAccepted(_shot(i, '/$band/$i.jpg'));
    }
  });
  return reg;
}

ProviderContainer _container(
  LevelCaptureLedgerRegistry reg, {
  ConfigNotifier Function() config = _DefaultConfig.new,
}) {
  final c = ProviderContainer(overrides: [
    levelCaptureLedgerRegistryProvider.overrideWithValue(reg),
    captureConfigProvider.overrideWith(config),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('every level at the coverage floor (10 distinct segments) → eligible',
      () {
    final gate = _container(_registry(
            {'mid': kCoverageFloor, 'high': kCoverageFloor, 'low': kCoverageFloor}))
        .read(uploadGateProvider);
    expect(gate.eligible, isTrue);
    expect(gate.totalDeficit, 0);
  });

  test('a level below the coverage floor → not eligible, segments-short deficit',
      () {
    final gate = _container(_registry(
            {'mid': kCoverageFloor, 'high': 1, 'low': kCoverageFloor}))
        .read(uploadGateProvider);
    expect(gate.eligible, isFalse);
    expect(gate.shortLevelsLabel, 'B'); // high == Level B
    expect(gate.totalDeficit, kCoverageFloor - 1);
  });

  test('duplicate-segment shots do NOT count toward coverage', () {
    final reg =
        _registry({'mid': kCoverageFloor, 'high': kCoverageFloor, 'low': 9});
    // A 10th shot on an ALREADY-FILLED segment: accepted rises to 10 but the
    // distinct coverage stays 9 — the gate must stay closed (the packer
    // dedupes to one image per segment, so the bundle would be 9 on this ring).
    reg.ledgerFor('low').recordAccepted(_shot(0, '/low/dup.jpg'));
    final gate = _container(reg).read(uploadGateProvider);
    expect(gate.eligible, isFalse);
    expect(gate.shortLevelsLabel, 'C');
    expect(gate.shortLevels.single.accepted, 10);
    expect(gate.shortLevels.single.filled, 9);
    expect(gate.totalDeficit, 1);
  });

  test('config-driven shot minimum above the coverage floor (A=12)', () {
    final gate = _container(
      _registry({'mid': kCoverageFloor, 'high': kCoverageFloor, 'low': kCoverageFloor}),
      config: _OverrideConfig.new,
    ).read(uploadGateProvider);
    // A: coverage met (10/10) but 10/12 shots → short by 2.
    expect(gate.eligible, isFalse);
    expect(gate.shortLevelsLabel, 'A');
    expect(gate.shortLevels.single.deficit, 2);
  });

  test('empty registry → fail safe NOT eligible', () {
    final gate =
        _container(LevelCaptureLedgerRegistry()).read(uploadGateProvider);
    expect(gate.eligible, isFalse);
    expect(gate.totalDeficit, 3 * kCoverageFloor); // coverage floor × 3 levels
  });

  test('reactive: filling the missing segment flips to eligible', () {
    final reg = _registry(
        {'mid': kCoverageFloor, 'high': kCoverageFloor - 1, 'low': kCoverageFloor});
    final c = _container(reg);
    expect(c.read(uploadGateProvider).eligible, isFalse);

    reg
        .ledgerFor('high')
        .recordAccepted(_shot(kCoverageFloor - 1, '/high/last.jpg'));
    // Mirror the screen's refresh-on-return: invalidate the per-level item source
    // (which the gate reads) + the gate itself.
    c.invalidate(reviewGridItemsProvider('high'));
    c.invalidate(uploadGateProvider);
    expect(c.read(uploadGateProvider).eligible, isTrue);
  });

  group('analytics', () {
    late List<({String name, Map<String, Object?> props})> events;
    setUp(() {
      events = [];
      Analytics.testSink =
          (name, props) => events.add((name: name, props: props));
    });
    tearDown(() => Analytics.testSink = null);

    test('passed fires once per not-eligible→eligible transition', () {
      final c = _container(_registry(
          {'mid': kCoverageFloor, 'high': kCoverageFloor, 'low': kCoverageFloor}));
      final n = c.read(uploadGateAnalyticsProvider.notifier);
      final gate = c.read(uploadGateProvider);

      n.syncPassedMilestone(gate, sessionId: 's1');
      n.syncPassedMilestone(gate, sessionId: 's1'); // idempotent while eligible
      expect(events.where((e) => e.name == AnalyticsEvents.uploadGatePassed),
          hasLength(1));
    });

    test('blocked carries short_levels + total_deficit', () {
      final c = _container(_registry(
          {'mid': kCoverageFloor - 2, 'high': kCoverageFloor - 1, 'low': kCoverageFloor}));
      final n = c.read(uploadGateAnalyticsProvider.notifier);
      n.logBlocked(c.read(uploadGateProvider), sessionId: 's1');
      final blocked =
          events.firstWhere((e) => e.name == AnalyticsEvents.uploadGateBlocked);
      expect(blocked.props['short_levels'], 'A,B');
      expect(blocked.props['total_deficit'], 3); // A short 2, B short 1
      expect(blocked.props['phase'], 'upload');
    });
  });
}
