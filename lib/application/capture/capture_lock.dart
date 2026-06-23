// lib/application/capture/capture_lock.dart
//
// A single in-flight guard shared across every capture path (manual tap +
// auto-capture trigger) so the two can never run overlapping captures against
// the one native capture resource. Dart's single-threaded event loop makes a
// plain boolean a correct mutex here: [tryAcquire] check-and-sets synchronously
// (before any `await`), so two callers cannot both acquire in the same
// microtask.
//
// Inject ONE instance into both AutoCaptureController and ManualCaptureController
// to make them mutually exclusive; omit it and each controller gets its own.
class CaptureLock {
  bool _busy = false;

  /// True while a capture is in flight (acquired and not yet released).
  bool get isBusy => _busy;

  /// Acquires the lock if free, returning true. Returns false if already held —
  /// the caller must NOT proceed with a capture.
  bool tryAcquire() {
    if (_busy) return false;
    _busy = true;
    return true;
  }

  /// Releases the lock. Idempotent.
  void release() => _busy = false;
}
