// test/projects/photo_upload_progress_screen_test.dart
//
// The screen the artist lands on when they tap "Upload N photos".
//
// What is pinned here is the behaviour the feature was asked for, and nothing
// about how the rows are styled:
//   • a row per picked photo, each showing ITS OWN live status;
//   • the run starts on its own — the artist taps nothing to begin it;
//   • a finished upload does NOT walk on to the 3D-model screen; it offers Done
//     and hands the project to the Projects list;
//   • a failure keeps the picked set and offers a retry.
//
// Hermetic: the engine is a fake, so no bytes move and no network is touched.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/application/projects/project_photos_notifier.dart';
import 'package:recapture/application/upload/photo_set_upload_flow.dart';
import 'package:recapture/application/upload/resilient_upload_runner.dart';
import 'package:recapture/application/upload/upload_progress_provider.dart';
import 'package:recapture/data/datasources/project_photo_picker.dart';
import 'package:recapture/data/repositories/project_photos_repository.dart';
import 'package:recapture/data/repositories/projects_repository.dart';
import 'package:recapture/domain/entities/create_project_options.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_source.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';
import 'package:recapture/presentation/screens/projects/photo_upload_progress_screen.dart';
import 'package:recapture/presentation/widgets/app_button.dart';

void main() {
  testWidgets('renders one row per picked photo, named, all waiting at first',
      (tester) async {
    final gate = Completer<void>();
    await _pump(tester, engine: _HeldEngine(gate));

    // Every photo is on screen by name — a set is never summarised into a
    // single opaque spinner.
    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.text('b.jpg'), findsOneWidget);
    expect(find.text('c.jpg'), findsOneWidget);
    // And each carries its own status: the engine has opened the first photo,
    // so exactly one row is moving and the other two are still queued.
    expect(find.text('Uploading'), findsOneWidget);
    expect(find.text('Waiting'), findsNWidgets(2));

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('starts the upload itself — no button to press', (tester) async {
    final engine = _HeldEngine(Completer<void>());
    await _pump(tester, engine: engine);

    // The screen was only built; nothing was tapped.
    expect(engine.started, isTrue);
    expect(find.text('Uploading your photos…'), findsOneWidget);
    // Nothing to press while it runs — stopping lives in the app bar.
    expect(find.byType(AppButton), findsNothing);

    engine.gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('per-photo status advances as the engine reports files',
      (tester) async {
    final engine = _SteppingEngine([100, 200, 300]);
    await _pump(tester, engine: engine);

    // First photo in flight, the rest queued.
    engine.emit(bytesUploaded: 50, filesUploaded: 0);
    // Two pumps: the first lets the stream event land on the notifier, the
    // second rebuilds with it.
    await tester.pump();
    await tester.pump();
    expect(find.text('Uploading'), findsOneWidget);
    expect(find.text('Waiting'), findsNWidgets(2));

    // First done, second in flight.
    engine.emit(bytesUploaded: 100, filesUploaded: 1);
    await tester.pump();
    await tester.pump();
    expect(find.text('Uploading'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);
    // The counter is part of a longer line that also carries the MB progress,
    // so this matches the count within it.
    expect(find.textContaining('1 of 3 photos'), findsOneWidget);

    engine.finish();
    await tester.pumpAndSettle();
  });

  testWidgets('a finished upload offers Done — never the 3D model step',
      (tester) async {
    await _pump(tester, engine: _InstantEngine());
    await tester.pumpAndSettle();

    expect(find.text('All photos uploaded.'), findsOneWidget);
    expect(find.byKey(const Key('photo_upload_done')), findsOneWidget);
    // The generate CTA belongs to the photo grid, which this flow no longer
    // walks into. Its absence here IS the requirement.
    expect(find.text('Generate 3D model'), findsNothing);
    expect(find.byKey(const Key('project_photos_generate')), findsNothing);
  });

  testWidgets('the project reaches the Projects list when the upload finishes',
      (tester) async {
    final projects = _StubProjectsRepo();
    await _pump(tester, engine: _InstantEngine(), projects: projects);
    await tester.pumpAndSettle();

    // Created once, as an UPLOAD project, with the name from the form.
    expect(projects.created, hasLength(1));
    expect(projects.created.single.name, 'My set');
    expect(projects.created.single.source, ProjectSource.upload);
  });

  testWidgets('a failure keeps the set and offers a retry', (tester) async {
    await _pump(
      tester,
      engine: _InstantEngine(),
      repo: _StubPhotosRepo(
        commitError: const PhotoUploadException(
          PhotoUploadFailure.rateLimited,
          'Too many uploads. Try again shortly.',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("The upload didn't finish."), findsOneWidget);
    expect(find.text('Too many uploads. Try again shortly.'), findsOneWidget);
    expect(find.byKey(const Key('photo_upload_retry')), findsOneWidget);
    expect(find.byKey(const Key('photo_upload_done')), findsNothing);
    // The picked set survives, so the retry has something to send.
    expect(find.text('a.jpg'), findsOneWidget);
  });
}

// ── Harness ──────────────────────────────────────────────────────────────────

/// Pumps the screen with a picked set of three photos already in the notifier,
/// every seam faked.
Future<void> _pump(
  WidgetTester tester, {
  required PhotoSetUploadEngine engine,
  _StubProjectsRepo? projects,
  _StubPhotosRepo? repo,
}) async {
  final projectsRepo = projects ?? _StubProjectsRepo();
  final photosRepo = repo ?? _StubPhotosRepo();
  final container = ProviderContainer(
    overrides: [
      projectPhotoPickerProvider.overrideWithValue(const _StubPicker()),
      projectPhotosRepositoryProvider.overrideWithValue(photosRepo),
      projectsRepositoryProvider.overrideWithValue(projectsRepo),
      photoSetUploadFlowFactoryProvider.overrideWithValue(
        () => PhotoSetUploadFlow(
          projects: projectsRepo,
          photos: photosRepo,
          isOnline: () => true,
          engineFor: (_, __) => engine,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);

  // The set is picked on the FORM; this screen only ever transfers what is
  // already there.
  await container.read(projectPhotosProvider.notifier).pickPhotos();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: PhotoUploadProgressScreen(projectName: 'My set'),
      ),
    ),
  );
  // Lets the post-frame callback fire the upload.
  await tester.pump();
  await tester.pump();
}

/// Blocks inside `run` until its gate completes — the screen stays mid-transfer
/// for as long as a test needs it to.
class _HeldEngine implements PhotoSetUploadEngine {
  _HeldEngine(this.gate);

  final Completer<void> gate;
  bool started = false;
  final _controller = StreamController<UploadProgress>.broadcast();

  @override
  UploadProgressSource get progress => _Source(_controller.stream);

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec) async {
    started = true;
    _controller.add(UploadProgress(
      status: UploadStatus.inProgress,
      bytesUploaded: 0,
      totalBytes: 600,
      filesUploaded: 0,
      totalFiles: spec.files.length,
    ));
    await gate.future;
    return const ResilientUploadOutcome(
      status: ResilientUploadStatus.succeeded,
      attemptsUsed: 1,
    );
  }

  @override
  void cancel() => gate.complete();
}

/// Lets a test push progress frames one at a time and then release the run.
class _SteppingEngine implements PhotoSetUploadEngine {
  _SteppingEngine(this.sizes);

  final List<int> sizes;
  final _gate = Completer<void>();
  final _controller = StreamController<UploadProgress>.broadcast();

  @override
  UploadProgressSource get progress => _Source(_controller.stream);

  void emit({required int bytesUploaded, required int filesUploaded}) {
    _controller.add(UploadProgress(
      status: UploadStatus.inProgress,
      bytesUploaded: bytesUploaded,
      totalBytes: sizes.fold(0, (a, b) => a + b),
      filesUploaded: filesUploaded,
      totalFiles: sizes.length,
    ));
  }

  void finish() => _gate.complete();

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec) async {
    await _gate.future;
    return const ResilientUploadOutcome(
      status: ResilientUploadStatus.succeeded,
      attemptsUsed: 1,
    );
  }

  @override
  void cancel() => _gate.complete();
}

/// Succeeds without emitting anything — for the terminal states.
class _InstantEngine implements PhotoSetUploadEngine {
  @override
  UploadProgressSource get progress => const NoUploadProgressSource();

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec) async =>
      const ResilientUploadOutcome(
        status: ResilientUploadStatus.succeeded,
        attemptsUsed: 1,
      );

  @override
  void cancel() {}
}

class _Source implements UploadProgressSource {
  const _Source(this._stream);
  final Stream<UploadProgress> _stream;

  @override
  Stream<UploadProgress> watch() => _stream;
}

class _StubPicker implements ProjectPhotoPicker {
  const _StubPicker();

  @override
  Future<PickedPhotoSet> pickPhotos({int alreadyPicked = 0}) async =>
      const PickedPhotoSet(
        accepted: [
          PickedProjectPhoto(
            name: 'a.jpg',
            path: '/a.jpg',
            size: 100,
            contentType: 'image/jpeg',
          ),
          PickedProjectPhoto(
            name: 'b.jpg',
            path: '/b.jpg',
            size: 200,
            contentType: 'image/jpeg',
          ),
          PickedProjectPhoto(
            name: 'c.jpg',
            path: '/c.jpg',
            size: 300,
            contentType: 'image/jpeg',
          ),
        ],
        rejected: [],
      );
}

class _StubProjectsRepo implements ProjectsRepository {
  final List<Project> created = [];

  @override
  Future<Project> create({
    required String name,
    ObjectSize? size,
    CaptureMode? mode,
    String? category,
    ProjectSource source = ProjectSource.capture,
  }) async {
    final project = Project(
      id: 'p1',
      name: name,
      status: ProjectStatus.draft,
      updatedAt: DateTime.utc(2026, 8, 24),
      source: source,
    );
    created.add(project);
    return project;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubPhotosRepo implements ProjectPhotosRepository {
  _StubPhotosRepo({this.commitError});

  final PhotoUploadException? commitError;

  @override
  Future<PhotoUploadSession> openSession({
    required String projectId,
    required List<({String contentType, int size})> files,
    String? idempotencyKey,
  }) async =>
      PhotoUploadSession(
        jobId: 'job1',
        keyPrefix: 'dev/set_p1/job1/',
        slots: [
          for (var i = 1; i <= files.length; i++)
            PhotoUploadSlot(key: 'dev/set_p1/job1/uploads/photo_000$i.jpg'),
        ],
      );

  @override
  Future<int> commit({required String projectId, required String jobId}) async {
    if (commitError != null) throw commitError!;
    return 3;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
