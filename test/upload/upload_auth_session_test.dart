// test/upload/upload_auth_session_test.dart
//
// Regression tests for the UNK-01 bug: a token-acquisition failure inside the
// upload Dio's auth interceptor must surface with its TRUE category (AUTH-01 /
// NET-01), never fall through to the generic UNK-01 bucket.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/upload_auth_session.dart';
import 'package:recapture/domain/upload/upload_failure.dart';

/// A session whose token acquisition always fails with [error].
class _ThrowingSession implements UploadAuthSession {
  const _ThrowingSession(this.error);
  final Object error;

  @override
  Future<String> accessToken({bool forceRefresh = false}) async => throw error;
}

void main() {
  group('UploadAuthException classification', () {
    test('auth category → AUTH-01, non-retryable', () {
      const e = UploadAuthException(UploadErrorCategory.auth,
          detail: 'session gone');
      final category = classifyUploadFailure(e);
      expect(category, UploadErrorCategory.auth);
      expect(category.retryable, isFalse);
      expect(category.code, 'AUTH-01');
    });

    test('network category (transient refresh) → NET-01, retryable', () {
      const e = UploadAuthException(UploadErrorCategory.network,
          detail: 'refresh timed out; session retained');
      final category = classifyUploadFailure(e);
      expect(category, UploadErrorCategory.network);
      expect(category.retryable, isTrue);
      expect(category.code, 'NET-01');
    });
  });

  group('buildUploadApiDio token-failure rejection', () {
    // The interceptor rejects BEFORE any network I/O, so the bogus base URL is
    // never contacted.
    Future<DioException> rejectedBy(Object error) async {
      final dio = buildUploadApiDio(_ThrowingSession(error),
          baseUrl: 'http://127.0.0.1:1');
      try {
        await dio.get<void>('/projects');
        fail('request should have been rejected by the auth interceptor');
      } on DioException catch (e) {
        return e;
      }
    }

    test('UploadAuthException(auth) stays AUTH-01 through the Dio wrap',
        () async {
      final e = await rejectedBy(
        const UploadAuthException(UploadErrorCategory.auth),
      );
      expect(classifyUploadFailure(e), UploadErrorCategory.auth);
    });

    test('UploadAuthException(network) stays NET-01 through the Dio wrap',
        () async {
      final e = await rejectedBy(
        const UploadAuthException(UploadErrorCategory.network),
      );
      expect(classifyUploadFailure(e), UploadErrorCategory.network);
    });

    test('an unmapped inner error still falls back to unknown', () async {
      final e = await rejectedBy(StateError('boom'));
      expect(classifyUploadFailure(e), UploadErrorCategory.unknown);
    });
  });
}
