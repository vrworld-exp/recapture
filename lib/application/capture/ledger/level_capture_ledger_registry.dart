// lib/application/capture/ledger/level_capture_ledger_registry.dart
//
// Keyed container mapping each guided-capture level to its own independent
// LevelCaptureLedger, so captures for one level never bleed into another's counts.
//
// GROUNDING: the repo has no `PitchLevel` enum — the real, server-tunable level
// identifier is the [PitchBand.id] string ("low"/"mid"/"high"; Level A Eye Ring =
// "mid"), the same id the capture analytics events key on (CaptureEventProperties
// .pitchBandId). The registry is therefore keyed by that String level id.
import 'level_capture_ledger.dart';

class LevelCaptureLedgerRegistry {
  final Map<String, LevelCaptureLedger> _ledgers = {};

  /// The ledger for [levelId] (a PitchBand.id), created lazily on first access.
  /// Uses putIfAbsent so exactly one instance per level is ever created.
  LevelCaptureLedger ledgerFor(String levelId) =>
      _ledgers.putIfAbsent(levelId, LevelCaptureLedger.new);

  /// Resets only [levelId]'s ledger; other levels are unaffected. No-op (no
  /// throw) if that level has never been accessed.
  void resetLevel(String levelId) => _ledgers[levelId]?.reset();

  /// Resets every created ledger (new full session across all levels).
  void resetAll() {
    for (final ledger in _ledgers.values) {
      ledger.reset();
    }
  }

  /// Removes [levelId]'s ledger entirely (vs. resetting its contents) — a later
  /// [ledgerFor] recreates a fresh instance.
  void clearLevel(String levelId) => _ledgers.remove(levelId);

  /// True if a ledger has ever been created for [levelId].
  bool hasLedgerFor(String levelId) => _ledgers.containsKey(levelId);
}
