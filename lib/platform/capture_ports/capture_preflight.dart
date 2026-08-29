// lib/platform/capture_ports/capture_preflight.dart
//
// The capability probe that runs BEFORE the capture screen mounts.
//
// It exists because of one specific failure the web build can produce and the
// native builds cannot: a user shoots 30 photos and only then discovers that
// this browser, on this connection, could never have finished the job — no
// secure context, no environment camera, motion access denied on a mode that
// hard-gates on tilt, or an IndexedDB quota too small to hold the bundle.
// Learning that in one screen at the start is the entire point.
//
// Natively the probe is trivially "supported": the permission flow and the
// native camera manager already own these questions, and nothing about
// Android/iOS behaviour changes.
import '../../domain/capture/capture_mode.dart';

import 'capture_preflight_stub.dart'
    if (dart.library.io) 'capture_preflight_io.dart'
    if (dart.library.js_interop) 'capture_preflight_web.dart';

/// One capability the capture flow needs.
enum CaptureCapability {
  /// A secure context (HTTPS or localhost). `getUserMedia` and the motion
  /// sensors are secure-context APIs — over plain HTTP they are not merely
  /// blocked, they are absent, which is why this is checked first and reported
  /// by name.
  secureContext,

  /// `getUserMedia` plus at least one camera. Required by BOTH modes.
  camera,

  /// Granted device-orientation events. REQUIRED for `meshy` (its tilt gate is
  /// a hard gate by design), OPTIONAL for `full` (which fails open with the
  /// existing "guidance unavailable" note).
  motionSensors,

  /// A writable local store for captured frames.
  localStorage,

  /// Enough remaining quota for the expected bundle.
  storageQuota,
}

extension CaptureCapabilityLabel on CaptureCapability {
  /// Short, user-facing name — the probe names the MISSING capability rather
  /// than saying "capture is unavailable".
  String get label => switch (this) {
        CaptureCapability.secureContext => 'A secure (HTTPS) connection',
        CaptureCapability.camera => 'Camera access',
        CaptureCapability.motionSensors => 'Motion & orientation access',
        CaptureCapability.localStorage => 'Local photo storage',
        CaptureCapability.storageQuota => 'Free storage space',
      };
}

/// One capability's verdict.
class CaptureCapabilityResult {
  const CaptureCapabilityResult({
    required this.capability,
    required this.available,
    required this.required_,
    this.detail,
  });

  final CaptureCapability capability;
  final bool available;

  /// Whether this capability BLOCKS capture in the mode being probed. Named
  /// with a trailing underscore because `required` is a Dart keyword.
  final bool required_;

  /// A specific, user-facing explanation of what is wrong and what to do.
  final String? detail;

  bool get blocks => required_ && !available;
}

/// The probe's verdict for one capture mode.
class CapturePreflightReport {
  const CapturePreflightReport(this.results);

  /// Nothing to check — the native path.
  static const CapturePreflightReport allClear =
      CapturePreflightReport(<CaptureCapabilityResult>[]);

  final List<CaptureCapabilityResult> results;

  /// The blocking capabilities, in declaration order (secure context first, so
  /// the root cause is named before its downstream symptoms).
  List<CaptureCapabilityResult> get blockers =>
      results.where((r) => r.blocks).toList();

  bool get canCapture => blockers.isEmpty;

  /// Capabilities that are missing but do NOT block — `full` mode without
  /// motion sensors is the real case: capture proceeds, guidance does not.
  List<CaptureCapabilityResult> get degradations =>
      results.where((r) => !r.available && !r.required_).toList();
}

/// Whether this platform has anything to probe at all.
///
/// False everywhere but web, and the gate short-circuits on it so a native
/// build renders the capture screen SYNCHRONOUSLY — no extra frame, no
/// FutureBuilder, no change to what an existing widget test sees after its
/// first `pump()`.
const bool isCapturePreflightRequired = capturePreflightRequired;

/// Probes the capabilities [mode] needs.
///
/// [expectedPhotoCount] and [estimatedBytesPerPhoto] size the quota check
/// against the job the user is about to start, not against a guess — a Meshy
/// session needs room for 6 photos, a full session for 48.
Future<CapturePreflightReport> runCapturePreflight({
  required CaptureMode mode,
  required int expectedPhotoCount,
  int estimatedBytesPerPhoto = kEstimatedBytesPerPhoto,
}) =>
    probeCaptureCapabilities(
      mode: mode,
      expectedPhotoCount: expectedPhotoCount,
      estimatedBytesPerPhoto: estimatedBytesPerPhoto,
    );

/// Rough per-photo budget for the quota check: a 1920-wide JPEG at quality 90
/// lands around 1.5 MB, and the check is deliberately generous rather than
/// exact — a preflight that lets a doomed job start is worse than one that asks
/// the user to free some space.
const int kEstimatedBytesPerPhoto = 2 * 1024 * 1024;
