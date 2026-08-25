// test/auth/auth_repository_test.dart
//
// Contract of the REAL AuthRepository against a scripted Dio transport (no
// network): request paths + camelCase bodies match recapture-api's schemas,
// devCode/expiry parsing, the enumeration-safe 401 → null mapping, 429 →
// OtpRateLimitedException, refresh rotation, and the debug-only master OTP
// short-circuit (no network touched).
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/data/repositories/auth_repository.dart';

/// Scriptable [HttpClientAdapter] (mirrors token_refresh_test's MockHttpAdapter).
class _MockHttpAdapter implements HttpClientAdapter {
  _MockHttpAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _resp(int status, [Map<String, dynamic> body = const {}]) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

/// Repository over a scripted transport.
(AuthRepository, _MockHttpAdapter) _repo(
    ResponseBody Function(RequestOptions) handler) {
  final adapter = _MockHttpAdapter(handler);
  final repo = AuthRepository(dio: () {
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
    dio.httpClientAdapter = adapter;
    return dio;
  });
  return (repo, adapter);
}

Map<String, dynamic> _body(RequestOptions o) =>
    (o.data as Map).cast<String, dynamic>();

void main() {
  group('sendOtp', () {
    test('sms: posts channel+phone and parses devCode/expiresInSeconds',
        () async {
      final (repo, adapter) = _repo((o) =>
          _resp(200, {'status': 'success', 'expiresInSeconds': 300, 'devCode': '123456'}));

      final result = await repo.sendOtp(
        channel: 'sms',
        identifier: '+919876543210',
      );

      expect(adapter.requests.single.path, '/auth/send-otp');
      expect(_body(adapter.requests.single),
          {'channel': 'sms', 'phone': '+919876543210'});
      expect(result.devCode, '123456');
      expect(result.expiresInSeconds, 300);
    });

    test('email: posts channel+email; missing devCode → null (production)',
        () async {
      final (repo, adapter) =
          _repo((o) => _resp(200, {'status': 'success', 'expiresInSeconds': 300}));

      final result =
          await repo.sendOtp(channel: 'email', identifier: 'a@b.com');

      expect(_body(adapter.requests.single),
          {'channel': 'email', 'email': 'a@b.com'});
      expect(result.devCode, isNull);
    });

    test('429 → OtpRateLimitedException carrying retryAfter', () async {
      final (repo, _) = _repo((o) =>
          _resp(429, {'status': 'error', 'code': 'RATE_LIMITED', 'retryAfter': 42}));

      await expectLater(
        repo.sendOtp(channel: 'sms', identifier: '+919876543210'),
        throwsA(isA<OtpRateLimitedException>()
            .having((e) => e.retryAfterSeconds, 'retryAfter', 42)),
      );
    });

    test('transport/server failure rethrows DioException', () async {
      final (repo, _) = _repo((o) => _resp(502, {'status': 'error'}));

      await expectLater(
        repo.sendOtp(channel: 'sms', identifier: '+919876543210'),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('verifyOtp', () {
    test('success parses the session (accessTokenExpiresIn honored)', () async {
      final (repo, adapter) = _repo((o) => _resp(200, {
            'status': 'success',
            'accessToken': 'access-1',
            'accessTokenExpiresIn': 900,
            'refreshToken': 'refresh-1',
            'refreshTokenExpiresIn': 2592000,
            'isNewUser': true,
          }));

      final before = DateTime.now().toUtc();
      final session = await repo.verifyOtp(
        channel: 'sms',
        identifier: '+919876543210',
        code: '654321',
      );

      expect(adapter.requests.single.path, '/auth/verify-otp');
      expect(_body(adapter.requests.single), {
        'channel': 'sms',
        'phone': '+919876543210',
        'code': '654321',
      });
      expect(session, isNotNull);
      expect(session!.accessToken, 'access-1');
      expect(session.refreshToken, 'refresh-1');
      // Expiry derived from accessTokenExpiresIn seconds (not the 15-min JWT
      // fallback — the token here is not a JWT, so a wrong mapping would show).
      expect(
        session.accessTokenExpiry.difference(before).inSeconds,
        closeTo(900, 30),
      );
    });

    test('the enumeration-safe 401 → null (invalid code, no throw)', () async {
      final (repo, _) = _repo((o) =>
          _resp(401, {'status': 'error', 'code': 'INVALID_OTP'}));

      final session = await repo.verifyOtp(
        channel: 'sms',
        identifier: '+919876543210',
        code: '000000',
      );

      expect(session, isNull);
    });

    test('master OTP short-circuits to a stub session with NO network',
        () async {
      final (repo, adapter) = _repo((o) => _resp(500));

      final session = await repo.verifyOtp(
        channel: 'sms',
        identifier: '+919876543210',
        code: '555555',
      );

      expect(session, isNotNull);
      expect(session!.accessToken, 'stub.access.token');
      expect(adapter.requests, isEmpty);
    });
  });

  group('refresh', () {
    test('success returns the ROTATED pair', () async {
      final (repo, adapter) = _repo((o) => _resp(200, {
            'status': 'success',
            'accessToken': 'access-2',
            'accessTokenExpiresIn': 900,
            'refreshToken': 'refresh-2',
          }));

      final session = await repo.refresh('refresh-1');

      expect(adapter.requests.single.path, '/auth/refresh');
      expect(_body(adapter.requests.single), {'refreshToken': 'refresh-1'});
      expect(session.accessToken, 'access-2');
      expect(session.refreshToken, 'refresh-2');
    });

    test('expired/revoked token (401) throws — caller treats as unrecoverable',
        () async {
      final (repo, _) = _repo((o) =>
          _resp(401, {'status': 'error', 'code': 'INVALID_REFRESH_TOKEN'}));

      await expectLater(repo.refresh('gone'), throwsA(isA<DioException>()));
    });
  });
}
