// test/capture/variant_gates_test.dart
//
// The 2-ring (without_bottom) flow variant against BOTH live gates and the
// funnel-end latch:
//   - completionGateProvider demands only the variant's levels → a session
//     with A+B (no Level C data at all) unlocks the Summary.
//   - uploadGateProvider never blocks on a missing Level C.
//   - the capture_session_complete latch fires exactly once when the 2-level
//     gate unlocks, with levels_total = 2 and NO level_c_frame_count key.
// The 3-ring gate semantics stay covered by completion_gate_provider_test.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/capture_flow_variant_provider.dart';
import 'package:recapture/application/capture/completion_gate_provider.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/upload_gate_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/utils/analytics.dart';

class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

class _StubVariantController extends CaptureFlowVariantController {
  _StubVariantController(this._variant);
  final CaptureFlowVariant _variant;
  @override
  CaptureFlowVariant build() => _variant;
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
  LevelCaptureLedgerRegistry reg,
  CaptureFlowVariant variant,
) {
  final c = ProviderContainer(overrides: [
    levelCaptureLedgerRegistryProvider.overrideWithValue(reg),
    captureConfigProvider.overrideWith(_StubConfigNotifier.new),
    captureFlowVariantProvider
        .overrideWith(() => _StubVariantController(variant)),
  ]);
  addTearDown(c.dispose);
  return c;
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

  group('completion gate under without_bottom', () {
    test('unlocks with A+B only — Level C is never demanded', () {
      final c = _container(
        _registryWith({'mid': 1, 'high': 1}), // zero Level C data
        CaptureFlowVariant.withoutBottom,
      );
      final gate = c.read(completionGateProvider);
      expect(gate.isUnlocked, isTrue);
      expect(gate.levelsTotal, 2);
      expect(gate.levels.map((l) => l.levelCode).toList(), ['A', 'B']);
    });

    test('still locks when an ACTIVE level is short', () {
      final c = _container(
        _registryWith({'mid': 1, 'high': 0}),
        CaptureFlowVariant.withoutBottom,
      );
      final gate = c.read(completionGateProvider);
      expect(gate.isUnlocked, isFalse);
      expect(gate.incompleteLevelCodes, ['B']);
    });

    test('with_bottom keeps demanding Level C (control case)', () {
      final c = _container(
        _registryWith({'mid': 1, 'high': 1}),
        CaptureFlowVariant.withBottom,
      );
      expect(c.read(completionGateProvider).isUnlocked, isFalse);
      expect(c.read(completionGateProvider).incompleteLevelCodes, ['C']);
    });
  });

  group('upload hard gate under without_bottom', () {
    test('eligible with A+B at their coverage floors — no Level C floor applies',
        () {
      // without_bottom rings carry 24 segments → floor ceil(0.8 × 24) = 20.
      final c = _container(
        _registryWith({'mid': 20, 'high': 20}), // zero Level C data
        CaptureFlowVariant.withoutBottom,
      );
      final gate = c.read(uploadGateProvider);
      expect(gate.eligible, isTrue);
    });

    test('a ring below the without_bottom coverage floor (19/24) blocks', () {
      final c = _container(
        _registryWith({'mid': 20, 'high': 19}),
        CaptureFlowVariant.withoutBottom,
      );
      final gate = c.read(uploadGateProvider);
      expect(gate.eligible, isFalse);
      expect(gate.shortLevelsLabel, 'B');
      expect(gate.totalDeficit, 1);
    });

    test('with_bottom stays blocked on the missing Level C (control case)', () {
      final c = _container(
        _registryWith({'mid': 20, 'high': 20}),
        CaptureFlowVariant.withBottom,
      );
      expect(c.read(uploadGateProvider).eligible, isFalse);
    });
  });

  group('capture_session_complete latch (2-level funnel end)', () {
    test('fires exactly once when the 2-level gate unlocks, after B', () {
      final c = _container(
        _registryWith({'mid': 3, 'high': 2}),
        CaptureFlowVariant.withoutBottom,
      );
      final gate = c.read(completionGateProvider);
      final n = c.read(summaryGateAnalyticsProvider.notifier);

      n.syncUnlockMilestone(gate, sessionId: 'sess-2ring');
      n.syncUnlockMilestone(gate, sessionId: 'sess-2ring'); // idempotent

      final done = named(AnalyticsEvents.captureSessionComplete);
      expect(done, hasLength(1));
      final p = done.single.props;
      expect(p['levels_total'], 2);
      expect(p['levels_completed'], 2);
      expect(p['level_a_frame_count'], 3);
      expect(p['level_b_frame_count'], 2);
      expect(p.containsKey('level_c_frame_count'), isFalse,
          reason: 'a 2-ring session has no Level C to report');
      expect(p['total_frame_count'], 5);
    });
  });
}
