// test/capture/review_grid_items_provider_test.dart
//
// The ledger → ReviewItem bridge that turns the per-level capture ledger's real
// accepted frames into the display items the review grid renders. Verifies the
// mapping: framePath drives captureId/filePath, segmentIndex → ringIndex, a frame
// also present in a warned record becomes verdict=warn (others accepted), capture
// order is preserved, and an untouched level yields an empty list.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';
import 'package:recapture/application/capture/review_grid_items_provider.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';

CapturedPhotoRecord _accepted(int seg, String path, int ts) =>
    CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 0,
      sensorTimestampNs: ts,
    );

void main() {
  late ProviderContainer container;
  late LevelCaptureLedgerRegistry registry;

  setUp(() {
    registry = LevelCaptureLedgerRegistry();
    container = ProviderContainer(overrides: [
      levelCaptureLedgerRegistryProvider.overrideWithValue(registry),
    ]);
    addTearDown(container.dispose);
  });

  test('maps accepted records to ReviewItems, warned→warn verdict', () {
    final ledger = registry.ledgerFor('mid');
    ledger.recordAccepted(_accepted(0, '/f/0.jpg', 1000));
    ledger.recordAccepted(_accepted(3, '/f/1.jpg', 2000));
    ledger.recordWarned(const WarnedPhotoRecord(
      framePath: '/f/1.jpg',
      isUnderexposed: false,
      isOverexposed: true,
      meanLuminance: 240,
      sensorTimestampNs: 2000,
    ));

    final items = container.read(reviewGridItemsProvider('mid'));

    expect(items, hasLength(2));
    // Order preserved (capture order).
    expect(items[0].captureId, '/f/0.jpg');
    expect(items[0].filePath, '/f/0.jpg');
    expect(items[0].ringIndex, 0);
    expect(items[0].verdict, CaptureVerdict.accepted);
    // The frame that also has a warned record is flagged.
    expect(items[1].captureId, '/f/1.jpg');
    expect(items[1].ringIndex, 3);
    expect(items[1].verdict, CaptureVerdict.warn);
  });

  test('untouched level → empty list', () {
    expect(container.read(reviewGridItemsProvider('high')), isEmpty);
  });

  test('levels are isolated', () {
    registry.ledgerFor('low').recordAccepted(_accepted(1, '/low/0.jpg', 5));
    expect(container.read(reviewGridItemsProvider('low')), hasLength(1));
    expect(container.read(reviewGridItemsProvider('mid')), isEmpty);
  });
}
