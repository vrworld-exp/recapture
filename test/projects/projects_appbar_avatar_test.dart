// test/projects/projects_appbar_avatar_test.dart
//
// The Projects app-bar profile action. It shows the user's ACTUAL picture when
// the account has one, and the previous `account_circle_outlined` glyph when it
// does not — the "if there is an avatar on the server, and only then" rule.
//
// The failure case is the one worth pinning: an avatar fetch that errors (an
// expired session, a cold backend, no network) must degrade to the glyph. An app
// bar with a hole in it where the profile button used to be would be a worse
// regression than never showing the picture at all.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/application/auth/profile_provider.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/projects/projects_screen.dart';

/// Serves one owner project without repositories/Hive, and makes the
/// focus-driven refresh a no-op so nothing reaches the network.
class _FakeProjectsNotifier extends ProjectsNotifier {
  @override
  Future<List<Project>> build() async => [
        Project(
          id: 'mine-1',
          name: 'My vase',
          // COMPLETED, not PROCESSING: a processing card spins forever, and
          // these cases want a tree that can settle.
          status: ProjectStatus.completed,
          updatedAt: DateTime(2026, 7, 12),
          totalPhotos: 36,
        ),
      ];

  @override
  Future<void> refresh() async {}
}

/// A REAL 1×1 transparent PNG. [Image.memory] runs the actual codec, so a
/// header-only stub would take the errorBuilder path and the "renders the
/// picture" assertion would pass for the wrong reason.
final Uint8List kPngBytes = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Widget _app(Future<Uint8List?> Function() avatar) {
  return ProviderScope(
    overrides: [
      projectsProvider.overrideWith(_FakeProjectsNotifier.new),
      isStaffProvider.overrideWithValue(false),
      isAdminProvider.overrideWithValue(false),
      avatarBytesProvider.overrideWith((ref) => avatar()),
    ],
    child: const MaterialApp(home: ProjectsScreen()),
  );
}

void main() {
  setUp(() {
    // The image cache is a BINDING-level singleton shared across this file —
    // clear it so one case's decoded picture can't be served to another.
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  testWidgets('an account WITH a picture renders it in place of the glyph',
      (tester) async {
    await tester.pumpWidget(_app(() async => kPngBytes));
    await tester.pumpAndSettle();

    final avatar = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(Image),
    );
    expect(avatar, findsOneWidget);
    // MemoryImage, not NetworkImage: the picture comes through our own API, not
    // from the snapshot's presigned (CORS-less, hour-lived) avatarUrl.
    expect(tester.widget<Image>(avatar).image, isA<MemoryImage>());
    // Clipped to a circle, and the glyph is gone.
    expect(
      find.ancestor(of: avatar, matching: find.byType(ClipOval)),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.account_circle_outlined), findsNothing);
  });

  testWidgets('an account with NO picture keeps the plain glyph',
      (tester) async {
    await tester.pumpWidget(_app(() async => null));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.byType(Image)),
      findsNothing,
    );
  });

  testWidgets('a failed avatar fetch degrades to the glyph, not to nothing',
      (tester) async {
    await tester.pumpWidget(_app(() async => throw Exception('offline')));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
  });

  testWidgets('the profile action is still tappable while the avatar loads',
      (tester) async {
    // An avatar fetch that never resolves must not swallow the button: the way
    // to the Profile screen cannot depend on a picture arriving.
    await tester.pumpWidget(_app(() => Completer<Uint8List?>().future));
    await tester.pump();

    // Scoped to the Profile action by its glyph: the app bar carries the Catalog
    // entry point too, and this test is about the way to Profile surviving a
    // stalled picture — not about how many actions the bar happens to have.
    final button = find.descendant(
      of: find.byType(AppBar),
      matching: find.widgetWithIcon(IconButton, Icons.account_circle_outlined),
    );
    expect(button, findsOneWidget);
    expect(tester.widget<IconButton>(button).onPressed, isNotNull);
    expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
  });

  testWidgets('the app bar offers the Catalog entry point alongside Profile',
      (tester) async {
    // The catalog is reachable from Projects (T-006). A stalled avatar fetch
    // must not take it down with it either — the two actions are independent.
    await tester.pumpWidget(_app(() => Completer<Uint8List?>().future));
    await tester.pump();

    final catalog = find.descendant(
      of: find.byType(AppBar),
      matching: find.widgetWithIcon(IconButton, Icons.storefront_outlined),
    );
    expect(catalog, findsOneWidget);
    expect(tester.widget<IconButton>(catalog).onPressed, isNotNull);
    expect(find.byIcon(Icons.storefront_outlined), findsOneWidget);
  });
}
