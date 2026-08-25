// lib/presentation/screens/capture/capture_instructions.dart
//
// Pure Dart — NO Flutter/Riverpod imports. The per-level HUD instruction cycles,
// extracted from capture_screen.dart so the copy can be referenced (and tested)
// without dragging in the full capture-screen widget graph. capture_screen.dart
// re-exports these, so existing call sites (the router) and tests that import them
// from capture_screen.dart keep resolving unchanged.

/// Default per-level instruction cycle (Level A / Eye Ring). Used whenever a
/// level supplies no tuned copy, so Level A — and any un-tuned level — keeps
/// exactly this set. Cycled in the HUD instruction pill.
const List<String> kDefaultCaptureInstructions = [
  'Move clockwise',
  'Keep object centered',
  'Maintain distance',
  'Move slowly',
];

/// Level B (Top Ring) instruction cycle — the lead cue is tuned to match the
/// Level B intro rule "Tilt down more to show top". Same length and tone as
/// [kDefaultCaptureInstructions]; only the level-specific lead line differs.
const List<String> kLevelBCaptureInstructions = [
  'Tilt down to show the top',
  'Keep object centered',
  'Maintain distance',
  'Move slowly',
];

/// Level C (Low Ring) instruction cycle — the lead cue is tuned to match the
/// Level C intro rule "Lower phone, tilt slightly up" (see [kLevelCIntroContent]:
/// "Angle up so the base and underside stay in frame"). The second cue is the
/// Low-Ring-specific framing reminder: the base of the object is easily clipped
/// or occluded by the supporting surface, and reconstruction needs the whole
/// base, so the user is reminded to keep it fully in frame. Same length and tone
/// as [kDefaultCaptureInstructions]; only the level-specific lines differ.
const List<String> kLevelCCaptureInstructions = [
  'Tilt up to show the base',
  "Keep the whole base in frame — don't cut off the bottom",
  'Maintain distance',
  'Move slowly',
];
