// lib/app/bootstrap/app_bootstrap_service.dart
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/session_store.dart';

/// Where the splash should route after init.
enum AppInitRoute { login, projectsHub }

/// Outcome of the bootstrap check: the route to take plus the auth status
/// used for the `app_launch` analytics event.
class BootstrapResult {
  const BootstrapResult(this.route, this.authStatus);

  final AppInitRoute route;

  /// One of: authenticated | unauthenticated | expired_token | error.
  final String authStatus;
}

/// Resolves the initial route by inspecting the stored auth token. The check
/// is fully local/offline — it never makes a network call — so the splash
/// works in airplane mode and stays fast on low-end devices.
class AppBootstrapService {
  const AppBootstrapService({SessionStore store = const SessionStore()})
      : _store = store;

  final SessionStore _store;

  Future<BootstrapResult> resolveInitialRoute() async {
    try {
      final token = await _store.readToken();
      if (token == null) {
        return const BootstrapResult(AppInitRoute.login, 'unauthenticated');
      }
      if (_isExpired(token)) {
        await _store.clearToken();
        return const BootstrapResult(AppInitRoute.login, 'expired_token');
      }
      return const BootstrapResult(AppInitRoute.projectsHub, 'authenticated');
    } catch (_) {
      // Malformed/corrupted token or a storage error — clear and fall back to
      // login so the user is never stuck behind a bad token.
      await _safeClear();
      return const BootstrapResult(AppInitRoute.login, 'error');
    }
  }

  Future<void> _safeClear() async {
    try {
      await _store.clearToken();
    } catch (_) {
      // Nothing more we can do — already routing to login.
    }
  }

  /// Decodes the JWT `exp` claim locally and reports whether it has passed.
  /// Throws [FormatException] on anything that is not a well-formed JWT with
  /// an integer `exp` claim — the caller treats that as a bad token.
  bool _isExpired(String token) {
    final parts = token.split('.');
    if (parts.length != 3) {
      throw const FormatException('Not a JWT');
    }
    final payload = json.decode(_decodeSegment(parts[1]));
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('JWT payload is not an object');
    }
    final exp = payload['exp'];
    if (exp is! int) {
      throw const FormatException('Missing or invalid exp claim');
    }
    final expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    return DateTime.now().toUtc().isAfter(expiry);
  }

  String _decodeSegment(String segment) {
    // base64Url.normalize re-applies the padding JWTs strip off.
    return utf8.decode(base64Url.decode(base64Url.normalize(segment)));
  }
}

/// Riverpod provider for the bootstrap service — keeps the splash widget free
/// of construction logic and matches the app's existing Riverpod setup.
final appBootstrapServiceProvider =
    Provider<AppBootstrapService>((ref) => const AppBootstrapService());
