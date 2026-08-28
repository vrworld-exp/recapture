// lib/domain/capture/capture_cancel.dart
//
// Pure Dart — NO Flutter/IO imports. The vocabulary for the "Cancel → Keep as
// Draft" leave-flow shared by the Capture Summary and Uploading screens.
//
// The central guarantee is NO ACCIDENTAL DATA LOSS: cancelling defaults the user
// toward keeping their captures ([keepDraft] is the primary, reassuring outcome),
// only the explicit destructive [discard] deletes anything, and any dismissal
// resolves to [keepEditing] (unchanged, nothing touched).

/// The user's resolution of the cancel confirmation.
///
///   • [keepDraft]   — PRIMARY, safe. Persist the session as a resumable draft,
///     then leave. Never deletes captured data.
///   • [discard]     — DESTRUCTIVE. Delete the in-progress session/captures, then
///     leave. The ONLY choice that deletes data.
///   • [keepEditing] — DISMISS. Close the confirmation and stay, unchanged. ANY
///     dismissal (tap-outside / system back on the dialog) resolves here.
enum CaptureCancelChoice { keepDraft, discard, keepEditing }

/// Which step of the funnel the user cancelled from — carried on the cancel
/// analytics as the `phase` property so the events join the rest of the funnel.
enum CaptureCancelPhase {
  /// The Capture Summary review step (no upload running).
  captureSummary,

  /// The Uploading step (an upload may be in progress and is aborted first).
  upload;

  /// The analytics `phase` string. Matches the values the brief specifies
  /// (`"capture_summary"` / `"upload"`).
  String get wireName => switch (this) {
        CaptureCancelPhase.captureSummary => 'capture_summary',
        CaptureCancelPhase.upload => 'upload',
      };
}
