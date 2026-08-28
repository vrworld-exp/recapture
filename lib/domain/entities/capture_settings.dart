// lib/domain/entities/capture_settings.dart
//
// Pure Dart — NO Flutter imports. The small set of user-tunable Level A capture
// settings surfaced by the Settings sheet (and kept consistent with the
// auto-capture pill). This is a transport/view model — the parent owns the
// authoritative state, persists each value, and applies it live. `autoCapture`
// shares the pill's persisted key (`level_a_auto_capture`); save-to-gallery and
// quality have their own keys.

enum QualityMode { standard, high }

QualityMode qualityModeFromString(String? s) =>
    s == 'high' ? QualityMode.high : QualityMode.standard;

String qualityModeToString(QualityMode m) =>
    m == QualityMode.high ? 'high' : 'standard';

class CaptureSettings {
  const CaptureSettings({
    this.autoCapture = true,
    this.saveToGallery = false,
    this.quality = QualityMode.standard,
  });

  final bool autoCapture;
  final bool saveToGallery;
  final QualityMode quality;

  CaptureSettings copyWith({
    bool? autoCapture,
    bool? saveToGallery,
    QualityMode? quality,
  }) =>
      CaptureSettings(
        autoCapture: autoCapture ?? this.autoCapture,
        saveToGallery: saveToGallery ?? this.saveToGallery,
        quality: quality ?? this.quality,
      );

  @override
  bool operator ==(Object other) =>
      other is CaptureSettings &&
      other.autoCapture == autoCapture &&
      other.saveToGallery == saveToGallery &&
      other.quality == quality;

  @override
  int get hashCode => Object.hash(autoCapture, saveToGallery, quality);
}
