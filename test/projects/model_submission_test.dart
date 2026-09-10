// test/projects/model_submission_test.dart
//
// The staff "Submit model" flow: the entry point on the Live projects list, and
// the screen behind it (pick a .glb → upload → commit → success).
//
// The three cases worth having are the ones where the flow could quietly do the
// WRONG thing rather than fail: submitting the file to a slot other than the
// one just minted, uploading a file the server will only reject at the end, and
// letting a double-press put two identical models on someone else's project.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/application/auth/profile_provider.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/live_projects_notifier.dart';
import 'package:recapture/application/projects/model_submission_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/data/datasources/model_file_picker.dart';
import 'package:recapture/data/remote/model_upload_client.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/projects/projects_screen.dart';
import 'package:recapture/presentation/screens/projects/submit_model_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'repo_fake_defaults.dart';

const _projectId = 'live-1';

/// A repository that records the submission calls and answers with a canned
/// slot + model. Everything else throws — see repo_fake_defaults.
class _FakeRepo
    with
        FakeModelGenerationDefaults,
        FakeAutoGenerationDefaults,
        FakeModelOptimizeDefaults,
        FakeOwnerModelListDefaults,
        FakePreviewBrowseDefaults,
        FakeAdminDeleteDefaults
    implements LiveProjectsRepository {
  _FakeRepo({this.maxBytes = 128 * 1024 * 1024, this.commitFailure});

  final int maxBytes;

  /// When set, the COMMIT refuses with this failure.
  final LiveProjectsFailure? commitFailure;

  int slotCalls = 0;
  final List<String> committedKeys = [];

  @override
  Future<ModelUploadSlot> createModelUploadSlot(String projectId) async {
    slotCalls++;
    return ModelUploadSlot(
      key: 'model-upload/session-$slotCalls/model.glb',
      url: 'https://s3.example/put?sig=$slotCalls',
      maxBytes: maxBytes,
    );
  }

  @override
  Future<ProjectModelView> submitUploadedModel(
    String projectId,
    String key,
  ) async {
    if (commitFailure != null) {
      throw LiveProjectsException(commitFailure!);
    }
    committedKeys.add(key);
    return ProjectModelView.tryFromStaffMap({
      'id': 'model-1',
      'source': 'manual',
      'status': 'SUCCEEDED',
      'artifacts': {'glb': 'https://cdn.example/model.glb'},
      'createdAt': DateTime(2026, 8, 1).toIso8601String(),
    })!;
  }

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async =>
      throw UnimplementedError('not used here');

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

/// Records the URLs it was asked to PUT to, and reports progress.
class _FakeUploadClient implements ModelUploadClient {
  final List<String> urls = [];
  bool throws = false;

  @override
  Future<void> putGlb({
    required String url,
    required PickedModelFile file,
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    urls.add(url);
    if (throws) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        message: 'connection closed',
      );
    }
    onProgress?.call(0.5);
    onProgress?.call(1);
  }
}

class _FakePicker implements ModelFilePicker {
  _FakePicker(this.file);

  /// Null → the user cancelled.
  PickedModelFile? file;

  @override
  Future<PickedModelFile?> pickGlb() async => file;
}

PickedModelFile _model({String name = 'chair.glb', int size = 2048}) =>
    PickedModelFile(
      name: name,
      size: size,
      openRead: () => Stream<List<int>>.value(Uint8List(size)),
    );

Widget _screen({
  required _FakeRepo repo,
  required ModelFilePicker picker,
  required ModelUploadClient uploader,
  String projectName = 'Someone else’s statue',
}) {
  return ProviderScope(
    overrides: [
      liveProjectsRepositoryProvider.overrideWithValue(repo),
      modelFilePickerProvider.overrideWithValue(picker),
      modelUploadClientProvider.overrideWithValue(uploader),
    ],
    child: MaterialApp(
      home: SubmitModelScreen(
        projectId: _projectId,
        projectName: projectName,
      ),
    ),
  );
}

// ── The entry point on the Live list ────────────────────────────────────────

class _FakeProjectsNotifier extends ProjectsNotifier {
  @override
  Future<List<Project>> build() async => [
        Project(
          id: 'mine-1',
          name: 'My vase',
          status: ProjectStatus.completed,
          updatedAt: DateTime(2026, 7, 12),
        ),
      ];
}

class _FakeLiveProjectsNotifier extends LiveProjectsNotifier {
  _FakeLiveProjectsNotifier(this.status);
  final ProjectStatus status;

  @override
  Future<LiveProjectsState> build() async => LiveProjectsState(
        items: [
          LiveProject(
            id: _projectId,
            name: 'Someone else’s statue',
            status: status,
            updatedAt: DateTime(2026, 7, 10),
            ownerId: 'owner123456',
            totalPhotos: 37,
          ),
        ],
        nextCursor: null,
      );
}

Widget _projectsScreen({ProjectStatus liveStatus = ProjectStatus.completed}) {
  return ProviderScope(
    overrides: [
      projectsProvider.overrideWith(_FakeProjectsNotifier.new),
      liveProjectsProvider
          .overrideWith(() => _FakeLiveProjectsNotifier(liveStatus)),
      isStaffProvider.overrideWithValue(true),
      isAdminProvider.overrideWithValue(false),
      avatarBytesProvider.overrideWith((ref) async => null),
    ],
    child: const MaterialApp(home: ProjectsScreen()),
  );
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('Live projects list', () {
    testWidgets('an exportable project offers Submit model', (tester) async {
      await tester.pumpWidget(_projectsScreen());
      await tester.tap(find.text('Live projects'));
      await _pumpFrames(tester);

      expect(find.text('Submit model'), findsOneWidget);
    });

    testWidgets('a project with no finalized upload does not', (tester) async {
      // Same gate as Generate: without a finalized job the server has nothing
      // to attach a model to, and a button that always errors is worse than no
      // button.
      await tester.pumpWidget(_projectsScreen(liveStatus: ProjectStatus.draft));
      await tester.tap(find.text('Live projects'));
      await _pumpFrames(tester);

      expect(find.text('Someone else’s statue'), findsOneWidget);
      expect(find.text('Submit model'), findsNothing);
    });
  });

  group('Submit model screen', () {
    testWidgets('names the project being submitted to', (tester) async {
      await tester.pumpWidget(_screen(
        repo: _FakeRepo(),
        picker: _FakePicker(null),
        uploader: _FakeUploadClient(),
      ));
      await tester.pump();

      expect(find.text('Submitting model for'), findsOneWidget);
      expect(find.text('Someone else’s statue'), findsOneWidget);
      expect(find.text('No file chosen yet.'), findsOneWidget);
    });

    testWidgets('a cold deep-link without a name degrades, never blanks',
        (tester) async {
      await tester.pumpWidget(_screen(
        repo: _FakeRepo(),
        picker: _FakePicker(null),
        uploader: _FakeUploadClient(),
        projectName: '',
      ));
      await tester.pump();

      expect(find.text('this project'), findsOneWidget);
    });

    testWidgets('pick → submit → success, committing the key just minted',
        (tester) async {
      final repo = _FakeRepo();
      final uploader = _FakeUploadClient();
      await tester.pumpWidget(_screen(
        repo: repo,
        picker: _FakePicker(_model()),
        uploader: uploader,
      ));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('submit_model_choose_button')));
      await tester.pump();
      expect(find.text('chair.glb'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('submit_model_button')));
      await tester.pump();
      await tester.pump();

      // The PUT went to the slot's own URL, and the commit named that slot's
      // key — not a stale one from an earlier attempt.
      expect(uploader.urls, ['https://s3.example/put?sig=1']);
      expect(repo.committedKeys, ['model-upload/session-1/model.glb']);

      expect(find.byKey(const ValueKey('submit_model_success')), findsOneWidget);
      // The confirmation says where the model went — this is the only feedback
      // the submitter gets, since they cannot see the owner's screen.
      expect(
        find.textContaining('the owner can see it in their projects'),
        findsOneWidget,
      );
    });

    testWidgets('a file over the ceiling is refused BEFORE the upload',
        (tester) async {
      final repo = _FakeRepo(maxBytes: 1024);
      final uploader = _FakeUploadClient();
      await tester.pumpWidget(_screen(
        repo: repo,
        picker: _FakePicker(_model(size: 4096)),
        uploader: uploader,
      ));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('submit_model_choose_button')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('submit_model_button')));
      await tester.pump();
      await tester.pump();

      // The slot request is how the ceiling is learned, so it happens — but no
      // bytes are sent and nothing is committed.
      expect(repo.slotCalls, 1);
      expect(uploader.urls, isEmpty);
      expect(repo.committedKeys, isEmpty);
      expect(find.textContaining('larger than the server accepts'), findsOneWidget);
    });

    testWidgets('a rejected commit shows mapped copy and stays submittable',
        (tester) async {
      final repo = _FakeRepo(commitFailure: LiveProjectsFailure.notAModel);
      await tester.pumpWidget(_screen(
        repo: repo,
        picker: _FakePicker(_model()),
        uploader: _FakeUploadClient(),
      ));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('submit_model_choose_button')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('submit_model_button')));
      await tester.pump();
      await tester.pump();

      expect(find.text('That file is not a .glb model.'), findsOneWidget);
      expect(find.byKey(const ValueKey('submit_model_success')), findsNothing);
    });

    testWidgets('a failed upload never leaks the presigned URL', (tester) async {
      final uploader = _FakeUploadClient()..throws = true;
      await tester.pumpWidget(_screen(
        repo: _FakeRepo(),
        picker: _FakePicker(_model()),
        uploader: uploader,
      ));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('submit_model_choose_button')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('submit_model_button')));
      await tester.pump();
      await tester.pump();

      // The raw DioException carries the signed URL; the screen must show the
      // mapped copy instead.
      expect(find.textContaining('s3.example'), findsNothing);
      expect(find.textContaining('check your connection'), findsOneWidget);
    });
  });

  group('ModelSubmissionNotifier', () {
    late ProviderContainer container;
    late _FakeRepo repo;
    late _FakeUploadClient uploader;

    late _FakePicker picker;

    ProviderContainer build(PickedModelFile? picked) {
      repo = _FakeRepo();
      uploader = _FakeUploadClient();
      picker = _FakePicker(picked);
      return ProviderContainer(
        overrides: [
          liveProjectsRepositoryProvider.overrideWithValue(repo),
          modelFilePickerProvider.overrideWithValue(picker),
          modelUploadClientProvider.overrideWithValue(uploader),
        ],
      );
    }

    tearDown(() => container.dispose());

    test('submit without a chosen file is a no-op', () async {
      container = build(null);
      final notifier =
          container.read(modelSubmissionProvider(_projectId).notifier);

      await notifier.submit();

      expect(repo.slotCalls, 0);
      expect(uploader.urls, isEmpty);
    });

    test('a cancelled re-pick leaves the previous choice alone', () async {
      // Dismissing the browser by accident must not throw away the file the
      // user already chose — they would have to find it again for nothing.
      container = build(_model(name: 'chair.glb'));
      final notifier =
          container.read(modelSubmissionProvider(_projectId).notifier);
      await notifier.pickFile();

      picker.file = null;
      await notifier.pickFile();

      final state = container.read(modelSubmissionProvider(_projectId));
      expect(state.file?.name, 'chair.glb');
      expect(state.phase, ModelSubmissionPhase.ready);
    });

    test('a second submit while one is in flight uploads once', () async {
      container = build(_model());
      final notifier =
          container.read(modelSubmissionProvider(_projectId).notifier);
      await notifier.pickFile();

      // Both started before either awaits — the guard has to be in the state,
      // not only on the button.
      await Future.wait([notifier.submit(), notifier.submit()]);

      expect(uploader.urls, hasLength(1));
      expect(repo.committedKeys, hasLength(1));
    });

    test('reset returns the form to empty', () async {
      container = build(_model());
      final notifier =
          container.read(modelSubmissionProvider(_projectId).notifier);
      await notifier.pickFile();
      await notifier.submit();
      expect(
        container.read(modelSubmissionProvider(_projectId)).phase,
        ModelSubmissionPhase.submitted,
      );

      notifier.reset();
      final state = container.read(modelSubmissionProvider(_projectId));
      expect(state.phase, ModelSubmissionPhase.idle);
      expect(state.file, isNull);
    });
  });
}
