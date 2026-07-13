// test/auth/user_role_notifier_test.dart
//
// P7-A role plumbing: the role comes from GET /auth/me after auth is
// established, persists as a warm-start hint, falls back to USER on ANY
// failure (fail-closed — the staff UI must never appear on error), and resets
// on logout. Hermetic: fake account repository + in-memory role store + a
// driveable auth notifier.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/data/local/user_role_store.dart';
import 'package:recapture/data/repositories/account_repository.dart';
import 'package:recapture/domain/entities/auth_session.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/user_role.dart';

class _FakeAccountRepository implements AccountRepository {
  UserRole? role;
  bool fail = false;
  int calls = 0;

  @override
  Future<UserRole> fetchRole() async {
    calls++;
    if (fail) throw Exception('auth/me failed');
    return role ?? UserRole.user;
  }
}

class _FakeUserRoleStore implements UserRoleStore {
  UserRole? stored;
  int clearCalls = 0;

  @override
  Future<UserRole?> read() async => stored;

  @override
  Future<void> save(UserRole role) async => stored = role;

  @override
  Future<void> clear() async {
    clearCalls++;
    stored = null;
  }
}

/// Driveable auth double — no secure storage, test-controlled transitions.
class _DrivenAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();

  void emit(AuthState next) => state = next;
}

AuthSession _session() => AuthSession(
      accessToken: 'a',
      refreshToken: 'r',
      accessTokenExpiry: DateTime.now().toUtc().add(const Duration(hours: 1)),
      userId: 'u1',
    );

Future<void> _pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeAccountRepository account;
  late _FakeUserRoleStore store;
  late ProviderContainer container;

  ProviderContainer buildContainer() => ProviderContainer(overrides: [
        accountRepositoryProvider.overrideWithValue(account),
        userRoleStoreProvider.overrideWithValue(store),
        authProvider.overrideWith(_DrivenAuthNotifier.new),
      ]);

  _DrivenAuthNotifier auth() =>
      container.read(authProvider.notifier) as _DrivenAuthNotifier;

  setUp(() {
    account = _FakeAccountRepository();
    store = _FakeUserRoleStore();
  });

  tearDown(() => container.dispose());

  test('auth established → role fetched from /auth/me and persisted', () async {
    account.role = UserRole.modelArtist;
    container = buildContainer();

    expect(container.read(userRoleProvider), UserRole.user);
    expect(container.read(isStaffProvider), isFalse);

    auth().emit(AuthAuthenticated(_session()));
    await _pump();

    expect(container.read(userRoleProvider), UserRole.modelArtist);
    expect(container.read(isStaffProvider), isTrue);
    expect(store.stored, UserRole.modelArtist);
    expect(account.calls, 1);
  });

  test('/auth/me failure → falls back to USER (fail-closed)', () async {
    account.fail = true;
    container = buildContainer();
    container.read(userRoleProvider); // initialize before auth establishes

    auth().emit(AuthAuthenticated(_session()));
    await _pump();

    expect(container.read(userRoleProvider), UserRole.user);
    expect(container.read(isStaffProvider), isFalse);
  });

  test('persisted role paints the warm start before any fetch', () async {
    store.stored = UserRole.admin;
    container = buildContainer();
    container.read(userRoleProvider); // initialize; auth never establishes

    await _pump(); // restore-from-disk only

    expect(container.read(userRoleProvider), UserRole.admin);
  });

  test('logout resets to USER and clears the persisted flag', () async {
    account.role = UserRole.admin;
    container = buildContainer();
    container.read(userRoleProvider);

    auth().emit(AuthAuthenticated(_session()));
    await _pump();
    expect(container.read(userRoleProvider), UserRole.admin);

    auth().emit(const AuthUnauthenticated());
    await _pump();

    expect(container.read(userRoleProvider), UserRole.user);
    expect(store.stored, isNull);
    expect(store.clearCalls, greaterThanOrEqualTo(1));
  });

  test('a refresh rotation does not refetch the role', () async {
    account.role = UserRole.modelArtist;
    container = buildContainer();
    container.read(userRoleProvider);

    auth().emit(AuthAuthenticated(_session()));
    await _pump();
    expect(account.calls, 1);

    // Routine rotation: Authenticated → Refreshing → Authenticated.
    auth().emit(AuthRefreshing(_session()));
    auth().emit(AuthAuthenticated(_session()));
    await _pump();

    expect(account.calls, 1, reason: 'no refetch on token rotation');
    expect(container.read(userRoleProvider), UserRole.modelArtist);
  });
}
