// test/capture/capture_summary_provider_test.dart
//
// The aggregation behind the Capture Summary: one LevelCaptureSummary per
// configured level (CaptureLevel.values — not a hardcoded 3-tuple), sourced from
// the real per-level ledger + config. Verifies counts, warned tally, coverage %,
// the composed completion (evaluateLevelA: 80%-coverage AND min-count) with its
// shortfall, the aggregated warnings, the representative thumbnail, and the
// most-work ranking + all-complete helpers.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/capture_summary_provider.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/entities/capture_config.dart';

/// Bundled default (bands low=12 / mid=10 / high=8, minCoveragePct=80, min count=1).
class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
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

LevelCaptureLedgerRegistry _registry(Map<String, int> framesPerBand) {
  final reg = LevelCaptureLedgerRegistry();
  framesPerBand.forEach((band, n) {
    final ledger = reg.ledgerFor(band);
    for (var i = 0; i < n; i++) {
      ledger.recordAccepted(_accepted(i, '/$band/$i.jpg'));
    }
  });
  return reg;
}

ProviderContainer _container(LevelCaptureLedgerRegistry reg) {
  final c = ProviderContainer(overrides: [
    levelCaptureLedgerRegistryProvider.overrideWithValue(reg),
    captureConfigProvider.overrideWith(_StubConfigNotifier.new),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('per-level counts/coverage/completion/shortfall/warnings/thumb', () {
    final reg = _registry({'mid': 2, 'high': 1, 'low': 0});
    reg.ledgerFor('high').recordWarned(const WarnedPhotoRecord(
          framePath: '/high/0.jpg',
          isUnderexposed: true,
          isOverexposed: false,
          meanLuminance: 10,
          sensorTimestampNs: 1,
        ));

    final summaries = _container(reg).read(captureSummaryProvider);

    expect(summaries.map((s) => s.level).toList(),
        [CaptureLevel.a, CaptureLevel.b, CaptureLevel.c]);

    // Every ring is 16 segments under the default with_bottom variant, so the
    // 80% gate needs ceil(0.8*16)=13 filled segments per level.
    final a = summaries[0]; // mid: 2 frames of 16
    expect(a.name, 'Eye Ring');
    expect(a.frameCount, 2);
    expect(a.warnedCount, 0);
    expect(a.minRequired, 1);
    expect(a.coveragePct, 13); // 12.5 → 13
    expect(a.isComplete, isFalse);
    expect(a.completion.segmentsShort, 11); // need 13, filled 2
    expect(a.completion.photosShort, 0); // 2 >= 1
    expect(a.shortfall, 11);
    expect(a.thumbnailPath, '/mid/0.jpg');

    final b = summaries[1]; // high: 1 of 16
    expect(b.frameCount, 1);
    expect(b.warnedCount, 1);
    expect(b.coveragePct, 6); // 6.25 → 6
    expect(b.completion.segmentsShort, 12);
    expect(b.warnings.single.message, contains('too dark'));

    final c = summaries[2]; // low: 0 of 16, need 13; 0 photos
    expect(c.frameCount, 0);
    expect(c.coveragePct, 0);
    expect(c.completion.segmentsShort, 13);
    expect(c.completion.photosShort, 1);
    expect(c.shortfall, 14);
    expect(c.thumbnailPath, isNull);
  });

  test('mostWorkLevel = greatest shortfall among incomplete', () {
    final summaries =
        _container(_registry({'mid': 2, 'high': 1, 'low': 0}))
            .read(captureSummaryProvider);
    // C has the largest shortfall (14) → most work.
    expect(mostWorkLevel(summaries), CaptureLevel.c);
    expect(allLevelsComplete(summaries), isFalse);
  });

  test('all levels complete → mostWorkLevel null, allLevelsComplete true', () {
    // Every ring is 16 segments → each needs ≥13 filled (80%) + ≥1 photo.
    final summaries = _container(_registry({'mid': 13, 'high': 13, 'low': 13}))
        .read(captureSummaryProvider);
    expect(summaries.every((s) => s.isComplete), isTrue);
    expect(mostWorkLevel(summaries), isNull);
    expect(allLevelsComplete(summaries), isTrue);
  });

  test('empty registry → every level zero frames, incomplete', () {
    final summaries =
        _container(LevelCaptureLedgerRegistry()).read(captureSummaryProvider);
    expect(summaries, hasLength(CaptureLevel.values.length));
    expect(summaries.every((s) => s.frameCount == 0), isTrue);
    expect(summaries.every((s) => !s.isComplete), isTrue);
    expect(allLevelsComplete(summaries), isFalse);
  });

  test('overexposed warning maps to a bright message', () {
    final reg = LevelCaptureLedgerRegistry();
    reg.ledgerFor('mid').recordWarned(const WarnedPhotoRecord(
          framePath: '/mid/0.jpg',
          isUnderexposed: false,
          isOverexposed: true,
          meanLuminance: 250,
          sensorTimestampNs: 1,
        ));
    final summaries = _container(reg).read(captureSummaryProvider);
    expect(summaries[0].warnings.single.message, contains('too bright'));
  });
}
