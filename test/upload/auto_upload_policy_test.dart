// test/upload/auto_upload_policy_test.dart
//
// Every row of the offline-capture B3 table, plus the manual override:
//
//   | Capture | Wi-Fi | Mobile data                          |
//   | Meshy   | auto  | auto                                 |
//   | Full    | auto  | only if "Upload on mobile data" is ON |
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/upload/auto_upload_policy.dart';
import 'package:recapture/domain/upload/pending_capture.dart';

PendingCapture capture(String mode, {bool approved = false}) {
  final at = DateTime.utc(2026, 10, 1);
  return PendingCapture(
    localId: 'l',
    projectId: 'p',
    ownerUserId: 'u',
    projectName: 'n',
    objectSize: 'medium',
    captureMode: mode,
    flowVariant: 'with_bottom',
    frameCount: 6,
    byteCount: 1,
    state: PendingCaptureState.savedLocal,
    capturedAt: at,
    updatedAt: at,
    bundleRelPath: 'b',
    perLevelCounts: const {'EYE': 6},
    mobileDataApproved: approved,
  );
}

const off = AutoUploadSettings();
const on = AutoUploadSettings(uploadOnMobileData: true);

void main() {
  final meshy = capture('meshy');
  final full = capture('full');

  group('canAutoUpload — the B3 table', () {
    test('Meshy uploads on Wi-Fi', () {
      expect(canAutoUpload(meshy, UploadNetwork.unmetered, off), isTrue);
    });
    test('Meshy uploads on mobile data, setting OFF', () {
      expect(canAutoUpload(meshy, UploadNetwork.metered, off), isTrue);
    });
    test('Full uploads on Wi-Fi', () {
      expect(canAutoUpload(full, UploadNetwork.unmetered, off), isTrue);
    });
    test('Full waits on mobile data while the setting is OFF', () {
      expect(canAutoUpload(full, UploadNetwork.metered, off), isFalse);
      expect(isWaitingForWifi(full, UploadNetwork.metered, off), isTrue);
    });
    test('Full uploads on mobile data once the setting is ON', () {
      expect(canAutoUpload(full, UploadNetwork.metered, on), isTrue);
      expect(isWaitingForWifi(full, UploadNetwork.metered, on), isFalse);
    });
    test('nothing uploads with no network', () {
      for (final c in [meshy, full]) {
        expect(canAutoUpload(c, UploadNetwork.none, on), isFalse);
      }
    });
  });

  group('manual "Upload now" override', () {
    test('a Full capture on mobile data needs the size confirm first', () {
      expect(needsMobileDataConfirm(full, UploadNetwork.metered, off), isTrue);
    });
    test('no confirm on Wi-Fi, for Meshy, or with the setting ON', () {
      expect(needsMobileDataConfirm(full, UploadNetwork.unmetered, off), isFalse);
      expect(needsMobileDataConfirm(meshy, UploadNetwork.metered, off), isFalse);
      expect(needsMobileDataConfirm(full, UploadNetwork.metered, on), isFalse);
    });
    test('a confirmed capture keeps going on mobile data (no re-ask, no pause)',
        () {
      final approved = capture('full', approved: true);
      expect(needsMobileDataConfirm(approved, UploadNetwork.metered, off),
          isFalse);
      expect(canAutoUpload(approved, UploadNetwork.metered, off), isTrue);
    });
  });
}
