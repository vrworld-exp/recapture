// lib/application/capture/capture_shape_mode_provider.dart
//
// Reactive + persistence wiring for the capture SHAPE MODE (full / meshy — see
// CaptureShapeMode). Mirrors capture_flow_variant_provider.dart exactly: the mode
// is chosen at project creation (the provisional Meshy entry), held here for the
// app session, and persisted per project as a sibling key in the
// capture-progression box (LevelProgressionStore.saveShapeMode) — ONE durable
// location, so nothing can disagree.
//
// Its most important consumer is [effectiveCaptureConfigProvider]: the config the
// LIVE capture flow reads. Routing the config through the mode is what lets a
// Meshy session's single [90,180) ring of 6 and its 100% floor flow through the
// SAME band-driven machinery the full flow uses, with no parallel screen.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/capture_shape_mode.dart';
import '../../domain/entities/capture_config.dart';
import '../config/config_notifier.dart';
import 'progression/level_progression_provider.dart';

/// The active session's capture shape mode. Defaults to [CaptureShapeMode.full]
/// (every project that predates Meshy, and the common path) until a project's
/// persisted value / creation choice loads. A flow that never sets it behaves
/// exactly as before Meshy existed.
final captureShapeModeProvider =
    NotifierProvider<CaptureShapeModeController, CaptureShapeMode>(
  CaptureShapeModeController.new,
);

class CaptureShapeModeController extends Notifier<CaptureShapeMode> {
  @override
  CaptureShapeMode build() => CaptureShapeMode.full;

  /// The creation-time selection: updates the live state and (when the project
  /// context is known) persists it durably. Persistence is best-effort — an
  /// unavailable store never blocks the flow (in-memory state stays authoritative,
  /// matching the flow-variant controller's policy).
  Future<void> select(CaptureShapeMode mode, {String? projectId}) async {
    state = mode;
    if (projectId == null) return;
    try {
      await ref.read(levelProgressionStoreProvider).saveShapeMode(projectId, mode);
    } catch (_) {
      // Best-effort durability; the in-memory selection still drives the flow.
    }
  }

  /// Restores [projectId]'s persisted shape mode into the live state (absent /
  /// pre-Meshy projects resolve to [CaptureShapeMode.full]) and returns it.
  /// Called at capture-flow entry so a resumed session runs the SAME mode it was
  /// created under.
  Future<CaptureShapeMode> loadFor(String projectId) async {
    CaptureShapeMode mode;
    try {
      mode = await ref.read(levelProgressionStoreProvider).loadShapeMode(projectId);
    } catch (_) {
      mode = CaptureShapeMode.full;
    }
    state = mode;
    return mode;
  }

  /// Installs an already-known [mode] without IO (resume paths that load it
  /// alongside the progression).
  void restore(CaptureShapeMode mode) => state = mode;
}

/// The config the LIVE capture flow should use: the fixed Meshy single-ring
/// config when the active project is a Meshy capture, else the remote/full
/// [captureConfigProvider]. Every flow consumer that shapes capture behaviour
/// (tilt gate, segment count, coverage/completion/upload gates, the manifest)
/// reads THIS, so a Meshy session's [90,180) band, 6 segments, and 100% floor all
/// flow through unchanged code.
///
/// In full mode it is byte-identical to [captureConfigProvider] (a single
/// provider indirection), so the shipping full flow — and every test that
/// overrides [captureConfigProvider] — is unaffected.
final effectiveCaptureConfigProvider = Provider<CaptureConfig>((ref) {
  final mode = ref.watch(captureShapeModeProvider);
  if (mode.isMeshy) return CaptureConfig.meshy;
  return ref.watch(captureConfigProvider);
});
