// lib/domain/entities/save_exit_decision.dart
//
// Pure Dart — NO Flutter imports. The user's choice when leaving a Level A
// capture session with unsaved progress, plus the context the confirmation modal
// renders. The modal returns a [SaveExitChoice]; the parent performs the actual
// save-as-draft / discard / navigation. Generic so Levels B/C reuse it.

enum SaveExitChoice { saveExit, discardExit, cancel }

class SaveExitContext {
  const SaveExitContext({
    required this.capturedCount,
    required this.hasUnsavedProgress,
  });

  /// Photos captured in this session (shown so the user knows what's at stake).
  final int capturedCount;

  /// Whether there is anything to lose. When false the parent exits directly and
  /// never shows the modal.
  final bool hasUnsavedProgress;

  @override
  bool operator ==(Object other) =>
      other is SaveExitContext &&
      other.capturedCount == capturedCount &&
      other.hasUnsavedProgress == hasUnsavedProgress;

  @override
  int get hashCode => Object.hash(capturedCount, hasUnsavedProgress);
}
