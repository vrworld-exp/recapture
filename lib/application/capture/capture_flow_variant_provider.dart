// lib/application/capture/capture_flow_variant_provider.dart
//
// Reactive + persistence wiring for the capture FLOW VARIANT (with_bottom
// 3-ring 12-12-12 vs without_bottom 2-ring 18-18 — see CaptureFlowVariant).
//
// OWNERSHIP: the variant is chosen on the Pre-Capture Checklist (Screen 4),
// held here for the whole app session, and persisted per project as a sibling
// key in the capture-progression box (LevelProgressionStore.saveVariant) — ONE
// durable location, so no two stores can disagree. Every flow-shaping consumer
// (gates, builders, HUD segment counts, the summary) watches this provider;
// none of them defaults to a hardcoded 3-level set.
//
// LOCK RULE: once the project has ≥1 accepted photo the variant is locked
// (changing rings mid-capture would invalidate coverage); the checklist checks
// [projectHasAcceptedCaptures] and disables the control. Start Over clears the
// captures, which unlocks it again.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/capture_flow_variant.dart';
import '../../domain/entities/capture_config.dart';
import '../config/config_notifier.dart';
import 'analytics/capture_level_events.dart';
import 'ledger/level_capture_ledger_registry.dart';
import 'progression/level_progression_provider.dart';
import 'session/capture_session_store.dart';

/// The active session's flow variant. Defaults to [CaptureFlowVariant.withBottom]
/// (the legacy 3-ring flow) until the checklist selection / a persisted project
/// value loads — so a flow that never touches the checklist behaves exactly as
/// before the variant existed.
final captureFlowVariantProvider =
    NotifierProvider<CaptureFlowVariantController, CaptureFlowVariant>(
  CaptureFlowVariantController.new,
);

class CaptureFlowVariantController extends Notifier<CaptureFlowVariant> {
  @override
  CaptureFlowVariant build() => CaptureFlowVariant.withBottom;

  /// The user's checklist selection: updates the live state and (when the
  /// project context is known) persists it durably. Persistence is best-effort
  /// — an unavailable store never blocks the flow (in-memory state remains
  /// authoritative, matching the progression controller's policy).
  Future<void> select(CaptureFlowVariant variant, {String? projectId}) async {
    state = variant;
    if (projectId == null) return;
    try {
      await ref.read(levelProgressionStoreProvider).saveVariant(
            projectId,
            variant,
          );
    } catch (_) {
      // Best-effort durability; the in-memory selection still drives the flow.
    }
  }

  /// Restores [projectId]'s persisted variant into the live state (absent /
  /// pre-variant projects resolve to [CaptureFlowVariant.withBottom]) and
  /// returns it. Called at capture-flow entry so a resumed session runs the
  /// SAME variant it was captured under, not whatever the checklist last showed.
  Future<CaptureFlowVariant> loadFor(String projectId) async {
    CaptureFlowVariant variant;
    try {
      variant =
          await ref.read(levelProgressionStoreProvider).loadVariant(projectId);
    } catch (_) {
      variant = CaptureFlowVariant.withBottom;
    }
    state = variant;
    return variant;
  }

  /// Installs an already-known [variant] without IO (e.g. the progression
  /// controller's resume path, which loads it alongside the progression).
  void restore(CaptureFlowVariant variant) => state = variant;
}

/// The `PitchBand.id` of the level CURRENTLY being captured ('mid'/'high'/
/// 'low'). The shared capture screen stamps it at ring entry so the level-
/// agnostic HUD providers (segment coverage, live yaw→segment) size themselves
/// for THIS ring — previously they were pinned to the Eye Ring's count for
/// every level (the eyeRingSegments-for-all-levels bug).
final activeCaptureBandIdProvider =
    NotifierProvider<ActiveCaptureBandIdNotifier, String>(
  ActiveCaptureBandIdNotifier.new,
);

class ActiveCaptureBandIdNotifier extends Notifier<String> {
  @override
  String build() => 'mid'; // Level A — the flow's first ring

  /// Stamps the active ring's band id (idempotent).
  void set(String bandId) {
    if (state != bandId) state = bandId;
  }
}

/// The ACTIVE ring's effective segment count (N): config × variant × active
/// band, through the single [effectiveSegmentsFor] resolver. The one N source
/// for the live HUD (fill state + yaw→segment), so they can never disagree
/// with the progression/machine layers.
final activeLevelSegmentCountProvider = Provider<int>((ref) {
  final config = ref.watch(captureConfigProvider);
  final variant = ref.watch(captureFlowVariantProvider);
  final bandId = ref.watch(activeCaptureBandIdProvider);
  return effectiveSegmentsFor(config, variant, bandId);
});

/// Whether [projectId] already has ≥1 ACCEPTED photo on ANY ring (all three
/// bands are checked regardless of variant — a leftover Level C draft still
/// locks). Checks the live in-memory ledgers first, then the persisted
/// session drafts (so the lock survives an app restart). Best-effort: an
/// unreadable store counts as "no captures" rather than blocking the checklist.
Future<bool> projectHasAcceptedCaptures({
  required String projectId,
  required LevelCaptureLedgerRegistry registry,
  CaptureSessionStore? sessionStore,
}) async {
  for (final level in CaptureLevel.values) {
    if (registry.ledgerFor(pitchBandIdForLevel(level)).accepted.isNotEmpty) {
      return true;
    }
  }
  final store = sessionStore ?? CaptureSessionStore();
  for (final level in CaptureLevel.values) {
    try {
      final snap = await store.load(projectId, pitchBandIdForLevel(level));
      if (snap != null && snap.accepted.isNotEmpty) return true;
    } catch (_) {
      // Unreadable draft → treat as absent.
    }
  }
  return false;
}
