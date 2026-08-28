// test/projects/owner_generate_routing_test.dart
//
// The Projects Hub card's "Generate 3D model" button is no longer staff-only.
// A NON-STAFF owner pressing it must reach the OWNER route
// (`POST /projects/:id/model` via [OwnerGenerationRequestNotifier]) and NEVER
// the `/admin` auto route — which an owner is forbidden from and would only
// ever 403 on live.
//
// This pins the routing, not the request itself (that is covered end-to-end by
// post_capture_generate_model_test). The admin repository is deliberately NOT
// provided here: a regression back to the staff path would throw reaching the
// real one, instead of silently 403-ing in production.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:recapture/application/auth/profile_provider.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/data/repositories/projects_repository.dart';
import 'package:recapture/domain/entities/create_project_options.dart';
import 'package:recapture/domain/entities/project_source.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/projects/model_building_screen.dart';
import 'package:recapture/presentation/screens/projects/projects_screen.dart';

import 'repo_fake_defaults.dart';

/// Serves the owner list without repositories/Hive, and makes the focus-driven
/// refresh a no-op so the seeded card can't be blanked mid-test.
class _FakeProjectsNotifier extends ProjectsNotifier {
  _FakeProjectsNotifier(this._items);
  final List<Project> _items;

  @override
  Future<List<Project>> build() async => _items;

  @override
  Future<void> refresh() async {}
}

/// Records every owner generation request. `fetchModel`/`fetchModelState`
/// default (from the mixin) to "nothing yet", so the pushed build screen
/// schedules no poll timer.
class _RecordingProjectsRepo
    with FakeProjectModelDefaults
    implements ProjectsRepository {
  final List<String> generated = [];

  @override
  Future<OwnerGenerationRequestResult> requestModelGeneration(
    String id, {
    bool regenerate = false,
  }) async {
    generated.add(id);
    return const OwnerGenerationRequestResult(
      OwnerGenerationRequestOutcome.started,
      'Creating your 3D model.',
    );
  }

  @override
  Future<List<Project>> list() async => const [];
  @override
  Future<Project> create({
    required String name,
    ObjectSize? size,
    CaptureMode? mode,
    String? category,
    ProjectSource source = ProjectSource.capture,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> rename(String id, String newName) async {}
  @override
  Future<void> delete(String id, {String? confirmName}) async {}
  @override
  Future<void> retry(String id) async {}
}

/// Bounded pump: the PROCESSING card spins forever, so `pumpAndSettle` never
/// settles — pump fixed frames instead (same pattern as the other card tests).
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('non-staff owner Generate tap hits the owner endpoint, not /admin',
      (tester) async {
    final repo = _RecordingProjectsRepo();
    final project = Project(
      id: 'proj-9',
      name: 'My vase',
      status: ProjectStatus.processing, // exportable → Generate shows
      updatedAt: DateTime(2026, 7, 12),
      totalPhotos: 36,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        projectsProvider.overrideWith(() => _FakeProjectsNotifier([project])),
        projectsRepositoryProvider.overrideWithValue(repo),
        isStaffProvider.overrideWithValue(false),
        // The role chain would otherwise open Hive for the admin flag.
        isAdminProvider.overrideWithValue(false),
        // The app-bar avatar watches this; the real one would reach /auth/me
        // through the account repository. No picture → the plain glyph.
        avatarBytesProvider.overrideWith((ref) async => null),
      ],
      child: const MaterialApp(home: ProjectsScreen()),
    ));
    await _pumpFrames(tester);

    expect(find.text('Generate 3D model'), findsOneWidget);
    await tester.tap(find.text('Generate 3D model'));
    await tester.pump();
    await tester.pump();

    // The wallet assertion: the owner route was hit exactly once, and the
    // owner-safe build screen opened. The admin repo was never provided, so a
    // regression back to it would throw here rather than 403 in the field.
    expect(repo.generated, ['proj-9']);
    expect(find.byType(ModelBuildingScreen), findsOneWidget);
  });
}
