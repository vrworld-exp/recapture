// test/projects/live_project_owner_test.dart
//
// The ADMIN-only "Created by" label on the Live-projects list, and the sheet it
// opens.
//
// Two things are worth pinning here, and they are not the layout:
//
//   1. THE GATE. The label is drawn only when the caller is ADMIN *and* the row
//      resolved an owner. Either half missing must fall back to the opaque
//      `Owner …a1b2c3` line the card has always shown — never to a blank space,
//      and never to a name a MODEL_ARTIST was not meant to see. isAdminProvider
//      fails closed, so a failed role fetch lands in the same fallback.
//   2. THE CONTACT BOUNDARY. The raw phone/email exist ONLY inside the sheet,
//      and only after it is opened. Nothing about them may reach the list.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/profile_provider.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/live_projects_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_owner.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/domain/entities/user_role.dart';
import 'package:recapture/presentation/screens/projects/projects_screen.dart';

import 'repo_fake_defaults.dart';

const _summary = ProjectOwnerSummary(
  id: 'owner1234567890abcdef1234',
  displayName: 'Ravi Sharma',
);

final _detail = ProjectOwnerDetail(
  id: _summary.id,
  displayName: 'Ravi Sharma',
  email: 'ravi@example.com',
  phone: '+919876543210',
  phoneVerified: true,
  role: UserRole.user,
  createdAt: DateTime.utc(2026, 3, 4),
);

/// Owner list kept empty — these tests live entirely on the Live tab.
class _FakeProjectsNotifier extends ProjectsNotifier {
  @override
  Future<List<Project>> build() async => const <Project>[];
}

class _FakeLiveProjectsNotifier extends LiveProjectsNotifier {
  _FakeLiveProjectsNotifier(this.owner);

  final ProjectOwnerSummary? owner;

  @override
  Future<LiveProjectsState> build() async => LiveProjectsState(
        items: [
          LiveProject(
            id: 'live-1',
            name: 'Someone else’s statue',
            status: ProjectStatus.completed,
            updatedAt: DateTime(2026, 7, 10),
            ownerId: _summary.id,
            owner: owner,
            totalPhotos: 37,
          ),
        ],
        nextCursor: null,
      );
}

/// An account that exists but has no way to reach it — an identifier can be
/// cleared after the fact, and the sheet must say so rather than draw two
/// empty rows.
final _contactless = ProjectOwnerDetail(
  id: _summary.id,
  displayName: 'Ravi Sharma',
  role: UserRole.user,
  createdAt: DateTime.utc(2026, 3, 4),
);

/// Answers the two owner reads; everything else on the repository throws.
class _FakeOwnerRepo
    with
        FakeModelGenerationDefaults,
        FakeAutoGenerationDefaults,
        FakeModelOptimizeDefaults,
        FakeOwnerModelListDefaults,
        FakePreviewBrowseDefaults,
        FakeModelSubmissionDefaults,
        FakeAdminDeleteDefaults
    implements LiveProjectsRepository {
  _FakeOwnerRepo({this.failure, ProjectOwnerDetail? detail})
      : detail = detail ?? _detail;

  /// When set, the identity call fails with it — the sheet's error path.
  final LiveProjectsFailure? failure;

  final ProjectOwnerDetail detail;

  int ownerCalls = 0;

  @override
  Future<ProjectOwnerDetail> owner(String userId) async {
    ownerCalls += 1;
    if (failure != null) throw LiveProjectsException(failure!);
    return detail;
  }

  @override
  Future<Uint8List?> ownerAvatarBytes(String userId) async => null;

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      const LiveProjectsPage(items: [], nextCursor: null);

  @override
  Future<Map<String, dynamic>> export(String projectId) async =>
      throw UnimplementedError('not used here');

  @override
  Future<PreviewDeleteResult> deletePhotos(
    String projectId,
    List<String> keys,
  ) async =>
      throw UnimplementedError('not used here');
}

Widget _app({
  required bool isAdmin,
  ProjectOwnerSummary? owner = _summary,
  _FakeOwnerRepo? repo,
}) {
  return ProviderScope(
    overrides: [
      projectsProvider.overrideWith(_FakeProjectsNotifier.new),
      liveProjectsProvider.overrideWith(() => _FakeLiveProjectsNotifier(owner)),
      // Staff, so the Live tab exists at all; admin is the separate gate under
      // test.
      isStaffProvider.overrideWithValue(true),
      isAdminProvider.overrideWithValue(isAdmin),
      liveProjectsRepositoryProvider
          .overrideWithValue(repo ?? _FakeOwnerRepo()),
      avatarBytesProvider.overrideWith((ref) async => null),
    ],
    child: const MaterialApp(home: ProjectsScreen()),
  );
}

/// Bounded pump — the same reason as the sibling live-projects tests: a
/// processing card spins forever, so pumpAndSettle never settles.
Future<void> _pumpFrames(WidgetTester tester, [int frames = 5]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _openLiveTab(WidgetTester tester) async {
  await tester.tap(find.text('Live projects'));
  await _pumpFrames(tester);
}

void main() {
  group('the "Created by" label', () {
    testWidgets('an ADMIN sees the name, and the opaque owner line is gone',
        (tester) async {
      await tester.pumpWidget(_app(isAdmin: true));
      await _openLiveTab(tester);

      expect(find.text('Created by Ravi Sharma'), findsOneWidget);
      expect(find.textContaining('Owner …'), findsNothing);
    });

    testWidgets('a MODEL_ARTIST keeps the opaque owner line and gets no name',
        (tester) async {
      // The server omits `owner` below ADMIN, so a non-admin row arrives
      // without one — and isAdmin is false besides. Either alone is enough.
      await tester.pumpWidget(_app(isAdmin: false, owner: null));
      await _openLiveTab(tester);

      expect(find.text('Created by Ravi Sharma'), findsNothing);
      expect(find.textContaining('Owner …'), findsOneWidget);
    });

    testWidgets('an admin whose row carries no owner falls back, not blank',
        (tester) async {
      // The account behind the row was deleted: the server leaves `owner`
      // absent. The card must still say who it belonged to, opaquely.
      await tester.pumpWidget(_app(isAdmin: true, owner: null));
      await _openLiveTab(tester);

      expect(find.textContaining('Owner …'), findsOneWidget);
    });

    testWidgets('an owner with no name falls back to the short id in the label',
        (tester) async {
      await tester.pumpWidget(
        _app(isAdmin: true, owner: ProjectOwnerSummary(id: _summary.id)),
      );
      await _openLiveTab(tester);

      expect(find.textContaining('Created by …'), findsOneWidget);
    });

    testWidgets('the list itself never carries a contact detail',
        (tester) async {
      final repo = _FakeOwnerRepo();
      await tester.pumpWidget(_app(isAdmin: true, repo: repo));
      await _openLiveTab(tester);

      // Not fetched until asked for — a page of projects must not become a
      // page of identity lookups.
      expect(repo.ownerCalls, 0);
      expect(find.textContaining('9876543210'), findsNothing);
      expect(find.textContaining('ravi@example.com'), findsNothing);
    });
  });

  group('the owner sheet', () {
    testWidgets('tapping the label opens it with the RAW phone and email',
        (tester) async {
      final repo = _FakeOwnerRepo();
      await tester.pumpWidget(_app(isAdmin: true, repo: repo));
      await _openLiveTab(tester);

      await tester.tap(find.text('Created by Ravi Sharma'));
      await _pumpFrames(tester, 10);

      expect(repo.ownerCalls, 1);
      expect(find.text('Created by'), findsOneWidget);
      expect(find.text('+919876543210'), findsOneWidget);
      expect(find.text('ravi@example.com'), findsOneWidget);
      expect(find.text('March 2026'), findsOneWidget);
    });

    testWidgets('a refused lookup shows mapped copy, never a code',
        (tester) async {
      final repo = _FakeOwnerRepo(failure: LiveProjectsFailure.forbidden);
      await tester.pumpWidget(_app(isAdmin: true, repo: repo));
      await _openLiveTab(tester);

      await tester.tap(find.text('Created by Ravi Sharma'));
      await _pumpFrames(tester, 10);

      expect(
        find.text('Your account no longer has admin access.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      // The header still names who was tapped — a failed contact read must not
      // leave the sheet anonymous.
      expect(find.text('Ravi Sharma'), findsOneWidget);
    });

    testWidgets('a vanished account reads as gone, not as a crash',
        (tester) async {
      final repo = _FakeOwnerRepo(failure: LiveProjectsFailure.notFound);
      await tester.pumpWidget(_app(isAdmin: true, repo: repo));
      await _openLiveTab(tester);

      await tester.tap(find.text('Created by Ravi Sharma'));
      await _pumpFrames(tester, 10);

      expect(find.text('This account no longer exists.'), findsOneWidget);
    });

    testWidgets('an account with no contact says so rather than showing gaps',
        (tester) async {
      final repo = _FakeOwnerRepo(detail: _contactless);
      await tester.pumpWidget(_app(isAdmin: true, repo: repo));
      await _openLiveTab(tester);

      await tester.tap(find.text('Created by Ravi Sharma'));
      await _pumpFrames(tester, 10);

      expect(find.text('No contact details on this account.'), findsOneWidget);
      // The rest of the sheet still renders — it is not an error state.
      expect(find.text('March 2026'), findsOneWidget);
    });
  });
}
