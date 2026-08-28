// lib/domain/capture/guidance_output.dart
//
// Pure Dart — NO Flutter imports. The single resolved output of the instruction
// engine for one tick: exactly ONE [CaptureInstruction] (the banner message) and
// ONE [DirectionHint] (the arrow). The HUD never shows conflicting cues because
// the resolver returns exactly one of these.
import '../entities/capture_instruction.dart';
import '../entities/direction_hint.dart';

class GuidanceOutput {
  const GuidanceOutput({required this.instruction, required this.direction});

  /// The single active banner instruction (stable [CaptureInstruction.id] per
  /// logical state, so the banner re-animates only on a real change).
  final CaptureInstruction instruction;

  /// The arrow decision — visible only in the direction branch, hidden otherwise.
  final DirectionHint direction;

  @override
  bool operator ==(Object other) =>
      other is GuidanceOutput &&
      other.instruction == instruction &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(instruction, direction);
}
