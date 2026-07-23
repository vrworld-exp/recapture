// lib/application/capture/capture_mode_provider.dart
//
// Reactive + persistence wiring for the capture MODE (full 48-photo guided vs
// meshy 8–10-photo manual — see CaptureMode).
//
// OWNERSHIP: the mode is chosen when the project is created (the `+` sheet on
// Projects), held here for the whole app session, and persisted per project as
// a sibling key in the capture-progression box (LevelProgressionStore.saveMode)
// — the same ONE durable location the flow variant uses, so no two stores can
// disagree.
//
// ── WHY PERSISTENCE IS NOT OPTIONAL HERE ────────────────────────────────────
// The variant is re-chosen every time the user passes the Pre-Capture
// Checklist, so an unpersisted variant self-heals. The MODE has no such screen:
// a user resuming a project from the list goes straight into capture. If the
// mode did not survive, a resumed Meshy project would run as a full 48-photo
// capture, and the counts the server validates against would be wrong. Mode
// lives on the project — never only on the navigation stack.
//
// LOCK RULE: identical to the variant's, and for the same reason — once the
// project has ≥1 accepted photo, switching modes would invalidate every
// expected count. The checklist reuses [projectHasAcceptedCaptures] and Start
// Over unlocks both together.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/capture_mode.dart';
import '../../utils/analytics.dart';
import 'progression/level_progression_provider.dart';

/// The active session's capture mode. Defaults to [CaptureMode.full] — the
/// behaviour that existed before Meshy mode, so any flow that never sets it
/// (including every project created before this shipped) is unchanged.
final captureModeProvider =
    NotifierProvider<CaptureModeController, CaptureMode>(
  CaptureModeController.new,
);

class CaptureModeController extends Notifier<CaptureMode> {
  @override
  CaptureMode build() => CaptureMode.full;

  /// The user's choice: updates the live state and (when the project context is
  /// known) persists it durably, then logs it.
  ///
  /// [projectId] is null at the moment of choosing — the project does not exist
  /// until the create form is submitted — so this degrades to in-memory only,
  /// exactly as `CaptureFlowVariantController.select` does. The caller MUST
  /// call [persistFor] once the id exists; see CreateProjectScreen.
  ///
  /// Persistence is best-effort: an unavailable store never blocks the flow.
  Future<void> select(CaptureMode mode, {String? projectId}) async {
    state = mode;
    Analytics.logEvent('capture_mode_selected', {
      'capture_mode': mode.id,
      'has_project': projectId != null,
    });
    if (projectId == null) return;
    await persistFor(projectId);
  }

  /// Writes the CURRENT mode against [projectId] — the second half of a
  /// [select] made before the project existed. Idempotent and best-effort.
  Future<void> persistFor(String projectId) async {
    try {
      await ref.read(levelProgressionStoreProvider).saveMode(projectId, state);
    } catch (_) {
      // Best-effort durability; the in-memory selection still drives the flow.
    }
  }

  /// Restores [projectId]'s persisted mode into the live state (absent /
  /// pre-mode projects resolve to [CaptureMode.full]) and returns it.
  ///
  /// Called at capture-flow entry so a RESUMED session runs the mode it was
  /// captured under rather than whatever the last-created project chose. This
  /// is the call that makes the mode a property of the project.
  Future<CaptureMode> loadFor(String projectId) async {
    CaptureMode mode;
    try {
      mode = await ref.read(levelProgressionStoreProvider).loadMode(projectId);
    } catch (_) {
      mode = CaptureMode.full;
    }
    state = mode;
    return mode;
  }

  /// Installs an already-known [mode] without IO and without logging — the
  /// rehydrate path (a resume that loaded it alongside the progression).
  /// Deliberately distinct from [select]: restoring is not a user action, and
  /// counting it as one would inflate the mode-choice funnel.
  void restore(CaptureMode mode) => state = mode;
}
