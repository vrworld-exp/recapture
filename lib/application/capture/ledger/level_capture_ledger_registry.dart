// lib/application/capture/ledger/level_capture_ledger_registry.dart
//
// Keyed container mapping each guided-capture level to its own independent
// LevelCaptureLedger, so captures for one level never bleed into another's counts.
//
// GROUNDING: the repo has no `PitchLevel` enum — the real, server-tunable level
// identifier is the [PitchBand.id] string ("low"/"mid"/"high"; Level A Eye Ring =
// "mid"), the same id the capture analytics events key on (CaptureEventProperties
// .pitchBandId). The registry is therefore keyed by that String level id.
//
// RUN OWNERSHIP: the ledgers are plain in-memory objects living in an app-scoped
// provider, while the review grid / summary read them as "the captures of the run
// the user just finished". Nothing else bounds their lifetime, so the registry
// owns that bound itself: [bindProject] wipes every ledger when the capture run
// moves to a DIFFERENT project (otherwise a second capture would review the first
// object's frames alongside its own), and [endRun] wipes them when a run reaches
// its terminal handoff (upload completed, or the session discarded). Re-binding
// the SAME project never wipes — a resume must not lose the pass it is resuming.
import 'level_capture_ledger.dart';

class LevelCaptureLedgerRegistry {
  final Map<String, LevelCaptureLedger> _ledgers = {};

  String? _projectId;

  /// The project whose capture run these ledgers hold, or null when no run is
  /// bound (a fresh app, or one whose last run ended via [endRun]).
  String? get projectId => _projectId;

  /// The ledger for [levelId] (a PitchBand.id), created lazily on first access.
  /// Uses putIfAbsent so exactly one instance per level is ever created.
  LevelCaptureLedger ledgerFor(String levelId) =>
      _ledgers.putIfAbsent(levelId, LevelCaptureLedger.new);

  /// Binds the ledgers to [projectId]'s capture run, wiping every level when
  /// they belong to a different project. Returns true when it displaced another
  /// project's run (the first bind of an unbound registry has nothing to
  /// displace and returns false, though it still starts from clean ledgers). An
  /// empty [projectId] — no resolvable project context — leaves the binding
  /// untouched rather than clearing a live pass on a failed lookup.
  bool bindProject(String projectId) {
    if (projectId.isEmpty || projectId == _projectId) return false;
    final displacedRun = _projectId != null;
    _projectId = projectId;
    resetAll();
    return displacedRun;
  }

  /// Ends the bound run: every ledger is reset and the binding dropped, so the
  /// next capture starts from nothing. Called where a run is handed off for good
  /// (a completed upload) or deliberately thrown away (Discard).
  void endRun() {
    resetAll();
    _projectId = null;
  }

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
