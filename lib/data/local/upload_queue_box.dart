// lib/data/local/upload_queue_box.dart
//
// The durable persistence layer for the OFFLINE UPLOAD QUEUE — the P2
// offline-outbox durability pattern applied to upload jobs. One JSON entry per
// job in a `Box<String>` (repo convention: [openStringBoxSafely], NO
// TypeAdapters). [UploadQueueStore] is the clean, testable API the
// [OfflineUploadQueue] coordinator reads/writes; [InMemoryUploadQueueStore] is
// the unit-test fake.
//
// This box holds the QUEUE bookkeeping (which jobs wait, their state + order +
// re-runnable spec). The byte-level resume point (uploadId/ETags/offset) lives
// in the separate `upload_progress` box — the two are keyed by the same
// sessionId and cleared together on cancel.
//
// CORRUPTION POLICY (matches the other gateways): an absent/unparseable entry is
// skipped (treated as absent); [list]/[get] never throw. Writes for the SAME job
// are serialized via a per-key lock (mirrors HiveUploadProgressStore) so a state
// transition can't clobber a concurrent one.
import 'dart:convert';

import 'package:hive/hive.dart';

import '../../domain/upload/upload_queue_entry.dart';
import 'box_names.dart';
import 'hive_init.dart';

/// The persistence API the offline upload queue depends on. Injectable so the
/// coordinator is unit-testable with [InMemoryUploadQueueStore].
abstract interface class UploadQueueStore {
  /// Every persisted entry, in FIFO ([UploadQueueEntry.seq]-ascending) order.
  /// Corrupt entries are skipped, never thrown.
  Future<List<UploadQueueEntry>> list();

  /// The persisted entry for [jobId], or null when absent/corrupt.
  Future<UploadQueueEntry?> get(String jobId);

  /// Inserts or replaces [entry] (keyed by its jobId).
  Future<void> put(UploadQueueEntry entry);

  /// Removes one job's entry (complete/cancel). Idempotent.
  Future<void> remove(String jobId);
}

/// Hive-backed [UploadQueueStore]. One JSON entry per jobId.
class HiveUploadQueueStore implements UploadQueueStore {
  HiveUploadQueueStore();

  Box<String>? _box;
  Future<Box<String>>? _opening;

  /// Per-key write lock so concurrent transitions for one job serialize.
  final Map<String, Future<void>> _locks = {};

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??= openStringBoxSafely(BoxNames.uploadQueue).then((box) {
      _box = box;
      _opening = null;
      return box;
    });
  }

  Future<T> _locked<T>(String key, Future<T> Function() action) {
    final prev = _locks[key] ?? Future<void>.value();
    final result = prev.then((_) => action());
    _locks[key] = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<List<UploadQueueEntry>> list() async {
    final box = await _open();
    final out = <UploadQueueEntry>[];
    for (final k in box.keys) {
      final e = _decode(box.get(k));
      if (e != null) out.add(e);
    }
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }

  @override
  Future<UploadQueueEntry?> get(String jobId) async {
    final box = await _open();
    return _decode(box.get(jobId));
  }

  @override
  Future<void> put(UploadQueueEntry entry) => _locked(entry.jobId, () async {
        final box = await _open();
        await box.put(entry.jobId, jsonEncode(entry.toJson()));
      });

  @override
  Future<void> remove(String jobId) => _locked(jobId, () async {
        final box = await _open();
        await box.delete(jobId);
      });

  UploadQueueEntry? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return UploadQueueEntry.fromJson(Map<String, Object?>.from(decoded));
    } on FormatException {
      return null; // corrupt blob → treated as absent
    }
  }
}

/// In-memory [UploadQueueStore] for unit tests (no Hive/disk).
class InMemoryUploadQueueStore implements UploadQueueStore {
  final Map<String, UploadQueueEntry> _data = {};

  @override
  Future<List<UploadQueueEntry>> list() async =>
      _data.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));

  @override
  Future<UploadQueueEntry?> get(String jobId) async => _data[jobId];

  @override
  Future<void> put(UploadQueueEntry entry) async => _data[entry.jobId] = entry;

  @override
  Future<void> remove(String jobId) async => _data.remove(jobId);
}
