// lib/data/local/pending_capture_box.dart
//
// Durable store for finished captures waiting for upload ([PendingCapture]).
// One JSON record per capture in a `Box<String>` keyed by `localId` (repo
// convention: [openStringBoxSafely], NO TypeAdapters). [PendingCaptureStore] is
// the API the pending-captures notifier and the upload coordinator depend on;
// [InMemoryPendingCaptureStore] is the unit-test fake.
//
// CORRUPTION POLICY (matches the other gateways): an unparseable record is
// skipped, never thrown — [list]/[get] cannot crash the Projects screen. Writes
// for the same capture are serialized through a per-key lock (as in
// HiveUploadQueueStore) so a state transition cannot clobber a concurrent one.
//
// NOT CLEARED ON LOGOUT. Every read takes the owner and filters on it; the
// records stay on the phone for their owner (see BoxNames.pendingCaptures).
import 'dart:convert';

import 'package:hive/hive.dart';

import '../../domain/upload/pending_capture.dart';
import 'box_names.dart';
import 'hive_init.dart';

abstract interface class PendingCaptureStore {
  /// [ownerUserId]'s pending captures, oldest first. Corrupt records are
  /// skipped. A null/empty owner gets an empty list.
  Future<List<PendingCapture>> listFor(String? ownerUserId);

  /// The record for [localId] (any owner), or null when absent/corrupt.
  Future<PendingCapture?> get(String localId);

  /// Inserts or replaces [capture] (keyed by its localId).
  Future<void> put(PendingCapture capture);

  /// Removes one record. Idempotent.
  Future<void> remove(String localId);
}

class HivePendingCaptureStore implements PendingCaptureStore {
  HivePendingCaptureStore();

  Box<String>? _box;
  Future<Box<String>>? _opening;
  final Map<String, Future<void>> _locks = {};

  Future<Box<String>> _open() {
    final existing = _box;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??=
        openStringBoxSafely(BoxNames.pendingCaptures).then((box) {
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
  Future<List<PendingCapture>> listFor(String? ownerUserId) async {
    if (ownerUserId == null || ownerUserId.isEmpty) return const [];
    final box = await _open();
    final all = <PendingCapture>[];
    for (final k in box.keys) {
      if (k == BoxSchema.versionKey) continue;
      final c = _decode(box.get(k));
      if (c != null) all.add(c);
    }
    return pendingCapturesOwnedBy(all, ownerUserId);
  }

  @override
  Future<PendingCapture?> get(String localId) async {
    if (localId == BoxSchema.versionKey) return null;
    final box = await _open();
    return _decode(box.get(localId));
  }

  @override
  Future<void> put(PendingCapture capture) => _locked(capture.localId, () async {
        final box = await _open();
        await box.put(capture.localId, jsonEncode(capture.toJson()));
      });

  @override
  Future<void> remove(String localId) => _locked(localId, () async {
        final box = await _open();
        await box.delete(localId);
      });

  static PendingCapture? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return PendingCapture.fromJson(Map<String, Object?>.from(decoded));
    } catch (_) {
      return null; // corrupt / wrongly-typed blob → treated as absent
    }
  }
}

/// In-memory [PendingCaptureStore] for unit tests (no Hive/disk).
class InMemoryPendingCaptureStore implements PendingCaptureStore {
  final Map<String, PendingCapture> _data = {};

  @override
  Future<List<PendingCapture>> listFor(String? ownerUserId) async =>
      pendingCapturesOwnedBy(_data.values, ownerUserId);

  @override
  Future<PendingCapture?> get(String localId) async => _data[localId];

  @override
  Future<void> put(PendingCapture capture) async =>
      _data[capture.localId] = capture;

  @override
  Future<void> remove(String localId) async => _data.remove(localId);
}
