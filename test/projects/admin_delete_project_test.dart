// test/projects/admin_delete_project_test.dart
//
// The ADMIN "delete a live project" curation flow:
//   • the delete affordance is ADMIN-only (a MODEL_ARTIST sees nothing);
//   • the dialog offers SOFT vs HARD and arms its CTA only when the typed
//     name matches the project (the backend re-checks regardless);
//   • confirming sends the chosen mode + confirmName and removes the row;
//   • a server-side name mismatch surfaces MAPPED copy, never a raw code.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/projects/live_projects_view.dart';
import 'repo_fake_defaults.dart';

const _projectName = 'Bad Capture 07-18';

LiveProject _lp() => LiveProject(
      id: 'proj-1',
      name: _projectName,
      status: ProjectStatus.processing,
      updatedAt: DateTime(2026, 7, 1),
      ownerId: 'owner-abcdef',
      totalPhotos: 48,
    );

class _FakeRepo
    with
        FakeModelGenerationDefaults,
        FakeAutoGenerationDefaults,
        FakeModelOptimizeDefaults,
        FakeOwnerModelListDefaults
    implements LiveProjectsRepository {
  /// (projectId, wire mode, confirmName) per deleteProject call.
  final List<(String, String, String)> deletes = [];
  LiveProjectsException? deleteFailure;

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      LiveProjectsPage(items: [_lp()], nextCursor: null);

  @override
  Future<void> deleteProject(
    String projectId, {
    required AdminDeleteMode mode,
    required String confirmName,
  }) async {
    if (deleteFailure case final failure?) throw failure;
    deletes.add((projectId, mode.wire, confirmName));
  }

  @override
  Future<Map<String, dynamic>> export(String projectId) async =>
      throw UnimplementedError('not used here');

  @override
  Future<PreviewDeleteResult> deletePhotos(
          String projectId, List<String> keys) async =>
      throw UnimplementedError('not used here');
}

Widget _app(_FakeRepo repo, {required bool isAdmin}) => ProviderScope(
      overrides: [
        liveProjectsRepositoryProvider.overrideWithValue(repo),
        isAdminProvider.overrideWithValue(isAdmin),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: LiveProjectsView()),
      ),
    );

/// Bounded pump: the processing card's status pill animates forever, so
/// pumpAndSettle never settles (same reason as projects_screen_role_gating_test).
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  const deleteBtn = ValueKey('live_delete_proj-1');
  const confirmCta = ValueKey('admin_delete_confirm_cta');
  const confirmField = ValueKey('admin_delete_confirm_field');

  testWidgets('non-ADMIN staff see no delete affordance', (tester) async {
    await tester.pumpWidget(_app(_FakeRepo(), isAdmin: false));
    await _pumpFrames(tester);

    expect(find.text(_projectName), findsOneWidget);
    expect(find.byKey(deleteBtn), findsNothing);
  });

  testWidgets('CTA stays disarmed until the exact name is typed',
      (tester) async {
    final repo = _FakeRepo();
    await tester.pumpWidget(_app(repo, isAdmin: true));
    await _pumpFrames(tester);

    await tester.tap(find.byKey(deleteBtn));
    await _pumpFrames(tester);

    // Dialog is up with both modes visible.
    expect(find.text('Soft delete'), findsOneWidget);
    expect(find.text('Hard delete'), findsOneWidget);

    // No name yet → disarmed. A wrong name → still disarmed.
    expect(tester.widget<TextButton>(find.byKey(confirmCta)).onPressed, isNull);
    await tester.enterText(find.byKey(confirmField), 'wrong name');
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(confirmCta)).onPressed, isNull);

    await tester.enterText(find.byKey(confirmField), _projectName);
    await tester.pump();
    expect(
        tester.widget<TextButton>(find.byKey(confirmCta)).onPressed, isNotNull);
  });

  testWidgets('SOFT is the default: confirming sends SOFT and removes the row',
      (tester) async {
    final repo = _FakeRepo();
    await tester.pumpWidget(_app(repo, isAdmin: true));
    await _pumpFrames(tester);

    await tester.tap(find.byKey(deleteBtn));
    await _pumpFrames(tester);
    await tester.enterText(find.byKey(confirmField), _projectName);
    await tester.pump();
    await tester.tap(find.byKey(confirmCta));
    await _pumpFrames(tester);

    expect(repo.deletes, [('proj-1', 'SOFT', _projectName)]);
    expect(find.text(_projectName), findsNothing);
    expect(find.textContaining('restore'), findsOneWidget);
  });

  testWidgets('HARD: picking Hard delete sends HARD with "Delete forever"',
      (tester) async {
    final repo = _FakeRepo();
    await tester.pumpWidget(_app(repo, isAdmin: true));
    await _pumpFrames(tester);

    await tester.tap(find.byKey(deleteBtn));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('admin_delete_mode_hard')));
    await tester.pump();
    expect(find.text('Delete forever'), findsOneWidget);

    await tester.enterText(find.byKey(confirmField), _projectName);
    await tester.pump();
    await tester.tap(find.byKey(confirmCta));
    await _pumpFrames(tester);

    expect(repo.deletes, [('proj-1', 'HARD', _projectName)]);
    expect(find.text(_projectName), findsNothing);
    expect(find.textContaining('permanently'), findsOneWidget);
  });

  testWidgets('a server-side name mismatch shows mapped copy and keeps the row',
      (tester) async {
    final repo = _FakeRepo()
      ..deleteFailure = const LiveProjectsException(
          LiveProjectsFailure.confirmationMismatch);
    await tester.pumpWidget(_app(repo, isAdmin: true));
    await _pumpFrames(tester);

    await tester.tap(find.byKey(deleteBtn));
    await _pumpFrames(tester);
    await tester.enterText(find.byKey(confirmField), _projectName);
    await tester.pump();
    await tester.tap(find.byKey(confirmCta));
    await _pumpFrames(tester);

    expect(find.textContaining('doesn’t match'), findsOneWidget);
    expect(find.text(_projectName), findsOneWidget);
  });
}
