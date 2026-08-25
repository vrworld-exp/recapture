// test/auth/auth_session_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/auth_session.dart';

void main() {
  AuthSession sessionExpiring(Duration fromNow) => AuthSession(
        accessToken: 'a',
        refreshToken: 'r',
        accessTokenExpiry: DateTime.now().toUtc().add(fromNow),
        userId: 'u',
      );

  group('isAccessTokenExpired', () {
    test('past expiry is expired', () {
      expect(sessionExpiring(const Duration(minutes: -1)).isAccessTokenExpired,
          isTrue);
    });

    test('future expiry is not expired', () {
      expect(sessionExpiring(const Duration(minutes: 10)).isAccessTokenExpired,
          isFalse);
    });
  });

  group('needsRefreshWithin', () {
    test('true when expiry falls inside the window', () {
      expect(
        sessionExpiring(const Duration(minutes: 1))
            .needsRefreshWithin(const Duration(minutes: 2)),
        isTrue,
      );
    });

    test('false when expiry is beyond the window', () {
      expect(
        sessionExpiring(const Duration(minutes: 30))
            .needsRefreshWithin(const Duration(minutes: 2)),
        isFalse,
      );
    });

    test('already-expired token needs refresh', () {
      expect(
        sessionExpiring(const Duration(seconds: -5))
            .needsRefreshWithin(const Duration(minutes: 2)),
        isTrue,
      );
    });
  });

  group('json roundtrip', () {
    test('toJson/fromJson preserves fields and normalises to UTC', () {
      final original = sessionExpiring(const Duration(hours: 1));
      final restored = AuthSession.fromJson(original.toJson());
      expect(restored.accessToken, original.accessToken);
      expect(restored.refreshToken, original.refreshToken);
      expect(restored.userId, original.userId);
      expect(restored.accessTokenExpiry.isUtc, isTrue);
      expect(
        restored.accessTokenExpiry.millisecondsSinceEpoch,
        original.accessTokenExpiry.millisecondsSinceEpoch,
      );
    });

    test('fromJson throws on missing token', () {
      expect(
        () => AuthSession.fromJson({
          'refreshToken': 'r',
          'accessTokenExpiry': DateTime.now().toUtc().toIso8601String(),
        }),
        throwsFormatException,
      );
    });

    test('fromJson throws on malformed expiry', () {
      expect(
        () => AuthSession.fromJson({
          'accessToken': 'a',
          'refreshToken': 'r',
          'accessTokenExpiry': 'not-a-date',
        }),
        throwsFormatException,
      );
    });
  });

  group('fromAuthResponse', () {
    test('derives expiry from expiresIn seconds', () {
      final before = DateTime.now().toUtc();
      final session = AuthSession.fromAuthResponse(const {
        'accessToken': 'a',
        'refreshToken': 'r',
        'expiresIn': 900,
        'userId': 'u',
      });
      final delta = session.accessTokenExpiry.difference(before).inSeconds;
      expect(delta, inInclusiveRange(890, 905));
      expect(session.accessTokenExpiry.isUtc, isTrue);
    });

    test('uses the rotated refresh token from the response', () {
      final session = AuthSession.fromAuthResponse(
        const {
          'accessToken': 'a',
          'refreshToken': 'rotated',
          'expiresIn': 900,
        },
        previousRefreshToken: 'old',
      );
      expect(session.refreshToken, 'rotated');
    });

    test('falls back to previous refresh token when response omits one', () {
      final session = AuthSession.fromAuthResponse(
        const {'accessToken': 'a', 'expiresIn': 900},
        previousRefreshToken: 'old',
      );
      expect(session.refreshToken, 'old');
    });

    test('throws when no refresh token is available at all', () {
      expect(
        () => AuthSession.fromAuthResponse(
            const {'accessToken': 'a', 'expiresIn': 900}),
        throwsFormatException,
      );
    });
  });
}
