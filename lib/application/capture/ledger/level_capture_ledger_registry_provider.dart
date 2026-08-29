// lib/application/capture/ledger/level_capture_ledger_registry_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'level_capture_ledger_registry.dart';

/// Root-scoped registry of per-level capture ledgers (keyed by PitchBand.id —
/// the repo has no `PitchLevel` enum; see [LevelCaptureLedgerRegistry]). A single
/// instance persists for the app session — ledgers within it are reset via
/// [LevelCaptureLedgerRegistry.bindProject] / [LevelCaptureLedgerRegistry.endRun]
/// (the capture-run boundaries) or the per-level
/// [LevelCaptureLedgerRegistry.resetLevel] / [LevelCaptureLedgerRegistry.resetAll],
/// not by recreating this provider.
///
/// First Riverpod seam onto the ledger layer; intentionally exposes ONLY the
/// registry (no CaptureController / capture-flow wiring).
final levelCaptureLedgerRegistryProvider =
    Provider<LevelCaptureLedgerRegistry>((ref) => LevelCaptureLedgerRegistry());
