// lib/domain/capture/pitch_band_resolution.dart
//
// Pure Dart — NO Flutter/Riverpod. Resolves the EFFECTIVE per-level pitch band
// with a clear precedence and safe fallback, and the shared validation every
// candidate band must pass. The reactive wiring (override store, config provider,
// diagnostics) lives in the application layer (pitch_band_resolver.dart); this is
// the deterministic, unit-testable core.
//
// Bands are keyed by [PitchBand.id] ("mid"/"high"/"low") — the repo's canonical
// per-level key via `pitchBandIdForLevel` (Level A=mid, B=high, C=low). There is
// no separate "A"/"B"/"C" payload: the existing config IS keyed by band id, so the
// override + resolver use the same key.
import '../entities/capture_config.dart';

/// Sane physical range (degrees) a band must lie within — the 0–180°
/// CAMERA-TILT scale (angle between the back camera's aim and world-up; see
/// `camera_tilt.dart`): bands tile [0, 180] (see `sanitizeCaptureConfig`) —
/// BOTTOM ring `low` [0,40), EYE ring `mid` [40,110), TOP ring `high`
/// [110,180). Override/remote/default all validate against it. The bands are
/// unequal by design (40/70/70); only the VALIDITY window is [0, 180].
const double kPitchBandMinDegrees = 0;
const double kPitchBandMaxDegrees = 180;

/// True iff [band] is usable: finite bounds, `min < max`, and within
/// [kPitchBandMinDegrees, kPitchBandMaxDegrees]. The SAME rule applied to every
/// source (override, remote, default) — an invalid band is never used.
bool isValidPitchBand(PitchBand band) {
  final min = band.minDegrees;
  final max = band.maxDegrees;
  if (min.isNaN || min.isInfinite || max.isNaN || max.isInfinite) return false;
  if (!(min < max)) return false;
  if (min < kPitchBandMinDegrees || max > kPitchBandMaxDegrees) return false;
  return true;
}

/// Which source the resolver took (or rejected) a band from.
enum PitchBandSource { override, remote, bundledDefault }

/// Diagnostic hook fired when a candidate band is REJECTED (invalid) or ABSENT
/// and the resolver falls through to the next source. [source] is the source that
/// failed; [minDegrees]/[maxDegrees] are the offending values (null when absent).
typedef PitchBandRejectLog = void Function({
  required String bandId,
  required PitchBandSource source,
  required double? minDegrees,
  required double? maxDegrees,
  required String reason,
});

/// Resolves the effective [PitchBand] for [bandId] following the precedence
/// (highest wins):
///   1. `overrides[bandId]`        — dev/QA or per-client runtime override
///   2. `config.pitchBands` by id  — remote → cache → bundled (already sanitized)
///   3. bundled default by id      — the guaranteed floor (always valid)
///
/// A candidate failing [isValidPitchBand] (or absent) is rejected, reported via
/// [onReject], and the resolver falls through. It ALWAYS returns a valid band —
/// the bundled default is the floor, so capture can never receive a null/invalid
/// band. Resolution is per-band, so a partial/invalid payload for one level does
/// not affect another.
PitchBand resolvePitchBand({
  required String bandId,
  required CaptureConfig config,
  Map<String, PitchBand> overrides = const {},
  PitchBandRejectLog? onReject,
}) {
  // 1) Runtime override (highest precedence). Not pre-sanitized → validate here.
  final override = overrides[bandId];
  if (override != null) {
    if (isValidPitchBand(override)) return override;
    onReject?.call(
      bandId: bandId,
      source: PitchBandSource.override,
      minDegrees: override.minDegrees,
      maxDegrees: override.maxDegrees,
      reason: 'invalid_override',
    );
  }

  // 2) Config (remote → cache → bundled; already sanitized, re-validated for parity).
  final remote = _bandById(config.pitchBands, bandId);
  if (remote != null) {
    if (isValidPitchBand(remote)) return remote;
    onReject?.call(
      bandId: bandId,
      source: PitchBandSource.remote,
      minDegrees: remote.minDegrees,
      maxDegrees: remote.maxDegrees,
      reason: 'invalid_remote',
    );
  } else {
    onReject?.call(
      bandId: bandId,
      source: PitchBandSource.remote,
      minDegrees: null,
      maxDegrees: null,
      reason: 'absent_remote',
    );
  }

  // 3) Bundled default for this band id — the guaranteed floor.
  final fallback = _bandById(CaptureConfig.bundledDefault.pitchBands, bandId);
  if (fallback != null && isValidPitchBand(fallback)) return fallback;

  // Ultimate floor: a band id not present in the bundled defaults at all. Never
  // return null/invalid — use the first bundled band (always valid, non-empty).
  return CaptureConfig.bundledDefault.pitchBands.first;
}

PitchBand? _bandById(List<PitchBand> bands, String id) {
  for (final b in bands) {
    if (b.id == id) return b;
  }
  return null;
}
