// lib/domain/entities/capture_photo_metadata.dart
//
// Pure Dart — NO Flutter/native imports. The immutable client-side mirror of the
// per-frame JSON sidecar the native capture-metadata task writes next to each
// captured JPEG (`<frame>.json`). It is the record persistence/sync/reconstruction
// consumes. Designed to round-trip LOSSLESSLY with that sidecar.
//
// AUTHORITATIVE SCHEMA = the native sidecar. The shape here mirrors
// android/.../camera/CaptureMetadata.kt `toSidecarMap` and docs/camera/
// capture-metadata.md EXACTLY (field names, nesting, units, null policy):
//
//   { sessionId, frameId, frameIndex,
//     captureTimestampNs,            // precise MONOTONIC sensor-alignment key
//     wallClockIso,                  // human/interop wall-clock (distinct!)
//     device:{manufacturer,model,osVersion,appVersion?,cameraId?},
//     resolution:{width,height,aspectRatio,jpegQuality,fellBack},
//     intrinsics:{focalLengthMm?,focalLength35mm?,fNumber?,sensorWidthMm?,sensorHeightMm?},
//     capture:{afLocked,aeLocked,awbLocked,exposureTimeNs,iso,focusDistanceDiopters},
//     orientationApplied, pose }     // pose = reserved null (sensor/fusion fills later)
//
// RECONCILIATION (deliberate, see task): the sidecar does NOT carry guided-capture
// context (segmentIndex / level / objectSize), per-frame QUALITY (blur/exposure/
// decision), or yaw/pitch/roll — those are owned by OTHER models (CaptureEvaluation
// for the verdict, the ring engine / SegmentCoverage for segment context, the
// orientation pipeline for YPR) and are intentionally NOT duplicated here: adding
// them would fabricate schema and break the mandatory lossless round-trip. A
// higher-level "captured photo record" can compose this with those models when a
// join is needed. File paths (jpegPath/sidecarPath) likewise live on the runtime
// `CaptureMetadataEvent`, not in the sidecar.
//
// NULL POLICY (matches native exactly — required for lossless round-trip):
//   • intrinsics: null fields are OMITTED (a device lacking a value writes nothing).
//   • capture conditions: all six keys ALWAYS present (exposureTimeNs/iso/
//     focusDistanceDiopters serialize as explicit null when unobserved).
//   • device: all five keys present (appVersion/cameraId emitted as null).
//   • orientationApplied & pose: always present (pose reserved null).
//
// Parsing is tolerant (missing → default/null, extra/unknown keys ignored) for
// forward-compatibility as the schema evolves. Numbers coerce num→int/double so a
// JSON `4` and `4.0` parse identically. Pure data: no IO/logic. Hive-compatible via
// toJson/fromJson (the app persists JSON strings — no TypeAdapter needed).

/// Per-frame capture metadata — the Dart mirror of the native JSON sidecar.
class CapturePhotoMetadata {
  const CapturePhotoMetadata({
    required this.sessionId,
    required this.frameId,
    required this.frameIndex,
    required this.captureTimestampNs,
    required this.wallClockIso,
    required this.device,
    required this.resolution,
    required this.intrinsics,
    required this.conditions,
    this.orientationApplied,
    this.pose,
  });

  /// Capture session/job id (the `/recapture/{project}/{job}/…` job).
  final String sessionId;

  /// Stable per-frame id (matches the captured frame + CaptureMetadataEvent).
  final String frameId;

  /// 0-based index of this frame within the session/burst.
  final int frameIndex;

  /// PRECISE monotonic sensor timestamp (nanoseconds) — the sensor/pose alignment
  /// key. Distinct from wall-clock; never conflate the two.
  final int captureTimestampNs;

  /// Wall-clock capture time, ISO-8601 UTC (e.g. `2026-06-17T10:00:00.123Z`) —
  /// human/interop only.
  final String wallClockIso;

  final CaptureDeviceInfo device;
  final CaptureResolutionMeta resolution;
  final CaptureIntrinsics intrinsics;

  /// Capture conditions (lock state / exposure), serialized under the `capture`
  /// key to match the sidecar.
  final CaptureConditions conditions;

  /// Human label of the EXIF orientation the writer applied (e.g. `normal`).
  final String? orientationApplied;

  /// RESERVED — filled later by the sensor/pose-fusion task (joining on
  /// [captureTimestampNs]). Always null today; kept opaque + nullable so a future
  /// sidecar carrying a pose object round-trips without loss.
  final Map<String, dynamic>? pose;

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'frameId': frameId,
        'frameIndex': frameIndex,
        'captureTimestampNs': captureTimestampNs,
        'wallClockIso': wallClockIso,
        'device': device.toJson(),
        'resolution': resolution.toJson(),
        'intrinsics': intrinsics.toJson(),
        'capture': conditions.toJson(),
        'orientationApplied': orientationApplied,
        'pose': pose,
      };

  /// Tolerant parse — missing scalars fall back to safe defaults, unknown keys
  /// are ignored. Never throws on a Map input.
  factory CapturePhotoMetadata.fromJson(Map<String, dynamic> json) =>
      CapturePhotoMetadata(
        sessionId: _str(json['sessionId']),
        frameId: _str(json['frameId']),
        frameIndex: _int(json['frameIndex']) ?? 0,
        captureTimestampNs: _int(json['captureTimestampNs']) ?? 0,
        wallClockIso: _str(json['wallClockIso']),
        device: CaptureDeviceInfo.fromJson(_map(json['device'])),
        resolution: CaptureResolutionMeta.fromJson(_map(json['resolution'])),
        intrinsics: CaptureIntrinsics.fromJson(_map(json['intrinsics'])),
        conditions: CaptureConditions.fromJson(_map(json['capture'])),
        orientationApplied:
            json['orientationApplied'] is String ? json['orientationApplied'] as String : null,
        pose: json['pose'] is Map
            ? (json['pose'] as Map).cast<String, dynamic>()
            : null,
      );

  CapturePhotoMetadata copyWith({
    String? sessionId,
    String? frameId,
    int? frameIndex,
    int? captureTimestampNs,
    String? wallClockIso,
    CaptureDeviceInfo? device,
    CaptureResolutionMeta? resolution,
    CaptureIntrinsics? intrinsics,
    CaptureConditions? conditions,
    String? orientationApplied,
    Map<String, dynamic>? pose,
  }) =>
      CapturePhotoMetadata(
        sessionId: sessionId ?? this.sessionId,
        frameId: frameId ?? this.frameId,
        frameIndex: frameIndex ?? this.frameIndex,
        captureTimestampNs: captureTimestampNs ?? this.captureTimestampNs,
        wallClockIso: wallClockIso ?? this.wallClockIso,
        device: device ?? this.device,
        resolution: resolution ?? this.resolution,
        intrinsics: intrinsics ?? this.intrinsics,
        conditions: conditions ?? this.conditions,
        orientationApplied: orientationApplied ?? this.orientationApplied,
        pose: pose ?? this.pose,
      );

  @override
  bool operator ==(Object other) =>
      other is CapturePhotoMetadata &&
      other.sessionId == sessionId &&
      other.frameId == frameId &&
      other.frameIndex == frameIndex &&
      other.captureTimestampNs == captureTimestampNs &&
      other.wallClockIso == wallClockIso &&
      other.device == device &&
      other.resolution == resolution &&
      other.intrinsics == intrinsics &&
      other.conditions == conditions &&
      other.orientationApplied == orientationApplied &&
      _deepMapEquals(other.pose, pose);

  @override
  int get hashCode => Object.hash(
        sessionId,
        frameId,
        frameIndex,
        captureTimestampNs,
        wallClockIso,
        device,
        resolution,
        intrinsics,
        conditions,
        orientationApplied,
        pose == null ? null : Object.hashAll(pose!.keys),
      );
}

/// Device descriptor — mirrors the sidecar `device` object (all keys present).
class CaptureDeviceInfo {
  const CaptureDeviceInfo({
    required this.manufacturer,
    required this.model,
    required this.osVersion,
    this.appVersion,
    this.cameraId,
  });

  final String manufacturer;
  final String model;
  final String osVersion;
  final String? appVersion;
  final String? cameraId;

  Map<String, dynamic> toJson() => {
        'manufacturer': manufacturer,
        'model': model,
        'osVersion': osVersion,
        'appVersion': appVersion,
        'cameraId': cameraId,
      };

  factory CaptureDeviceInfo.fromJson(Map<String, dynamic> json) =>
      CaptureDeviceInfo(
        manufacturer: _str(json['manufacturer']),
        model: _str(json['model']),
        osVersion: _str(json['osVersion']),
        appVersion: json['appVersion'] is String ? json['appVersion'] as String : null,
        cameraId: json['cameraId'] is String ? json['cameraId'] as String : null,
      );

  CaptureDeviceInfo copyWith({
    String? manufacturer,
    String? model,
    String? osVersion,
    String? appVersion,
    String? cameraId,
  }) =>
      CaptureDeviceInfo(
        manufacturer: manufacturer ?? this.manufacturer,
        model: model ?? this.model,
        osVersion: osVersion ?? this.osVersion,
        appVersion: appVersion ?? this.appVersion,
        cameraId: cameraId ?? this.cameraId,
      );

  @override
  bool operator ==(Object other) =>
      other is CaptureDeviceInfo &&
      other.manufacturer == manufacturer &&
      other.model == model &&
      other.osVersion == osVersion &&
      other.appVersion == appVersion &&
      other.cameraId == cameraId;

  @override
  int get hashCode =>
      Object.hash(manufacturer, model, osVersion, appVersion, cameraId);
}

/// Actual session resolution — mirrors the sidecar `resolution` object.
class CaptureResolutionMeta {
  const CaptureResolutionMeta({
    required this.width,
    required this.height,
    required this.aspectRatio,
    required this.jpegQuality,
    required this.fellBack,
  });

  final int width;
  final int height;

  /// e.g. `4:3` / `16:9` (the native wire string).
  final String aspectRatio;
  final int jpegQuality;

  /// True when the resolution policy fell back from the requested target.
  final bool fellBack;

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
        'aspectRatio': aspectRatio,
        'jpegQuality': jpegQuality,
        'fellBack': fellBack,
      };

  factory CaptureResolutionMeta.fromJson(Map<String, dynamic> json) =>
      CaptureResolutionMeta(
        width: _int(json['width']) ?? 0,
        height: _int(json['height']) ?? 0,
        aspectRatio: _str(json['aspectRatio']),
        jpegQuality: _int(json['jpegQuality']) ?? 0,
        fellBack: json['fellBack'] == true,
      );

  CaptureResolutionMeta copyWith({
    int? width,
    int? height,
    String? aspectRatio,
    int? jpegQuality,
    bool? fellBack,
  }) =>
      CaptureResolutionMeta(
        width: width ?? this.width,
        height: height ?? this.height,
        aspectRatio: aspectRatio ?? this.aspectRatio,
        jpegQuality: jpegQuality ?? this.jpegQuality,
        fellBack: fellBack ?? this.fellBack,
      );

  @override
  bool operator ==(Object other) =>
      other is CaptureResolutionMeta &&
      other.width == width &&
      other.height == height &&
      other.aspectRatio == aspectRatio &&
      other.jpegQuality == jpegQuality &&
      other.fellBack == fellBack;

  @override
  int get hashCode =>
      Object.hash(width, height, aspectRatio, jpegQuality, fellBack);
}

/// Camera intrinsics — mirrors the sidecar `intrinsics` object. Every field is
/// nullable and, per native, OMITTED from JSON when null (never fabricated).
class CaptureIntrinsics {
  const CaptureIntrinsics({
    this.focalLengthMm,
    this.focalLength35mm,
    this.fNumber,
    this.sensorWidthMm,
    this.sensorHeightMm,
  });

  static const CaptureIntrinsics empty = CaptureIntrinsics();

  final double? focalLengthMm;

  /// 35mm-equivalent (derived natively); integer per the sidecar.
  final int? focalLength35mm;
  final double? fNumber;
  final double? sensorWidthMm;
  final double? sensorHeightMm;

  /// Omits null fields, matching the native sidecar exactly.
  Map<String, dynamic> toJson() => {
        if (focalLengthMm != null) 'focalLengthMm': focalLengthMm,
        if (focalLength35mm != null) 'focalLength35mm': focalLength35mm,
        if (fNumber != null) 'fNumber': fNumber,
        if (sensorWidthMm != null) 'sensorWidthMm': sensorWidthMm,
        if (sensorHeightMm != null) 'sensorHeightMm': sensorHeightMm,
      };

  factory CaptureIntrinsics.fromJson(Map<String, dynamic> json) =>
      CaptureIntrinsics(
        focalLengthMm: _double(json['focalLengthMm']),
        focalLength35mm: _int(json['focalLength35mm']),
        fNumber: _double(json['fNumber']),
        sensorWidthMm: _double(json['sensorWidthMm']),
        sensorHeightMm: _double(json['sensorHeightMm']),
      );

  CaptureIntrinsics copyWith({
    double? focalLengthMm,
    int? focalLength35mm,
    double? fNumber,
    double? sensorWidthMm,
    double? sensorHeightMm,
  }) =>
      CaptureIntrinsics(
        focalLengthMm: focalLengthMm ?? this.focalLengthMm,
        focalLength35mm: focalLength35mm ?? this.focalLength35mm,
        fNumber: fNumber ?? this.fNumber,
        sensorWidthMm: sensorWidthMm ?? this.sensorWidthMm,
        sensorHeightMm: sensorHeightMm ?? this.sensorHeightMm,
      );

  @override
  bool operator ==(Object other) =>
      other is CaptureIntrinsics &&
      other.focalLengthMm == focalLengthMm &&
      other.focalLength35mm == focalLength35mm &&
      other.fNumber == fNumber &&
      other.sensorWidthMm == sensorWidthMm &&
      other.sensorHeightMm == sensorHeightMm;

  @override
  int get hashCode => Object.hash(
        focalLengthMm,
        focalLength35mm,
        fNumber,
        sensorWidthMm,
        sensorHeightMm,
      );
}

/// Capture conditions (lock state + exposure) — mirrors the sidecar `capture`
/// object. All six keys are ALWAYS serialized (the three exposure/focus fields as
/// explicit null when unobserved), matching native.
class CaptureConditions {
  const CaptureConditions({
    required this.afLocked,
    required this.aeLocked,
    required this.awbLocked,
    this.exposureTimeNs,
    this.iso,
    this.focusDistanceDiopters,
  });

  final bool afLocked;
  final bool aeLocked;
  final bool awbLocked;

  /// Exposure time in ns — null when not observed via a CaptureResult.
  final int? exposureTimeNs;
  final int? iso;
  final double? focusDistanceDiopters;

  Map<String, dynamic> toJson() => {
        'afLocked': afLocked,
        'aeLocked': aeLocked,
        'awbLocked': awbLocked,
        'exposureTimeNs': exposureTimeNs,
        'iso': iso,
        'focusDistanceDiopters': focusDistanceDiopters,
      };

  factory CaptureConditions.fromJson(Map<String, dynamic> json) =>
      CaptureConditions(
        afLocked: json['afLocked'] == true,
        aeLocked: json['aeLocked'] == true,
        awbLocked: json['awbLocked'] == true,
        exposureTimeNs: _int(json['exposureTimeNs']),
        iso: _int(json['iso']),
        focusDistanceDiopters: _double(json['focusDistanceDiopters']),
      );

  CaptureConditions copyWith({
    bool? afLocked,
    bool? aeLocked,
    bool? awbLocked,
    int? exposureTimeNs,
    int? iso,
    double? focusDistanceDiopters,
  }) =>
      CaptureConditions(
        afLocked: afLocked ?? this.afLocked,
        aeLocked: aeLocked ?? this.aeLocked,
        awbLocked: awbLocked ?? this.awbLocked,
        exposureTimeNs: exposureTimeNs ?? this.exposureTimeNs,
        iso: iso ?? this.iso,
        focusDistanceDiopters: focusDistanceDiopters ?? this.focusDistanceDiopters,
      );

  @override
  bool operator ==(Object other) =>
      other is CaptureConditions &&
      other.afLocked == afLocked &&
      other.aeLocked == aeLocked &&
      other.awbLocked == awbLocked &&
      other.exposureTimeNs == exposureTimeNs &&
      other.iso == iso &&
      other.focusDistanceDiopters == focusDistanceDiopters;

  @override
  int get hashCode => Object.hash(
        afLocked,
        aeLocked,
        awbLocked,
        exposureTimeNs,
        iso,
        focusDistanceDiopters,
      );
}

// ── tolerant parse helpers ───────────────────────────────────────────────────

String _str(Object? v) => v is String ? v : '';

int? _int(Object? v) => v is num ? v.toInt() : null;

double? _double(Object? v) => v is num ? v.toDouble() : null;

Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};

bool _deepMapEquals(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (!_deepValueEquals(entry.value, b[entry.key])) return false;
  }
  return true;
}

/// Structural equality for the opaque [CapturePhotoMetadata.pose] payload
/// (nested maps/lists/scalars), so a parsed pose compares by value.
bool _deepValueEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return _deepMapEquals(a.cast<String, dynamic>(), b.cast<String, dynamic>());
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepValueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
