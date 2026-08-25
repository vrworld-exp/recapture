// lib/data/local/level_intro_box.dart
import 'dart:convert';

import 'package:hive/hive.dart';

import 'box_names.dart';
import 'hive_init.dart';

/// Persisted "intro seen" facts for a capture-level intro screen, keyed by an
/// intro id (e.g. `level_a`). Holds only flow state — no capture data.
class LevelIntroPrefs {
  const LevelIntroPrefs({this.seen = false, this.dontShowAgain = false});

  /// True once the user has reached capture through this intro at least once.
  final bool seen;

  /// True when the user explicitly opted out of seeing this intro again.
  final bool dontShowAgain;

  /// Safe default for a first run / unreadable record.
  static const LevelIntroPrefs initial = LevelIntroPrefs();

  Map<String, dynamic> toJson() =>
      {'seen': seen, 'dontShowAgain': dontShowAgain};

  factory LevelIntroPrefs.fromJson(Map<String, dynamic> j) => LevelIntroPrefs(
        seen: j['seen'] == true,
        dontShowAgain: j['dontShowAgain'] == true,
      );

  LevelIntroPrefs copyWith({bool? seen, bool? dontShowAgain}) => LevelIntroPrefs(
        seen: seen ?? this.seen,
        dontShowAgain: dontShowAgain ?? this.dontShowAgain,
      );
}

/// The store contract the intro screen depends on. Lets the UI read/persist the
/// "seen"/"don't show again" flags without binding to Hive (tests inject a fake).
abstract interface class LevelIntroStore {
  /// Prefs for [introId]; [LevelIntroPrefs.initial] when absent/corrupt.
  Future<LevelIntroPrefs> get(String introId);

  /// Records that the user proceeded to capture through this intro, optionally
  /// opting out of future views. `dontShowAgain` is sticky once set true.
  Future<void> markSeen(String introId, {required bool dontShowAgain});
}

/// Hive-backed [LevelIntroStore]. Stores one JSON record per intro id in the
/// `level_intro` `Box<String>` (same JSON-string convention as the other boxes —
/// no TypeAdapters).
///
/// Resilience mirrors [PermissionFlowBox]: every operation is wrapped so it never
/// throws past this class. A missing/corrupt record — or an environment where
/// Hive is unavailable (e.g. a widget-test host) — degrades [get] to
/// [LevelIntroPrefs.initial] (safe "not seen") and makes writes a no-op. It never
/// defaults to "seen".
class LevelIntroBox implements LevelIntroStore {
  LevelIntroBox();

  Box<String>? _box;

  /// Opens the box, returning null on ANY failure. Deliberately does NOT cache an
  /// in-flight future: caching a rejected open would resurface its error later.
  Future<Box<String>?> _tryOpen() async {
    final existing = _box;
    if (existing != null && existing.isOpen) return existing;
    try {
      return _box = await openStringBoxSafely(BoxNames.levelIntro);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<LevelIntroPrefs> get(String introId) async {
    try {
      final box = await _tryOpen();
      if (box == null) return LevelIntroPrefs.initial;
      final raw = box.get(introId);
      if (raw == null || raw.isEmpty) return LevelIntroPrefs.initial;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return LevelIntroPrefs.initial;
      return LevelIntroPrefs.fromJson(decoded);
    } catch (_) {
      return LevelIntroPrefs.initial;
    }
  }

  @override
  Future<void> markSeen(String introId, {required bool dontShowAgain}) async {
    try {
      final box = await _tryOpen();
      if (box == null) return;
      final current = await get(introId);
      final next = current.copyWith(
        seen: true,
        // Sticky: once opted out, never silently flip back on a later view.
        dontShowAgain: current.dontShowAgain || dontShowAgain,
      );
      await box.put(introId, jsonEncode(next.toJson()));
    } catch (_) {
      // Persistence unavailable — fail silent (intro just shows again).
    }
  }

  /// Clears all stored intro flags (e.g. on logout / account switch).
  Future<void> clear() async {
    try {
      final box = await _tryOpen();
      if (box == null) return;
      await box.clear();
    } catch (_) {
      // No-op on failure.
    }
  }
}
