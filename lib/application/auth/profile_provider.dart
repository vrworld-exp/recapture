// lib/application/auth/profile_provider.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/account_repository.dart';
import '../../domain/entities/auth_state.dart';
import '../../domain/entities/user_profile.dart';
import 'auth_notifier.dart';

/// Whether an avatar change (upload or removal) is in flight.
///
/// A SEPARATE flag rather than dropping [profileProvider] into AsyncLoading, on
/// purpose: the name, the masked contact and — above all — Sign out must stay on
/// screen and usable while a picture uploads. A user who is mid-upload is
/// exactly the user who might want to abandon the session; an AsyncLoading here
/// would repaint the skeleton and take that away.
///
/// Written only by [ProfileNotifier]; read by the Profile screen.
final avatarUploadingProvider = StateProvider<bool>((ref) => false);

/// Owns the signed-in user's account snapshot for the Profile screen — fetched
/// from `GET /auth/me` on first watch, mutated through `PATCH /auth/me`.
///
/// Lifecycle (the same `ref.listen` + epoch-guard idiom as [UserRoleNotifier]):
///   - First watch → fetch.
///   - On logout (auth → [AuthUnauthenticated]) → the state is DROPPED and the
///     epoch bumped, so a second user can never see the first user's name, and a
///     fetch that was in flight across the transition can never land into it.
///   - On auth becoming established again → re-fetch for the NEW user.
///
/// NOT persisted to Hive. Unlike the role (which is cached as a warm-start hint),
/// a name + contact mask is per-user identity: a stale one painted at startup
/// would be showing the previous account. It is cheap to re-fetch and it always
/// belongs to the live session.
///
/// Distinct from [userRoleProvider] on purpose: that one is FAIL-CLOSED (any
/// error silently becomes USER, because it gates staff UI). This one surfaces
/// errors as AsyncError so the screen can offer a retry.
class ProfileNotifier extends AsyncNotifier<UserProfile> {
  /// Bumped on every auth transition; a fetch captures it at its start and
  /// discards its result if it changed meanwhile.
  int _epoch = 0;

  @override
  Future<UserProfile> build() async {
    ref.listen<AuthState>(authProvider, (prev, next) {
      final wasAuthed = prev is AuthAuthenticated || prev is AuthRefreshing;
      if (next is AuthUnauthenticated) {
        _epoch++;
        // Back to loading rather than to a stale value: the router is already
        // bouncing to /auth, and whatever renders in the meantime must not be
        // the departing user's identity.
        //
        // NOTE: Riverpod carries the previous data ALONG a loading transition,
        // so `.value` stays populated here. That is why consumers must switch
        // on the AsyncValue CASE (AsyncData/AsyncError/_) and never read
        // `.value` unconditionally — the Profile screen does exactly that, so a
        // reset paints the skeleton, not the departing user.
        state = const AsyncLoading<UserProfile>();
      } else if (next is AuthAuthenticated && !wasAuthed) {
        // Auth established (restore or OTP verify) — NOT a routine
        // refresh-rotation, which cycles Authenticated→Refreshing→Authenticated.
        _epoch++;
        final epoch = _epoch;
        state = const AsyncLoading<UserProfile>();
        unawaited(_load(epoch));
      }
    });

    // The FIRST fetch is epoch-guarded too. Riverpod installs whatever this
    // future resolves to, so an unguarded one that landed after a logout would
    // overwrite the listener's reset with the DEPARTING user's identity.
    final epoch = _epoch;
    return ref.read(accountRepositoryProvider).fetchProfile().then(
      (profile) => epoch == _epoch ? profile : _superseded(),
      onError: (Object error, StackTrace stack) =>
          epoch == _epoch ? Future<UserProfile>.error(error, stack) : _superseded(),
    );
  }

  /// A future that never completes — used when an in-flight build fetch is
  /// superseded by an auth transition. The listener has already installed the
  /// correct state; completing (with either a value or an error) would clobber
  /// it. Riverpod simply leaves the notifier in that state.
  Future<UserProfile> _superseded() => Completer<UserProfile>().future;

  /// Re-fetches the snapshot. Used by the screen's error-state retry and by
  /// pull-to-refresh-style callers.
  Future<void> refresh() async {
    _epoch++;
    final epoch = _epoch;
    state = const AsyncLoading<UserProfile>();
    await _load(epoch);
  }

  /// Sets the display name OPTIMISTICALLY (the projects-state convention): the
  /// new name paints immediately and the previous snapshot is restored if the
  /// server rejects it. Rethrows so the caller can show the failure.
  ///
  /// A failure while there is no loaded snapshot to roll back to leaves the
  /// state untouched rather than inventing one.
  Future<void> updateDisplayName(String name) async {
    final trimmed = name.trim();
    final previous = state.valueOrNull;
    final epoch = _epoch;

    if (previous != null) {
      state = AsyncData(previous.copyWith(displayName: trimmed));
    }

    try {
      final updated =
          await ref.read(accountRepositoryProvider).updateDisplayName(trimmed);
      if (epoch != _epoch) return; // auth changed mid-flight — discard
      state = AsyncData(updated);
    } catch (_) {
      if (epoch == _epoch && previous != null) {
        state = AsyncData(previous); // rollback
      }
      rethrow;
    }
  }

  /// Sets the profile picture: pick → presigned PUT → commit, all inside the
  /// repository. Rethrows the typed [AvatarUploadException] so the screen can
  /// map it to copy.
  ///
  /// Deliberately NOT optimistic, unlike [updateDisplayName]. There is no local
  /// URL to paint — the only URL that exists is the presigned one the server
  /// mints at commit time — so an "optimistic" avatar would have to be a
  /// half-applied guess, which is worse than a spinner. The previous snapshot
  /// stays on screen untouched until the real one arrives.
  Future<void> updateAvatar(Uint8List bytes, {required String contentType}) {
    return _runAvatarChange(
      () => ref
          .read(accountRepositoryProvider)
          .uploadAvatar(bytes, contentType: contentType),
    );
  }

  /// Clears the profile picture. Same non-optimistic contract as
  /// [updateAvatar] — the server's snapshot is the only truth about whether the
  /// picture is gone.
  Future<void> removeAvatar() {
    return _runAvatarChange(
      () => ref.read(accountRepositoryProvider).removeAvatar(),
    );
  }

  /// Runs one avatar mutation behind the in-flight flag, with the same epoch
  /// guard the rest of this notifier uses.
  ///
  /// The guard matters more here than anywhere else in the file: an upload can
  /// easily outlive a sign-out on a slow connection, and a late response that
  /// repainted the profile would be showing the DEPARTING user's picture to
  /// whoever signed in next.
  Future<void> _runAvatarChange(Future<UserProfile> Function() change) async {
    if (ref.read(avatarUploadingProvider)) return; // double-tap guard
    final epoch = _epoch;
    ref.read(avatarUploadingProvider.notifier).state = true;
    try {
      final updated = await change();
      if (epoch != _epoch) return; // auth changed mid-flight — discard
      state = AsyncData(updated);
    } finally {
      // Cleared even when superseded: the flag belongs to the SCREEN, and the
      // next user's screen must not open with a stuck spinner.
      ref.read(avatarUploadingProvider.notifier).state = false;
    }
  }

  Future<void> _load(int epoch) async {
    try {
      final profile = await ref.read(accountRepositoryProvider).fetchProfile();
      if (epoch != _epoch) return; // superseded (logout, or a newer refresh)
      state = AsyncData(profile);
    } catch (error, stack) {
      if (epoch != _epoch) return;
      state = AsyncError<UserProfile>(error, stack);
    }
  }
}

/// The signed-in user's account snapshot. Resets on logout — never persisted.
final profileProvider =
    AsyncNotifierProvider<ProfileNotifier, UserProfile>(ProfileNotifier.new);

/// The avatar IMAGE BYTES for whatever profile is currently loaded.
///
/// Derived from [profileProvider] rather than fetched independently, so it
/// re-reads on every snapshot change — a new upload, a removal, a different
/// user after sign-out — with no cache key to get stale. Null means "no picture"
/// and an error means "could not load one"; the screen renders initials for both,
/// so a failure here is never worse than a plain-looking profile.
final avatarBytesProvider = FutureProvider<Uint8List?>((ref) async {
  final profile = ref.watch(profileProvider).valueOrNull;
  if (profile == null || !profile.hasAvatar) return null;
  return ref.read(accountRepositoryProvider).fetchAvatarBytes();
});
