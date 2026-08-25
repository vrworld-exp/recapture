// lib/data/local/upload_progress_box.dart
//
// The durable persistence layer for resumable uploads. [UploadProgressStore] is
// the clean, testable API the transport (Dart engine, or a native foreground
// service reporting back over a channel) reads/writes; [HiveUploadProgressStore]
// is the Hive-backed implementation (repo convention: a `Box<String>` of JSON,
// opened via [openStringBoxSafely], NO TypeAdapters). [InMemoryUploadProgressStore]
// is a fake for unit tests.
//
// ATOMICITY: [recordPartComplete] does a read-modify-write and persists the part
// ETag AND the advanced offset in ONE `box.put` — a single Hive write, so the
// offset can never land without its ETag (or vice-versa). Concurrent parts of the
// SAME file are SERIALIZED via a per-key write lock so two simultaneous confirms
// can't clobber each other's completed-part list.
//
// CORRUPTION POLICY (matches the other gateways): absent/unparseable → treated as
// "no progress" (start fresh); [get] never throws.
import 'dart:convert';

import 'package:hive/hive.dart';

import '../../domain/entities/upload_progress.dart' show UploadStatus;
import '../../domain/upload/file_upload_progress.dart';
import 'box_names.dart';
import 'hive_init.dart';

/// The persistence API the resumable-upload engine depends on. Injectable so the
/// engine is unit-testable with [InMemoryUploadProgressStore].
abstract interface class UploadProgressStore {
  /// The persisted progress for (sessionId, fileId), or null when absent/corrupt.
  Future<FileUploadProgress?> get(String sessionId, String fileId);

  /// Starts (or restarts, on re-initiate) a file's progress: records the server
  /// [uploadId] + [objectKey] + [totalParts]/[totalBytes], CLEARING any prior
  /// completed parts (a new uploadId invalidates old parts). Status → inProgress.
  Future<void> begin(
    String sessionId,
    String fileId, {
    required String uploadId,
    required String objectKey,
    required int totalParts,
    required int totalBytes,
  });

  /// ATOMIC: records a server-confirmed part ([partNumber] + [etag]) and advances
  /// the byte [offset] together (idempotent — re-recording a part replaces it).
  Future<void> recordPartComplete(
    String sessionId,
    String fileId, {
    required int partNumber,
    required String etag,
    required int offset,
  });

  /// Marks the file's multipart upload finalized (status → completed).
  Future<void> markFileComplete(String sessionId, String fileId);

  /// Removes one file's persisted progress (e.g. on re-initiate reset).
  Future<void> clearFile(String sessionId, String fileId);

  /// Removes ALL files' progress for a session (on cancel/complete). Local captured
  /// data is retained separately — this clears only the upload bookkeeping.
  Future<void> clearSession(String sessionId);

  /// Every persisted file-progress for a session (for relaunch resume).
  Future<List<FileUploadProgress>> listSession(String sessionId);
}

/// Hive-backed [UploadProgressStore]. One JSON entry per `sessionId::fileId`.
class HiveUploadProgressStore implements UploadProgressStore {
  HiveUploadProgressStore();

  Box<String>? _box;
  Future<Box<String>>? _opening;

  /// Per-key write lock so concurrent part confirms for one file serialize.
  final Map<String, Future<void>> _locks = {};

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??= openStringBoxSafely(BoxNames.uploadProgress).then((box) {
      _box = box;
      _opening = null;
      return box;
    });
  }

  /// The '::' separator is depended on by [clearSession]/[listSession] prefix
  /// matching — change all three together.
  String _keyFor(String sessionId, String fileId) => '$sessionId::$fileId';

  /// Serializes writes for one key: chains onto any in-flight write for that key so
  /// a read-modify-write cannot interleave with another for the same file. The
  /// chained tail swallows errors so one failed write never wedges the queue.
  Future<T> _locked<T>(String key, Future<T> Function() action) {
    final prev = _locks[key] ?? Future<void>.value();
    final result = prev.then((_) => action());
    _locks[key] = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<FileUploadProgress?> get(String sessionId, String fileId) async {
    final box = await _open();
    return _decode(box.get(_keyFor(sessionId, fileId)));
  }

  @override
  Future<void> begin(
    String sessionId,
    String fileId, {
    required String uploadId,
    required String objectKey,
    required int totalParts,
    required int totalBytes,
  }) {
    final key = _keyFor(sessionId, fileId);
    return _locked(key, () async {
      final box = await _open();
      final progress = FileUploadProgress(
        fileId: fileId,
        objectKey: objectKey,
        uploadId: uploadId,
        completedParts: const [],
        offset: 0,
        totalParts: totalParts,
        totalBytes: totalBytes,
        status: UploadStatus.inProgress,
      );
      await box.put(key, jsonEncode(progress.toJson()));
    });
  }

  @override
  Future<void> recordPartComplete(
    String sessionId,
    String fileId, {
    required int partNumber,
    required String etag,
    required int offset,
  }) {
    final key = _keyFor(sessionId, fileId);
    return _locked(key, () async {
      final box = await _open();
      final current = _decode(box.get(key)) ??
          FileUploadProgress(fileId: fileId, objectKey: fileId);
      final next = current.withPart(
        UploadPart(partNumber: partNumber, etag: etag),
        offset: offset,
      );
      // Single put = atomic: the ETag and the advanced offset land together.
      await box.put(key, jsonEncode(next.toJson()));
    });
  }

  @override
  Future<void> markFileComplete(String sessionId, String fileId) {
    final key = _keyFor(sessionId, fileId);
    return _locked(key, () async {
      final box = await _open();
      final current = _decode(box.get(key));
      if (current == null) return;
      await box.put(
        key,
        jsonEncode(current.copyWith(status: UploadStatus.completed).toJson()),
      );
    });
  }

  @override
  Future<void> clearFile(String sessionId, String fileId) {
    final key = _keyFor(sessionId, fileId);
    return _locked(key, () async {
      final box = await _open();
      await box.delete(key);
    });
  }

  @override
  Future<void> clearSession(String sessionId) async {
    final box = await _open();
    final prefix = '$sessionId::';
    final keys =
        box.keys.where((k) => k.toString().startsWith(prefix)).toList();
    await box.deleteAll(keys);
  }

  @override
  Future<List<FileUploadProgress>> listSession(String sessionId) async {
    final box = await _open();
    final prefix = '$sessionId::';
    final out = <FileUploadProgress>[];
    for (final k in box.keys) {
      if (!k.toString().startsWith(prefix)) continue;
      final p = _decode(box.get(k));
      if (p != null) out.add(p);
    }
    return out;
  }

  FileUploadProgress? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return FileUploadProgress.fromJson(jsonDecode(raw));
    } on FormatException {
      return null; // corrupt blob → start fresh
    }
  }
}

/// In-memory [UploadProgressStore] for unit tests (no Hive/disk).
class InMemoryUploadProgressStore implements UploadProgressStore {
  final Map<String, FileUploadProgress> _data = {};

  String _k(String s, String f) => '$s::$f';

  @override
  Future<FileUploadProgress?> get(String sessionId, String fileId) async =>
      _data[_k(sessionId, fileId)];

  @override
  Future<void> begin(
    String sessionId,
    String fileId, {
    required String uploadId,
    required String objectKey,
    required int totalParts,
    required int totalBytes,
  }) async {
    _data[_k(sessionId, fileId)] = FileUploadProgress(
      fileId: fileId,
      objectKey: objectKey,
      uploadId: uploadId,
      totalParts: totalParts,
      totalBytes: totalBytes,
      status: UploadStatus.inProgress,
    );
  }

  @override
  Future<void> recordPartComplete(
    String sessionId,
    String fileId, {
    required int partNumber,
    required String etag,
    required int offset,
  }) async {
    final key = _k(sessionId, fileId);
    final current =
        _data[key] ?? FileUploadProgress(fileId: fileId, objectKey: fileId);
    _data[key] = current.withPart(
      UploadPart(partNumber: partNumber, etag: etag),
      offset: offset,
    );
  }

  @override
  Future<void> markFileComplete(String sessionId, String fileId) async {
    final key = _k(sessionId, fileId);
    final current = _data[key];
    if (current != null) {
      _data[key] = current.copyWith(status: UploadStatus.completed);
    }
  }

  @override
  Future<void> clearFile(String sessionId, String fileId) async =>
      _data.remove(_k(sessionId, fileId));

  @override
  Future<void> clearSession(String sessionId) async {
    _data.removeWhere((k, _) => k.startsWith('$sessionId::'));
  }

  @override
  Future<List<FileUploadProgress>> listSession(String sessionId) async => [
        for (final e in _data.entries)
          if (e.key.startsWith('$sessionId::')) e.value,
      ];
}
