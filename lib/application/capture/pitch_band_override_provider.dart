// lib/application/capture/pitch_band_override_provider.dart
//
// Runtime per-band pitch-band OVERRIDES — the highest-precedence source in
// [resolvePitchBand] (above remote config + bundled defaults). Keyed by
// PitchBand.id ("mid"/"high"/"low"), the canonical per-level key.
//
// The repo had no prior config-override pattern, so this is the minimal,
// clearly-scoped store the resolver checks first: in-memory + runtime only (NOT
// persisted) — a dev/QA or per-client hook set before/at level entry. Empty by
// default, so with no override set, resolution is exactly remote → cache → default
// (no behavior change). An override is stored as-is and VALIDATED at resolve time,
// so an invalid override is rejected and falls through.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/capture_config.dart';

/// The active per-band overrides (band id → band). Empty by default.
final pitchBandOverrideProvider =
    NotifierProvider<PitchBandOverrideNotifier, Map<String, PitchBand>>(
  PitchBandOverrideNotifier.new,
);

class PitchBandOverrideNotifier extends Notifier<Map<String, PitchBand>> {
  @override
  Map<String, PitchBand> build() => const {};

  /// Sets (or replaces) the override for [band].id. Validation is deferred to the
  /// resolver, so setting an invalid band is harmless — it is rejected at resolve.
  void setOverride(PitchBand band) => state = {...state, band.id: band};

  /// Removes the override for [bandId] (no-op if absent).
  void clearOverride(String bandId) {
    if (!state.containsKey(bandId)) return;
    state = {...state}..remove(bandId);
  }

  /// Clears every override.
  void clearAll() {
    if (state.isNotEmpty) state = const {};
  }
}
