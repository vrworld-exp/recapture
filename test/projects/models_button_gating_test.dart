// test/projects/models_button_gating_test.dart
//
// The "Models" entry point on BOTH project surfaces (My projects — now open to
// any owner — and the staff Live tab), and the rule that decides whether it
// renders at all: `modelCount > 0` — SUCCEEDED generations only, by backend
// contract.
//
// The interesting case is the FAILED-only project: it HAS generation records,
// but nothing viewable, so the button must stay hidden rather than open an
// empty history. The client can't tell the difference on its own — it trusts
// modelCount — so these tests pin the wiring, not the counting.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/application/auth/profile_provider.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/application/projects/live_projects_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/domain/entities/live_project.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/presentation/screens/projects/projects_screen.dart';

/// Owner list with a caller-chosen model count.
class _FakeProjectsNotifier extends ProjectsNotifier {
  _FakeProjectsNotifier(this.modelCount);
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

/// Live list with a caller-chosen model count.
class _FakeLiveProjectsNotifier extends LiveProjectsNotifier {
  _FakeLiveProjectsNotifier(this.modelCount);
  final int modelCount;

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
            modelCount: modelCount,
          ),
        ],
        nextCursor: null,
      );
}

Widget _app({
  required bool isStaff,
  int mineModelCount = 0,
  int liveModelCount = 0,
}) {
  return ProviderScope(
    overrides: [
      projectsProvider.overrideWith(() => _FakeProjectsNotifier(mineModelCount)),
      liveProjectsProvider
          .overrideWith(() => _FakeLiveProjectsNotifier(liveModelCount)),
      isStaffProvider.overrideWithValue(isStaff),
      // The Live tab reads the admin flag for its delete affordance; without
      // this override the real userRoleProvider chain would open Hive.
      isAdminProvider.overrideWithValue(false),
      // The app-bar avatar watches this; the real one would reach /auth/me
      // through the account repository. No picture → the plain glyph.
      avatarBytesProvider.overrideWith((ref) async => null),
    ],
    child: const MaterialApp(home: ProjectsScreen()),
  );
}

/// Bounded pump: the processing card spins forever, so pumpAndSettle never
/// settles (same reason as projects_screen_role_gating_test).
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _openLiveTab(WidgetTester tester) async {
  await tester.tap(find.text('Live projects'));
  await _pumpFrames(tester);
}

void main() {
  group('My projects tab', () {
    testWidgets('staff + a viewable model → Models button shows', (tester) async {
      await tester.pumpWidget(_app(isStaff: true, mineModelCount: 2));
      await _pumpFrames(tester);

      expect(find.text('Models'), findsOneWidget);
    });

    testWidgets('staff + FAILED-only project (count 0) → no Models button',
        (tester) async {
      await tester.pumpWidget(_app(isStaff: true, mineModelCount: 0));
      await _pumpFrames(tester);

      // The project itself still renders — only the entry point is withheld.
      expect(find.text('My vase'), findsOneWidget);
      expect(find.text('Models'), findsNothing);
    });

    testWidgets('non-staff owner sees Models for their own viewable model',
        (tester) async {
      // Any owner can open their own generated models now — the staff gate on
      // onModels is gone (still requires modelCount > 0).
      await tester.pumpWidget(_app(isStaff: false, mineModelCount: 2));
      await _pumpFrames(tester);

      expect(find.text('My vase'), findsOneWidget);
      expect(find.text('Models'), findsOneWidget);
    });

    testWidgets('non-staff owner with no viewable model still sees no Models',
        (tester) async {
      await tester.pumpWidget(_app(isStaff: false, mineModelCount: 0));
      await _pumpFrames(tester);

      expect(find.text('My vase'), findsOneWidget);
      expect(find.text('Models'), findsNothing);
    });

    testWidgets('a viewable model hides the "Processing…" label',
        (tester) async {
      // Once a model exists the generation is done; the perpetual "Processing…"
      // spinner is stale noise, so it's suppressed. The fake project is
      // PROCESSING, so without a model the label would show (next test).
      await tester.pumpWidget(_app(isStaff: true, mineModelCount: 1));
      await _pumpFrames(tester);

      expect(find.text('Models'), findsOneWidget);
      expect(find.text('Processing…'), findsNothing);
    });

    testWidgets('processing with no viewable model still shows the label',
        (tester) async {
      await tester.pumpWidget(_app(isStaff: true, mineModelCount: 0));
      await _pumpFrames(tester);

      expect(find.text('Processing…'), findsOneWidget);
    });
  });

  group('Live projects tab', () {
    testWidgets('a viewable model → Models button shows beside Preview/Export',
        (tester) async {
      await tester.pumpWidget(_app(isStaff: true, liveModelCount: 1));
      await _openLiveTab(tester);

      expect(find.text('Someone else’s statue'), findsOneWidget);
      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('Export'), findsOneWidget);
      expect(find.text('Models'), findsOneWidget);
    });

    testWidgets('count 0 → no Models button, Preview/Export untouched',
        (tester) async {
      await tester.pumpWidget(_app(isStaff: true, liveModelCount: 0));
      await _openLiveTab(tester);

      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('Export'), findsOneWidget);
      expect(find.text('Models'), findsNothing);
    });
  });

  group('entity parsing', () {
    test('modelCount round-trips through the Project cache shape', () {
      const original = Project.new;
      final project = original(
        id: 'p1',
        name: 'Vase',
        status: ProjectStatus.completed,
        updatedAt: DateTime(2026, 7, 17),
        modelCount: 3,
      );

      // toMap → fromMap is the Hive cache path; dropping modelCount there would
      // hide the button until the next successful fetch.
      final restored = Project.fromMap(project.toMap());
      expect(restored.modelCount, 3);
      expect(restored.hasViewableModels, isTrue);
    });

    test('a row cached before modelCount existed parses as 0, not a crash', () {
      final restored = Project.fromMap({
        'id': 'p1',
        'name': 'Vase',
        'status': 'COMPLETED',
        'updatedAt': DateTime(2026, 7, 17).toIso8601String(),
        'stats': {'totalPhotos': 12},
      });

      expect(restored.modelCount, 0);
      expect(restored.hasViewableModels, isFalse);
    });

    test('LiveProject parses modelCount from the admin DTO', () {
      final live = LiveProject.fromMap({
        'id': 'l1',
        'name': 'Statue',
        'status': 'PROCESSING',
        'updatedAt': DateTime(2026, 7, 17).toIso8601String(),
        'ownerId': 'owner123456',
        'stats': {'totalPhotos': 37},
        'modelCount': 2,
      });

      expect(live.modelCount, 2);
      expect(live.hasViewableModels, isTrue);
    });
  });
}
