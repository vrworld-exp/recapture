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

  /// The client's id set no longer matches the server's — reload and retry.
  static const idSetMismatch = 'ID_SET_MISMATCH';

  static const invalidRequest = 'INVALID_REQUEST';
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

  bool get isNoCatalog => code == CatalogErrorCodes.noCatalog;
  bool get isNotFound => code == CatalogErrorCodes.notFound;
  bool get isDuplicateName => code == CatalogErrorCodes.duplicateName;

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
    );
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
