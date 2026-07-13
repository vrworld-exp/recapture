// lib/domain/capture/capture_flow_variant.dart
//
// Pure Dart — NO Flutter/Riverpod imports. The capture FLOW VARIANT: whether
// the object's bottom can be captured, chosen by the user on the Pre-Capture
// Checklist (Screen 4) before the guided flow begins.
//
//   with_bottom    → 3 rings: Eye (mid) → Top (high) → Bottom (low), 16
//                    segments per ring (16-16-16, 48 total)
//   without_bottom → 2 rings: Eye (mid) → Top (high), 24 segments per ring
//                    (24-24, 48 total). The Bottom Ring (Level C) never appears.
//
// INVARIANT: the 2-ring variant is always a PREFIX of the 3-ring one (A→B),
// so the flow order never changes between variants — only where it ends.
// Per-variant segment counts live in [CaptureConfig.variantSegments]
// (remote-overridable); this type owns only identity + the active band list.
//
// This is the single source of the ACTIVE level list for the whole app: every
// flow-shaping iteration goes through [bandIds] (or the application layer's
// `levels` extension over CaptureLevel) instead of a hardcoded 3-level set.

/// Which guided-capture flow the session runs — see the library doc above.
enum CaptureFlowVariant {
  /// The bottom of the object is capturable → 3 rings (Eye/Top/Bottom).
  withBottom,

  /// The bottom is NOT capturable → 2 rings (Eye/Top); Level C never appears.
  withoutBottom;

  /// Canonical wire/persistence id — used in Hive, analytics, remote config,
  /// and the upload manifest. Never rename an existing id.
  String get id => switch (this) {
        CaptureFlowVariant.withBottom => 'with_bottom',
        CaptureFlowVariant.withoutBottom => 'without_bottom',
      };

  /// The `PitchBand.id`s of this variant's ACTIVE rings, in flow order
  /// (A→B[→C]). The 2-ring list is a prefix of the 3-ring one (see invariant).
  List<String> get bandIds => switch (this) {
        CaptureFlowVariant.withBottom => const ['mid', 'high', 'low'],
        CaptureFlowVariant.withoutBottom => const ['mid', 'high'],
      };

  /// Whether [bandId] is an active ring in this variant.
  bool includesBand(String bandId) => bandIds.contains(bandId);

  /// Tolerant parse of a wire/persisted id. Unknown or null → [withBottom]
  /// (the pre-variant behavior — every legacy session was 3-ring). Never throws,
  /// matching the repo's defensive-parse convention.
  static CaptureFlowVariant fromId(String? id) => switch (id) {
        'without_bottom' => CaptureFlowVariant.withoutBottom,
        _ => CaptureFlowVariant.withBottom,
      };
}
