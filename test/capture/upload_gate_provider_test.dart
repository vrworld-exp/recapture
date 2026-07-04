// test/capture/upload_gate_provider_test.dart
//
// The reactive hard upload gate: reads live per-level accepted counts from the
// ledger (same source as the completion gate — no duplicated counting) against the
// config-driven absolute minimums (CaptureConfig.uploadMinShots). Verifies
// config-driven thresholds, default fallback, fail-safe on empty data, reactivity,
// and the passed/blocked analytics (passed fires once per transition).
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

/// Bundled default → every level's absolute minimum is the default (1).
class _DefaultConfig extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

/// Per-level overrides: A=3, B=2, C=4.
class _OverrideConfig extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault.copyWith(
        uploadMinShots: const UploadMinShots(
          perLevelMinShots: {'A': 3, 'B': 2, 'C': 4},
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
  test('default minimum (1): all levels with ≥1 shot → eligible', () {
    final gate =
        _container(_registry({'mid': 1, 'high': 1, 'low': 1})).read(uploadGateProvider);
    expect(gate.eligible, isTrue);
  });

  test('a level with 0 shots → not eligible, deficit 1', () {
    final gate =
        _container(_registry({'mid': 1, 'high': 0, 'low': 1})).read(uploadGateProvider);
    expect(gate.eligible, isFalse);
    expect(gate.shortLevelsLabel, 'B'); // high == Level B
    expect(gate.totalDeficit, 1);
  });

  test('config-driven per-level minimums (A=3,B=2,C=4)', () {
    final gate = _container(
      _registry({'mid': 3, 'high': 1, 'low': 4}),
      config: _OverrideConfig.new,
    ).read(uploadGateProvider);
    // A: 3/3 ok, C: 4/4 ok, B: 1/2 short.
    expect(gate.eligible, isFalse);
    expect(gate.shortLevelsLabel, 'B');
    expect(gate.shortLevels.single.deficit, 1);
  });

  test('empty registry → fail safe NOT eligible', () {
    final gate =
        _container(LevelCaptureLedgerRegistry()).read(uploadGateProvider);
    expect(gate.eligible, isFalse);
    expect(gate.totalDeficit, 3); // 1 per level, 3 levels (default min 1)
  });

  test('reactive: adding the missing shot flips to eligible', () {
    final reg = _registry({'mid': 1, 'high': 0, 'low': 1});
    final c = _container(reg);
    expect(c.read(uploadGateProvider).eligible, isFalse);

    reg.ledgerFor('high').recordAccepted(_shot(0, '/high/0.jpg'));
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
      final c = _container(_registry({'mid': 1, 'high': 1, 'low': 1}));
      final n = c.read(uploadGateAnalyticsProvider.notifier);
      final gate = c.read(uploadGateProvider);

      n.syncPassedMilestone(gate, sessionId: 's1');
      n.syncPassedMilestone(gate, sessionId: 's1'); // idempotent while eligible
      expect(events.where((e) => e.name == AnalyticsEvents.uploadGatePassed),
          hasLength(1));
    });

    test('blocked carries short_levels + total_deficit', () {
      final c = _container(_registry({'mid': 0, 'high': 0, 'low': 1}));
      final n = c.read(uploadGateAnalyticsProvider.notifier);
      n.logBlocked(c.read(uploadGateProvider), sessionId: 's1');
      final blocked =
          events.firstWhere((e) => e.name == AnalyticsEvents.uploadGateBlocked);
      expect(blocked.props['short_levels'], 'A,B');
      expect(blocked.props['total_deficit'], 2);
      expect(blocked.props['phase'], 'upload');
    });
  });
}
