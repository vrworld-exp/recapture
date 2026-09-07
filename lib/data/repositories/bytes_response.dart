// lib/data/repositories/bytes_response.dart
//
// The two things every `responseType: bytes` endpoint needs, in one place.
//
// Asking Dio for bytes applies to the FAILURE body too, so a typed envelope
// (`409 CODE_RETIRED`, `409 RESOLVER_NOT_CONFIGURED`, `409 CATALOG_NOT_PUBLISHED`)
// arrives as a byte array, and `CatalogFailure.fromDio` — which looks for a Map —
// flattens it to a generic "something went wrong". On these endpoints the typed
// code IS the useful sentence, so it has to be decoded by hand.
//
// EXTRACTED, not copied. This started life as two private statics on
// CatalogRepository, back when `GET /catalog/qr` was the only bytes endpoint in
// the app. The admin standee surface added three more, and a second hand-rolled
// copy of a subtle best-effort decoder is exactly the drift the QR pipeline
// cannot afford — the same argument that put `resolverUrlFor` in one place on
// the backend.
import 'dart:convert';

import 'package:dio/dio.dart';

/// Re-reads a bytes-mode error response as the house JSON envelope.
///
/// Best effort by design: a proxy's HTML page, a truncated body or a 502 from
/// the platform leaves the exception exactly as it was, and the caller gets the
/// generic sentence — which is the right outcome for a body that is not ours.
DioException withDecodedBody(DioException error) {
  final response = error.response;
  final data = response?.data;
  if (response == null || data is! List<int>) return error;

  try {
    final decoded = jsonDecode(utf8.decode(data));
    if (decoded is! Map<String, dynamic>) return error;
    return error.copyWith(
      response: Response<dynamic>(
        data: decoded,
        statusCode: response.statusCode,
        headers: response.headers,
        requestOptions: response.requestOptions,
      ),
    );
  } on FormatException {
    return error;
  }
}

/// The filename out of `Content-Disposition: attachment; filename="..."`.
///
/// Sanitised rather than trusted: it becomes a filename on the user's device,
/// and a value carrying a path separator would write outside the directory the
/// caller chose. The server builds it from a slug it controls, so this only ever
/// has to defend against a bug.
String? fileNameFromDisposition(String? disposition) {
  if (disposition == null) return null;
  final match = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
  final raw = match?.group(1)?.trim();
  if (raw == null || raw.isEmpty) return null;
  final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return safe.isEmpty ? null : safe;
}
