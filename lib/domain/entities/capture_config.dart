// lib/domain/entities/capture_config.dart
//
// Pure Dart — NO Flutter/Riverpod imports. Tuning parameters the capture
// pipeline depends on, sourced (in precedence) from sanitized remote →
// sanitized cache → these bundled defaults. Always a valid, non-empty config.

/// One pitch band (a vertical slice of the capture sphere) and how many capture
/// positions to take around it.
class PitchBand {
  const PitchBand({
    required this.id,
    required this.minDegrees,
    required this.maxDegrees,
    required this.segments,
  });

  final String id; // e.g. "low", "mid", "high"
  final double minDegrees; // inclusive
  final double maxDegrees; // exclusive
  final int segments; // capture positions around this band

  factory PitchBand.fromMap(Map<String, dynamic> m) => PitchBand(
        id: m['id'] is String ? m['id'] as String : 'band',
        minDegrees: m['minDegrees'] is num ? (m['minDegrees'] as num).toDouble() : 0,
        maxDegrees: m['maxDegrees'] is num ? (m['maxDegrees'] as num).toDouble() : 90,
        segments: m['segments'] is num ? (m['segments'] as num).toInt() : 12,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'minDegrees': minDegrees,
        'maxDegrees': maxDegrees,
        'segments': segments,
      };

  PitchBand copyWith({
    String? id,
    double? minDegrees,
    double? maxDegrees,
    int? segments,
  }) =>
      PitchBand(
        id: id ?? this.id,
        minDegrees: minDegrees ?? this.minDegrees,
        maxDegrees: maxDegrees ?? this.maxDegrees,
        segments: segments ?? this.segments,
      );
}

/// Quality gates the capture pipeline enforces per frame / per session.
class CaptureThresholds {
  const CaptureThresholds({
    required this.minSharpness,
    required this.minCoveragePct,
    required this.maxTiltDeltaDeg,
  });

  final double minSharpness; // 0..1 — reject blurry frames below this
  final double minCoveragePct; // % of segments required to allow finishing
  final double maxTiltDeltaDeg; // max device tilt deviation tolerated

  factory CaptureThresholds.fromMap(Map<String, dynamic> m) => CaptureThresholds(
        minSharpness:
            m['minSharpness'] is num ? (m['minSharpness'] as num).toDouble() : 0.45,
        minCoveragePct:
            m['minCoveragePct'] is num ? (m['minCoveragePct'] as num).toDouble() : 80,
        maxTiltDeltaDeg: m['maxTiltDeltaDeg'] is num
            ? (m['maxTiltDeltaDeg'] as num).toDouble()
            : 12,
      );

  Map<String, dynamic> toMap() => {
        'minSharpness': minSharpness,
        'minCoveragePct': minCoveragePct,
        'maxTiltDeltaDeg': maxTiltDeltaDeg,
      };

  CaptureThresholds copyWith({
    double? minSharpness,
    double? minCoveragePct,
    double? maxTiltDeltaDeg,
  }) =>
      CaptureThresholds(
        minSharpness: minSharpness ?? this.minSharpness,
        minCoveragePct: minCoveragePct ?? this.minCoveragePct,
        maxTiltDeltaDeg: maxTiltDeltaDeg ?? this.maxTiltDeltaDeg,
      );
}

/// App-wide capture configuration. Server-tunable without an app release.
class CaptureConfig {
  const CaptureConfig({
    required this.version,
    required this.pitchBands,
    required this.thresholds,
  });

  final int version;
  final List<PitchBand> pitchBands;
  final CaptureThresholds thresholds;

  /// Compile-time defaults — the app is fully functional on these alone (first
  /// launch, offline, malformed remote). Never empty.
  static const CaptureConfig bundledDefault = CaptureConfig(
    version: 0,
    pitchBands: [
      PitchBand(id: 'low', minDegrees: 0, maxDegrees: 30, segments: 12),
      PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 10),
      PitchBand(id: 'high', minDegrees: 60, maxDegrees: 90, segments: 8),
    ],
    thresholds: CaptureThresholds(
      minSharpness: 0.45,
      minCoveragePct: 80,
      maxTiltDeltaDeg: 12,
    ),
  );

  /// Total capture positions across all bands.
  int get totalSegments => pitchBands.fold(0, (sum, b) => sum + b.segments);

  /// Segment count (N) of the Level A Eye Ring — the 'mid' (eye-level) band the
  /// ring map and tilt meter target. Falls back to the first band, then a sane
  /// default if config is somehow empty. Single source so the ring map and the
  /// segment-fill state model can never disagree on N.
  int get eyeRingSegments {
    for (final b in pitchBands) {
      if (b.id == 'mid') return b.segments;
    }
    return pitchBands.isNotEmpty ? pitchBands.first.segments : 12;
  }

  /// Defensive parse — missing/ill-typed fields fall back to bundled values;
  /// empty/absent bands fall back to bundled bands. Never throws on a Map input.
  /// (Run [sanitizeCaptureConfig] afterwards to clamp out-of-range values.)
  factory CaptureConfig.fromMap(Map<String, dynamic> m) {
    final rawBands = m['pitchBands'];
    final bands = rawBands is List
        ? rawBands
            .whereType<Map>()
            .map((e) => PitchBand.fromMap(e.cast<String, dynamic>()))
            .toList()
        : null;
    return CaptureConfig(
      version: m['version'] is num ? (m['version'] as num).toInt() : 0,
      pitchBands: (bands == null || bands.isEmpty)
          ? bundledDefault.pitchBands
          : bands,
      thresholds: m['thresholds'] is Map
          ? CaptureThresholds.fromMap(
              (m['thresholds'] as Map).cast<String, dynamic>())
          : bundledDefault.thresholds,
    );
  }

  Map<String, dynamic> toMap() => {
        'version': version,
        'pitchBands': pitchBands.map((b) => b.toMap()).toList(),
        'thresholds': thresholds.toMap(),
      };

  CaptureConfig copyWith({
    int? version,
    List<PitchBand>? pitchBands,
    CaptureThresholds? thresholds,
  }) =>
      CaptureConfig(
        version: version ?? this.version,
        pitchBands: pitchBands ?? this.pitchBands,
        thresholds: thresholds ?? this.thresholds,
      );
}
