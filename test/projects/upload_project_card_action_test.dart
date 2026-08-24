// test/projects/upload_project_card_action_test.dart
//
// What an UPLOAD project's card offers once its photos are in.
//
// The bug this pins: a finished upload landed in the list as a DRAFT, and DRAFT
// maps to "Resume" — a capture word for an unfinished capture session. An
// upload project has no session to resume; the photos are already on S3. Its
// real next step is choosing which of them a 3D model gets built from, so the
// button says that and opens the photo grid.
//
// Everything ELSE about the card stays shared with capture projects: the status
// pill, the photo count, the Models button, the ⋮ menu, and every non-DRAFT
// status. "Like a normal project" is the requirement — not "a special one".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_source.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/widgets/project_card.dart';

Project _project({
  required ProjectSource source,
  ProjectStatus status = ProjectStatus.draft,
  int totalPhotos = 4,
  int modelCount = 0,
}) =>
    Project(
      id: 'p1',
      name: 'Test_upload',
      status: status,
      updatedAt: DateTime.utc(2026, 8, 24),
      totalPhotos: totalPhotos,
      modelCount: modelCount,
      source: source,
    );

void main() {
  group('Project.cardAction', () {
    test('a DRAFT upload project asks for a photo selection, never a resume',
        () {
      expect(
        _project(source: ProjectSource.upload).cardAction,
        ProjectCardAction.selectPhotos,
      );
    });

    test('a DRAFT capture project still resumes — unchanged', () {
      expect(
        _project(source: ProjectSource.capture).cardAction,
        ProjectCardAction.resume,
      );
    });

    test('every other status is shared by both sources', () {
      for (final status in [
        ProjectStatus.uploading,
        ProjectStatus.processing,
        ProjectStatus.completed,
        ProjectStatus.failed,
        ProjectStatus.unknown,
      ]) {
        expect(
          _project(source: ProjectSource.upload, status: status).cardAction,
          _project(source: ProjectSource.capture, status: status).cardAction,
          reason: '$status must behave the same whatever the source',
        );
      }
    });
  });

  group('the card itself', () {
    testWidgets('an uploaded set offers Select photos, not Resume',
        (tester) async {
      Project? opened;
      await _pump(
        tester,
        _project(source: ProjectSource.upload),
        onResume: (p) => opened = p,
      );

      expect(find.text('Select photos'), findsOneWidget);
      expect(find.text('Resume'), findsNothing);

      await tester.tap(find.text('Select photos'));
      await tester.pump();
      // Same callback the capture card's Resume uses — the screen is what
      // routes an upload project to its photo grid.
      expect(opened?.id, 'p1');
    });

    testWidgets('a capture project is untouched', (tester) async {
      await _pump(tester, _project(source: ProjectSource.capture));

      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Select photos'), findsNothing);
    });

    testWidgets('the rest of the card is the same one a capture project gets',
        (tester) async {
      await _pump(
        tester,
        _project(source: ProjectSource.upload, modelCount: 2),
        onModels: (_) {},
      );

      // Photo count, status pill, Models and the ⋮ menu are all shared — the
      // action label is the ONLY thing an upload project changes.
      expect(find.textContaining('4 photos'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('Models'), findsOneWidget);
      expect(find.byTooltip('Project options'), findsOneWidget);
    });

    testWidgets('a COMPLETED upload project views, exactly like a capture one',
        (tester) async {
      await _pump(
        tester,
        _project(source: ProjectSource.upload, status: ProjectStatus.completed),
      );

      expect(find.text('View'), findsOneWidget);
      expect(find.text('Select photos'), findsNothing);
    });
  });
}

Future<void> _pump(
  WidgetTester tester,
  Project project, {
  ValueChanged<Project>? onResume,
  ValueChanged<Project>? onModels,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProjectCard(
          project: project,
          onResume: onResume ?? (_) {},
          onView: (_) {},
          onRetry: (_) {},
          onMore: (_) {},
          onModels: onModels,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
