// test/upload/upload_failure_test.dart
//
// The pure classification behind Screen 9F: mapping raw pipeline errors to a small
// set of categories + a retryable flag + a MAPPED code, without retaining raw text.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/upload/upload_failure.dart';

class _Signalled implements UploadFailureSignal {
  _Signalled(this.uploadErrorCategory);
  @override
  final UploadErrorCategory uploadErrorCategory;
}

void main() {
  group('classifyUploadFailure', () {
    test('null → unknown (safe generic)', () {
      expect(classifyUploadFailure(null), UploadErrorCategory.unknown);
    });

    test('SocketException / TimeoutException → network', () {
      expect(classifyUploadFailure(const SocketException('x')),
          UploadErrorCategory.network);
      expect(classifyUploadFailure(TimeoutException('x')),
          UploadErrorCategory.network);
    });

    test('pipeline signal is authoritative over heuristics', () {
      // Text says "network" but the signal names quota → quota wins.
      expect(
        classifyUploadFailure(_Signalled(UploadErrorCategory.quota)),
        UploadErrorCategory.quota,
      );
    });

    test('auth cues → auth', () {
      expect(classifyUploadFailure(Exception('HTTP 401 Unauthorized')),
          UploadErrorCategory.auth);
      expect(classifyUploadFailure('session expired'),
          UploadErrorCategory.auth);
    });

    test('quota cues → quota', () {
      expect(classifyUploadFailure(Exception('429 Too Many Requests')),
          UploadErrorCategory.quota);
    });

    test('validation cues → validation', () {
      expect(classifyUploadFailure(Exception('422 Unprocessable Entity')),
          UploadErrorCategory.validation);
      expect(classifyUploadFailure('payload rejected: corrupt'),
          UploadErrorCategory.validation);
    });

    test('server cues → server', () {
      expect(classifyUploadFailure(Exception('503 Service Unavailable')),
          UploadErrorCategory.server);
      expect(classifyUploadFailure(const HttpException('boom')),
          UploadErrorCategory.server);
    });

    test('generic network text → network', () {
      expect(classifyUploadFailure(Exception('Connection reset by peer')),
          UploadErrorCategory.network);
    });

    test('unrecognised → unknown', () {
      expect(classifyUploadFailure(Exception('kaboom 7')),
          UploadErrorCategory.unknown);
    });
  });

  group('category presentation facts', () {
    test('retryable classification', () {
      expect(UploadErrorCategory.network.retryable, isTrue);
      expect(UploadErrorCategory.server.retryable, isTrue);
      expect(UploadErrorCategory.unknown.retryable, isTrue);
      expect(UploadErrorCategory.auth.retryable, isFalse);
      expect(UploadErrorCategory.validation.retryable, isFalse);
      expect(UploadErrorCategory.quota.retryable, isFalse);
    });

    test('wireName + code are stable mapped references', () {
      expect(UploadErrorCategory.network.wireName, 'network');
      expect(UploadErrorCategory.network.code, 'NET-01');
      expect(UploadErrorCategory.auth.wireName, 'auth');
      expect(UploadErrorCategory.unknown.code, 'UNK-01');
    });
  });
}
