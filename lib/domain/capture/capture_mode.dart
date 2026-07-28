// lib/domain/capture/capture_mode.dart
//
// Pure Dart — NO Flutter/Riverpod imports. The capture MODE: how much of the
// object the session captures, chosen by the user when the project is created
// (the `+` sheet on Projects) rather than on the Pre-Capture Checklist.
//
//   full  → the photogrammetry-grade guided capture: 48 photos, auto-capture
//           loop, the flow that existed before this type did.
//   meshy → a short capture tuned for Meshy AI: ONE ring of 6, shutter only,
//           with a hard eye→top tilt gate. The model selector picks the best 4
//           of them, so the capture only has to supply spread — not density.
//
// ── ORTHOGONAL TO CaptureFlowVariant IN FULL MODE ───────────────────────────
// [CaptureFlowVariant] answers "can you photograph the object's BOTTOM?". In
// FULL mode that question is meaningful, so the two compose into a matrix:
//
//   full  × with_bottom    → 16 / 16 / 16  (48)
//   full  × without_bottom → 24 / 24       (48)
//
// In MESHY mode the variant is INERT — both cells are the identical single eye
// ring of 6 (there is no top or bottom ring to add), so:
//
//   meshy × with_bottom    → 6  (one eye ring)
//   meshy × without_bottom → 6  (the same one eye ring)
//
// The active level list in Meshy is therefore always just Level A regardless of
// variant — see `activeCaptureLevels` (capture_level_events.dart), the single
// source every flow-shaping iteration goes through.
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

  /// The short Meshy AI capture (one ring of 6, manual shutter, hard tilt gate).
  meshy;

  /// Canonical wire/persistence id — used in Hive, analytics, the API
  /// (`POST /jobs`), and the upload manifest. Never rename an existing id.
  String get id => switch (this) {
        CaptureMode.full => 'full',
        CaptureMode.meshy => 'meshy',
      };

  /// Whether the capture screen runs its AUTO-CAPTURE loop.
  ///
  /// False for Meshy: on a single ring of 6 there is nothing for an auto loop
  /// to pace, and every frame it takes on its own is one the user did not
  /// compose. The shutter stays live in both modes — this gates only the loop.
  bool get usesAutoCapture => this == CaptureMode.full;

  /// Whether OBJECT SIZE modulates this mode's counts.
  ///
  /// False for Meshy: the size-based knobs (30/24/18 minimum photos, 36/30/24
  /// segments) are all far above Meshy's ring count, so applying them would make
  /// every Meshy capture permanently incomplete. Meshy captures one ring of 6
  /// for a thimble and for a motorcycle alike.
  bool get usesObjectSize => this == CaptureMode.full;

  /// Whether the shutter's tilt gate is HARD in this mode — enforced even when
  /// the motion sensors are unavailable (no fail-open).
  ///
  /// True for Meshy: a shot outside the eye→top window is worthless to the
  /// model, so the band must bite regardless of sensor state (a sensor-less
  /// device then cannot capture, which is correct — it cannot meet the
  /// guarantee). False for full, whose shutter fails OPEN so a sensor-less
  /// device is never locked out. See [CaptureReadiness].
  bool get usesHardTiltGate => this == CaptureMode.meshy;

  /// Whether each ring wedge accepts exactly ONE shot.
  ///
  /// True for Meshy: the ring is six wedges and the selector wants SPREAD, so a
  /// second shot into a wedge that already holds one adds nothing — it just
  /// lets a user fill the quota without turning, producing six near-identical
  /// frames and a model built from one side of the object. Once a wedge is
  /// filled the shutter refuses it and the user must turn to an empty one.
  /// False for full, whose 16-per-ring density expects repeat shots.
  bool get oneShotPerSegment => this == CaptureMode.meshy;

  /// Whether the Capture Summary offers the INCOMPLETE-capture remedies — the
  /// "Fix Issues" button and the below-minimum confirm dialog.
  ///
  /// False for Meshy: with one shot per wedge and an auto-advance the moment
  /// the coverage floor is met, a Meshy user who reached the Summary captured
  /// correctly by construction, so both surfaces offer a remedy for a problem
  /// that isn't there. This hides only those two; the HARD upload gate, its
  /// remedy rows, and the offline block are safety and stay in both modes.
  bool get offersIncompleteRemedies => this != CaptureMode.meshy;

  /// Whether a 3D model is generated automatically once the upload finishes.
  ///
  /// True for Meshy — the whole point of the mode is "capture and get a model",
  /// so making the user press a second button afterwards would be a step with
  /// no decision in it. In full mode generation stays an explicit request.
  bool get generatesModelAutomatically => this == CaptureMode.meshy;

  /// Human-facing name for the creation sheet and analytics-free UI copy.
  String get label => switch (this) {
        CaptureMode.full => 'Full Capture',
        CaptureMode.meshy => 'Maya AI Capture',
      };

  /// Word printed on the capture shutter, naming what the button does in THIS
  /// mode: full runs the auto-capture loop ("Auto"), Meshy is shutter-only, so
  /// every frame is a deliberate press ("Click"). Kept next to
  /// [usesAutoCapture] — the behaviour the copy describes — so the two can
  /// never drift apart.
  String get shutterLabel => switch (this) {
        CaptureMode.full => 'Auto',
        CaptureMode.meshy => 'Click',
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
