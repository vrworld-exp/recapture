// lib/data/repositories/catalog_failure.dart
import 'package:dio/dio.dart';

/// Stable error codes the `/catalog` endpoints return in the house envelope
/// (`{status:"error", code:"<UPPER_SNAKE>", message:"..."}`).
///
/// Only the ones a screen actually branches on are named. Anything else keeps
/// its raw string on [CatalogFailure.code] — the goal is a decidable switch, not
/// an exhaustive mirror of the backend that goes stale.
abstract final class CatalogErrorCodes {
  /// The caller has no catalog yet — the first-run state, not a failure.
  static const noCatalog = 'CATALOG_NOT_FOUND';

  /// Also used for a product/category that is missing OR belongs to someone
  /// else: the API makes those indistinguishable on purpose, and the client must
  /// not try to tell them apart either.
  static const notFound = 'NOT_FOUND';

  static const categoryNotFound = 'CATEGORY_NOT_FOUND';
  static const modelNotFound = 'MODEL_NOT_FOUND';
  static const modelNotReady = 'MODEL_NOT_READY';

  /// Mirage keys items by name within a restaurant, so the backend refuses a
  /// duplicate here rather than letting publish fail later.
  static const duplicateName = 'DUPLICATE_NAME';

  /// Another business already holds this catalog's name on Mirage. Arrives two
  /// ways — a synchronous 409 from `POST /catalog/publish`, and (since the run
  /// carries its real error) as a RUN-level error code on the publish status —
  /// and both offer the same one-tap rename.
  static const catalogNameTaken = 'CATALOG_NAME_TAKEN';

  /// Too many requests in the window. The envelope carries `retryAfter` and the
  /// response a `Retry-After` header; see [CatalogFailure.retryAfterSeconds].
  static const rateLimited = 'RATE_LIMITED';

  /// The client's id set no longer matches the server's — reload and retry.
  static const idSetMismatch = 'ID_SET_MISMATCH';

  static const invalidRequest = 'INVALID_REQUEST';

  /// The three 409s a trial start can answer. The server's sentence is the
  /// one to show; these exist so a screen can tell "already used" (nothing
  /// to do) from "active" (nothing to do either, but the chip should refresh).
  static const trialAlreadyUsed = 'TRIAL_ALREADY_USED';
  static const subscriptionActive = 'SUBSCRIPTION_ACTIVE';
  static const trialNotEligible = 'TRIAL_NOT_ELIGIBLE';

  /// Mirage could not be reached for a report. A DEGRADATION, not a failure:
  /// nothing the user did is wrong, nothing has been lost, and only the report
  /// is missing — the dashboard branches on this to render a soft empty state
  /// with a retry rather than an error.
  static const analyticsUnavailable = 'ANALYTICS_UNAVAILABLE';
}

/// A `/catalog` request that failed, translated out of Dio at the repository
/// boundary so notifiers and screens never touch [DioException].
///
/// [message] is the server's own copy where there was one — the backend writes
/// owner-safe sentences and never passes Mirage's prose through, so it is safe
/// to show. [code] is what UI logic should branch on.
class CatalogFailure implements Exception {
  const CatalogFailure({
    required this.code,
    required this.message,
    this.statusCode,
    this.isOffline = false,
    this.retryAfterSeconds,
  });

  /// The envelope's `code`, or a local sentinel when the request never got an
  /// envelope back (`OFFLINE`, `UNKNOWN`).
  final String code;

  final String message;

  /// The HTTP status, when there was a response at all.
  final int? statusCode;

  /// Transport failure — no connection, DNS, or a timeout. Worth its own flag
  /// because the retry affordance differs: nothing the user typed was wrong.
  final bool isOffline;

  /// How long to wait before trying again, in seconds, from a 429.
  ///
  /// Null when the server did not say, or said it in a shape we do not read.
  /// The copy layer treats null as "we do not know" and falls back to the
  /// generic `RATE_LIMITED` sentence rather than inventing a number — see
  /// `retryAfterAction`.
  final int? retryAfterSeconds;

  bool get isNoCatalog => code == CatalogErrorCodes.noCatalog;
  bool get isAnalyticsUnavailable =>
      code == CatalogErrorCodes.analyticsUnavailable;
  bool get isNotFound => code == CatalogErrorCodes.notFound;
  bool get isDuplicateName => code == CatalogErrorCodes.duplicateName;

  /// A trial refusal of any of the three kinds — a 409 with a sentence worth
  /// showing, not an error worth retrying.
  bool get isTrialRefused =>
      code == CatalogErrorCodes.trialAlreadyUsed ||
      code == CatalogErrorCodes.subscriptionActive ||
      code == CatalogErrorCodes.trialNotEligible;

  @override
  String toString() => 'CatalogFailure($code): $message';

  /// Translates a Dio error into a [CatalogFailure], reading the house envelope
  /// when the server sent one.
  ///
  /// A non-envelope body (a proxy's HTML error page, a 502 from the platform) is
  /// deliberately NOT surfaced verbatim — the user gets one plain sentence
  /// instead of somebody else's stack trace.
  factory CatalogFailure.fromDio(DioException error) {
    final response = error.response;
    final body = response?.data;
    final retryAfter = _retryAfterFrom(error);

    if (body is Map) {
      final code = body['code'];
      final message = body['message'];
      if (code is String && code.isNotEmpty) {
        return CatalogFailure(
          code: code,
          message: message is String && message.trim().isNotEmpty
              ? message.trim()
              : _fallbackMessage,
          statusCode: response?.statusCode,
          retryAfterSeconds: retryAfter,
        );
      }
    }

    final offline = switch (error.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        true,
      _ => false,
    };

    return CatalogFailure(
      code: offline ? 'OFFLINE' : 'UNKNOWN',
      message: offline
          ? "You're offline — check your connection and try again."
          : _fallbackMessage,
      statusCode: response?.statusCode,
      isOffline: offline,
      retryAfterSeconds: retryAfter,
    );
  }

  /// The wait a 429 asked for, in seconds.
  ///
  /// TWO SOURCES, HEADER FIRST. `Retry-After` is the standard one and survives
  /// anything in the path that speaks HTTP but not our envelope; the envelope's
  /// own `retryAfter` is what this API has sent all along and is the fallback.
  /// An HTTP-date is legal in the header and is deliberately NOT parsed — we
  /// take an integer or nothing, because a half-understood date would put a
  /// wrong number in a sentence, which is worse than the generic one.
  static int? _retryAfterFrom(DioException error) {
    final response = error.response;
    if (response == null) return null;

    final header = response.headers.value('retry-after');
    final fromHeader = header == null ? null : int.tryParse(header.trim());
    if (fromHeader != null && fromHeader > 0) return fromHeader;

    final body = response.data;
    if (body is Map) {
      final value = body['retryAfter'];
      if (value is int && value > 0) return value;
      if (value is num && value > 0) return value.round();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    return null;
  }

  static const _fallbackMessage = 'Something went wrong. Please try again.';
}

/// Runs [request] and rethrows any [DioException] as a [CatalogFailure].
///
/// Every catalog repository method funnels through this, so there is ONE place
/// where HTTP becomes a domain error — the AGENTS.md rule that repositories own
/// all HTTP and error translation.
Future<T> mapCatalogErrors<T>(Future<T> Function() request) async {
  try {
    return await request();
  } on DioException catch (error) {
    throw CatalogFailure.fromDio(error);
  }
}
