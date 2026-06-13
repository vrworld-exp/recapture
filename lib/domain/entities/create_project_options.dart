// lib/domain/entities/create_project_options.dart

/// Physical size of the object being captured. Guides camera distance and
/// downstream processing parameters.
enum ObjectSize { small, medium, large }

/// How the capture session is driven.
///
/// [guided] walks the user through quality-checked rings (Level A/B/C);
/// [manual] gives advanced users full control of each shot.
enum CaptureMode { guided, manual }

extension ObjectSizeApi on ObjectSize {
  /// Stable string for the API payload and analytics. Must match the backend.
  String get apiValue => switch (this) {
        ObjectSize.small => 'small',
        ObjectSize.medium => 'medium',
        ObjectSize.large => 'large',
      };
}

extension CaptureModeApi on CaptureMode {
  /// Stable string for the API payload and analytics. Must match the backend.
  String get apiValue => switch (this) {
        CaptureMode.guided => 'guided',
        CaptureMode.manual => 'manual',
      };
}

/// A selectable object-size option with display copy.
class SizeOption {
  const SizeOption(this.value, this.label, this.helper);

  final ObjectSize value;
  final String label;
  final String helper;
}

/// A selectable capture-mode option with display copy and a recommended hint.
class ModeOption {
  const ModeOption(
    this.value,
    this.label,
    this.helper, {
    this.recommended = false,
  });

  final CaptureMode value;
  final String label;
  final String helper;
  final bool recommended;
}

/// Object-size choices. Helper copy is placeholder — final content TBD.
const List<SizeOption> kSizeOptions = [
  SizeOption(ObjectSize.small, 'Small', 'Fits on a tabletop (under ~30 cm)'),
  SizeOption(ObjectSize.medium, 'Medium', 'Furniture-sized (~0.3–1.5 m)'),
  SizeOption(ObjectSize.large, 'Large', 'Room-scale or bigger (over ~1.5 m)'),
];

/// Capture-mode choices. Helper copy is placeholder — final content TBD.
const List<ModeOption> kModeOptions = [
  ModeOption(
    CaptureMode.guided,
    'Guided',
    'Step-by-step capture with live quality checks',
    recommended: true,
  ),
  ModeOption(
    CaptureMode.manual,
    'Manual',
    'You control every shot (advanced)',
  ),
];
