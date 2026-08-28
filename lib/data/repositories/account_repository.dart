// lib/data/repositories/account_repository.dart
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dev/dev_log/dev_upload_log.dart';
import '../../domain/entities/avatar_upload_failure.dart';
import '../../domain/entities/user_profile.dart';
import '../../domain/entities/user_role.dart';
import '../remote/api_client.dart';

/// Account self-info over `/auth/me` (authed — rides the app Dio with the
/// Bearer/refresh interceptor).
///
/// PII: the endpoint deliberately ships NO raw phone/email. [UserProfile] carries
/// only a display MASK of the contact identifier; never log it or pass it to
/// analytics.
abstract interface class AccountRepository {
  /// The signed-in user's role. Throws on transport/auth failure — the caller
  /// (UserRoleNotifier) maps any failure to [UserRole.user] (fail-closed).
  ///
  /// DO NOT relax this contract or fold it into [fetchProfile]: staff gating
  /// depends on the throw. A profile fetch that degrades gracefully would
  /// silently turn a network blip into "not staff" or, worse, into a stale
  /// staff role.
  Future<UserRole> fetchRole();

  /// The full account snapshot for the Profile screen. Throws on any
  /// transport/auth/parse failure; the profile provider surfaces that as an
  /// AsyncError with a retry.
  Future<UserProfile> fetchProfile();

  /// Sets the display name and returns the UPDATED snapshot (the server returns
  /// the same shape as `GET /auth/me`, so this is the same parser). Throws on
  /// failure — the caller rolls its optimistic update back.
  Future<UserProfile> updateDisplayName(String name);

  /// Sets the profile picture and returns the UPDATED snapshot.
  ///
  /// ONE call: the image bytes go to `POST /auth/me/avatar/bytes` and the server
  /// stores them and flips the pointer. The presigned three-step flow it
  /// replaced could not work in the BROWSER build — a presigned PUT is
  /// cross-origin to the raw bucket, which serves no CORS policy by design (the
  /// same constraint behind the admin photo-bytes proxy). One path for web and
  /// native beats two that diverge.
  ///
  /// Throws [AvatarUploadException] with a mapped [AvatarUploadFailure], NEVER
  /// a raw DioException: the Screen-9F convention is that transport errors do
  /// not reach user-facing copy.
  Future<UserProfile> uploadAvatar(Uint8List bytes, {required String contentType});

  /// Clears the profile picture and returns the UPDATED snapshot. Idempotent
  /// server-side — removing a picture that is not there succeeds. Throws
  /// [AvatarUploadException] on failure.
  Future<UserProfile> removeAvatar();

  /// The signed-in user's avatar BYTES, or null when there is no picture.
  ///
  /// Read through our API rather than from the snapshot's `avatarUrl`, for two
  /// reasons that both bite in practice:
  ///   - the browser build cannot fetch that URL at all (it is cross-origin to
  ///     the raw bucket, which serves no CORS policy — the same wall the upload
  ///     hit), and
  ///   - a presigned URL expires in about an hour, so a backgrounded app comes
  ///     back to a dead link.
  /// Bytes over the authenticated Dio have neither problem, and one display
  /// path serves web and native alike.
  ///
  /// Returns null (never throws) when the picture is simply absent; a transport
  /// failure throws so the caller can fall back to initials.
  Future<Uint8List?> fetchAvatarBytes();
}

class RemoteAccountRepository implements AccountRepository {
  RemoteAccountRepository(this._dio);

  final Dio _dio;

  @override
  Future<UserRole> fetchRole() async {
    final res = await _dio.get<Map<String, dynamic>>('/auth/me');
    final user = res.data?['user'];
    final role = user is Map ? user['role'] : null;
    return UserRole.fromApiValue(role is String ? role : null);
  }

  @override
  Future<UserProfile> fetchProfile() async {
    final res = await _dio.get<Map<String, dynamic>>('/auth/me');
    return _profileFrom(res.data);
  }

  @override
  Future<UserProfile> updateDisplayName(String name) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      '/auth/me',
      data: {'displayName': name},
    );
    return _profileFrom(res.data);
  }

  @override
  Future<UserProfile> uploadAvatar(
    Uint8List bytes, {
    required String contentType,
  }) async {
    try {
      DevUploadLog.instance
          .add('avatar upload — type=$contentType bytes=${bytes.length}');
      // The raw image IS the body — not multipart, not JSON. The app Dio is
      // right here (unlike the old direct-to-S3 PUT): this endpoint is ours and
      // needs the Bearer token.
      final res = await _dio.post<Map<String, dynamic>>(
        '/auth/me/avatar/bytes',
        data: Stream.value(bytes),
        options: Options(
          headers: {
            Headers.contentTypeHeader: contentType,
            Headers.contentLengthHeader: bytes.length,
          },
        ),
      );
      DevUploadLog.instance.add('avatar upload done');
      return _profileFrom(res.data);
    } on AvatarUploadException {
      rethrow;
    } on DioException catch (error) {
      throw AvatarUploadException(_failureFor(error, step: 'upload'), error);
    } catch (error, stack) {
      DevUploadLog.instance
          .add('avatar upload failed (non-Dio)', error: error, stack: stack);
      throw AvatarUploadException(AvatarUploadFailure.unknown, error);
    }
  }

  @override
  Future<UserProfile> removeAvatar() async {
    try {
      final res = await _dio.delete<Map<String, dynamic>>('/auth/me/avatar');
      return _profileFrom(res.data);
    } on DioException catch (error) {
      throw AvatarUploadException(_failureFor(error, step: 'remove'), error);
    } catch (error, stack) {
      DevUploadLog.instance
          .add('avatar remove failed (non-Dio)', error: error, stack: stack);
      throw AvatarUploadException(AvatarUploadFailure.unknown, error);
    }
  }

  @override
  Future<Uint8List?> fetchAvatarBytes() async {
    try {
      final res = await _dio.get<List<int>>(
        '/auth/me/avatar/bytes',
        options: Options(responseType: ResponseType.bytes),
      );
      final data = res.data;
      return data == null ? null : Uint8List.fromList(data);
    } on DioException catch (error) {
      // No picture is a normal answer, not a failure — the route 404s when the
      // account has no avatar.
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Maps a transport failure onto the closed [AvatarUploadFailure] set. This is
  /// the ONLY place a DioException is inspected — past here the UI sees an enum,
  /// never a status code and never a response body.
  ///
  /// It is also the ONE place the real cause is recorded. Five distinct
  /// failures — a route that isn't deployed, a bad S3 signature, an object the
  /// server can't find, a dead socket — all surface to the user as the same
  /// sentence by design, which makes them indistinguishable from a bug report.
  /// The dev log keeps the detail the copy throws away.
  static AvatarUploadFailure _failureFor(
    DioException error, {
    required String step,
  }) {
    final status = error.response?.statusCode;
    final failure = switch (status) {
      413 => AvatarUploadFailure.tooLarge,
      429 => AvatarUploadFailure.rateLimited,
      // 400/415 from our API means the declared content type was refused; the
      // picker normally catches this locally from the magic bytes first.
      400 || 415 => AvatarUploadFailure.unsupportedType,
      null => AvatarUploadFailure.network, // timeout, DNS, socket, cancel
      _ => AvatarUploadFailure.unknown,
    };

    // Host only — NEVER the path or query. A presigned URL carries its
    // signature in the query string and the S3 key in the path; both are
    // credentials/internal identifiers that must not reach a log line.
    final host = error.requestOptions.uri.host;
    final detail = _errorCodeFrom(error.response?.data);
    DevUploadLog.instance.add(
      'avatar $step FAILED → $failure — ${error.type.name} '
      'status=${status ?? '-'} host=$host${detail == null ? '' : ' code=$detail'}',
    );
    return failure;
  }

  /// The machine-readable error code out of a failure body, or null.
  ///
  /// Two shapes, because two very different servers answer here: our API's
  /// envelope (`{status, code, message}` → e.g. `OBJECT_NOT_FOUND`,
  /// `INVALID_KEY`, `FORBIDDEN`) and S3's XML (`<Code>SignatureDoesNotMatch</Code>`).
  /// Only the CODE is extracted — never the whole body, which for S3 can echo
  /// the object key back.
  static String? _errorCodeFrom(Object? data) {
    if (data is Map && data['code'] is String) return data['code'] as String;
    if (data is String) {
      final match = RegExp(r'<Code>([^<]{1,64})</Code>').firstMatch(data);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// The ONE snapshot parser, shared by every /auth/me endpoint (they return an
  /// identical `user` object by contract — GET, PATCH, the avatar commit and the
  /// avatar delete). A missing/ill-shaped `user` is a hard failure — unlike the
  /// individual FIELDS, which UserProfile.fromJson tolerates.
  UserProfile _profileFrom(Map<String, dynamic>? body) {
    final user = body?['user'];
    if (user is! Map) {
      throw const FormatException('auth/me response has no user object');
    }
    return UserProfile.fromJson(Map<String, dynamic>.from(user));
  }
}

/// App-wide account repository. The S3 leg uses its own bare Dio, created
/// inside the repository — see [RemoteAccountRepository._s3Dio].
final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => RemoteAccountRepository(ref.watch(dioProvider)),
);
