// test/projects/live_projects_notifier_test.dart
//
// P7-A staff list state: first page on build, cursor pagination (append, no
// double-fetch, terminal page), failure semantics (loaded rows never blanked;
// translated errors rethrown for the screen's snackbar). Hermetic: scripted
// fake repository — the notifier never touches Dio by design.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/application/projects/live_projects_notifier.dart';
import 'package:recapture/data/repositories/live_projects_repository.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'repo_fake_defaults.dart';

LiveProject _lp(String id) => LiveProject(
      id: id,
      name: 'Project $id',
      status: ProjectStatus.processing,
      updatedAt: DateTime(2026, 7, 1),
      ownerId: 'owner-abcdef$id',
      totalPhotos: 36,
    );

class _ScriptedLiveRepo with FakeModelGenerationDefaults implements LiveProjectsRepository {
  /// Pages keyed by cursor (null key = first page).
  final Map<String?, LiveProjectsPage> pages = {};
  LiveProjectsException? failWith;
  final List<String?> cursorsSeen = [];

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async {
    cursorsSeen.add(cursor);
    final fail = failWith;
    if (fail != null) throw fail;
    return pages[cursor] ??
        const LiveProjectsPage(items: [], nextCursor: null);
  }

  @override
  Future<Map<String, dynamic>> export(String projectId) async =>
      throw UnimplementedError('not used here');

  @override
  Future<PreviewDeleteResult> deletePhotos(
          String projectId, List<String> keys) async =>
      throw UnimplementedError('not used here');
}

void main() {
  late _ScriptedLiveRepo repo;
  late ProviderContainer container;

  setUp(() {
    repo = _ScriptedLiveRepo();
    container = ProviderContainer(overrides: [
      liveProjectsRepositoryProvider.overrideWithValue(repo),
    ]);
  });

  tearDown(() => container.dispose());

  test('build loads the first page; loadMore appends until the cursor ends',
      () async {
    repo.pages[null] =
        LiveProjectsPage(items: [_lp('1'), _lp('2')], nextCursor: 'c1');
    repo.pages['c1'] = LiveProjectsPage(items: [_lp('3')], nextCursor: null);

    final first = await container.read(liveProjectsProvider.future);
    expect(first.items.map((p) => p.id), ['1', '2']);
    expect(first.hasMore, isTrue);

    await container.read(liveProjectsProvider.notifier).loadMore();
    final second = container.read(liveProjectsProvider).value!;
    expect(second.items.map((p) => p.id), ['1', '2', '3']);
    expect(second.hasMore, isFalse);

    // Terminal page: further loadMore calls never hit the repository.
    await container.read(liveProjectsProvider.notifier).loadMore();
    expect(repo.cursorsSeen, [null, 'c1']);
  });

  test('loadMore failure keeps the loaded rows and rethrows the translated error',
      () async {
    repo.pages[null] =
        LiveProjectsPage(items: [_lp('1')], nextCursor: 'c1');
    await container.read(liveProjectsProvider.future);

    repo.failWith = const LiveProjectsException(
      LiveProjectsFailure.rateLimited,
      retryAfterSeconds: 120,
    );

    await expectLater(
      container.read(liveProjectsProvider.notifier).loadMore(),
      throwsA(isA<LiveProjectsException>().having(
        (e) => e.failure,
        'failure',
        LiveProjectsFailure.rateLimited,
      )),
    );

    final state = container.read(liveProjectsProvider).value!;
    expect(state.items.map((p) => p.id), ['1'], reason: 'rows never blanked');
    expect(state.isLoadingMore, isFalse);
    expect(state.hasMore, isTrue, reason: 'cursor retained for a later retry');
  });

  test('first-load failure surfaces as AsyncError (screen renders retry)',
      () async {
    repo.failWith = const LiveProjectsException(LiveProjectsFailure.network);

    await expectLater(
      container.read(liveProjectsProvider.future),
      throwsA(isA<LiveProjectsException>()),
    );
    expect(container.read(liveProjectsProvider).hasError, isTrue);
  });

  test('refresh reloads from the first page', () async {
    repo.pages[null] =
        LiveProjectsPage(items: [_lp('1')], nextCursor: null);
    await container.read(liveProjectsProvider.future);

    repo.pages[null] =
        LiveProjectsPage(items: [_lp('9'), _lp('1')], nextCursor: null);
    await container.read(liveProjectsProvider.notifier).refresh();

    expect(
      container.read(liveProjectsProvider).value!.items.map((p) => p.id),
      ['9', '1'],
    );
  });
}
