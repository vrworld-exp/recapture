// lib/domain/capture/capture_mode.dart
//
// Pure Dart — NO Flutter/Riverpod imports. The capture MODE: how much of the
// object the session captures, chosen by the user when the project is created
// (the `+` sheet on Projects) rather than on the Pre-Capture Checklist.
//
//   full  → the photogrammetry-grade guided capture: 48 photos, auto-capture
//           loop, the flow that existed before this type did.
//   meshy → a short capture tuned for Meshy AI: 8–10 photos, shutter only.
//           The model selector picks 4 of them, so the capture only has to
//           supply spread — not density.
//
// ── ORTHOGONAL TO CaptureFlowVariant, NOT A THIRD VARIANT ───────────────────
// [CaptureFlowVariant] answers "can you photograph the object's BOTTOM?", and
// that question is still meaningful in Meshy mode — so the two compose into a
// matrix rather than collapsing into one enum:
//
//   full  × with_bottom    → 16 / 16 / 16  (48)
//   full  × without_bottom → 24 / 24       (48)
//   meshy × with_bottom    → 6 / 2 / 2     (10)
//   meshy × without_bottom → 6 / 2         (8)
//
// Folding Meshy into the variant enum would also break that type's documented
// invariant that `without_bottom.bandIds` is a strict PREFIX of
// `with_bottom.bandIds` — the flow order would stop being one sequence.
//
// Per-ring segment counts live in [CaptureConfig.variantSegments]
// (remote-overridable, resolved through `effectiveSegmentsFor`); this type owns
// only identity and the behavioural rules that follow from the mode itself.
//
// ── WHERE THE MODE LIVES ────────────────────────────────────────────────────
// On the PROJECT, persisted alongside the flow variant — never only in a route
// argument. A user resuming a project from the list never passes through the
// creation sheet, and the resumed session must run the mode it was captured
// under or its expected counts are wrong.

/// How much the guided capture collects — see the library doc above.
enum CaptureMode {
  /// The full photogrammetry capture (48 photos, guided auto-capture).
  full,

  /// The short Meshy AI capture (8–10 photos, manual shutter).
  meshy;

  /// Canonical wire/persistence id — used in Hive, analytics, the API
  /// (`POST /jobs`), and the upload manifest. Never rename an existing id.
  String get id => switch (this) {
        CaptureMode.full => 'full',
        CaptureMode.meshy => 'meshy',
      };

  /// Whether the capture screen runs its AUTO-CAPTURE loop.
  ///
  /// False for Meshy: at 2 photos on a ring there is nothing for an auto loop
  /// to pace, and every frame it takes on its own is one the user did not
  /// compose. The shutter stays live in both modes — this gates only the loop.
  bool get usesAutoCapture => this == CaptureMode.full;

  /// Whether OBJECT SIZE modulates this mode's counts.
  ///
  /// False for Meshy: the size-based knobs (30/24/18 minimum photos, 36/30/24
  /// segments) are all far above Meshy's per-ring counts, so applying them
  /// would make every Meshy capture permanently incomplete. Meshy captures
  /// 6/2/2 for a thimble and for a motorcycle alike.
  bool get usesObjectSize => this == CaptureMode.full;

  /// Whether a 3D model is generated automatically once the upload finishes.
  ///
  /// True for Meshy — the whole point of the mode is "capture and get a model",
  /// so making the user press a second button afterwards would be a step with
  /// no decision in it. In full mode generation stays an explicit request.
  bool get generatesModelAutomatically => this == CaptureMode.meshy;

  /// Human-facing name for the creation sheet and analytics-free UI copy.
  String get label => switch (this) {
        CaptureMode.full => 'Full Capture',
        CaptureMode.meshy => 'Meshy Capture',
      };

  /// Tolerant parse of a wire/persisted id. Unknown or null → [full] (the
  /// pre-mode behavior — every legacy session was a full capture). Never
  /// throws, matching the repo's defensive-parse convention.
  static CaptureMode fromId(String? id) => tryFromId(id) ?? CaptureMode.full;

  /// Strict parse: the exact wire ids only; anything else (including null) →
  /// null. Lets persistence callers distinguish "never chosen" from a real
  /// choice instead of collapsing both onto the legacy default.
  static CaptureMode? tryFromId(String? id) => switch (id) {
        'full' => CaptureMode.full,
        'meshy' => CaptureMode.meshy,
        _ => null,
      };
}
