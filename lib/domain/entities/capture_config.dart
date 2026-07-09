// lib/domain/entities/capture_config.dart
//
// Pure Dart — NO Flutter/Riverpod imports. Tuning parameters the capture
// pipeline depends on, sourced (in precedence) from sanitized remote →
// sanitized cache → these bundled defaults. Always a valid, non-empty config.

import '../capture/capture_flow_variant.dart';

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

/// Default minimum accepted frames a level needs to count as complete when no
/// per-level override is configured. Validated `>= 1`.
const int kDefaultMinAcceptedFrames = 1;

/// Per-level completion thresholds: how many ACCEPTED frames each level needs
/// before the final completion gate ([SummaryGate]) treats it as done. Pure,
/// immutable, config-driven (defaultable + remote-overridable). Keyed by the
/// display level code ("A"/"B"/"C"); lookups are case-insensitive and any level
/// without a valid override falls back to [kDefaultMinAcceptedFrames].
class CompletionThresholds {
  /// [perLevelMinAcceptedFrames] is keyed by UPPERCASE level code. Use
  /// [CompletionThresholds.fromMap] for untrusted (remote) input — it validates.
  const CompletionThresholds({
    Map<String, int> perLevelMinAcceptedFrames = const {},
  }) : _perLevel = perLevelMinAcceptedFrames;

  final Map<String, int> _perLevel;

  /// No overrides — every level uses [kDefaultMinAcceptedFrames]. The const
  /// default carried by [CaptureConfig].
  static const CompletionThresholds bundledDefault = CompletionThresholds();

  /// The minimum accepted frames [levelCode] needs (case-insensitive). Falls back
  /// to [kDefaultMinAcceptedFrames] for an absent or (defensively) invalid entry.
  int minAcceptedFramesFor(String levelCode) {
    final v = _perLevel[levelCode.toUpperCase()];
    return (v != null && v >= 1) ? v : kDefaultMinAcceptedFrames;
  }

  /// Parses the remote-config block (keyed by level code → `{minAcceptedFrames}`):
  /// `{ "A": { "minAcceptedFrames": 5 }, "B": { "minAcceptedFrames": 3 } }`.
  /// Only positive-integer entries survive; non-positive / ill-typed / non-map
  /// entries are dropped so that level falls back to the default. A non-map input
  /// yields all-defaults. Never throws.
  factory CompletionThresholds.fromMap(Object? raw) {
    if (raw is! Map) return bundledDefault;
    final parsed = <String, int>{};
    raw.forEach((key, value) {
      if (key is! String || value is! Map) return;
      final n = value['minAcceptedFrames'];
      if (n is num && n.toInt() >= 1) parsed[key.toUpperCase()] = n.toInt();
    });
    return CompletionThresholds(perLevelMinAcceptedFrames: parsed);
  }

  /// Round-trips back to the wire shape [fromMap] consumes (only stored overrides).
  Map<String, dynamic> toMap() => {
        for (final e in _perLevel.entries)
          e.key: {'minAcceptedFrames': e.value},
      };

  @override
  bool operator ==(Object other) =>
      other is CompletionThresholds &&
      _perLevel.length == other._perLevel.length &&
      _perLevel.entries.every((e) => other._perLevel[e.key] == e.value);

  @override
  int get hashCode => Object.hashAllUnordered(
        _perLevel.entries.map((e) => Object.hash(e.key, e.value)),
      );
}

/// Default absolute-minimum accepted shots a level needs to be UPLOADABLE at all
/// (the hard upload floor — distinct from, and never above, the soft completion
/// minimum). Validated `>= 1`: a level always needs at least one accepted shot.
const int kDefaultMinAcceptedShots = 1;

/// Per-level ABSOLUTE-MINIMUM accepted shots required before the captured set may
/// be uploaded at all — the hard upload gate's floor. Pure, immutable,
/// config-driven (defaultable + remote-overridable), keyed by display level code
/// ("A"/"B"/"C"); lookups are case-insensitive and any level without a valid
/// override falls back to [kDefaultMinAcceptedShots].
///
/// This is a SEPARATE threshold from [CompletionThresholds] (the soft completion
/// gate): completion is "good enough to count as done"; this is "enough raw shots
/// that the pipeline can use it at all". They are evaluated independently.
class UploadMinShots {
  /// [perLevelMinShots] is keyed by UPPERCASE level code. Use
  /// [UploadMinShots.fromMap] for untrusted (remote) input — it validates.
  const UploadMinShots({Map<String, int> perLevelMinShots = const {}})
      : _perLevel = perLevelMinShots;

  final Map<String, int> _perLevel;

  /// No overrides — every level uses [kDefaultMinAcceptedShots].
  static const UploadMinShots bundledDefault = UploadMinShots();

  /// The absolute-minimum accepted shots [levelCode] needs (case-insensitive).
  /// Falls back to [kDefaultMinAcceptedShots] for an absent or invalid entry.
  int minShotsFor(String levelCode) {
    final v = _perLevel[levelCode.toUpperCase()];
    return (v != null && v >= 1) ? v : kDefaultMinAcceptedShots;
  }

  /// Parses the remote-config block (keyed by level code → int):
  /// `{ "A": 3, "B": 2, "C": 4 }`. Only positive-integer entries survive;
  /// non-positive / ill-typed entries are dropped so that level falls back to the
  /// default. A non-map input yields all-defaults. Never throws.
  factory UploadMinShots.fromMap(Object? raw) {
    if (raw is! Map) return bundledDefault;
    final parsed = <String, int>{};
    raw.forEach((key, value) {
      if (key is! String) return;
      if (value is num && value.toInt() >= 1) parsed[key.toUpperCase()] = value.toInt();
    });
    return UploadMinShots(perLevelMinShots: parsed);
  }

  /// Round-trips back to the wire shape [fromMap] consumes (only stored overrides).
  Map<String, dynamic> toMap() => {
        for (final e in _perLevel.entries) e.key: e.value,
      };

  @override
  bool operator ==(Object other) =>
      other is UploadMinShots &&
      _perLevel.length == other._perLevel.length &&
      _perLevel.entries.every((e) => other._perLevel[e.key] == e.value);

  @override
  int get hashCode => Object.hashAllUnordered(
        _perLevel.entries.map((e) => Object.hash(e.key, e.value)),
      );
}

/// Per-VARIANT ring segment counts, keyed variant id → (band id → positive
/// count) — wire key `guided_capture_variant_segments`:
///
/// ```json
/// {
///   "with_bottom":    { "mid": 12, "high": 12, "low": 12 },
///   "without_bottom": { "mid": 18, "high": 18 }
/// }
/// ```
///
/// Pure, immutable, config-driven (defaultable + remote-overridable), following
/// the [CompletionThresholds]/[UploadMinShots] pattern. Lookups fall back
/// PER-ENTRY to [bundledDefault]'s numbers, so a partial remote map can never
/// strand a variant on the legacy per-band counts. The effective count a flow
/// consumer uses comes from [effectiveSegmentsFor] — the ONE resolver both the
/// progression builder and the segment machines share.
class VariantSegments {
  /// [perVariant] is keyed by variant id ('with_bottom'/'without_bottom') →
  /// (band id → count). Use [VariantSegments.fromMap] for untrusted (remote)
  /// input — it validates.
  const VariantSegments({
    Map<String, Map<String, int>> perVariant = const {},
  }) : _perVariant = perVariant;

  final Map<String, Map<String, int>> _perVariant;

  /// The product defaults: 12-12-12 with bottom, 18-18 without (36 total both).
  static const VariantSegments bundledDefault = VariantSegments(perVariant: {
    'with_bottom': {'mid': 12, 'high': 12, 'low': 12},
    'without_bottom': {'mid': 18, 'high': 18},
  });

  /// The configured count for ([variantId], [bandId]): the stored override when
  /// present and valid, else [bundledDefault]'s entry, else null (an unknown
  /// variant/band pair — the caller falls back to the legacy band count).
  int? segmentsFor(String variantId, String bandId) {
    final v = _perVariant[variantId]?[bandId];
    if (v != null && v >= 1) return v;
    final d = bundledDefault._perVariant[variantId]?[bandId];
    return (d != null && d >= 1) ? d : null;
  }

  /// Parses the remote-config block (variant id → band id → int). Only
  /// positive-integer entries survive; non-positive / ill-typed entries are
  /// dropped so that pair falls back to the bundled default. A non-map input
  /// yields all-defaults. Never throws.
  factory VariantSegments.fromMap(Object? raw) {
    if (raw is! Map) return bundledDefault;
    final parsed = <String, Map<String, int>>{};
    raw.forEach((variantId, bands) {
      if (variantId is! String || bands is! Map) return;
      final perBand = <String, int>{};
      bands.forEach((bandId, count) {
        if (bandId is! String) return;
        if (count is num && count.toInt() >= 1) perBand[bandId] = count.toInt();
      });
      if (perBand.isNotEmpty) parsed[variantId] = perBand;
    });
    return VariantSegments(perVariant: parsed);
  }

  /// Round-trips back to the wire shape [fromMap] consumes (only stored
  /// overrides — the bundled fallback stays implicit).
  Map<String, dynamic> toMap() => {
        for (final e in _perVariant.entries) e.key: Map<String, int>.of(e.value),
      };

  /// Rebuilds with every stored count passed through [transform] (the
  /// sanitizer's clamp hook). Entries the transform maps below 1 are dropped.
  VariantSegments mapCounts(int Function(int count) transform) {
    final out = <String, Map<String, int>>{};
    _perVariant.forEach((variantId, bands) {
      final perBand = <String, int>{};
      bands.forEach((bandId, count) {
        final t = transform(count);
        if (t >= 1) perBand[bandId] = t;
      });
      if (perBand.isNotEmpty) out[variantId] = perBand;
    });
    return VariantSegments(perVariant: out);
  }

  @override
  bool operator ==(Object other) {
    if (other is! VariantSegments) return false;
    if (_perVariant.length != other._perVariant.length) return false;
    for (final e in _perVariant.entries) {
      final o = other._perVariant[e.key];
      if (o == null || o.length != e.value.length) return false;
      for (final b in e.value.entries) {
        if (o[b.key] != b.value) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered(
        _perVariant.entries.map((e) => Object.hash(
              e.key,
              Object.hashAllUnordered(
                  e.value.entries.map((b) => Object.hash(b.key, b.value))),
            )),
      );
}

/// The effective ring segment count for [bandId] under [variant] — the SINGLE
/// resolver every flow consumer (progression builder, segment machines, live
/// HUD providers) goes through, so no two layers can disagree on N.
///
/// Precedence: variant override / bundled variant default
/// ([VariantSegments.segmentsFor]) → the band's legacy [PitchBand.segments]
/// (old cached configs) → 12. Always `>= 1`.
int effectiveSegmentsFor(
  CaptureConfig config,
  CaptureFlowVariant variant,
  String bandId,
) {
  final v = config.variantSegments.segmentsFor(variant.id, bandId);
  if (v != null) return v;
  for (final b in config.pitchBands) {
    if (b.id == bandId && b.segments >= 1) return b.segments;
  }
  return 12;
}

/// App-wide capture configuration. Server-tunable without an app release.
class CaptureConfig {
  const CaptureConfig({
    required this.version,
    required this.pitchBands,
    required this.thresholds,
    this.completionThresholds = CompletionThresholds.bundledDefault,
    this.uploadMinShots = UploadMinShots.bundledDefault,
    this.variantSegments = VariantSegments.bundledDefault,
  });

  final int version;
  final List<PitchBand> pitchBands;
  final CaptureThresholds thresholds;

  /// Per-level minimum accepted-frame thresholds for the final completion gate.
  final CompletionThresholds completionThresholds;

  /// Per-level absolute-minimum accepted shots required to upload (hard gate).
  final UploadMinShots uploadMinShots;

  /// Per-flow-variant ring segment counts (12-12-12 / 18-18 by default) —
  /// resolved through [effectiveSegmentsFor], never read raw by flow consumers.
  final VariantSegments variantSegments;

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
      completionThresholds: CompletionThresholds.fromMap(
          m['guided_capture_completion_thresholds']),
      uploadMinShots:
          UploadMinShots.fromMap(m['guided_capture_min_accepted_shots']),
      variantSegments:
          VariantSegments.fromMap(m['guided_capture_variant_segments']),
    );
  }

  Map<String, dynamic> toMap() => {
        'version': version,
        'pitchBands': pitchBands.map((b) => b.toMap()).toList(),
        'thresholds': thresholds.toMap(),
        'guided_capture_completion_thresholds': completionThresholds.toMap(),
        'guided_capture_min_accepted_shots': uploadMinShots.toMap(),
        'guided_capture_variant_segments': variantSegments.toMap(),
      };

  CaptureConfig copyWith({
    int? version,
    List<PitchBand>? pitchBands,
    CaptureThresholds? thresholds,
    CompletionThresholds? completionThresholds,
    UploadMinShots? uploadMinShots,
    VariantSegments? variantSegments,
  }) =>
      CaptureConfig(
        version: version ?? this.version,
        pitchBands: pitchBands ?? this.pitchBands,
        thresholds: thresholds ?? this.thresholds,
        completionThresholds: completionThresholds ?? this.completionThresholds,
        uploadMinShots: uploadMinShots ?? this.uploadMinShots,
        variantSegments: variantSegments ?? this.variantSegments,
      );
}
