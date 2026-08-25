// lib/application/capture/session/capture_session_codec.dart
//
// Pure conversions for the capture-session snapshot, in two groups:
//   A) LIVE state ⇄ CaptureSessionState — capture from / restore into the real
//      state classes ([SegmentCoverage] for fill, [LevelCaptureLedger] for the
//      photo lists), using only their public APIs.
//   B) CaptureSessionState ⇄ Map<String,dynamic> — the JSON-storable shape the
//      Hive box persists (the repo stores JSON strings in Box<String>; there are
//      NO Hive TypeAdapters — see hive_init.dart). Keys come from
//      [CaptureSessionKeys] (no inline literals).
//
// GROUNDING vs the brief's fictional API: there is no mutable EyeRingSegmentMap —
// SegmentCoverage is immutable, so [restoreCoverage] REBUILDS a SegmentCoverage
// (the caller swaps it in) rather than mutating one; a segmentCount mismatch
// (ring density changed between app versions) is surfaced via
// [CaptureSessionParseException] when an `expectedSegmentCount` is supplied. The
// ledger IS mutable, so [restoreLedger] reset-then-replays. Records keep their
// real fields (segmentIndex int, yawDegrees, sensorTimestampNs) so segmentIndex
// restores faithfully.
import '../../../domain/entities/segment_coverage.dart';
import '../ledger/captured_photo_record.dart';
import '../ledger/level_capture_ledger.dart';
import '../ledger/photo_rejection_reason.dart';
import '../ledger/rejected_photo_record.dart';
import '../ledger/warned_photo_record.dart';
import 'capture_session_keys.dart';
import 'capture_session_state.dart';

/// Current persisted schema version for a session snapshot.
const int kCaptureSessionSchemaVersion = 1;

/// Thrown when a stored snapshot cannot be parsed/restored. The store catches
/// this and treats it as "no valid session" (start fresh) rather than crashing.
class CaptureSessionParseException implements Exception {
  const CaptureSessionParseException(this.message, {this.rawPayload});

  final String message;
  final Map<dynamic, dynamic>? rawPayload;

  @override
  String toString() => 'CaptureSessionParseException: $message';
}

abstract final class CaptureSessionCodec {
  CaptureSessionCodec._();

  // ─── A: live state ⇄ CaptureSessionState ─────────────────────────────────

  /// Snapshots [coverage] + [ledger]. Pure read — mutates neither.
  static CaptureSessionState capture({
    required String projectId,
    required String levelId,
    required SegmentCoverage coverage,
    required LevelCaptureLedger ledger,
    required int savedAtMs,
  }) =>
      CaptureSessionState(
        projectId: projectId,
        levelId: levelId,
        segmentCount: coverage.segmentCount,
        fillThreshold: coverage.fillThreshold,
        fillCounts: List<int>.of(coverage.fillCounts),
        position: coverage.position,
        accepted: List<CapturedPhotoRecord>.of(ledger.accepted),
        warned: List<WarnedPhotoRecord>.of(ledger.warned),
        rejected: List<RejectedPhotoRecord>.of(ledger.rejected),
        savedAtMs: savedAtMs,
      );

  /// Rebuilds the [SegmentCoverage] from [snapshot] (exact: counts + threshold +
  /// position). If [expectedSegmentCount] is given and differs from the
  /// snapshot's, throws [CaptureSessionParseException] — the caller decides the
  /// fallback (discard / migrate / prompt).
  static SegmentCoverage restoreCoverage(
    CaptureSessionState snapshot, {
    int? expectedSegmentCount,
  }) {
    if (expectedSegmentCount != null &&
        expectedSegmentCount != snapshot.segmentCount) {
      throw CaptureSessionParseException(
        'segmentCount mismatch: expected $expectedSegmentCount, '
        'snapshot has ${snapshot.segmentCount}',
      );
    }
    return SegmentCoverage.of(
      segmentCount: snapshot.segmentCount,
      fillThreshold: snapshot.fillThreshold,
      fillCounts: snapshot.fillCounts,
      position: snapshot.position,
    );
  }

  /// Restores [ledger] to match [snapshot]: resets first (no stale state
  /// survives a partial restore), then replays the three lists in order.
  static void restoreLedger(
    CaptureSessionState snapshot,
    LevelCaptureLedger ledger,
  ) {
    ledger.reset();
    for (final r in snapshot.accepted) {
      ledger.recordAccepted(r);
    }
    for (final r in snapshot.warned) {
      ledger.recordWarned(r);
    }
    for (final r in snapshot.rejected) {
      ledger.recordRejected(r);
    }
  }

  // ─── B: CaptureSessionState ⇄ Map<String,dynamic> ────────────────────────

  static Map<String, dynamic> toJson(CaptureSessionState state) => {
        CaptureSessionKeys.schemaVersion: kCaptureSessionSchemaVersion,
        CaptureSessionKeys.projectId: state.projectId,
        CaptureSessionKeys.levelId: state.levelId,
        CaptureSessionKeys.segmentCount: state.segmentCount,
        CaptureSessionKeys.fillThreshold: state.fillThreshold,
        CaptureSessionKeys.fillCounts: List<int>.of(state.fillCounts),
        CaptureSessionKeys.position: state.position,
        CaptureSessionKeys.accepted: state.accepted.map(_acceptedToJson).toList(),
        CaptureSessionKeys.warned: state.warned.map(_warnedToJson).toList(),
        CaptureSessionKeys.rejected: state.rejected.map(_rejectedToJson).toList(),
        CaptureSessionKeys.savedAtMs: state.savedAtMs,
      };

  static CaptureSessionState fromJson(Map<dynamic, dynamic> raw) {
    try {
      final rawStates = raw[CaptureSessionKeys.fillCounts];
      if (rawStates is! List) {
        throw CaptureSessionParseException(
          'Missing or invalid ${CaptureSessionKeys.fillCounts}',
          rawPayload: raw,
        );
      }
      return CaptureSessionState(
        projectId: _requireString(raw, CaptureSessionKeys.projectId),
        levelId: _requireString(raw, CaptureSessionKeys.levelId),
        segmentCount: _requireInt(raw, CaptureSessionKeys.segmentCount),
        fillThreshold: _requireInt(raw, CaptureSessionKeys.fillThreshold),
        fillCounts: [for (final v in rawStates) _asInt(v, CaptureSessionKeys.fillCounts)],
        position: _requireInt(raw, CaptureSessionKeys.position),
        accepted: _requireList(raw, CaptureSessionKeys.accepted)
            .map((m) => _acceptedFromJson(_asMap(m)))
            .toList(),
        warned: _requireList(raw, CaptureSessionKeys.warned)
            .map((m) => _warnedFromJson(_asMap(m)))
            .toList(),
        rejected: _requireList(raw, CaptureSessionKeys.rejected)
            .map((m) => _rejectedFromJson(_asMap(m)))
            .toList(),
        savedAtMs: _requireInt(raw, CaptureSessionKeys.savedAtMs),
      );
    } on CaptureSessionParseException {
      rethrow;
    } catch (e) {
      throw CaptureSessionParseException('Unexpected parse error: $e',
          rawPayload: raw);
    }
  }

  // ─── record (de)serialisation ────────────────────────────────────────────

  static Map<String, dynamic> _acceptedToJson(CapturedPhotoRecord r) => {
        CaptureSessionKeys.segmentIndex: r.segmentIndex,
        CaptureSessionKeys.framePath: r.framePath,
        CaptureSessionKeys.blurScore: r.blurScore,
        CaptureSessionKeys.meanLuminance: r.meanLuminance,
        CaptureSessionKeys.yawDegrees: r.yawDegrees,
        CaptureSessionKeys.pitchDegrees: r.pitchDegrees,
        CaptureSessionKeys.sensorTimestampNs: r.sensorTimestampNs,
      };

  static CapturedPhotoRecord _acceptedFromJson(Map<dynamic, dynamic> m) =>
      CapturedPhotoRecord(
        // Grounded improvement over the brief: segmentIndex is a plain int, so it
        // restores faithfully (no null-out).
        segmentIndex: _optionalInt(m, CaptureSessionKeys.segmentIndex),
        framePath: _requireString(m, CaptureSessionKeys.framePath),
        blurScore: _requireDouble(m, CaptureSessionKeys.blurScore),
        meanLuminance: _requireDouble(m, CaptureSessionKeys.meanLuminance),
        yawDegrees: _requireDouble(m, CaptureSessionKeys.yawDegrees),
        pitchDegrees: _requireDouble(m, CaptureSessionKeys.pitchDegrees),
        sensorTimestampNs: _requireInt(m, CaptureSessionKeys.sensorTimestampNs),
      );

  static Map<String, dynamic> _warnedToJson(WarnedPhotoRecord r) => {
        CaptureSessionKeys.framePath: r.framePath,
        CaptureSessionKeys.isUnderexposed: r.isUnderexposed,
        CaptureSessionKeys.isOverexposed: r.isOverexposed,
        CaptureSessionKeys.meanLuminance: r.meanLuminance,
        CaptureSessionKeys.sensorTimestampNs: r.sensorTimestampNs,
      };

  static WarnedPhotoRecord _warnedFromJson(Map<dynamic, dynamic> m) =>
      WarnedPhotoRecord(
        framePath: _requireString(m, CaptureSessionKeys.framePath),
        isUnderexposed: _requireBool(m, CaptureSessionKeys.isUnderexposed),
        isOverexposed: _requireBool(m, CaptureSessionKeys.isOverexposed),
        meanLuminance: _requireDouble(m, CaptureSessionKeys.meanLuminance),
        sensorTimestampNs: _requireInt(m, CaptureSessionKeys.sensorTimestampNs),
      );

  static Map<String, dynamic> _rejectedToJson(RejectedPhotoRecord r) => {
        CaptureSessionKeys.reason: r.reason.name,
        CaptureSessionKeys.framePath: r.framePath,
        CaptureSessionKeys.blurScore: r.blurScore,
        CaptureSessionKeys.stabilityScore: r.stabilityScore,
        CaptureSessionKeys.yawDegrees: r.yawDegrees,
        CaptureSessionKeys.sensorTimestampNs: r.sensorTimestampNs,
      };

  static RejectedPhotoRecord _rejectedFromJson(Map<dynamic, dynamic> m) {
    final reasonName = _requireString(m, CaptureSessionKeys.reason);
    final reason = PhotoRejectionReason.values.firstWhere(
      (r) => r.name == reasonName,
      orElse: () => throw CaptureSessionParseException(
        'Unknown PhotoRejectionReason: $reasonName',
        rawPayload: m,
      ),
    );
    return RejectedPhotoRecord(
      reason: reason,
      framePath: m[CaptureSessionKeys.framePath] as String?,
      blurScore: _optionalDouble(m, CaptureSessionKeys.blurScore),
      stabilityScore: _optionalDouble(m, CaptureSessionKeys.stabilityScore),
      yawDegrees: _requireDouble(m, CaptureSessionKeys.yawDegrees),
      sensorTimestampNs: _requireInt(m, CaptureSessionKeys.sensorTimestampNs),
    );
  }

  // ─── primitive coercion helpers ──────────────────────────────────────────

  static String _requireString(Map<dynamic, dynamic> m, String key) {
    final v = m[key];
    if (v is String) return v;
    if (v == null) {
      throw CaptureSessionParseException('Missing key: $key', rawPayload: m);
    }
    throw CaptureSessionParseException(
        'Expected String for $key, got ${v.runtimeType}', rawPayload: m);
  }

  static int _requireInt(Map<dynamic, dynamic> m, String key) =>
      _asInt(m[key], key, raw: m, missingIfNull: true);

  static int _asInt(Object? v, String key,
      {Map<dynamic, dynamic>? raw, bool missingIfNull = false}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v == null && missingIfNull) {
      throw CaptureSessionParseException('Missing key: $key', rawPayload: raw);
    }
    throw CaptureSessionParseException(
        'Expected int for $key, got ${v.runtimeType}', rawPayload: raw);
  }

  static int? _optionalInt(Map<dynamic, dynamic> m, String key) {
    final v = m[key];
    if (v == null) return null;
    if (v is num) return v.toInt();
    throw CaptureSessionParseException(
        'Expected int? for $key, got ${v.runtimeType}', rawPayload: m);
  }

  static double _requireDouble(Map<dynamic, dynamic> m, String key) {
    final v = m[key];
    if (v is num) return v.toDouble();
    if (v == null) {
      throw CaptureSessionParseException('Missing key: $key', rawPayload: m);
    }
    throw CaptureSessionParseException(
        'Expected double for $key, got ${v.runtimeType}', rawPayload: m);
  }

  static double? _optionalDouble(Map<dynamic, dynamic> m, String key) {
    final v = m[key];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw CaptureSessionParseException(
        'Expected double? for $key, got ${v.runtimeType}', rawPayload: m);
  }

  static bool _requireBool(Map<dynamic, dynamic> m, String key) {
    final v = m[key];
    if (v is bool) return v;
    if (v == null) {
      throw CaptureSessionParseException('Missing key: $key', rawPayload: m);
    }
    throw CaptureSessionParseException(
        'Expected bool for $key, got ${v.runtimeType}', rawPayload: m);
  }

  static List<dynamic> _requireList(Map<dynamic, dynamic> m, String key) {
    final v = m[key];
    if (v is List) return v;
    if (v == null) {
      throw CaptureSessionParseException('Missing key: $key', rawPayload: m);
    }
    throw CaptureSessionParseException(
        'Expected List for $key, got ${v.runtimeType}', rawPayload: m);
  }

  static Map<dynamic, dynamic> _asMap(Object? v) {
    if (v is Map) return v;
    throw CaptureSessionParseException(
        'Expected Map for a record, got ${v.runtimeType}');
  }
}
