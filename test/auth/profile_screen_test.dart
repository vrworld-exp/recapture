// test/auth/profile_screen_test.dart
//
// The Profile screen's contract. Hermetic: a fake account repository, a driveable
// auth notifier that counts logout() calls, and no router (the screen is pumped
// directly — FlowBackScope is applied at the ROUTER, so screen tests stay
// router-free, and the auth guard is the router's job, not this screen's).
//
// The load-bearing cases:
//   - dismissing the sign-out confirm must call logout() ZERO times
//   - Sign out must stay tappable while the profile itself failed to load
//   - a double-tap must produce exactly ONE logout
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoActionSheet;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/app/theme/app_colors.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/data/local/user_role_store.dart';
import 'package:recapture/data/repositories/account_repository.dart';
import 'package:recapture/domain/entities/auth_session.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/user_profile.dart';
import 'package:recapture/domain/entities/user_role.dart';
import 'package:recapture/presentation/screens/profile/profile_screen.dart';

/// Fake repository. `profile` is served by fetchProfile unless [failProfile];
/// updateDisplayName echoes the new name back (or throws when [failUpdate]).
class _FakeAccountRepository implements AccountRepository {
  _FakeAccountRepository(this.profile);

  UserProfile profile;
  bool failProfile = false;
  bool failUpdate = false;
  UserRole role = UserRole.user;
  int updateCalls = 0;

  /// Completes fetchProfile only when this is resolved — lets a test hold the
  /// screen in AsyncLoading.
  Completer<void>? gate;

  /// Served by fetchAvatarBytes — the avatar display path.
  Uint8List? avatarBytes;

  @override
  Future<UserRole> fetchRole() async => role;

  @override
  Future<UserProfile> fetchProfile() async {
    if (gate != null) await gate!.future;
    if (failProfile) throw Exception('offline');
    return profile;
  }

  @override
  Future<UserProfile> updateDisplayName(String name) async {
    updateCalls++;
    if (failUpdate) throw Exception('rejected');
    profile = profile.copyWith(displayName: name);
    return profile;
  }

  // Avatar surface — required by the interface, unused by this file's cases.
  // The picture's own contract lives in profile_avatar_test.dart; nothing here
  // sets an avatarUrl, so these are never reached.
  @override
  Future<UserProfile> uploadAvatar(Uint8List bytes, {required String contentType}) =>
      throw UnimplementedError();

  @override
  Future<UserProfile> removeAvatar() => throw UnimplementedError();

  @override
  Future<Uint8List?> fetchAvatarBytes() async => avatarBytes;
}

/// Driveable auth double — no secure storage. Counts logout() calls and can be
/// held in-flight so a double-tap has a window to land in.
class _CountingAuthNotifier extends AuthNotifier {
  int logoutCalls = 0;
  Completer<void>? logoutGate;

  @override
  AuthState build() => const AuthRestoring();

  void emit(AuthState next) => state = next;

  @override
  Future<void> logout() async {
    logoutCalls++;
    if (logoutGate != null) await logoutGate!.future;
    state = const AuthUnauthenticated();
  }
}

class _FakeUserRoleStore implements UserRoleStore {
  UserRole? stored;

  @override
  Future<UserRole?> read() async => stored;

  @override
  Future<void> save(UserRole role) async => stored = role;

  @override
  Future<void> clear() async => stored = null;
}

UserProfile _profile({
  String? displayName = 'Ashish Kuldeep',
  String? contactMasked = '+91 ••••• ••210',
  String contactChannel = 'sms',
  UserRole role = UserRole.user,
}) =>
    UserProfile(
      id: 'u1',
      role: role,
      displayName: displayName,
      contactMasked: contactMasked,
      contactChannel: contactChannel,
      createdAt: DateTime.utc(2026, 3, 14),
    );

void main() {
  late _FakeAccountRepository account;
  late _FakeUserRoleStore roleStore;
  late ProviderContainer container;

  setUp(() {
    account = _FakeAccountRepository(_profile());
    roleStore = _FakeUserRoleStore();
  });

  /// Pumps the screen with the fakes installed. [staff] drives isStaffProvider
  /// through the real role notifier's /auth/me path.
  Future<_CountingAuthNotifier> pumpScreen(
    WidgetTester tester, {
    UserRole role = UserRole.user,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    account.role = role;
    container = ProviderContainer(overrides: [
      accountRepositoryProvider.overrideWithValue(account),
      userRoleStoreProvider.overrideWithValue(roleStore),
      authProvider.overrideWith(_CountingAuthNotifier.new),
    ]);
    addTearDown(container.dispose);

    final auth = container.read(authProvider.notifier) as _CountingAuthNotifier;
    // Establish auth so the role notifier fetches (staff gating) — the screen
    // itself never checks auth; the router guard owns that.
    auth.emit(
      AuthAuthenticated(
        AuthSession(
          accessToken: 'a',
          refreshToken: 'r',
          accessTokenExpiry:
              DateTime.now().toUtc().add(const Duration(hours: 1)),
          userId: 'u1',
        ),
      ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark.copyWith(platform: platform),
          home: const ProfileScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return auth;
  }

  testWidgets('renders the name, masked contact and initials avatar',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('Ashish Kuldeep'), findsOneWidget);
    expect(find.text('+91 ••••• ••210'), findsOneWidget);
    expect(find.text('AK'), findsOneWidget); // derived initials, not an asset
    expect(find.byIcon(Icons.phone_outlined), findsOneWidget);
    expect(find.text('Member since'), findsOneWidget);
    expect(find.text('March 2026'), findsOneWidget);
  });

  testWidgets('email channel shows the mail icon', (tester) async {
    account.profile = _profile(
      contactMasked: 'a•••@example.com',
      contactChannel: 'email',
    );
    await pumpScreen(tester);

    expect(find.text('a•••@example.com'), findsOneWidget);
    expect(find.byIcon(Icons.mail_outline), findsOneWidget);
    expect(find.byIcon(Icons.phone_outlined), findsNothing);
  });

  testWidgets('no name → "Add your name" and the fallback glyph',
      (tester) async {
    account.profile = _profile(displayName: null);
    await pumpScreen(tester);

    expect(find.text('Add your name'), findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });

  testWidgets('null contact hides the row entirely (no placeholder)',
      (tester) async {
    account.profile = _profile(contactMasked: null);
    await pumpScreen(tester);

    expect(find.byIcon(Icons.phone_outlined), findsNothing);
    expect(find.byIcon(Icons.mail_outline), findsNothing);
  });

  testWidgets('role pill: absent for a plain user, present for staff',
      (tester) async {
    await pumpScreen(tester);
    expect(find.text('Role'), findsNothing);
    expect(find.text('Model artist'), findsNothing);
    expect(find.text('User'), findsNothing);

    // Rebuild as staff.
    account.profile = _profile(role: UserRole.modelArtist);
    await pumpScreen(tester, role: UserRole.modelArtist);

    expect(find.text('Role'), findsOneWidget);
    expect(find.text('Model artist'), findsOneWidget);
  });

  testWidgets('rep tools: hidden for a plain USER, shown from SALES_REP up',
      (tester) async {
    // The only in-app door to /rep. It rides the SAME isSalesRepProvider gate
    // as the Role pill above, but is asserted separately on purpose: they are
    // two independent rows, and a refactor that kept the badge while dropping
    // this one would restore the original bug -- routes that render but that
    // nothing navigates to -- without failing a single existing test.
    //
    // Presence only, no tap: this file pumps the screen ROUTER-FREE (see the
    // header), and the row's onTap is a context.push. Where the push LANDS is
    // the router's contract and is pinned in rep_role_gating_test.dart.
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('profile_rep_tools')), findsNothing);
    expect(find.text('My restaurants'), findsNothing);

    // A SALES_REP is the lowest role that may see it -- the gate is inclusive
    // upward, so this is the boundary case, not modelArtist.
    account.profile = _profile(role: UserRole.salesRep);
    await pumpScreen(tester, role: UserRole.salesRep);

    expect(find.byKey(const ValueKey('profile_rep_tools')), findsOneWidget);
    expect(find.text('My restaurants'), findsOneWidget);
  });

  testWidgets('sign out is error-coloured, NOT the mirageRed primary CTA',
      (tester) async {
    await pumpScreen(tester);

    // Secondary (outlined) variant — not an ElevatedButton, so it can't be
    // mistaken for the primary CTA.
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.byIcon(Icons.logout), findsOneWidget);

    final style = Theme.of(tester.element(find.byType(OutlinedButton)))
        .outlinedButtonTheme
        .style!;
    expect(style.foregroundColor!.resolve(<WidgetState>{}), AppColors.error);
  });

  testWidgets('sign out: dismissing the confirm calls logout() zero times',
      (tester) async {
    final auth = await pumpScreen(tester);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out?'), findsOneWidget);
    expect(find.text("You'll need to sign in again."), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(auth.logoutCalls, 0);
  });

  testWidgets('sign out: confirming calls logout() exactly once',
      (tester) async {
    final auth = await pumpScreen(tester);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    // The dialog's destructive action carries the same label as the button, so
    // target the one inside the AlertDialog.
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Sign out'),
      ),
    );
    await tester.pumpAndSettle();

    expect(auth.logoutCalls, 1);
  });

  testWidgets('iOS gets the Cupertino action sheet, and it confirms the same',
      (tester) async {
    // Forced via Theme.platform (not Platform.isIOS) — the whole reason the
    // shared modal branches on the theme.
    final auth = await pumpScreen(tester, platform: TargetPlatform.iOS);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(CupertinoActionSheet),
        matching: find.text('Sign out'),
      ),
    );
    await tester.pumpAndSettle();

    expect(auth.logoutCalls, 1);
  });

  testWidgets('double-tapping Sign out fires logout() once', (tester) async {
    final auth = await pumpScreen(tester);
    // Hold logout() in flight so the second tap has a real window to land in.
    auth.logoutGate = Completer<void>();

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Sign out'),
      ),
    );
    // NOT pumpAndSettle: the in-flight button renders a CircularProgressIndicator,
    // which never settles. Pump past the dialog's dismiss animation explicitly.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsNothing);

    // Second tap on the (now blocked) button: it must not even re-open the
    // confirm, let alone reach logout().
    await tester.tap(find.byType(OutlinedButton), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsNothing);

    // Releasing logout() clears the in-flight flag, so the spinner goes and the
    // tree can settle again.
    auth.logoutGate!.complete();
    await tester.pumpAndSettle();

    expect(auth.logoutCalls, 1);
  });

  testWidgets('sign out stays tappable while the profile is still loading',
      (tester) async {
    account.gate = Completer<void>();
    final auth = await pumpScreen(tester);

    // Skeleton, not content.
    expect(find.text('Ashish Kuldeep'), findsNothing);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Sign out'),
      ),
    );
    await tester.pumpAndSettle();

    expect(auth.logoutCalls, 1);
    account.gate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('sign out stays tappable while the profile is in AsyncError',
      (tester) async {
    account.failProfile = true;
    final auth = await pumpScreen(tester);

    // The identity block failed…
    expect(find.text("Couldn't load your profile."), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    // …and Sign out still works end to end.
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Sign out'),
      ),
    );
    await tester.pumpAndSettle();

    expect(auth.logoutCalls, 1);
  });

  testWidgets('editing the name calls updateDisplayName and repaints',
      (tester) async {
    account.profile = _profile(displayName: null);
    await pumpScreen(tester);

    await tester.tap(find.text('Add your name'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Ashish K');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(account.updateCalls, 1);
    expect(find.text('Ashish K'), findsOneWidget);
    expect(find.text('AK'), findsOneWidget);
  });

  testWidgets('a failed rename rolls back to the previous name',
      (tester) async {
    account.failUpdate = true;
    await pumpScreen(tester);

    await tester.tap(find.text('Ashish Kuldeep'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'New Name');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(account.updateCalls, 1);
    expect(find.text('Ashish Kuldeep'), findsOneWidget);
    expect(find.text('New Name'), findsNothing);
  });
}
