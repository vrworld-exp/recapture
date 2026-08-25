// lib/domain/upload/file_upload_progress.dart
//
// Pure Dart — NO Flutter / Hive / IO. The DURABLE per-file upload progress the
// resumable-upload layer persists: the server multipart [uploadId], the confirmed
// part ETags ([completedParts] — the resume key + the finalize input), the byte
// [offset] (cumulative confirmed bytes, for progress restore), and [status].
//
// CORRECTNESS INVARIANTS this shape enforces:
//   • A part appears in [completedParts] ONLY after the server confirmed it and
//     returned its ETag. Never a partial/in-flight part.
//   • The ETag list is never lost — it is the only way to finalize (complete) a
//     multipart upload without re-uploading everything.
//   • For S3 multipart the durable resume key is the SET of completed PART NUMBERS
//     (parts are addressed by number, uploaded concurrently/out-of-order), so
//     [offset] is a progress convenience, NOT the resume authority — resume skips
//     parts by [completedPartNumbers].
//
// Round-trips losslessly through JSON (the Hive store persists JSON strings, the
// repo convention — no TypeAdapters). Tolerant parse: unknown keys ignored, bad
// rows skipped, so a corrupt blob degrades to a recoverable/empty state.
import '../entities/upload_progress.dart' show UploadStatus;

/// One server-confirmed multipart part: its 1-based [partNumber] + [etag].
class UploadPart {
  const UploadPart({required this.partNumber, required this.etag});

  final int partNumber;
  final String etag;

  Map<String, dynamic> toJson() => {'partNumber': partNumber, 'etag': etag};

  static UploadPart? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final pn = raw['partNumber'];
    final etag = raw['etag'];
    if (pn is! num || etag is! String || etag.isEmpty) return null;
    return UploadPart(partNumber: pn.toInt(), etag: etag);
  }

  @override
  bool operator ==(Object other) =>
      other is UploadPart && other.partNumber == partNumber && other.etag == etag;

  @override
  int get hashCode => Object.hash(partNumber, etag);

  @override
  String toString() => 'UploadPart(#$partNumber, $etag)';
}

/// Durable progress for ONE file within an upload session.
class FileUploadProgress {
  const FileUploadProgress({
    required this.fileId,
    required this.objectKey,
    this.uploadId,
    this.completedParts = const [],
    this.offset = 0,
    this.totalParts = 0,
    this.totalBytes = 0,
    this.status = UploadStatus.idle,
  });

  /// Stable per-file id within the session (the file's S3 object key is [objectKey];
  /// [fileId] may equal it — kept distinct so the key can carry a prefix).
  final String fileId;

  /// The S3 object key echoed to complete/abort.
  final String objectKey;

  /// The server multipart upload id — null until initiated; reused on resume.
  final String? uploadId;

  /// Server-confirmed parts (partNumber + ETag). The resume key + finalize input.
  final List<UploadPart> completedParts;

  /// Cumulative confirmed bytes — advances ATOMICALLY with a part (progress restore).
  final int offset;

  /// Total parts planned for the file (finalize is possible only when all are in).
  final int totalParts;

  /// Total file size in bytes.
  final int totalBytes;

  final UploadStatus status;

  /// The set of confirmed part numbers — resume skips these (never re-uploads).
  Set<int> get completedPartNumbers =>
      {for (final p in completedParts) p.partNumber};

  /// Whether part [n] is already confirmed.
  bool isPartComplete(int n) => completedPartNumbers.contains(n);

  /// Completed parts sorted ascending by part number — the order S3 complete needs.
  List<UploadPart> get orderedParts =>
      [...completedParts]..sort((a, b) => a.partNumber.compareTo(b.partNumber));

  /// Whether every planned part is confirmed (finalize is safe — no gap). Requires
  /// a known [totalParts] and the confirmed set to cover 1..totalParts.
  bool get allPartsComplete {
    if (totalParts <= 0) return false;
    final done = completedPartNumbers;
    if (done.length < totalParts) return false;
    for (var n = 1; n <= totalParts; n++) {
      if (!done.contains(n)) return false;
    }
    return true;
  }

  bool get isComplete => status == UploadStatus.completed;

  /// Returns a copy with [part] added (replacing any prior entry for the same part
  /// number — idempotent) and [offset]/[status] updated. Used by the atomic
  /// record-part-complete write.
  FileUploadProgress withPart(UploadPart part, {required int offset}) {
    final next = [
      for (final p in completedParts)
        if (p.partNumber != part.partNumber) p,
      part,
    ];
    return copyWith(
      completedParts: next,
      offset: offset,
      status: UploadStatus.inProgress,
    );
  }

  FileUploadProgress copyWith({
    String? uploadId,
    List<UploadPart>? completedParts,
    int? offset,
    int? totalParts,
    int? totalBytes,
    UploadStatus? status,
  }) =>
      FileUploadProgress(
        fileId: fileId,
        objectKey: objectKey,
        uploadId: uploadId ?? this.uploadId,
        completedParts: completedParts ?? this.completedParts,
        offset: offset ?? this.offset,
        totalParts: totalParts ?? this.totalParts,
        totalBytes: totalBytes ?? this.totalBytes,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'objectKey': objectKey,
        'uploadId': uploadId,
        'completedParts': [for (final p in completedParts) p.toJson()],
        'offset': offset,
        'totalParts': totalParts,
        'totalBytes': totalBytes,
        'status': status.name,
      };

  /// Tolerant parse — returns null only when the required identity is unreadable
  /// (then the caller treats the file as "start fresh"). Bad part rows are skipped.
  static FileUploadProgress? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fileId = raw['fileId'];
    final objectKey = raw['objectKey'];
    if (fileId is! String || objectKey is! String) return null;
    final partsRaw = raw['completedParts'];
    final parts = <UploadPart>[];
    if (partsRaw is List) {
      for (final row in partsRaw) {
        final p = UploadPart.fromJson(row);
        if (p != null) parts.add(p);
      }
    }
    return FileUploadProgress(
      fileId: fileId,
      objectKey: objectKey,
      uploadId: raw['uploadId'] is String ? raw['uploadId'] as String : null,
      completedParts: parts,
      offset: raw['offset'] is num ? (raw['offset'] as num).toInt() : 0,
      totalParts: raw['totalParts'] is num ? (raw['totalParts'] as num).toInt() : 0,
      totalBytes: raw['totalBytes'] is num ? (raw['totalBytes'] as num).toInt() : 0,
      status: _statusFrom(raw['status']),
    );
  }

  static UploadStatus _statusFrom(Object? raw) {
    if (raw is String) {
      for (final s in UploadStatus.values) {
        if (s.name == raw) return s;
      }
    }
    return UploadStatus.idle;
  }

  @override
  bool operator ==(Object other) =>
      other is FileUploadProgress &&
      other.fileId == fileId &&
      other.objectKey == objectKey &&
      other.uploadId == uploadId &&
      other.offset == offset &&
      other.totalParts == totalParts &&
      other.totalBytes == totalBytes &&
      other.status == status &&
      _partsEqual(other.completedParts, completedParts);

  @override
  int get hashCode => Object.hash(
        fileId,
        objectKey,
        uploadId,
        offset,
        totalParts,
        totalBytes,
        status,
        Object.hashAllUnordered(completedParts),
      );

  @override
  String toString() => 'FileUploadProgress($fileId, upload: $uploadId, '
      'parts: ${completedParts.length}/$totalParts, offset: $offset, $status)';
}

bool _partsEqual(List<UploadPart> a, List<UploadPart> b) {
  if (a.length != b.length) return false;
  final am = {for (final p in a) p.partNumber: p.etag};
  for (final p in b) {
    if (am[p.partNumber] != p.etag) return false;
  }
  return true;
}
