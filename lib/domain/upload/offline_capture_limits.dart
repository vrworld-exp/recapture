// lib/domain/upload/offline_capture_limits.dart
//
// Pure Dart. Every number the offline-capture limits use (Step C2), in one
// place — widgets never hard-code them. Product assumptions (README
// "Assumptions"): changing one is a one-line change here.

/// Most captures one user may have waiting on the phone. Enforced only when a
/// NEW capture would start OFFLINE — online, waiting captures drain anyway.
const int kMaxPendingCapturesPerUser = 5;

/// Free space required before an offline capture starts, as a multiple of the
/// mode's expected footprint (frames + the packed bundle copy + headroom).
const double kOfflineFreeSpaceMultiplier = 1.5;

/// Expected on-device footprint of one capture, worst case, by capture mode id.
/// Meshy: one ring of 6. Full: 48 photos at the highest quality setting.
const Map<String, int> kExpectedCaptureBytesByMode = {
  'meshy': 40 * 1024 * 1024,
  'full': 350 * 1024 * 1024,
};

/// Bytes that must be free before an offline capture in [modeId] may start.
int requiredFreeBytesFor(String modeId) {
  final expected = kExpectedCaptureBytesByMode[modeId] ??
      kExpectedCaptureBytesByMode['full']!;
  return (expected * kOfflineFreeSpaceMultiplier).ceil();
}

/// Why an offline capture may not start, or null when it may.
enum OfflineCaptureBlock { tooManyPending, lowStorage }

/// The C2 rule. [freeBytes] null = unknown (the check could not run) → not a
/// reason to block: a failed probe must never stop a user from capturing.
OfflineCaptureBlock? offlineCaptureBlock({
  required bool online,
  required int pendingCount,
  required String modeId,
  required int? freeBytes,
}) {
  if (online) return null;
  if (pendingCount >= kMaxPendingCapturesPerUser) {
    return OfflineCaptureBlock.tooManyPending;
  }
  if (freeBytes != null && freeBytes < requiredFreeBytesFor(modeId)) {
    return OfflineCaptureBlock.lowStorage;
  }
  return null;
}
