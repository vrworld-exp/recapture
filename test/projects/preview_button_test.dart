// test/projects/preview_button_test.dart
//
// The staff Preview affordance:
//   • On the shared ProjectCard it appears ONLY when onPreview is non-null
//     (non-staff pass null → the card is unchanged) and taps back the project.
//   • On the Live tab (_LiveProjectCard) it appears for exportable statuses and
//     routes to the preview gallery with the correct project id.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/projects/live_projects_view.dart';
import 'package:recapture/presentation/widgets/project_card.dart';
import 'repo_fake_defaults.dart';

Project _project(ProjectStatus status) => Project(
      id: 'proj-123',
      name: 'My Project',
      status: status,
      updatedAt: DateTime(2026, 7, 1),
    );

class _StubLiveRepo with FakeModelGenerationDefaults implements LiveProjectsRepository {
  _StubLiveRepo(this._page);
  final LiveProjectsPage _page;

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      _page;

  @override
  Future<Map<String, dynamic>> export(String projectId) async =>
      throw UnimplementedError();

  @override
  Future<PreviewDeleteResult> deletePhotos(
          String projectId, List<String> keys) async =>
      throw UnimplementedError();
}

void main() {
  group('ProjectCard onPreview (My-projects, staff)', () {
    testWidgets('null onPreview → no Preview button (non-regression)',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: ProjectCard(
            project: _project(ProjectStatus.completed),
            onResume: (_) {},
            onView: (_) {},
            onRetry: (_) {},
            onMore: (_) {},
          ),
        ),
      ));
      expect(find.text('Preview'), findsNothing);
    });

    testWidgets('non-null onPreview → button shows and calls back with project',
        (tester) async {
      Project? tapped;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: ProjectCard(
            project: _project(ProjectStatus.completed),
            onResume: (_) {},
            onView: (_) {},
            onRetry: (_) {},
            onMore: (_) {},
            onPreview: (p) => tapped = p,
          ),
        ),
      ));
      expect(find.text('Preview'), findsOneWidget);
      await tester.tap(find.text('Preview'));
      expect(tapped?.id, 'proj-123');
    });
  });

  testWidgets('Live tab: Preview appears for an exportable card and routes with the id',
      (tester) async {
    final repo = _StubLiveRepo(LiveProjectsPage(
      items: [
        LiveProject(
          id: 'proj-123',
          name: 'Live Project',
          status: ProjectStatus.processing, // exportable
          updatedAt: DateTime(2026, 7, 1),
          ownerId: 'owner-abcdef',
          totalPhotos: 48,
        ),
      ],
      nextCursor: null,
    ));

    String? previewedId;
    final router = GoRouter(
      initialLocation: AppRoutes.projects,
      routes: [
        GoRoute(
          path: AppRoutes.projects,
          name: AppRouteNames.projects,
          builder: (_, __) =>
              const Scaffold(body: LiveProjectsView()),
        ),
        GoRoute(
          path: AppRoutes.previewGallery,
          name: AppRouteNames.previewGallery,
          builder: (context, state) {
            previewedId = state.pathParameters['id'];
            return const Scaffold(body: Text('preview-probe'));
          },
        ),
      ],
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [liveProjectsRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(theme: AppTheme.dark, routerConfig: router),
    ));
    // Resolve the async list() load without waiting for the loading spinner to
    // "settle" (an indeterminate CircularProgressIndicator never does).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Preview'), findsOneWidget);
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.text('preview-probe'), findsOneWidget);
    expect(previewedId, 'proj-123');
  });
}
