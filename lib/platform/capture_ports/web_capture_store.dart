// lib/platform/capture_ports/web_capture_store.dart
//
// WEB ONLY (imported exclusively from `*_web.dart` port implementations).
//
// The browser's stand-in for the native app-scoped capture tree
// (`/recapture/{projectId}/{jobId}/images/{level}/`): an IndexedDB database with
// the SAME hierarchy encoded in the key, so every accounting, listing and
// deletion rule the native CaptureStorage enforces has a direct equivalent —
// including the **active-job delete guard** the project-deletion cleanup hook
// depends on (`StorageDeleteResult.code == 'active_job'` /
// `PurgeResult.status == 'refused'`).
//
// Two stores:
//   frames  key `{projectId}/{jobId}/{level}/{frameId}` → the JPEG Blob + its
//           metadata. Indexed by `projectId`, `jobKey` and `levelKey` so a
//           scoped usage/delete is an index range scan, never a full sweep.
//   jobs    key `{projectId}/{jobId}` → whether the job is actively capturing
//           and whether its manifest was finalized. This is what makes
//           "incomplete job" and "active job" answerable at all.
//
// Memory rule (the one that decides whether 48 photos work on a low-end phone):
// a captured frame is written to IndexedDB **immediately** and only its handle
// is kept in Dart. Nothing here ever holds more than one frame's bytes, and
// reads hand back a Blob the caller slices.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Database + store names. Bumping [_dbVersion] runs `onupgradeneeded`.
const String _dbName = 'recapture_capture_store';
const int _dbVersion = 1;
const String _framesStore = 'frames';
const String _jobsStore = 'jobs';

/// The URI scheme captured frames are addressed by on web. It is an opaque
/// handle, not a filesystem path: `CapturedFrame.path` carries it, the ledger
/// and the manifest plan pass it around untouched, and only
/// [WebCaptureStore.readBytes] resolves it.
const String kWebCaptureScheme = 'idb://';

/// One stored frame's metadata (never its bytes).
class WebFrameEntry {
  const WebFrameEntry({
    required this.key,
    required this.projectId,
    required this.jobId,
    required this.level,
    required this.frameId,
    required this.byteCount,
    required this.capturedAtMs,
    required this.timestampNs,
  });

  final String key;
  final String projectId;
  final String jobId;
  final String level;
  final String frameId;
  final int byteCount;
  final int capturedAtMs;
  final int timestampNs;

  /// The opaque handle stored in `CapturedFrame.path`.
  String get path => '$kWebCaptureScheme$key';
}

/// Where the next captured frame belongs. Native derives this itself from the
/// session it owns; the browser has no such session, so the capture flow sets it
/// (see `CaptureStorageClient.setActiveScope`) and it is a no-op on native.
class CaptureScope {
  const CaptureScope({
    required this.projectId,
    required this.jobId,
    required this.level,
  });

  static const CaptureScope unassigned = CaptureScope(
    projectId: 'unassigned',
    jobId: 'unassigned',
    level: 'EYE',
  );

  final String projectId;
  final String jobId;
  final String level;
}

/// IndexedDB-backed capture store.
class WebCaptureStore {
  WebCaptureStore._();

  static final WebCaptureStore instance = WebCaptureStore._();

  Future<web.IDBDatabase>? _db;

  /// Where the next captured frame belongs; set by the capture flow through
  /// `CaptureStorageClient.setActiveScope`.
  CaptureScope scope = CaptureScope.unassigned;

  Future<web.IDBDatabase> _open() => _db ??= _openDatabase();

  static Future<web.IDBDatabase> _openDatabase() {
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_dbName, _dbVersion);
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_framesStore)) {
        final frames = db.createObjectStore(
          _framesStore,
          web.IDBObjectStoreParameters(keyPath: 'key'.toJS),
        );
        frames.createIndex('projectId', 'projectId'.toJS);
        frames.createIndex('jobKey', 'jobKey'.toJS);
        frames.createIndex('levelKey', 'levelKey'.toJS);
      }
      if (!db.objectStoreNames.contains(_jobsStore)) {
        final jobs = db.createObjectStore(
          _jobsStore,
          web.IDBObjectStoreParameters(keyPath: 'key'.toJS),
        );
        jobs.createIndex('projectId', 'projectId'.toJS);
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.complete(request.result as web.IDBDatabase);
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('IndexedDB is unavailable: ${request.error?.message}'),
        );
      }
    }).toJS;
    return completer.future;
  }

  /// Whether IndexedDB can actually be opened AND written in this context —
  /// the preflight probe's check. Private-mode Safari and some embedded
  /// WebViews expose `indexedDB` but reject every write.
  Future<bool> isWritable() async {
    try {
      final db = await _open();
      final tx = db.transaction(_jobsStore.toJS, 'readwrite');
      final store = tx.objectStore(_jobsStore);
      const probeKey = '__probe__/__probe__';
      await _request<JSAny?>(store.put(
        _jobRecord(
          key: probeKey,
          projectId: '__probe__',
          jobId: '__probe__',
          active: false,
          manifestComplete: true,
        ),
      ));
      await _request<JSAny?>(store.delete(probeKey.toJS));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// `{usage, quota}` from `navigator.storage.estimate()`, or nulls when the
  /// API is absent (older Safari). Used for the pre-capture free-space check
  /// native performs with `StatFs`.
  Future<({int? usage, int? quota})> estimate() async {
    try {
      final storage = web.window.navigator.storage;
      final estimate = await storage.estimate().toDart;
      return (usage: estimate.usage, quota: estimate.quota);
    } catch (_) {
      return (usage: null, quota: null);
    }
  }

  /// Writes one captured frame and marks its job active. Returns the handle.
  Future<WebFrameEntry> writeFrame({
    required String frameId,
    required Uint8List bytes,
    required int timestampNs,
    CaptureScope? scope,
  }) async {
    final s = scope ?? this.scope;
    final key = frameKey(s.projectId, s.jobId, s.level, frameId);
    final db = await _open();
    final tx = db.transaction(
      <JSString>[_framesStore.toJS, _jobsStore.toJS].toJS,
      'readwrite',
    );
    final blob = web.Blob(
      <JSUint8Array>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'image/jpeg'),
    );
    final capturedAtMs = DateTime.now().millisecondsSinceEpoch;
    final record = JSObject()
      ..setProperty('key'.toJS, key.toJS)
      ..setProperty('projectId'.toJS, s.projectId.toJS)
      ..setProperty('jobId'.toJS, s.jobId.toJS)
      ..setProperty('jobKey'.toJS, jobKey(s.projectId, s.jobId).toJS)
      ..setProperty('level'.toJS, s.level.toJS)
      ..setProperty(
          'levelKey'.toJS, levelKey(s.projectId, s.jobId, s.level).toJS)
      ..setProperty('frameId'.toJS, frameId.toJS)
      ..setProperty('bytes'.toJS, blob)
      ..setProperty('byteCount'.toJS, bytes.length.toJS)
      ..setProperty('capturedAtMs'.toJS, capturedAtMs.toJS)
      ..setProperty('timestampNs'.toJS, timestampNs.toJS);
    await _request<JSAny?>(tx.objectStore(_framesStore).put(record));
    await _touchJob(tx.objectStore(_jobsStore), s.projectId, s.jobId);
    return WebFrameEntry(
      key: key,
      projectId: s.projectId,
      jobId: s.jobId,
      level: s.level,
      frameId: frameId,
      byteCount: bytes.length,
      capturedAtMs: capturedAtMs,
      timestampNs: timestampNs,
    );
  }

  /// Resolves an `idb://…` handle (or a bare key) to its bytes; null if gone.
  Future<Uint8List?> readBytes(String pathOrKey) async {
    final blob = await readBlob(pathOrKey);
    if (blob == null) return null;
    final buffer = await blob.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  /// Resolves a handle to its Blob WITHOUT reading it into memory — the entry
  /// point the streaming MD5 and the multipart part reader slice.
  Future<web.Blob?> readBlob(String pathOrKey) async {
    final key = keyOf(pathOrKey);
    final db = await _open();
    final tx = db.transaction(_framesStore.toJS, 'readonly');
    final record =
        await _request<JSAny?>(tx.objectStore(_framesStore).get(key.toJS));
    if (record == null || !record.isA<JSObject>()) return null;
    final blob = (record as JSObject).getProperty<JSAny?>('bytes'.toJS);
    return blob.isA<web.Blob>() ? blob as web.Blob : null;
  }

  /// Every frame in a scope, oldest-first. [jobId]/[level] narrow it.
  Future<List<WebFrameEntry>> listFrames(
    String projectId, {
    String? jobId,
    String? level,
  }) async {
    final db = await _open();
    final tx = db.transaction(_framesStore.toJS, 'readonly');
    final store = tx.objectStore(_framesStore);
    final JSAny? raw;
    if (jobId != null && level != null) {
      raw = await _request<JSAny?>(store
          .index('levelKey')
          .getAll(levelKey(projectId, jobId, level).toJS));
    } else if (jobId != null) {
      raw = await _request<JSAny?>(
          store.index('jobKey').getAll(jobKey(projectId, jobId).toJS));
    } else {
      raw = await _request<JSAny?>(
          store.index('projectId').getAll(projectId.toJS));
    }
    final out = <WebFrameEntry>[];
    for (final item in _toList(raw)) {
      final entry = _entryOf(item);
      if (entry != null) out.add(entry);
    }
    out.sort((a, b) => a.capturedAtMs.compareTo(b.capturedAtMs));
    return out;
  }

  /// Distinct project ids that hold capture data.
  Future<List<String>> listProjects() async {
    final db = await _open();
    final tx = db.transaction(_jobsStore.toJS, 'readonly');
    final raw = await _request<JSAny?>(tx.objectStore(_jobsStore).getAll());
    final ids = <String>{};
    for (final item in _toList(raw)) {
      final id = _stringProp(item, 'projectId');
      if (id != null) ids.add(id);
    }
    return ids.toList()..sort();
  }

  /// Job ids recorded for [projectId].
  Future<List<String>> listJobs(String projectId) async {
    final jobs = await _jobsFor(projectId);
    return jobs.map((j) => j.jobId).toList()..sort();
  }

  /// Jobs that never finalized a manifest — resumable or cleanable.
  Future<List<({String projectId, String jobId, String reason})>>
      listIncompleteJobs() async {
    final db = await _open();
    final tx = db.transaction(_jobsStore.toJS, 'readonly');
    final raw = await _request<JSAny?>(tx.objectStore(_jobsStore).getAll());
    final out = <({String projectId, String jobId, String reason})>[];
    for (final item in _toList(raw)) {
      final job = _jobOf(item);
      if (job == null || job.manifestComplete) continue;
      out.add((
        projectId: job.projectId,
        jobId: job.jobId,
        // Mirrors the native vocabulary: a job still marked active was
        // interrupted mid-capture; one that is idle has data but no manifest.
        reason: job.active ? 'in_progress' : 'no_manifest',
      ));
    }
    return out;
  }

  /// Marks a job as actively capturing (or not). The delete guard reads this.
  Future<void> setJobActive(
    String projectId,
    String jobId, {
    required bool active,
  }) async {
    final db = await _open();
    final tx = db.transaction(_jobsStore.toJS, 'readwrite');
    await _touchJob(tx.objectStore(_jobsStore), projectId, jobId,
        active: active);
  }

  /// Records that a job's manifest was finalized (so it stops being reported
  /// as incomplete) and clears its active flag.
  Future<void> markJobComplete(String projectId, String jobId) async {
    final db = await _open();
    final tx = db.transaction(_jobsStore.toJS, 'readwrite');
    await _touchJob(
      tx.objectStore(_jobsStore),
      projectId,
      jobId,
      active: false,
      manifestComplete: true,
    );
  }

  /// Deletes every frame in a scope. Returns `(filesDeleted, bytesFreed)`.
  Future<({int files, int bytes})> deleteFrames(
    String projectId, {
    String? jobId,
    String? level,
  }) async {
    final entries = await listFrames(projectId, jobId: jobId, level: level);
    if (entries.isEmpty) return (files: 0, bytes: 0);
    final db = await _open();
    final tx = db.transaction(_framesStore.toJS, 'readwrite');
    final store = tx.objectStore(_framesStore);
    var bytes = 0;
    for (final e in entries) {
      await _request<JSAny?>(store.delete(e.key.toJS));
      bytes += e.byteCount;
    }
    return (files: entries.length, bytes: bytes);
  }

  /// Deletes the job rows for a scope (after its frames are gone).
  Future<void> deleteJobRows(String projectId, {String? jobId}) async {
    final jobs = await _jobsFor(projectId);
    final db = await _open();
    final tx = db.transaction(_jobsStore.toJS, 'readwrite');
    final store = tx.objectStore(_jobsStore);
    for (final job in jobs) {
      if (jobId != null && job.jobId != jobId) continue;
      await _request<JSAny?>(store.delete(jobKey(projectId, job.jobId).toJS));
    }
  }

  /// Whether any job in the scope is currently capturing — the delete guard.
  Future<bool> hasActiveJob(String projectId, {String? jobId}) async {
    final jobs = await _jobsFor(projectId);
    return jobs.any((j) => j.active && (jobId == null || j.jobId == jobId));
  }

  // ── key helpers (the encoded native folder hierarchy) ──────────────────────

  static String frameKey(
    String projectId,
    String jobId,
    String level,
    String frameId,
  ) =>
      '$projectId/$jobId/$level/$frameId.jpg';

  static String jobKey(String projectId, String jobId) => '$projectId/$jobId';

  static String levelKey(String projectId, String jobId, String level) =>
      '$projectId/$jobId/$level';

  /// Strips the `idb://` scheme from a handle, leaving the store key.
  static String keyOf(String pathOrKey) =>
      pathOrKey.startsWith(kWebCaptureScheme)
          ? pathOrKey.substring(kWebCaptureScheme.length)
          : pathOrKey;

  // ── internals ─────────────────────────────────────────────────────────────

  Future<
      List<
          ({
            String projectId,
            String jobId,
            bool active,
            bool manifestComplete
          })>> _jobsFor(String projectId) async {
    final db = await _open();
    final tx = db.transaction(_jobsStore.toJS, 'readonly');
    final raw = await _request<JSAny?>(
        tx.objectStore(_jobsStore).index('projectId').getAll(projectId.toJS));
    final out = <({
      String projectId,
      String jobId,
      bool active,
      bool manifestComplete
    })>[];
    for (final item in _toList(raw)) {
      final job = _jobOf(item);
      if (job != null) out.add(job);
    }
    return out;
  }

  Future<void> _touchJob(
    web.IDBObjectStore store,
    String projectId,
    String jobId, {
    bool active = true,
    bool? manifestComplete,
  }) async {
    final key = jobKey(projectId, jobId);
    final existing = await _request<JSAny?>(store.get(key.toJS));
    final wasComplete = existing != null && existing.isA<JSObject>()
        ? _boolProp(existing, 'manifestComplete') ?? false
        : false;
    await _request<JSAny?>(store.put(_jobRecord(
      key: key,
      projectId: projectId,
      jobId: jobId,
      active: active,
      manifestComplete: manifestComplete ?? wasComplete,
    )));
  }

  static JSObject _jobRecord({
    required String key,
    required String projectId,
    required String jobId,
    required bool active,
    required bool manifestComplete,
  }) =>
      JSObject()
        ..setProperty('key'.toJS, key.toJS)
        ..setProperty('projectId'.toJS, projectId.toJS)
        ..setProperty('jobId'.toJS, jobId.toJS)
        ..setProperty('active'.toJS, active.toJS)
        ..setProperty('manifestComplete'.toJS, manifestComplete.toJS);

  static WebFrameEntry? _entryOf(JSAny? item) {
    final key = _stringProp(item, 'key');
    final projectId = _stringProp(item, 'projectId');
    final jobId = _stringProp(item, 'jobId');
    final level = _stringProp(item, 'level');
    final frameId = _stringProp(item, 'frameId');
    if (key == null ||
        projectId == null ||
        jobId == null ||
        level == null ||
        frameId == null) {
      return null;
    }
    return WebFrameEntry(
      key: key,
      projectId: projectId,
      jobId: jobId,
      level: level,
      frameId: frameId,
      byteCount: _intProp(item, 'byteCount') ?? 0,
      capturedAtMs: _intProp(item, 'capturedAtMs') ?? 0,
      timestampNs: _intProp(item, 'timestampNs') ?? 0,
    );
  }

  static ({String projectId, String jobId, bool active, bool manifestComplete})?
      _jobOf(JSAny? item) {
    final projectId = _stringProp(item, 'projectId');
    final jobId = _stringProp(item, 'jobId');
    if (projectId == null || jobId == null) return null;
    return (
      projectId: projectId,
      jobId: jobId,
      active: _boolProp(item, 'active') ?? false,
      manifestComplete: _boolProp(item, 'manifestComplete') ?? false,
    );
  }

  static List<JSAny?> _toList(JSAny? raw) {
    if (raw == null || !raw.isA<JSArray>()) return const [];
    return (raw as JSArray).toDart;
  }

  static String? _stringProp(JSAny? item, String name) {
    if (item == null || !item.isA<JSObject>()) return null;
    final v = (item as JSObject).getProperty<JSAny?>(name.toJS);
    return v.isA<JSString>() ? (v as JSString).toDart : null;
  }

  static int? _intProp(JSAny? item, String name) {
    if (item == null || !item.isA<JSObject>()) return null;
    final v = (item as JSObject).getProperty<JSAny?>(name.toJS);
    return v.isA<JSNumber>() ? (v as JSNumber).toDartInt : null;
  }

  static bool? _boolProp(JSAny? item, String name) {
    if (item == null || !item.isA<JSObject>()) return null;
    final v = (item as JSObject).getProperty<JSAny?>(name.toJS);
    return v.isA<JSBoolean>() ? (v as JSBoolean).toDart : null;
  }

  /// Bridges one `IDBRequest` to a Future, propagating its error rather than
  /// hanging (an over-quota `put` fails here, and the caller turns it into the
  /// storage error the capture flow already surfaces).
  static Future<T?> _request<T extends JSAny?>(web.IDBRequest request) {
    final completer = Completer<T?>();
    request.onsuccess = ((web.Event _) {
      if (completer.isCompleted) return;
      final result = request.result;
      completer.complete(result as T?);
    }).toJS;
    request.onerror = ((web.Event _) {
      if (completer.isCompleted) return;
      completer.completeError(
        StateError('IndexedDB request failed: ${request.error?.message}'),
      );
    }).toJS;
    return completer.future;
  }
}
