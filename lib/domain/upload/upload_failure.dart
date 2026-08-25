// lib/domain/upload/upload_failure.dart
//
// Pure Dart. The user-facing CLASSIFICATION of an upload failure — the substance
// of Screen 9F (Upload Failed). It maps whatever the upload pipeline surfaces (an
// exception off the progress stream, or a bare failed status) into a small, stable
// set of categories, each with a retryable flag and a MAPPED reference code.
//
// PRIVACY INVARIANT: nothing raw is carried here. The classifier reads only the
// TYPE/shape of the error (and an optional pipeline-provided category hint) — never
// its text — so no stack trace, server body, token, path, or PII can ride along to
// the UI. The raw detail is logged via diagnostics at the call site, not stored.
//
// This changes NONE of the pipeline's error generation: it is a read-only mapping
// the failure screen applies. A real pipeline can implement [UploadFailureSignal]
// to name its category directly (preferred over the type/text heuristics).
import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException, HttpException;

/// The stable, user-facing failure categories. `unknown` is the safe fallback for
/// anything unmapped (and for missing/garbled context).
enum UploadErrorCategory { network, server, auth, validation, quota, unknown }

/// Category-derived presentation facts. Kept in the domain (pure, testable); the
/// friendly COPY lives in the screen.
extension UploadErrorCategoryX on UploadErrorCategory {
  /// Analytics `error_category` value.
  String get wireName => switch (this) {
        UploadErrorCategory.network => 'network',
        UploadErrorCategory.server => 'server',
        UploadErrorCategory.auth => 'auth',
        UploadErrorCategory.validation => 'validation',
        UploadErrorCategory.quota => 'quota',
        UploadErrorCategory.unknown => 'unknown',
      };

  /// Whether re-attempting the SAME upload could plausibly succeed. Transient
  /// classes (network/server) and the safe generic fallback (unknown) are
  /// retryable; deterministic classes (auth/validation/quota) are not — Retry is
  /// hidden for those so the user isn't sent into a guaranteed re-failure.
  bool get retryable => switch (this) {
        UploadErrorCategory.network => true,
        UploadErrorCategory.server => true,
        UploadErrorCategory.unknown => true,
        UploadErrorCategory.auth => false,
        UploadErrorCategory.validation => false,
        UploadErrorCategory.quota => false,
      };

  /// A short MAPPED reference shown for support (never a raw error). Stable per
  /// category so it can be quoted without leaking anything.
  String get code => switch (this) {
        UploadErrorCategory.network => 'NET-01',
        UploadErrorCategory.server => 'SRV-01',
        UploadErrorCategory.auth => 'AUTH-01',
        UploadErrorCategory.validation => 'VAL-01',
        UploadErrorCategory.quota => 'QTA-01',
        UploadErrorCategory.unknown => 'UNK-01',
      };
}

/// An optional contract a pipeline error can implement to name its category
/// directly — authoritative over the type/text heuristics in [classifyUploadFailure].
abstract interface class UploadFailureSignal {
  UploadErrorCategory get uploadErrorCategory;
}

/// Maps a raw failure [error] to a [UploadErrorCategory] WITHOUT retaining any of
/// its detail. Precedence: an explicit [UploadFailureSignal] hint → well-known
/// exception types → conservative substring cues on the type's string form →
/// `unknown`. Never throws; `null`/unrecognised → `unknown` (safe generic).
UploadErrorCategory classifyUploadFailure(Object? error) {
  if (error == null) return UploadErrorCategory.unknown;

  // 1) Authoritative, pipeline-provided category.
  if (error is UploadFailureSignal) return error.uploadErrorCategory;

  // 2) Well-known transport exception types (no text inspected).
  if (error is SocketException || error is TimeoutException) {
    return UploadErrorCategory.network;
  }

  // 3) Conservative cues on the error's string form. We inspect it only to pick a
  //    bucket — nothing from it is stored or shown.
  final s = error.toString().toLowerCase();

  // Auth / session first (a 401/403 is deterministic, not a transient retry).
  if (s.contains('401') ||
      s.contains('403') ||
      s.contains('unauthor') || // unauthorized / unauthorised
      s.contains('forbidden') ||
      s.contains('token') ||
      s.contains('session expired')) {
    return UploadErrorCategory.auth;
  }
  // Quota / rate limit.
  if (s.contains('429') ||
      s.contains('quota') ||
      s.contains('too many requests') ||
      s.contains('limit exceeded')) {
    return UploadErrorCategory.quota;
  }
  // Validation / payload rejected.
  if (s.contains('400') ||
      s.contains('413') ||
      s.contains('422') ||
      s.contains('invalid') ||
      s.contains('corrupt') ||
      s.contains('rejected') ||
      s.contains('unprocessable')) {
    return UploadErrorCategory.validation;
  }
  // Server / transient (5xx, unavailable).
  if (error is HttpException ||
      s.contains('500') ||
      s.contains('502') ||
      s.contains('503') ||
      s.contains('504') ||
      s.contains('server error') ||
      s.contains('unavailable') ||
      s.contains('bad gateway') ||
      s.contains('gateway timeout')) {
    return UploadErrorCategory.server;
  }
  // Network cues that aren't a typed SocketException/TimeoutException.
  if (s.contains('socket') ||
      s.contains('network') ||
      s.contains('timeout') ||
      s.contains('timed out') ||
      s.contains('connection') ||
      s.contains('offline') ||
      s.contains('host') ||
      s.contains('dns')) {
    return UploadErrorCategory.network;
  }

  return UploadErrorCategory.unknown;
}
