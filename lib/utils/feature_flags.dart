// lib/utils/feature_flags.dart
//
// Compile-time feature gates, resolved from --dart-define at build time (the
// same mechanism as ENV in app_env.dart — this repo has no runtime flag
// service, and inventing one for two booleans would be a second config system).
//
// Every flag here defaults to FALSE. A build that says nothing behaves exactly
// as the build before the flag existed, which is what makes shipping a
// half-finished feature into main safe.

// Meshy CAPTURE mode itself is no longer flagged — the chooser on `+` is
// permanent, and the client always sends `captureMode`. That makes a server
// which understands the field a hard requirement, not a rollout step.

/// Requests automatic model generation when a MESHY capture finishes uploading.
///
/// Still flagged after the capture mode stopped being: generation costs credits
/// on every run, and this path has never executed against a real capture. With
/// it off, a Meshy capture uploads and then offers the same manual "Generate 3D
/// model" button a full capture does — one deliberate, human-triggered spend at
/// a time. Turning it on is a spending decision, not a rollout one.
const bool kMeshyAutoGenerateEnabled =
    bool.fromEnvironment('MESHY_AUTO_GENERATE', defaultValue: false);
