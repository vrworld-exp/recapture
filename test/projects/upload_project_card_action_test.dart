// test/projects/upload_project_card_action_test.dart
//
// What an UPLOAD project's card offers once its photos are in.
//
// The requirement is "like a normal captured project", so the card resolves to
// the SAME row a capture project settles on — Preview and Models (plus Generate
// 3D model while there is nothing built yet) — and offers no button of its own.
// Photo picking is not a card action at all: it lives inside Preview (app-bar
// "Create Model" → pick 3–4 → "Create Model"), the same door staff already use
// for a capture. Nor is "View": it opens the newest finished model, which is a
// subset of what Models opens, and a third labelled button ellipsizes the whole
// row down to nothing on a phone.
//
// Two capture words are what this pins against, both of which the status table
// would hand an upload project if it were allowed to fall through:
//
//   • "Resume" (from DRAFT) would send the artist into pre-capture — a ring
//     flow their project has no plan for and can never complete.
//   • "Processing…" (from PROCESSING, which every committed upload is promoted
//     to server-side, so it can be seen on the Live list) would spin forever,
//     because no worker ever claims a photo-upload job.
//
// So an upload project resolves on its own terms: no primary action, ever.
// Models is shown even with nothing in it, because it is that card's standing
// way in and its empty state names the next step rather than dead-ending.
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
    test('an upload project never resumes — that would open pre-capture', () {
      // DRAFT is the status the fall-through is most dangerous on: it maps to
      // "Resume", and there is no capture session to resume.
      expect(
        _project(source: ProjectSource.upload).cardAction,
        ProjectCardAction.none,
      );
    });

    test('a DRAFT capture project still resumes — unchanged', () {
      expect(
        _project(source: ProjectSource.capture).cardAction,
        ProjectCardAction.resume,
      );
    });

    test('a PROCESSING upload project shows no action, never a spinner', () {
      // The status every committed upload lands in. A shared "Processing…"
      // here would spin for good — nothing processes a photo-upload job.
      expect(
        _project(source: ProjectSource.upload, status: ProjectStatus.processing)
            .cardAction,
        ProjectCardAction.none,
      );
      expect(
        _project(
          source: ProjectSource.capture,
          status: ProjectStatus.processing,
        ).cardAction,
        ProjectCardAction.processing,
      );
    });

    test('a built model adds no View — Models already opens it', () {
      // View would work; it is left out because it opens the NEWEST model and
      // Models opens all of them, and three labelled buttons ellipsize the row.
      for (final status in ProjectStatus.values) {
        expect(
          _project(source: ProjectSource.upload, status: status, modelCount: 1)
              .cardAction,
          ProjectCardAction.none,
          reason: '$status with a model must still offer no primary action',
        );
      }
    });

    test('NO upload status resolves to an action — whatever the table grows',
        () {
      // The whole point of resolving the two sources separately: a status added
      // to the capture table later cannot leak onto an upload card.
      for (final status in ProjectStatus.values) {
        expect(
          _project(source: ProjectSource.upload, status: status).cardAction,
          ProjectCardAction.none,
          reason: '$status must not borrow a capture action',
        );
      }
    });
  });

  group('the card itself', () {
    testWidgets('an uploaded set offers no Resume and no picker of its own',
        (tester) async {
      await _pump(tester, _project(source: ProjectSource.upload));

      expect(find.text('Resume'), findsNothing);
      expect(find.text('Select photos'), findsNothing);
    });

    testWidgets('a capture project is untouched', (tester) async {
      await _pump(tester, _project(source: ProjectSource.capture));

      expect(find.text('Resume'), findsOneWidget);
    });

    testWidgets('the rest of the card is the same one a capture project gets',
        (tester) async {
      await _pump(
        tester,
        _project(source: ProjectSource.upload, modelCount: 2),
        onModels: (_) {},
      );

      // Photo count, status pill, Models and the ⋮ menu are all shared.
      expect(find.textContaining('4 photos'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('Models'), findsOneWidget);
      expect(find.byTooltip('Project options'), findsOneWidget);
    });

    testWidgets('a COMPLETED upload project offers Preview and Models, no View',
        (tester) async {
      await _pump(
        tester,
        _project(source: ProjectSource.upload, status: ProjectStatus.completed),
        onPreview: (_) {},
        onModels: (_) {},
      );

      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('Models'), findsOneWidget);
      // Exactly two buttons in the row — a third ellipsizes all of them away.
      expect(find.text('View'), findsNothing);
    });

    testWidgets('a committed (PROCESSING) upload reads like a live project',
        (tester) async {
      // The shape from the Live-projects screenshot this was built against: a
      // Processing pill, Preview, Models, and a full-width Generate.
      Project? opened;
      await _pump(
        tester,
        _project(source: ProjectSource.upload, status: ProjectStatus.processing),
        onPreview: (_) {},
        onModels: (p) => opened = p,
        onGenerate: (_) {},
        // The Processing pill pulses forever, so there is nothing to settle.
        settle: false,
      );

      expect(find.text('Processing'), findsOneWidget);
      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('Models'), findsOneWidget);
      expect(find.text('Generate 3D model'), findsOneWidget);
      // Never the dead spinner a shared PROCESSING action would have given it,
      // and never a third button squeezing the row.
      expect(find.text('Processing…'), findsNothing);
      expect(find.text('View'), findsNothing);

      await tester.tap(find.text('Models'));
      await tester.pump();
      expect(opened?.id, 'p1');
    });
  });
}

Future<void> _pump(
  WidgetTester tester,
  Project project, {
  ValueChanged<Project>? onResume,
  ValueChanged<Project>? onModels,
  ValueChanged<Project>? onPreview,
  ValueChanged<Project>? onGenerate,
  bool settle = true,
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
          onPreview: onPreview,
          onGenerate: onGenerate,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}
