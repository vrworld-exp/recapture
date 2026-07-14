// lib/data/repositories/account_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/user_role.dart';
import '../remote/api_client.dart';

/// Account self-info over `GET /auth/me` (authed — rides the app Dio with the
/// Bearer/refresh interceptor). Today the client only consumes the role; the
/// endpoint deliberately ships no raw phone/email.
abstract interface class AccountRepository {
  /// The signed-in user's role. Throws on transport/auth failure — the caller
  /// (UserRoleNotifier) maps any failure to [UserRole.user] (fail-closed).
  Future<UserRole> fetchRole();
}

class RemoteAccountRepository implements AccountRepository {
  const RemoteAccountRepository(this._dio);

  final Dio _dio;

  @override
  Future<UserRole> fetchRole() async {
    final res = await _dio.get<Map<String, dynamic>>('/auth/me');
    final user = res.data?['user'];
    final role = user is Map ? user['role'] : null;
    return UserRole.fromApiValue(role is String ? role : null);
  }
}

/// App-wide account repository.
final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => RemoteAccountRepository(ref.watch(dioProvider)),
);
