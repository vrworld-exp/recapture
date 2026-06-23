// lib/domain/entities/capture_top_bar_state.dart
//
// Pure Dart — NO Flutter imports. What the capture-screen top bar renders: the
// current level indicator (label + optional subtitle) and whether the Help /
// Settings entry points are actionable. This is a DISPLAY model — the bar emits
// intent via callbacks; deciding what Help/Settings open and whether to pause
// auto-capture is the parent's job, not this model's.
//
// Generic across levels: Level A passes "Level A" / "Eye Ring", but B/C reuse
// the same bar with a different label/subtitle.

class CaptureTopBarState {
  const CaptureTopBarState({
    required this.levelLabel,
    this.levelSubtitle,
    this.helpEnabled = true,
    this.settingsEnabled = true,
  });

  /// Prominent level label, e.g. "Level A".
  final String levelLabel;

  /// Secondary descriptor, e.g. "Eye Ring". Null hides the subtitle line.
  final String? levelSubtitle;

  /// When false the Help control is greyed and fires nothing.
  final bool helpEnabled;

  /// When false the Settings control is greyed and fires nothing.
  final bool settingsEnabled;

  CaptureTopBarState copyWith({
    String? levelLabel,
    String? levelSubtitle,
    bool? helpEnabled,
    bool? settingsEnabled,
  }) =>
      CaptureTopBarState(
        levelLabel: levelLabel ?? this.levelLabel,
        levelSubtitle: levelSubtitle ?? this.levelSubtitle,
        helpEnabled: helpEnabled ?? this.helpEnabled,
        settingsEnabled: settingsEnabled ?? this.settingsEnabled,
      );

  @override
  bool operator ==(Object other) =>
      other is CaptureTopBarState &&
      other.levelLabel == levelLabel &&
      other.levelSubtitle == levelSubtitle &&
      other.helpEnabled == helpEnabled &&
      other.settingsEnabled == settingsEnabled;

  @override
  int get hashCode =>
      Object.hash(levelLabel, levelSubtitle, helpEnabled, settingsEnabled);
}
