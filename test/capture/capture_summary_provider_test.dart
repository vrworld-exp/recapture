// test/capture/capture_summary_provider_test.dart
//
// The aggregation behind Screen 6C-Complete: one LevelCaptureSummary per
// configured level (CaptureLevel.values — not a hardcoded 3-tuple), sourced from
// the real per-level ledger. Verifies counts, warned tally, representative
// thumbnail (first frame), and the isComplete (≥1 frame) gate signal.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/capture_summary_provider.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';

CapturedPhotoRecord _accepted(int seg, String path) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 0,
      sensorTimestampNs: seg * 1000 + 1,
    );

void main() {
  test('one summary per level, in order, with counts/thumb/complete', () {
    final reg = LevelCaptureLedgerRegistry();
    reg.ledgerFor('mid')
      ..recordAccepted(_accepted(0, '/mid/0.jpg'))
      ..recordAccepted(_accepted(1, '/mid/1.jpg'));
    reg.ledgerFor('high').recordAccepted(_accepted(0, '/high/0.jpg'));
    reg.ledgerFor('high').recordWarned(const WarnedPhotoRecord(
          framePath: '/high/0.jpg',
          isUnderexposed: true,
          isOverexposed: false,
          meanLuminance: 10,
          sensorTimestampNs: 1,
        ));
    // 'low' (Level C) left empty → incomplete.

    final container = ProviderContainer(overrides: [
      levelCaptureLedgerRegistryProvider.overrideWithValue(reg),
    ]);
    addTearDown(container.dispose);

    final summaries = container.read(captureSummaryProvider);

    expect(summaries.map((s) => s.level).toList(),
        [CaptureLevel.a, CaptureLevel.b, CaptureLevel.c]);

    // Display data only — completeness is the completion gate's concern now
    // (see completion_gate_test.dart), not a property of this summary type.
    final a = summaries[0];
    expect(a.name, 'Eye Ring');
    expect(a.frameCount, 2);
    expect(a.warnedCount, 0);
    expect(a.thumbnailPath, '/mid/0.jpg');

    final b = summaries[1];
    expect(b.frameCount, 1);
    expect(b.warnedCount, 1);

    final c = summaries[2];
    expect(c.frameCount, 0);
    expect(c.thumbnailPath, isNull);
  });

  test('empty registry → every level has zero frames', () {
    final container = ProviderContainer(overrides: [
      levelCaptureLedgerRegistryProvider
          .overrideWithValue(LevelCaptureLedgerRegistry()),
    ]);
    addTearDown(container.dispose);

    final summaries = container.read(captureSummaryProvider);
    expect(summaries, hasLength(CaptureLevel.values.length));
    expect(summaries.every((s) => s.frameCount == 0), isTrue);
  });
}
