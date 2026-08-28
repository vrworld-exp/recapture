// test/capture/completion_gate_provider_test.dart
//
// The reactive gate wiring: completionGateProvider reads LIVE accepted counts per
// configured level from the ledger and applies config-driven thresholds; it
// re-locks when frames are removed; and SummaryGateAnalyticsNotifier dedups the
// unlock milestone to the locked→unlocked edge while always reporting blocked
// attempts. No platform channels.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/completion_gate_provider.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/review_grid_items_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/capture/completion_gate.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/utils/analytics.dart';

class _StubConfigNotifier extends ConfigNotifier {
  _StubConfigNotifier(this._config);
  final CaptureConfig _config;
  @override
  CaptureConfig build() => _config;
}

CapturedPhotoRecord _accepted(int seg, String path) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 0,
      sensorTimestampNs: seg * 1000 + 1,
    );

LevelCaptureLedgerRegistry _registryWith(Map<String, int> framesPerBand) {
  final reg = LevelCaptureLedgerRegistry();
  framesPerBand.forEach((band, n) {
    final ledger = reg.ledgerFor(band);
    for (var i = 0; i < n; i++) {
      ledger.recordAccepted(_accepted(i, '/$band/$i.jpg'));
    }
  });
  return reg;
}

ProviderContainer _container(
  LevelCaptureLedgerRegistry reg, {
  CaptureConfig? config,
}) {
  final container = ProviderContainer(overrides: [
    levelCaptureLedgerRegistryProvider.overrideWithValue(reg),
    captureConfigProvider.overrideWith(
      () => _StubConfigNotifier(config ?? CaptureConfig.bundledDefault),
    ),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  late List<({String name, Map<String, Object?> props})> events;
  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });
  tearDown(() => Analytics.testSink = null);
  List<({String name, Map<String, Object?> props})> named(String n) =>
      events.where((e) => e.name == n).toList();

  group('completionGateProvider (live + config-driven)', () {
    test('locked while any level is below threshold', () {
      final c = _container(_registryWith({'mid': 2, 'high': 2, 'low': 0}));
      final gate = c.read(completionGateProvider);
      expect(gate.isUnlocked, isFalse);
      expect(gate.incompleteLevelCodes, ['C']);
      expect(gate.levelsTotal, 3); // all configured levels
    });

    test('unlocked once every level meets the default threshold (1)', () {
      final c = _container(_registryWith({'mid': 1, 'high': 1, 'low': 1}));
      expect(c.read(completionGateProvider).isUnlocked, isTrue);
    });

    test('config thresholds raise the bar per level', () {
      final cfg = CaptureConfig.bundledDefault.copyWith(
        completionThresholds: CompletionThresholds.fromMap({
          'C': {'minAcceptedFrames': 3},
        }),
      );
      final c = _container(
        _registryWith({'mid': 1, 'high': 1, 'low': 2}),
        config: cfg,
      );
      // C needs 3, has 2 → locked.
      expect(c.read(completionGateProvider).isUnlocked, isFalse);
      expect(c.read(completionGateProvider).incompleteLevelCodes, ['C']);
    });

    test('re-locks when frames are removed (regression)', () {
      final reg = _registryWith({'mid': 1, 'high': 1, 'low': 1});
      final c = _container(reg);
      expect(c.read(completionGateProvider).isUnlocked, isTrue);

      // Delete Level C's only frame, then refresh the live source the way the
      // summary screen does on review return (the registry instance is stable, so
      // mutating a ledger doesn't auto-notify — the item provider is invalidated).
      reg.ledgerFor('low').removeAccepted('/low/0.jpg');
      c.invalidate(reviewGridItemsProvider(pitchBandIdForLevel(CaptureLevel.c)));
      final gate = c.read(completionGateProvider);
      expect(gate.isUnlocked, isFalse);
      expect(gate.incompleteLevelCodes, ['C']);
    });
  });

  group('SummaryGateAnalyticsNotifier', () {
    test('unlock milestone fires once per locked→unlocked transition', () {
      final c = _container(_registryWith({'mid': 1, 'high': 1, 'low': 1}));
      final gate = c.read(completionGateProvider);
      final n = c.read(summaryGateAnalyticsProvider.notifier);

      n.syncUnlockMilestone(gate, sessionId: 'sess-1');
      n.syncUnlockMilestone(gate, sessionId: 'sess-1'); // idempotent while unlocked
      expect(named(AnalyticsEvents.guidedCaptureSummaryUnlocked), hasLength(1));

      final unlocked = named(AnalyticsEvents.guidedCaptureSummaryUnlocked).single;
      expect(unlocked.props['session_id'], 'sess-1');
      expect(unlocked.props['phase'], 'guided_capture');
      expect(unlocked.props['levels_total'], 3);

      // Re-lock observed → latch re-arms; a fresh unlock fires again.
      final locked = evaluateSummaryGate([
        LevelCompletionStatus(
            levelCode: 'A', acceptedCount: 0, minAcceptedFrames: 1),
      ]);
      n.syncUnlockMilestone(locked, sessionId: 'sess-1');
      n.syncUnlockMilestone(gate, sessionId: 'sess-1');
      expect(named(AnalyticsEvents.guidedCaptureSummaryUnlocked), hasLength(2));
    });

    test('capture_session_complete fires once with derived totals on unlock', () {
      final c = _container(_registryWith({'mid': 3, 'high': 2, 'low': 4}));
      final gate = c.read(completionGateProvider);
      final n = c.read(summaryGateAnalyticsProvider.notifier);

      n.syncUnlockMilestone(gate, sessionId: 'sess-1');
      n.syncUnlockMilestone(gate, sessionId: 'sess-1'); // idempotent while unlocked

      final done = named(AnalyticsEvents.captureSessionComplete);
      expect(done, hasLength(1));
      final p = done.single.props;
      expect(p['session_id'], 'sess-1'); // joins with the per-level events
      expect(p['phase'], 'guided_capture');
      expect(p['levels_total'], 3);
      expect(p['levels_completed'], 3);
      // Per-level counts come straight from the gate's accepted counts…
      expect(p['level_a_frame_count'], 3);
      expect(p['level_b_frame_count'], 2);
      expect(p['level_c_frame_count'], 4);
      // …and total is their sum.
      expect(p['total_frame_count'], 9);
      // Omitted by design (no whole-session start timestamp).
      expect(p.containsKey('session_duration_ms'), isFalse);
    });

    test('capture_session_complete does NOT fire while the gate is locked', () {
      final c = _container(_registryWith({'mid': 1, 'high': 1, 'low': 0}));
      final gate = c.read(completionGateProvider);
      final n = c.read(summaryGateAnalyticsProvider.notifier);

      // A blocked attempt (the router path for a locked gate) emits nothing here.
      n.logBlockedAttempt(gate, sessionId: 'sess-x');
      // Even calling sync on a locked gate is a no-op for the completion event.
      n.syncUnlockMilestone(gate, sessionId: 'sess-x');
      expect(named(AnalyticsEvents.captureSessionComplete), isEmpty);
    });

    test('capture_session_complete re-fires on a fresh re-completion (edge)', () {
      final c = _container(_registryWith({'mid': 1, 'high': 1, 'low': 1}));
      final gate = c.read(completionGateProvider);
      final n = c.read(summaryGateAnalyticsProvider.notifier);

      n.syncUnlockMilestone(gate, sessionId: 'sess-1');
      expect(named(AnalyticsEvents.captureSessionComplete), hasLength(1));

      // Re-lock (a delete drops a level) then re-unlock → a genuinely new
      // completion, mirroring the unlock-milestone edge semantics.
      final locked = evaluateSummaryGate([
        LevelCompletionStatus(
            levelCode: 'A', acceptedCount: 0, minAcceptedFrames: 1),
      ]);
      n.syncUnlockMilestone(locked, sessionId: 'sess-1');
      n.syncUnlockMilestone(gate, sessionId: 'sess-1');
      expect(named(AnalyticsEvents.captureSessionComplete), hasLength(2));
    });

    test('blocked attempt reports the incomplete levels', () {
      final c = _container(_registryWith({'mid': 1, 'high': 0, 'low': 0}));
      final gate = c.read(completionGateProvider);
      c
          .read(summaryGateAnalyticsProvider.notifier)
          .logBlockedAttempt(gate, sessionId: 'sess-2');

      final blocked = named(AnalyticsEvents.guidedCaptureSummaryBlocked);
      expect(blocked, hasLength(1));
      expect(blocked.single.props['incomplete_levels'], 'B,C');
      expect(blocked.single.props['session_id'], 'sess-2');
      expect(blocked.single.props['phase'], 'guided_capture');
    });
  });
}
