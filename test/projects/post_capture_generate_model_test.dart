// test/projects/post_capture_generate_model_test.dart
//
// The post-capture "Generate 3D model" entry point: the owner's only route to
// `POST /projects/:id/model`.
//
// The load-bearing tests here are the ones that protect a WALLET and a USER, not
// a feature: one press must never become two charges, a decline must arrive as a
// value and render as one plain sentence with nothing internal in it, and a
// screen that cannot name a project must offer no button rather than one that
// would 404.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/owner_generation_request_notifier.dart';
import 'package:recapture/data/repositories/projects_repository.dart';
import 'package:recapture/domain/entities/create_project_options.dart';
import 'package:recapture/domain/entities/project_source.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/presentation/screens/capture/processing_screen.dart';
import 'package:recapture/presentation/screens/projects/model_building_screen.dart';

import 'repo_fake_defaults.dart';

// ── Fakes ────────────────────────────────────────────────────────────────────

/// Records every generation request and answers with a scripted result.
class _StubRepo with FakeProjectModelDefaults implements ProjectsRepository {
  _StubRepo({this.result, this.gate});

  final OwnerGenerationRequestResult? result;

  /// Holds the POST open so two presses genuinely overlap. Deliberately a
  /// Completer and not a delay: inside `testWidgets` the clock is fake, so a
  /// `Future.delayed` nothing pumps never completes and the run hangs forever.
  final Completer<void>? gate;

  /// Every project id this was asked to generate for. Length IS the bill.
  final List<String> requested = [];

  @override
  Future<OwnerGenerationRequestResult> requestModelGeneration(
    String id, {
    bool regenerate = false,
  }) async {
    requested.add(id);
    if (gate != null) await gate!.future;
    return result ??
        const OwnerGenerationRequestResult(
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

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.onFetch);

  final Future<ResponseBody> Function(RequestOptions options) onFetch;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      onFetch(options);
}

ResponseBody _json(Object? body, {int status = 200}) =>
    ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });

Widget _app(ProviderContainer container, {String? projectId}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark,
        home: ProcessingScreen(projectId: projectId),
      ),
    );

ProviderContainer _container(_StubRepo repo) => ProviderContainer(overrides: [
      projectsRepositoryProvider.overrideWithValue(repo),
      // ModelBuildingScreen's dev trace reads isStaffProvider; without this
      // override the real role chain opens Hive and throws — and only when this
      // file runs alongside others, which is the worst way to find out.
      isStaffProvider.overrideWithValue(false),
    ]);

void main() {
  // ── The screen the upload lands on ────────────────────────────────────────

  group('ProcessingScreen', () {
    testWidgets('confirms the upload and offers the generate CTA',
        (tester) async {
      final repo = _StubRepo();
      final container = _container(repo);
      await tester.pumpWidget(_app(container, projectId: 'proj-1'));

      expect(find.text('Photos uploaded'), findsOneWidget);
      expect(find.byKey(const Key('processing_generate_model')), findsOneWidget);
      expect(
          find.byKey(const Key('processing_back_to_projects')), findsOneWidget);
      // The stub screen's fictions must be gone: no fake pipeline stages, no
      // dead notify toggle, no timer that navigates on its own.
      expect(find.text('Texturing'), findsNothing);
      expect(find.text('Notify me when done'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Photos uploaded'), findsOneWidget);

      container.dispose();
    });

    testWidgets('no project id → no button at all, only Back to Projects',
        (tester) async {
      // A button that cannot name a project would 404 a PAID request. Absent
      // beats present-and-broken.
      final repo = _StubRepo();
      final container = _container(repo);
      await tester.pumpWidget(_app(container));

      expect(find.text('Photos uploaded'), findsOneWidget);
      expect(find.byKey(const Key('processing_generate_model')), findsNothing);
      expect(
          find.byKey(const Key('processing_back_to_projects')), findsOneWidget);
      expect(repo.requested, isEmpty);

      container.dispose();
    });

    testWidgets('tap → one request, and the build screen opens',
        (tester) async {
      final repo = _StubRepo();
      final container = _container(repo);
      await tester.pumpWidget(_app(container, projectId: 'proj-1'));

      await tester.tap(find.byKey(const Key('processing_generate_model')));
      await tester.pump();
      await tester.pump();

      expect(repo.requested, ['proj-1']);
      expect(find.byType(ModelBuildingScreen), findsOneWidget);
      expect(find.text('Creating your 3D model'), findsOneWidget);

      container.dispose();
    });

    testWidgets('double tap cannot start a second paid generation',
        (tester) async {
      final gate = Completer<void>();
      final repo = _StubRepo(gate: gate);
      final container = _container(repo);
      await tester.pumpWidget(_app(container, projectId: 'proj-1'));

      final button = find.byKey(const Key('processing_generate_model'));
      await tester.tap(button);
      // Second press lands before the first POST has answered — the case a
      // state-layer guard alone would miss and a widget guard alone would too.
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      gate.complete();
      await tester.pump();
      await tester.pump();

      expect(repo.requested, hasLength(1));

      container.dispose();
    });

    testWidgets('re-entering after a request does not pay again',
        (tester) async {
      final repo = _StubRepo();
      final container = _container(repo);
      await tester.pumpWidget(_app(container, projectId: 'proj-1'));

      await tester.tap(find.byKey(const Key('processing_generate_model')));
      await tester.pump();
      await tester.pump();
      // Back out of the build screen and press again.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('processing_generate_model')));
      await tester.pump();
      await tester.pump();

      expect(repo.requested, hasLength(1));
      // And the CTA says so rather than re-offering a purchase.
      expect(find.text('View progress'), findsOneWidget);

      container.dispose();
    });
  });

  // ── A decline is a RESULT ─────────────────────────────────────────────────

  group('decline', () {
    testWidgets('renders as one plain sentence with nothing internal in it',
        (tester) async {
      const copy = 'This capture only shows one side of the object. Walk all '
          'the way around it and capture again.';
      final repo = _StubRepo(
        result: const OwnerGenerationRequestResult(
          OwnerGenerationRequestOutcome.declined,
          copy,
        ),
      );
      final container = _container(repo);
      await tester.pumpWidget(_app(container, projectId: 'proj-1'));

      await tester.tap(find.byKey(const Key('processing_generate_model')));
      await tester.pump();
      await tester.pump();

      expect(find.text(copy), findsOneWidget);
      // Nothing from our internals may reach the tree.
      for (final leak in [
        'INSUFFICIENT_SPREAD',
        'NOT_SELECTABLE',
        'meshy',
        'Meshy',
        'recapture/',
        '422',
      ]) {
        expect(find.textContaining(leak), findsNothing, reason: 'leaked $leak');
      }

      container.dispose();
    });

    test('the notifier keeps a refusal as state and never throws', () async {
      final repo = _StubRepo(
        result: const OwnerGenerationRequestResult(
          OwnerGenerationRequestOutcome.dailyLimitReached,
          "You've reached today's limit for creating 3D models.",
        ),
      );
      final container = _container(repo);
      addTearDown(container.dispose);

      final state = await container
          .read(ownerGenerationRequestProvider('proj-1').notifier)
          .request();

      expect(state.isBuilding, isFalse);
      expect(state.refusalMessage,
          "You've reached today's limit for creating 3D models.");
    });

    test('a second request while one is in flight does not pay twice',
        () async {
      final gate = Completer<void>();
      final repo = _StubRepo(gate: gate);
      final container = _container(repo);
      addTearDown(container.dispose);

      final notifier =
          container.read(ownerGenerationRequestProvider('proj-1').notifier);
      final first = notifier.request();
      final second = notifier.request();
      gate.complete();
      await Future.wait([first, second]);

      expect(repo.requested, hasLength(1));
    });
  });

  // ── The wire ──────────────────────────────────────────────────────────────

  group('RemoteProjectsRepository.requestModelGeneration', () {
    late List<RequestOptions> requests;

    ProjectsRepository repoFor(
      Future<ResponseBody> Function(RequestOptions) handle,
    ) {
      requests = [];
      final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
        ..httpClientAdapter = _FakeAdapter((o) {
          requests.add(o);
          return handle(o);
        });
      return RemoteProjectsRepository(dio);
    }

    test('202 → started, and the request carries no force / cache-buster',
        () async {
      final repo = repoFor((_) async => _json({
            'status': 'success',
            'generation': {
              'id': 'gen-1',
              'status': 'QUEUED',
              'isAutoGenerated': false,
            },
          }, status: 202));

      final result = await repo.requestModelGeneration('proj-1');

      expect(result.outcome, OwnerGenerationRequestOutcome.started);
      expect(result.generation?.id, 'gen-1');
      expect(requests.single.uri.path, '/projects/proj-1/model');
      // The server's idempotency key is derived from the capture job; anything
      // the client added here would be a way to defeat it and pay twice.
      expect(requests.single.uri.queryParameters, isEmpty);
      expect(requests.single.data, anyOf(isNull, isEmpty));
    });

    test('422 NOT_SELECTABLE comes back as a value, not an exception',
        () async {
      const copy = 'The photos in this capture are too blurry.';
      final repo = repoFor((_) async => _json({
            'status': 'error',
            'code': 'NOT_SELECTABLE',
            'message': copy,
          }, status: 422));

      final result = await repo.requestModelGeneration('proj-1');

      expect(result.outcome, OwnerGenerationRequestOutcome.declined);
      expect(result.message, copy);
    });

    test('404 and 429 each get their own mapped copy', () async {
      final notFound = await repoFor((_) async => _json({
            'status': 'error',
            'code': 'NOT_FOUND',
            'message': 'Project not found.',
          }, status: 404)).requestModelGeneration('proj-1');
      final limited = await repoFor((_) async => _json({
            'status': 'error',
            'code': 'RATE_LIMITED',
            'message': 'Too many requests. Please try again later.',
          }, status: 429)).requestModelGeneration('proj-1');

      expect(notFound.outcome, OwnerGenerationRequestOutcome.notFound);
      expect(limited.outcome, OwnerGenerationRequestOutcome.rateLimited);
      expect(notFound.message, isNot(limited.message));
    });

    test('an unrecognised 500 body never reaches the user verbatim', () async {
      final repo = repoFor((_) async => _json({
            'status': 'error',
            'code': 'INTERNAL',
            'message': 'MongoServerError: E11000 duplicate key meshyTaskId',
          }, status: 500));

      final result = await repo.requestModelGeneration('proj-1');

      expect(result.outcome, OwnerGenerationRequestOutcome.failed);
      expect(result.message, 'Something went wrong. Please try again.');
    });

    test('a transport failure is offline, not a refusal', () async {
      final repo = repoFor((o) async =>
          throw DioException.connectionError(
              requestOptions: o, reason: 'no route'));

      final result = await repo.requestModelGeneration('proj-1');

      expect(result.outcome, OwnerGenerationRequestOutcome.offline);
    });
  });
}
