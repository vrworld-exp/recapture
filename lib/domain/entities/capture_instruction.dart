// lib/domain/entities/capture_instruction.dart
//
// Pure Dart — NO Flutter imports. The single instruction the Level A HUD shows
// in its instruction banner. The banner is a pure DISPLAY of whatever the parent
// supplies; selecting/prioritizing the instruction from tilt/stability/placement/
// ring state is a SEPARATE concern (a priority resolver task), not this model.
//
// [id] is the stable identity used by the banner to decide whether to animate: a
// re-emit with the same [id] (e.g. a sustained "Hold steady") is a no-op, while a
// changed [id] triggers the crossfade. Keep [id] tied to the *kind* of
// instruction, not the rendered string, so identical guidance keeps one id.

/// Subtle colour treatment for an instruction. [warning] gets an on-brand Mirage
/// Red accent (border/tint, not a full red fill); [info] is the neutral pill.
enum InstructionSeverity { info, warning }

/// One HUD instruction: a stable [id], the [message] to render, and a [severity].
class CaptureInstruction {
  const CaptureInstruction({
    required this.id,
    required this.message,
    this.severity = InstructionSeverity.info,
  });

  /// Stable identity for the *kind* of instruction. Only a change in [id]
  /// crossfades the banner; same-[id] re-emits do not re-animate.
  final String id;

  /// The text to display (capped to two lines by the banner).
  final String message;

  final InstructionSeverity severity;

  @override
  bool operator ==(Object other) =>
      other is CaptureInstruction &&
      other.id == id &&
      other.message == message &&
      other.severity == severity;

  @override
  int get hashCode => Object.hash(id, message, severity);
}
