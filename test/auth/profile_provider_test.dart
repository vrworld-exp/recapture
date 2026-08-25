// test/auth/profile_provider_test.dart
//
// The profile provider's lifecycle: fetch on first watch, retry via refresh(),
// optimistic rename with rollback, and — the load-bearing part — a RESET on
// logout that a second user can never see through.
//
// Two distinct leak paths are covered:
//   1. logout drops the loaded snapshot (the listener's reset);
//   2. a fetch already IN FLIGHT across the logout can't land afterwards
//      (the epoch guard on the build future).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/auth/profile_provider.dart';
import 'package:recapture/data/repositories/account_repository.dart';
import 'package:recapture/domain/entities/auth_session.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/user_profile.dart';
import 'package:recapture/domain/entities/user_role.dart';

class _FakeAccountRepository implements AccountRepository {
  UserProfile? profile;
  bool fail = false;
  int fetchCalls = 0;

  /// When set, fetchProfile waits on it — lets a test hold a fetch in flight
  /// across an auth transition.
  Completer<void>? gate;

  /// Served by fetchAvatarBytes — the avatar display path.
  Uint8List? avatarBytes;

  @override
  Future<UserRole> fetchRole() async => UserRole.user;

  @override
  Future<UserProfile> fetchProfile() async {
    fetchCalls++;
    if (gate != null) await gate!.future;
    if (fail) throw Exception('offline');
    return profile!;
  }

  @override
  Future<UserProfile> updateDisplayName(String name) async {
    if (fail) throw Exception('rejected');
    profile = profile!.copyWith(displayName: name);
    return profile!;
  }

  int uploadCalls = 0;

  /// When set, uploadAvatar waits on it — lets a test hold an upload in flight
  /// across an auth transition (the case the epoch guard exists for).
  Completer<void>? uploadGate;

  @override
  Future<UserProfile> uploadAvatar(
    Uint8List bytes, {
    required String contentType,
  }) async {
    uploadCalls++;
    if (uploadGate != null) await uploadGate!.future;
    if (fail) throw Exception('upload rejected');
    profile = profile!.copyWith(avatarUrl: 'https://example/signed.jpg');
    return profile!;
  }

  @override
  Future<UserProfile> removeAvatar() async {
    if (fail) throw Exception('remove rejected');
    profile = _profile(profile!.displayName!); // rebuilt without a url
    return profile!;
  }

  @override
  Future<Uint8List?> fetchAvatarBytes() async => avatarBytes;
}

class _DrivenAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();

  void emit(AuthState next) => state = next;
}

UserProfile _profile(String name) => UserProfile(
      id: 'u-$name',
      role: UserRole.user,
      displayName: name,
      contactMasked: '+91 ••••• ••210',
      contactChannel: 'sms',
      createdAt: DateTime.utc(2026, 3, 14),
    );

AuthSession _session() => AuthSession(
      accessToken: 'a',
      refreshToken: 'r',
      accessTokenExpiry: DateTime.now().toUtc().add(const Duration(hours: 1)),
      userId: 'u1',
    );

Future<void> _pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeAccountRepository account;
  late ProviderContainer container;

  ProviderContainer buildContainer() => ProviderContainer(overrides: [
        accountRepositoryProvider.overrideWithValue(account),
        authProvider.overrideWith(_DrivenAuthNotifier.new),
      ]);

  _DrivenAuthNotifier auth() =>
      container.read(authProvider.notifier) as _DrivenAuthNotifier;

  setUp(() {
    account = _FakeAccountRepository()..profile = _profile('Alice');
  });

  tearDown(() => container.dispose());

  test('fetches on first watch', () async {
    container = buildContainer();

    expect(container.read(profileProvider), isA<AsyncLoading<UserProfile>>());
    await _pump();

    expect(container.read(profileProvider).value?.displayName, 'Alice');
    expect(account.fetchCalls, 1);
  });

  test('a failed fetch surfaces AsyncError; refresh() recovers', () async {
    account.fail = true;
    container = buildContainer();
    container.read(profileProvider); // instantiate the lazy provider
    await _pump();

    expect(container.read(profileProvider), isA<AsyncError<UserProfile>>());

    account.fail = false;
    await container.read(profileProvider.notifier).refresh();

    expect(container.read(profileProvider).value?.displayName, 'Alice');
  });

  test('logout puts the provider back into AsyncLoading', () async {
    container = buildContainer();
    container.read(profileProvider); // instantiate the lazy provider
    await _pump();
    expect(container.read(profileProvider).value?.displayName, 'Alice');

    auth().emit(const AuthUnauthenticated());
    await _pump();

    // AsyncLoading — so nothing that renders on AsyncData shows the departing
    // user. Riverpod carries the previous value along on a loading transition
    // (`.value` is still populated); that is why the screen switches on the
    // AsyncValue CASE, never on `.value` alone. profile_screen_test's loading
    // case asserts the rendered result: skeleton, no name.
    final state = container.read(profileProvider);
    expect(state, isA<AsyncLoading<UserProfile>>());
    expect(state.isLoading, isTrue);
  });

  test('a fetch in flight across a logout can never land', () async {
    account.gate = Completer<void>();
    container = buildContainer();
    container.read(profileProvider); // start the build fetch
    await _pump();

    // Log out while the fetch is still hanging, then release it.
    auth().emit(const AuthUnauthenticated());
    await _pump();
    account.gate!.complete();
    await _pump();

    // Alice's snapshot must NOT have landed after the reset.
    expect(container.read(profileProvider).value, isNull);
  });

  test('updateAvatar installs the server snapshot and clears the flag',
      () async {
    container = buildContainer();
    container.read(profileProvider);
    await _pump();
    expect(container.read(avatarUploadingProvider), isFalse);

    await container
        .read(profileProvider.notifier)
        .updateAvatar(Uint8List.fromList(const [0xFF, 0xD8, 0xFF]), contentType: 'image/jpeg');

    expect(container.read(profileProvider).value?.avatarUrl,
        'https://example/signed.jpg');
    expect(container.read(profileProvider).value?.hasAvatar, isTrue);
    expect(container.read(avatarUploadingProvider), isFalse);
  });

  test('the in-flight flag is set during an upload, NOT AsyncLoading', () async {
    account.uploadGate = Completer<void>();
    container = buildContainer();
    container.read(profileProvider);
    await _pump();

    final pending = container
        .read(profileProvider.notifier)
        .updateAvatar(Uint8List.fromList(const [0xFF, 0xD8, 0xFF]), contentType: 'image/jpeg');
    await _pump();

    expect(container.read(avatarUploadingProvider), isTrue);
    // The profile itself stays AsyncData, so the screen keeps painting the name,
    // the contact and — the point of the whole design — Sign out.
    expect(container.read(profileProvider), isA<AsyncData<UserProfile>>());
    expect(container.read(profileProvider).value?.displayName, 'Alice');

    account.uploadGate!.complete();
    await pending;
    expect(container.read(avatarUploadingProvider), isFalse);
  });

  test('an upload in flight across a logout can never repaint the next user',
      () async {
    // THE reason updateAvatar is epoch-guarded: an upload easily outlives a
    // sign-out on a slow connection.
    account.uploadGate = Completer<void>();
    container = buildContainer();
    container.read(profileProvider);
    await _pump();

    final pending = container
        .read(profileProvider.notifier)
        .updateAvatar(Uint8List.fromList(const [0xFF, 0xD8, 0xFF]), contentType: 'image/jpeg');
    await _pump();

    auth().emit(const AuthUnauthenticated());
    await _pump();
    account.uploadGate!.complete();
    await pending;
    await _pump();

    // The late response was discarded: still the post-logout loading state,
    // never Alice's picture.
    expect(container.read(profileProvider), isA<AsyncLoading<UserProfile>>());
    // …and the flag is cleared, so the next user's screen has no stuck spinner.
    expect(container.read(avatarUploadingProvider), isFalse);
  });

  test('a failed upload rethrows, keeps the snapshot, and clears the flag',
      () async {
    container = buildContainer();
    container.read(profileProvider);
    await _pump();

    account.fail = true;
    await expectLater(
      container
          .read(profileProvider.notifier)
          .updateAvatar(Uint8List.fromList(const [0xFF, 0xD8, 0xFF]), contentType: 'image/jpeg'),
      throwsA(isA<Exception>()),
    );

    // NOT optimistic: the previous snapshot is untouched, with no half-applied
    // avatar to undo.
    expect(container.read(profileProvider).value?.displayName, 'Alice');
    expect(container.read(profileProvider).value?.hasAvatar, isFalse);
    expect(container.read(avatarUploadingProvider), isFalse);
  });

  test('removeAvatar installs the cleared snapshot', () async {
    container = buildContainer();
    container.read(profileProvider);
    await _pump();
    await container
        .read(profileProvider.notifier)
        .updateAvatar(Uint8List.fromList(const [0xFF, 0xD8, 0xFF]), contentType: 'image/jpeg');
    expect(container.read(profileProvider).value?.hasAvatar, isTrue);

    await container.read(profileProvider.notifier).removeAvatar();

    expect(container.read(profileProvider).value?.avatarUrl, isNull);
    expect(container.read(profileProvider).value?.hasAvatar, isFalse);
  });

  test('re-authenticating fetches the NEW user, never the old snapshot',
      () async {
    container = buildContainer();
    container.read(profileProvider); // instantiate the lazy provider
    await _pump();
    expect(container.read(profileProvider).value?.displayName, 'Alice');

    auth().emit(const AuthUnauthenticated());
    await _pump();

    account.profile = _profile('Bob');
    auth().emit(AuthAuthenticated(_session()));
    await _pump();

    expect(container.read(profileProvider).value?.displayName, 'Bob');
  });

  test('a routine token rotation does not refetch', () async {
    container = buildContainer();
    container.read(profileProvider); // instantiate the lazy provider
    await _pump();
    expect(account.fetchCalls, 1);

    auth().emit(AuthAuthenticated(_session()));
    auth().emit(AuthRefreshing(_session()));
    auth().emit(AuthAuthenticated(_session()));
    await _pump();

    // The first Authenticated is a real establish (build started from
    // AuthRestoring); the rotation that follows must add nothing.
    expect(account.fetchCalls, lessThanOrEqualTo(2));
    expect(container.read(profileProvider).value?.displayName, 'Alice');
  });

  test('updateDisplayName is optimistic and rolls back on failure', () async {
    container = buildContainer();
    container.read(profileProvider); // instantiate the lazy provider
    await _pump();

    await container.read(profileProvider.notifier).updateDisplayName('Alicia');
    expect(container.read(profileProvider).value?.displayName, 'Alicia');

    account.fail = true;
    await expectLater(
      container.read(profileProvider.notifier).updateDisplayName('Nope'),
      throwsA(isA<Exception>()),
    );
    expect(container.read(profileProvider).value?.displayName, 'Alicia');
  });
}
