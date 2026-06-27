// lib/application/capture/pitch_band_resolver.dart
//
// Reactive wiring around the pure [resolvePitchBand] core: exposes the effective
// per-level [PitchBand] (override → remote/cache → bundled default), validated,
// with a diagnostics log on any rejection/fallback. Synchronous and non-blocking
// — it reads the always-valid in-memory config + overrides, never the network.
//
// HOLD-STABLE-PER-PASS: capture reads this ONCE at level/phase entry and holds the
// result for the duration of the pass (see CaptureScreen._resolvedBand). A
// mid-pass remote-config or override change therefore does NOT alter the band of a
// capture pass already in progress — it applies on the next level entry.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/pitch_band_resolution.dart';
import '../../domain/entities/capture_config.dart';
import '../../utils/analytics.dart';
import '../config/config_notifier.dart';
import 'pitch_band_override_provider.dart';

/// The effective [PitchBand] for [bandId] (a `PitchBand.id` — the canonical
/// per-level key from `pitchBandIdForLevel`). Resolves override → remote/cache →
/// bundled default via [resolvePitchBand], logging rejections. Read ONCE at level
/// entry by capture and held for the pass (read, not watch).
final resolvedPitchBandProvider =
    Provider.family<PitchBand, String>((ref, bandId) {
  final config = ref.watch(captureConfigProvider);
  final overrides = ref.watch(pitchBandOverrideProvider);
  return resolvePitchBand(
    bandId: bandId,
    config: config,
    overrides: overrides,
    onReject: logPitchBandReject,
  );
});

/// Diagnostics for a rejected/absent candidate band — carries the level (band id),
/// the source that failed, and the offending values, per the config-fallback
/// requirement. Routed through the guarded [Analytics] seam (never throws).
void logPitchBandReject({
  required String bandId,
  required PitchBandSource source,
  required double? minDegrees,
  required double? maxDegrees,
  required String reason,
}) {
  Analytics.logEvent('pitch_band_fallback', {
    'band_id': bandId,
    'source': source.name,
    'reason': reason,
    'min_degrees': minDegrees,
    'max_degrees': maxDegrees,
    'device_type':
        defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
  });
}
