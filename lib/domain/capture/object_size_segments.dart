// lib/domain/capture/object_size_segments.dart
//
// Pure Dart — NO Flutter/native imports. The mapping from a project's object
// size to the Level A (Eye Ring) segment count. This is the FEEDER for the ring
// pipeline: `project.objectSize → eyeRingSegmentCount → segmentCount → ring
// coverage engine / SegmentCoverage`. It owns NO ring math or coverage — just
// the size→count decision.
//
// PRODUCT RULE: smaller objects get MORE segments (finer angular coverage at a
// closer orbit), larger fewer — Small 36, Medium 30, Large 24. These defaults
// mirror the backend's authoritative `SEGMENT_COUNT_BY_SIZE`
// (recapture-api capture.types.ts) and the doc on `LevelProgress.segmentCount`
// ("36 | 30 | 24, depends on objectSize").
//
// TUNABLE: the values are content/tuning-sensitive, so they are overridable
// per-size via remote config `segmentCounts` (GET /remote-config) — see
// [parseEyeRingSegmentCounts] for the wire shape. A partial/absent/invalid
// remote map falls back to these defaults per size; the result is always a valid
// count (>= 1).
//
// SCOPE: Level A (eye ring) only. Other pitch-band rings may grow their own
// per-size counts later — keep this map Level-A-named and add siblings then.

import '../entities/create_project_options.dart' show ObjectSize, ObjectSizeApi;

/// Default Level A eye-ring segment count per object size. Exhaustive over
/// [ObjectSize], so a lookup always resolves. Mirrors the backend default.
const Map<ObjectSize, int> kDefaultEyeRingSegments = {
  ObjectSize.small: 36,
  ObjectSize.medium: 30,
  ObjectSize.large: 24,
};

/// Used when the project's object size is null/unknown (a legacy project or an
/// unset field) — Medium is the middle of the range, a safe non-crashing pick.
const ObjectSize kDefaultObjectSize = ObjectSize.medium;

/// A ring is divided into at least 1 segment; the upper bound rejects absurd
/// remote values (finer than ~1° per segment is meaningless for guidance).
const int kMinSegmentCount = 1;
const int kMaxSegmentCount = 360;

/// A segment count is usable only within [kMinSegmentCount, kMaxSegmentCount].
bool isValidSegmentCount(int count) =>
    count >= kMinSegmentCount && count <= kMaxSegmentCount;

/// The Level A eye-ring [segmentCount] for [size].
///
/// - Defaults: Small 36, Medium 30, Large 24 (see [kDefaultEyeRingSegments]).
/// - [remoteOverrides] (from [parseEyeRingSegmentCounts] over remote-config
///   `segmentCounts`) override per size when present and valid; a missing or
///   invalid entry falls back to the default for that size (partial maps are
///   fine).
/// - Null/unknown [size] → [kDefaultObjectSize] (Medium).
/// - Always returns a valid count (`>= kMinSegmentCount`).
int eyeRingSegmentCount(
  ObjectSize? size, {
  Map<ObjectSize, int>? remoteOverrides,
}) {
  final resolved = size ?? kDefaultObjectSize;
  final override = remoteOverrides?[resolved];
  if (override != null && isValidSegmentCount(override)) return override;
  // Exhaustive map → always present; the ?? is belt-and-suspenders.
  return kDefaultEyeRingSegments[resolved] ?? kDefaultEyeRingSegments[kDefaultObjectSize]!;
}

/// Parses the remote-config `segmentCounts` block (flat, keyed by the API size
/// strings 'small'/'medium'/'large' — see backend `bySizeApiKey`) into a
/// validated per-size override map. Only entries that are numeric AND a valid
/// count survive; everything else is dropped so the caller falls back to the
/// default for that size. A non-map / null input yields an empty map (pure
/// defaults). Never throws.
Map<ObjectSize, int> parseEyeRingSegmentCounts(Object? raw) {
  final out = <ObjectSize, int>{};
  if (raw is! Map) return out;
  for (final size in ObjectSize.values) {
    final value = raw[size.apiValue];
    if (value is num) {
      final count = value.toInt();
      if (isValidSegmentCount(count)) out[size] = count;
    }
  }
  return out;
}
