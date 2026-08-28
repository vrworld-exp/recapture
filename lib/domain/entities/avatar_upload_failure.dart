// lib/domain/entities/avatar_upload_failure.dart
//
// Pure Dart — why a profile-picture change failed, as a CLOSED set the UI maps
// to copy. Lives in the domain layer so the repository (which owns the HTTP and
// the error translation) and the screen (which owns the wording) can share it
// without either depending on the other.
//
// The rule this exists to enforce is the Screen-9F convention: a raw transport
// error — a DioException, an S3 XML body, a stack trace — NEVER reaches
// user-facing copy. The repository maps everything to one of these; the screen
// maps each of these to a sentence. Nothing else is allowed through.

/// Why an avatar upload or removal failed.
enum AvatarUploadFailure {
  /// The image exceeded the server's byte ceiling (a 413 at commit time). Rare
  /// in practice — the picker downscales to 512×512 first — but reachable with
  /// a pathological source image.
  tooLarge,

  /// The chosen file is not a JPEG or PNG. Decided LOCALLY from the file's
  /// magic bytes before anything is uploaded, so the user is told immediately
  /// rather than after a round trip.
  unsupportedType,

  /// The per-user upload window is exhausted (a 429).
  rateLimited,

  /// Offline, a timeout, or any other transport failure — including a failed
  /// PUT straight to S3.
  network,

  /// Anything else, including a server 5xx and an unexpected response shape.
  /// The catch-all exists so the UI never has to render an unmapped error.
  unknown,
}

/// The failure a repository throws so it can carry a [AvatarUploadFailure]
/// without leaking the underlying transport exception into UI code.
///
/// [cause] is retained for logging/debugging ONLY — the screen must map
/// [reason] to copy and must never render [cause] or [toString].
class AvatarUploadException implements Exception {
  const AvatarUploadException(this.reason, [this.cause]);

  final AvatarUploadFailure reason;
  final Object? cause;

  @override
  String toString() => 'AvatarUploadException($reason)';
}
