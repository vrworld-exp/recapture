// test/auth/profile_avatar_test.dart
//
// The profile-picture surface on the Profile screen: rendering the picture
// inside the existing gold ring, its fallbacks, the source sheet, the remove
// confirmation, and the failure mapping.
//
// The load-bearing cases:
//   - an EXPIRED/failing presigned URL degrades to initials, never to a broken
//     image glyph (this WILL happen in real use — the URL lives ~1h)
//   - dismissing the remove confirm calls removeAvatar() ZERO times
//   - a failed upload keeps the previous profile on screen and shows MAPPED
//     copy — the raw error never reaches the tree
//   - Sign out stays enabled while an upload is in flight
//
// Hermetic: a fake account repository, a fake gallery picker, a driveable auth
// notifier, and an HttpOverrides that serves one real 1×1 PNG so the loaded-image
// case is genuinely loaded rather than merely mounted. No router (the screen is
// pumped directly, matching profile_screen_test.dart).
//
// TRAPS this file has to respect (both hit in the sibling profile tests):
//   - a CircularProgressIndicator NEVER settles, so anywhere the upload spinner
//     is on screen use pump(Duration), never pumpAndSettle — or the test hangs.
//   - the masked contact contains • (•); write such literals as escapes.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoActionSheet;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/data/datasources/avatar_image_picker.dart';
import 'package:recapture/data/local/user_role_store.dart';
import 'package:recapture/data/repositories/account_repository.dart';
import 'package:recapture/domain/entities/auth_session.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/avatar_upload_failure.dart';
import 'package:recapture/domain/entities/user_profile.dart';
import 'package:recapture/domain/entities/user_role.dart';
import 'package:recapture/presentation/screens/profile/profile_screen.dart';
import 'package:recapture/utils/analytics.dart';

/// A presigned-looking URL. Nothing ever fetches it for real — [_FakeHttpClient]
/// answers every request — but it is shaped like the thing the server mints so a
/// reader is not misled about what this field holds.
const String kAvatarUrl =
    'https://bucket.s3.amazonaws.com/dev/avatars/u1/pic.jpg?X-Amz-Signature=abc';

/// The one raw error string a failing upload carries. Asserted ABSENT from the
/// widget tree — the Screen-9F convention is that transport errors never reach
/// user-facing copy.
const String kRawError = 'DioException [connection error]: SocketException';

class _FakeAccountRepository implements AccountRepository {
  _FakeAccountRepository(this.profile);

  UserProfile profile;
  UserRole role = UserRole.user;

  int uploadCalls = 0;
  int removeCalls = 0;

  /// When set, uploadAvatar throws it instead of succeeding.
  Object? uploadError;

  /// When set, uploadAvatar waits on it — lets a test hold the upload in flight.
  Completer<void>? uploadGate;

  /// Served by fetchAvatarBytes. Set by a successful upload, cleared by a
  /// removal — mirroring what the server would then serve.
  Uint8List? avatarBytes;

  /// When set, fetchAvatarBytes throws it (an unreadable picture).
  Object? avatarBytesError;

  @override
  Future<UserRole> fetchRole() async => role;

  @override
  Future<UserProfile> fetchProfile() async => profile;

  @override
  Future<UserProfile> updateDisplayName(String name) async {
    profile = profile.copyWith(displayName: name);
    return profile;
  }

  @override
  Future<UserProfile> uploadAvatar(
    Uint8List bytes, {
    required String contentType,
  }) async {
    uploadCalls++;
    if (uploadGate != null) await uploadGate!.future;
    if (uploadError != null) throw uploadError!;
    profile = profile.copyWith(avatarUrl: kAvatarUrl);
    avatarBytes = kPngBytes; // the server would now serve a picture
    return profile;
  }

  @override
  Future<UserProfile> removeAvatar() async {
    removeCalls++;
    // A removal returns a SNAPSHOT WITHOUT the url — copyWith cannot clear a
    // nullable field, so rebuild it (which is exactly why the notifier takes
    // the server's snapshot rather than patching locally).
    profile = _profile(
      displayName: profile.displayName,
      avatarUrl: null,
      role: profile.role,
    );
    avatarBytes = null;
    return profile;
  }

  @override
  Future<Uint8List?> fetchAvatarBytes() async {
    if (avatarBytesError != null) throw avatarBytesError!;
    return avatarBytes;
  }
}

/// A minimal JPEG header — enough for anything that sniffs magic bytes. The
/// repository is faked, so the body past the marker never matters.
final Uint8List kJpegBytes = Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]);

/// A REAL 1×1 PNG. This one has to decode for real — [Image.memory] runs the
/// actual codec, so a header-only stub would take the errorBuilder path and
/// every "renders the picture" assertion would pass for the wrong reason.
final Uint8List kPngBytes = Uint8List.fromList(_kTransparentPng);

/// Gallery picker double. Returns a fixed pick, or null to simulate a cancel.
class _FakeAvatarPicker implements AvatarImagePicker {
  int pickCalls = 0;
  bool cancel = false;
  Object? error;

  /// A selection Android parked while the screen was torn down. Non-null makes
  /// the screen's mount-time recovery find one.
  bool hasLostPick = false;
  int recoverCalls = 0;

  /// Makes the mount-time probe blow up, the way a platform channel can.
  Object? recoverError;

  @override
  Future<PickedAvatar?> pickAvatar() async {
    pickCalls++;
    if (error != null) throw error!;
    if (cancel) return null;
    return _picked();
  }

  @override
  Future<PickedAvatar?> recoverLostAvatar() async {
    recoverCalls++;
    if (recoverError != null) throw recoverError!;
    if (!hasLostPick) return null;
    hasLostPick = false; // reclaimed once, like the real plugin
    return _picked();
  }

  PickedAvatar _picked() => PickedAvatar(
        bytes: kJpegBytes,
        contentType: 'image/jpeg',
      );
}

class _CountingAuthNotifier extends AuthNotifier {
  int logoutCalls = 0;

  @override
  AuthState build() => const AuthRestoring();

  void emit(AuthState next) => state = next;

  @override
  Future<void> logout() async {
    logoutCalls++;
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
  String? avatarUrl,
  UserRole role = UserRole.user,
}) =>
    UserProfile(
      id: 'u1',
      role: role,
      displayName: displayName,
      // '+91 ••••• ••210' — written as escapes (a literal • in a test source
      // file is the trap the sibling profile tests already hit).
      contactMasked: '+91 ••••• ••210',
      createdAt: DateTime.utc(2026, 3, 14),
      avatarUrl: avatarUrl,
      avatarUrlExpiresAt:
          avatarUrl == null ? null : DateTime.utc(2026, 3, 14, 1),
    );

void main() {
  late _FakeAccountRepository account;
  late _FakeAvatarPicker picker;
  late _FakeUserRoleStore roleStore;
  late ProviderContainer container;
  late List<({String name, Map<String, Object?> props})> events;

  setUp(() {
    account = _FakeAccountRepository(_profile());
    picker = _FakeAvatarPicker();
    roleStore = _FakeUserRoleStore();
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
    // Serve a real PNG so the loaded-image case is genuinely loaded. Individual
    // tests flip _FakeHttpClient.fail to exercise the errorBuilder path.
    _FakeHttpClient.fail = false;
    HttpOverrides.global = _FakeHttpOverrides();
    // The image cache is a BINDING-level singleton shared by every test in this
    // file. Without this, a test that expects the error path would be served the
    // successfully-decoded image an earlier test cached under the same URL.
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() {
    Analytics.testSink = null;
    HttpOverrides.global = null;
  });

  Future<_CountingAuthNotifier> pumpScreen(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    container = ProviderContainer(overrides: [
      accountRepositoryProvider.overrideWithValue(account),
      avatarImagePickerProvider.overrideWithValue(picker),
      userRoleStoreProvider.overrideWithValue(roleStore),
      authProvider.overrideWith(_CountingAuthNotifier.new),
    ]);
    addTearDown(container.dispose);

    final auth = container.read(authProvider.notifier) as _CountingAuthNotifier;
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

  /// Opens the avatar source sheet by tapping the camera-badge affordance.
  Future<void> openAvatarSheet(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.photo_camera_outlined));
    await tester.pumpAndSettle();
  }

  // ── Rendering ──────────────────────────────────────────────────────────────

  testWidgets('a profile with a picture renders it, not the initials',
      (tester) async {
    account.profile = _profile(avatarUrl: kAvatarUrl);
    account.avatarBytes = kPngBytes;

    await tester.runAsync(() async {
      await pumpScreen(tester);
      // Let the (faked) byte fetch + the real decode complete.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    // MemoryImage, not NetworkImage: the bytes come through our own API, since
    // the browser build cannot fetch the presigned S3 URL (no CORS on the raw
    // bucket) and that URL expires within the hour anyway.
    expect(image.image, isA<MemoryImage>());
    expect(image.fit, BoxFit.cover);
    // Clipped to the ring, never painted over it.
    expect(
      find.ancestor(of: find.byType(Image), matching: find.byType(ClipOval)),
      findsOneWidget,
    );
    // The picture WON — the initials fallback is gone.
    expect(find.text('AK'), findsNothing);
  });

  testWidgets(
      'a picture that cannot be loaded degrades to initials, never a broken glyph',
      (tester) async {
    account.profile = _profile(avatarUrl: kAvatarUrl);
    account.avatarBytesError = Exception('avatar fetch failed');

    await tester.runAsync(() async {
      await pumpScreen(tester);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(find.text('AK'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.broken_image), findsNothing);
    expect(find.byIcon(Icons.error), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('no picture → initials and NO Image widget in the tree',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('AK'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('no avatarUrl and no name → the person glyph', (tester) async {
    account.profile = _profile(displayName: null);
    await pumpScreen(tester);

    expect(find.byIcon(Icons.person_outline), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  // ── The source sheet ───────────────────────────────────────────────────────

  testWidgets('tapping the avatar opens the sheet; Remove is ABSENT with no photo',
      (tester) async {
    await pumpScreen(tester);
    await openAvatarSheet(tester);

    expect(find.text('Choose photo'), findsOneWidget);
    // Offering to remove a picture that does not exist would be a dead —
    // and destructive-styled — option.
    expect(find.text('Remove photo'), findsNothing);
  });

  testWidgets('Remove is PRESENT once there is a photo', (tester) async {
    account.profile = _profile(avatarUrl: kAvatarUrl);
    await pumpScreen(tester);
    await openAvatarSheet(tester);

    expect(find.text('Choose photo'), findsOneWidget);
    expect(find.text('Remove photo'), findsOneWidget);
  });

  testWidgets('iOS gets the Cupertino action sheet', (tester) async {
    account.profile = _profile(avatarUrl: kAvatarUrl);
    // Forced via Theme.platform (not Platform.isIOS) — the reason the sheet
    // branches on the theme at all.
    await pumpScreen(tester, platform: TargetPlatform.iOS);
    await openAvatarSheet(tester);

    expect(find.byType(CupertinoActionSheet), findsOneWidget);
    expect(find.text('Choose photo'), findsOneWidget);
    expect(find.text('Remove photo'), findsOneWidget);
  });

  // ── Remove ─────────────────────────────────────────────────────────────────

  testWidgets('remove: dismissing the confirm calls removeAvatar() ZERO times',
      (tester) async {
    account.profile = _profile(avatarUrl: kAvatarUrl);
    await pumpScreen(tester);
    await openAvatarSheet(tester);

    await tester.tap(find.text('Remove photo'));
    await tester.pumpAndSettle();

    expect(find.text('Remove photo?'), findsOneWidget);
    expect(find.text('Your initials will be shown instead.'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(account.removeCalls, 0);
    expect(
      events.where((e) => e.name == AnalyticsEvents.profileAvatarRemoved),
      isEmpty,
    );
  });

  testWidgets('remove: confirming calls removeAvatar() EXACTLY once',
      (tester) async {
    account.profile = _profile(avatarUrl: kAvatarUrl);
    await pumpScreen(tester);
    await openAvatarSheet(tester);

    await tester.tap(find.text('Remove photo'));
    await tester.pumpAndSettle();
    // The confirm's destructive action, targeted inside the dialog.
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Remove'),
      ),
    );
    await tester.pumpAndSettle();

    expect(account.removeCalls, 1);
    // Back to initials, and the tree holds no Image any more.
    expect(find.text('AK'), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    final removed = events
        .where((e) => e.name == AnalyticsEvents.profileAvatarRemoved)
        .toList();
    expect(removed, hasLength(1));
    // device_type and nothing else — no id, no key, no URL.
    expect(removed.single.props.keys.toList(), ['device_type']);
  });

  // ── Upload ─────────────────────────────────────────────────────────────────

  testWidgets('choosing a photo uploads it and repaints', (tester) async {
    await pumpScreen(tester);
    await openAvatarSheet(tester);

    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();

    expect(picker.pickCalls, 1);
    expect(account.uploadCalls, 1);

    final updated = events
        .where((e) => e.name == AnalyticsEvents.profileAvatarUpdated)
        .toList();
    expect(updated, hasLength(1));
    expect(updated.single.props.keys.toList(), ['device_type']);
    // Never the key, the URL, or a file path.
    expect(updated.single.props.values.join(), isNot(contains('/')));
  });

  testWidgets('a cancelled pick is a silent no-op', (tester) async {
    picker.cancel = true;
    await pumpScreen(tester);
    await openAvatarSheet(tester);

    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();

    expect(picker.pickCalls, 1);
    expect(account.uploadCalls, 0);
    expect(find.byType(SnackBar), findsNothing);
    expect(events.where((e) => e.name.startsWith('profile_avatar')), isEmpty);
  });

  // ── Android lost-pick recovery ─────────────────────────────────────────────
  //
  // When Android tears the activity down while the gallery is in front, the
  // future awaiting the pick dies with the old isolate: the screen is rebuilt
  // and NOTHING reports the selection. Without the recovery below, the user's
  // photo is silently gone — the "I picked a photo and nothing happened" bug.

  testWidgets('a pick Android parked is reclaimed on mount and uploaded',
      (tester) async {
    picker.hasLostPick = true;

    await pumpScreen(tester); // the rebuild after the activity came back
    await tester.pumpAndSettle();

    expect(picker.recoverCalls, 1);
    expect(account.uploadCalls, 1, reason: 'the parked photo must still upload');
    // The gallery is NOT reopened — the selection already happened.
    expect(picker.pickCalls, 0);
  });

  testWidgets('nothing parked → mount recovery is a silent no-op',
      (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(picker.recoverCalls, 1);
    expect(account.uploadCalls, 0);
    expect(find.byType(SnackBar), findsNothing);
    expect(events.where((e) => e.name.startsWith('profile_avatar')), isEmpty);
  });

  // REGRESSION: the mount probe runs unprompted on every open. When it failed,
  // it reported like a real upload failure — so merely opening Profile threw an
  // error snackbar about a photo the user had never chosen.
  testWidgets('a FAILING mount probe stays silent — no snackbar, no event',
      (tester) async {
    picker.recoverError = Exception('platform channel blew up');

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(picker.recoverCalls, 1);
    expect(find.byType(SnackBar), findsNothing);
    expect(
      events.where((e) => e.name == AnalyticsEvents.profileAvatarFailed),
      isEmpty,
      reason: 'a probe the user never asked for must not report a failure',
    );
    // The screen is otherwise perfectly usable.
    expect(find.text('Ashish Kuldeep'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets(
      'a failed upload keeps the previous profile and shows MAPPED copy only',
      (tester) async {
    account.uploadError = const AvatarUploadException(
      AvatarUploadFailure.network,
      kRawError,
    );
    await pumpScreen(tester);
    await openAvatarSheet(tester);

    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();

    // The previous snapshot is still on screen — no half-applied avatar.
    expect(find.text('Ashish Kuldeep'), findsOneWidget);
    expect(find.text('AK'), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    // Mapped copy…
    expect(
      find.text("Couldn't reach the server. Check your connection."),
      findsOneWidget,
    );
    // …and NOT the raw transport error, anywhere in the tree.
    expect(find.textContaining('DioException'), findsNothing);
    expect(find.textContaining('SocketException'), findsNothing);
    expect(find.textContaining(kRawError), findsNothing);

    final failed = events
        .where((e) => e.name == AnalyticsEvents.profileAvatarFailed)
        .toList();
    expect(failed, hasLength(1));
    expect(failed.single.props['reason'], 'network');
    // The mapped bucket + device_type only — never the raw error.
    expect(failed.single.props.keys.toSet(), {'reason', 'device_type'});
  });

  testWidgets('an unsupported file type is refused with its own copy',
      (tester) async {
    // Decided LOCALLY from the magic bytes — the picker throws before any
    // upload is attempted.
    picker.error =
        const AvatarUploadException(AvatarUploadFailure.unsupportedType);
    await pumpScreen(tester);
    await openAvatarSheet(tester);

    await tester.tap(find.text('Choose photo'));
    await tester.pumpAndSettle();

    expect(account.uploadCalls, 0);
    expect(
      find.text('That file type is not supported. Choose a JPG or PNG.'),
      findsOneWidget,
    );
    expect(
      events
          .firstWhere((e) => e.name == AnalyticsEvents.profileAvatarFailed)
          .props['reason'],
      'unsupported_type',
    );
  });

  // ── In-flight behaviour ────────────────────────────────────────────────────

  testWidgets('Sign out stays enabled while an avatar upload is in flight',
      (tester) async {
    account.uploadGate = Completer<void>();
    final auth = await pumpScreen(tester);
    await openAvatarSheet(tester);

    await tester.tap(find.text('Choose photo'));
    // NOT pumpAndSettle: the upload spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(account.uploadCalls, 1);
    // The identity block is still painted — NOT dropped into a skeleton…
    expect(find.text('Ashish Kuldeep'), findsOneWidget);
    // …and the upload spinner is up.
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    // Sign out is still enabled and works end to end.
    final signOut = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(signOut.onPressed, isNotNull);

    await tester.tap(find.text('Sign out'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Sign out'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(auth.logoutCalls, 1);

    account.uploadGate!.complete();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('double-tapping Choose photo fires exactly ONE upload',
      (tester) async {
    account.uploadGate = Completer<void>();
    await pumpScreen(tester);
    await openAvatarSheet(tester);

    // Two taps with no settle between them — the sheet is mid-dismissal on the
    // second, which is exactly the window a real double-tap lands in.
    await tester.tap(find.text('Choose photo'));
    await tester.pump();
    await tester.tap(find.text('Choose photo'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));

    // A third attempt, this time through the avatar itself while the upload is
    // still in flight: the in-flight guard must not even open the sheet.
    await tester.tap(
      find.byIcon(Icons.photo_camera_outlined),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Choose photo'), findsNothing);

    expect(account.uploadCalls, 1);

    account.uploadGate!.complete();
    await tester.pump(const Duration(milliseconds: 400));
  });
}

// ── Network image plumbing ───────────────────────────────────────────────────
//
// flutter_test's default HttpClient answers every request with a 400, which
// would make EVERY case look like the expired-URL case. These serve one real
// 1×1 PNG instead, and flip to a 404 when a test wants the errorBuilder path.

class _FakeHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

class _FakeHttpClient implements HttpClient {
  /// When true, every response is a 404 — what an EXPIRED presigned URL looks
  /// like from the client's side.
  static bool fail = false;

  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeHttpClientRequest();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeHttpClientResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientResponse implements HttpClientResponse {
  @override
  int get statusCode => _FakeHttpClient.fail ? 404 : 200;

  @override
  int get contentLength => _FakeHttpClient.fail ? 0 : _kTransparentPng.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(
      _FakeHttpClient.fail ? <List<int>>[] : <List<int>>[_kTransparentPng],
    ).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A valid 1×1 transparent PNG — the smallest thing the image codec accepts.
final List<int> _kTransparentPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
