// test/projects/projects_screen_role_gating_test.dart
//
// P7-A staff gating on the Projects screen: USER-role accounts see the
// pre-existing screen with ZERO change (no segmented control, no Live tab);
// staff (MODEL_ARTIST/ADMIN via isStaffProvider) get the "My projects /
// Live projects" control, and the Live tab renders the cross-user list with
// its Export action. Hermetic: every provider the tree watches is overridden.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/live_projects_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/projects/projects_screen.dart';

/// Serves the owner list without repositories/Hive (same pattern as the
/// dev-tools screen test).
class _FakeProjectsNotifier extends ProjectsNotifier {
  _FakeProjectsNotifier({this.modelCount = 0});
  final int modelCount;

  @override
  Future<List<Project>> build() async => [
        Project(
          id: 'mine-1',
          name: 'My vase',
          status: ProjectStatus.processing,
          updatedAt: DateTime(2026, 7, 12),
          totalPhotos: 36,
          modelCount: modelCount,
        ),
      ];
}

/// Serves one live page without touching the repository.
class _FakeLiveProjectsNotifier extends LiveProjectsNotifier {
  @override
  Future<LiveProjectsState> build() async => LiveProjectsState(
        items: [
          LiveProject(
            id: 'live-1',
            name: 'Someone else’s statue',
            status: ProjectStatus.completed,
            updatedAt: DateTime(2026, 7, 10),
            ownerId: 'owner123456',
            totalPhotos: 37,
          ),
        ],
        nextCursor: null,
      );
}

Widget _app({required bool isStaff, int mineModelCount = 0}) {
  return ProviderScope(
    overrides: [
      projectsProvider
          .overrideWith(() => _FakeProjectsNotifier(modelCount: mineModelCount)),
      liveProjectsProvider.overrideWith(_FakeLiveProjectsNotifier.new),
      isStaffProvider.overrideWithValue(isStaff),
      // The Live tab reads the admin flag for its delete affordance; without
      // this override the real userRoleProvider chain would open Hive.
      isAdminProvider.overrideWithValue(false),
    ],
    child: const MaterialApp(home: ProjectsScreen()),
  );
}

/// Bounded pump: the processing project card renders an infinite progress
/// spinner, so `pumpAndSettle` would never settle — pump fixed frames instead.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('USER role: zero UI change — no tabs, no Live projects',
      (tester) async {
    await tester.pumpWidget(_app(isStaff: false));
    await _pumpFrames(tester);

    expect(find.byType(SegmentedButton<Object?>), findsNothing);
    expect(find.byType(SegmentedButton), findsNothing);
    expect(find.text('Live projects'), findsNothing);
    expect(find.text('My projects'), findsNothing);
    // The normal owner list + FAB are untouched.
    expect(find.text('My vase'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('staff: segmented control present; Live tab lists other users\' projects with Export',
      (tester) async {
    await tester.pumpWidget(_app(isStaff: true));
    await _pumpFrames(tester);

    // Both tabs offered; My projects is the default and unchanged.
    expect(find.text('My projects'), findsOneWidget);
    expect(find.text('Live projects'), findsOneWidget);
    expect(find.text('My vase'), findsOneWidget);

    await tester.tap(find.text('Live projects'));
    await _pumpFrames(tester);

    // The cross-user list with photo count, opaque owner id, and Export.
    expect(find.text('Someone else’s statue'), findsOneWidget);
    expect(find.textContaining('37 photos'), findsOneWidget);
    expect(find.textContaining('Owner …123456'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    // Read-only tab: no create FAB here.
    expect(find.byType(FloatingActionButton), findsNothing);

    // Switching back restores the owner list.
    await tester.tap(find.text('My projects'));
    await _pumpFrames(tester);
    expect(find.text('My vase'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('non-staff owner gets Generate + Models on their own project',
      (tester) async {
    // The 3D-model flow is no longer staff-only: an owner sees "Generate 3D
    // model" on their exportable (PROCESSING) project, and "Models" once a
    // viewable model exists — all without any staff tab chrome.
    await tester.pumpWidget(_app(isStaff: false, mineModelCount: 1));
    await _pumpFrames(tester);

    expect(find.text('My vase'), findsOneWidget);
    expect(find.text('Generate 3D model'), findsOneWidget);
    expect(find.text('Models'), findsOneWidget);
    // Still no staff-only surface.
    expect(find.byType(SegmentedButton), findsNothing);
    expect(find.text('Live projects'), findsNothing);
  });
}
