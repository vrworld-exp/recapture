// test/capture/pre_capture_variant_toggle_test.dart
//
// The "can you capture the bottom?" flow-variant question on the Pre-Capture
// Checklist (Screen 4):
//   - renders both option cards with Yes (with_bottom) selected by default,
//   - a selection updates captureFlowVariantProvider, persists per project, and
//     fires bottom_capture_option_selected on TRANSITION only (re-selecting the
//     current value logs nothing),
//   - presets from the project's persisted variant on entry,
//   - LOCKS (disabled, no events, no state change) once the project has ≥1
//     accepted photo — the invariant that protects in-flight coverage math.
// All persistence seams are faked — no Hive in the test host.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/capture/capture_flow_variant_provider.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/progression/level_progression.dart';
import 'package:recapture/application/capture/progression/level_progression_provider.dart';
import 'package:recapture/application/capture/progression/level_progression_store.dart';
import 'package:recapture/application/capture/session/capture_session_state.dart';
import 'package:recapture/application/capture/session/capture_session_store.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/checklist_item.dart';
import 'package:recapture/presentation/screens/capture/pre_capture_screen.dart';
import 'package:recapture/utils/analytics.dart';

/// One short checklist item so the variant question fits the test viewport
/// (the real default list pushes it below the lazy ListView's fold).
const _oneItem = <ChecklistItem>[
  ChecklistItem(
    id: 'x',
    icon: Icons.star,
    title: 'Title X',
    shortDescription: 'Desc X',
    tooltipContent: 'Extended guidance for X.',
  ),
];

class _FakeSessionBox extends ActiveSessionBox {
  _FakeSessionBox([this._projectId]);
  final String? _projectId;
  @override
  Future<ActiveSession?> read() async => _projectId == null
      ? null
      : ActiveSession(projectId: _projectId, updatedAt: DateTime(2026, 7, 9));
}

/// In-memory variant persistence — no Hive.
class _FakeProgressionStore extends LevelProgressionStore {
  final Map<String, CaptureFlowVariant> variants = {};
  @override
  Future<void> saveVariant(String projectId, CaptureFlowVariant variant) async {
    variants[projectId] = variant;
  }

  @override
  Future<CaptureFlowVariant> loadVariant(String projectId) async =>
      variants[projectId] ?? CaptureFlowVariant.withBottom;

  @override
  Future<void> save(String projectId, LevelProgression p, {int? savedAtMs}) async {}
  @override
  Future<LevelProgression?> load(String projectId) async => null;
  @override
  Future<void> clear(String projectId) async {}
}

/// Draft store whose Level A snapshot carries [acceptedCount] accepted photos —
/// drives the variant lock.
class _FakeDraftStore extends CaptureSessionStore {
  _FakeDraftStore({this.acceptedCount = 0});
  final int acceptedCount;

  @override
  Future<CaptureSessionState?> load(String projectId, String levelId) async {
    if (levelId != 'mid' || acceptedCount == 0) return null;
    return CaptureSessionState(
      projectId: projectId,
      levelId: levelId,
      segmentCount: 12,
      fillThreshold: 1,
      fillCounts: List<int>.filled(12, 0),
      position: 0,
      accepted: [
        for (var i = 0; i < acceptedCount; i++)
          CapturedPhotoRecord(
            segmentIndex: i,
            framePath: '/mid/$i.jpg',
            blurScore: 100,
            meanLuminance: 128,
            yawDegrees: 0,
            pitchDegrees: 0,
            sensorTimestampNs: i + 1,
          ),
      ],
      warned: const [],
      rejected: const [],
      savedAtMs: 1,
    );
  }
}

void main() {
  late List<({String name, Map<String, Object?> props})> events;
  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });
  tearDown(() => Analytics.testSink = null);
  List<({String name, Map<String, Object?> props})> named(String n) =>
      events.where((e) => e.name == n).toList();

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    String? projectId = 'p1',
    _FakeProgressionStore? progressionStore,
    _FakeDraftStore? draftStore,
  }) async {
    final container = ProviderContainer(overrides: [
      levelProgressionStoreProvider
          .overrideWithValue(progressionStore ?? _FakeProgressionStore()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark,
        home: PreCaptureScreen(
          items: _oneItem,
          sessionBox: _FakeSessionBox(projectId),
          sessionStore: draftStore ?? _FakeDraftStore(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('renders the question with Yes selected by default', (tester) async {
    final container = await pump(tester);
    expect(find.text('Can you capture the bottom of the object?'), findsOneWidget);
    expect(find.text('Yes — capture the bottom'), findsOneWidget);
    expect(find.text('No — bottom stays hidden'), findsOneWidget);
    expect(
      container.read(captureFlowVariantProvider),
      CaptureFlowVariant.withBottom,
    );
  });

  testWidgets(
      'selecting No updates the variant, persists it, and logs the transition',
      (tester) async {
    final store = _FakeProgressionStore();
    final container = await pump(tester, progressionStore: store);

    await tester.ensureVisible(find.text('No — bottom stays hidden'));
    await tester.tap(find.text('No — bottom stays hidden'));
    await tester.pumpAndSettle();

    expect(
      container.read(captureFlowVariantProvider),
      CaptureFlowVariant.withoutBottom,
    );
    expect(store.variants['p1'], CaptureFlowVariant.withoutBottom);
    final logged = named(AnalyticsEvents.bottomCaptureOptionSelected);
    expect(logged, hasLength(1));
    expect(logged.single.props['flow_variant'], 'without_bottom');
  });

  testWidgets('re-selecting the current value logs NOTHING (transition-only)',
      (tester) async {
    await pump(tester);

    // Yes is already selected — tapping it is not a transition.
    await tester.ensureVisible(find.text('Yes — capture the bottom'));
    await tester.tap(find.text('Yes — capture the bottom'));
    await tester.pumpAndSettle();
    expect(named(AnalyticsEvents.bottomCaptureOptionSelected), isEmpty);

    // No → 1 event; No again → still 1; back to Yes → 2.
    await tester.ensureVisible(find.text('No — bottom stays hidden'));
    await tester.tap(find.text('No — bottom stays hidden'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No — bottom stays hidden'));
    await tester.pumpAndSettle();
    expect(named(AnalyticsEvents.bottomCaptureOptionSelected), hasLength(1));

    await tester.tap(find.text('Yes — capture the bottom'));
    await tester.pumpAndSettle();
    final logged = named(AnalyticsEvents.bottomCaptureOptionSelected);
    expect(logged, hasLength(2));
    expect(logged.last.props['flow_variant'], 'with_bottom');
  });

  testWidgets('presets from the project persisted variant on entry',
      (tester) async {
    final store = _FakeProgressionStore()
      ..variants['p1'] = CaptureFlowVariant.withoutBottom;
    final container = await pump(tester, progressionStore: store);
    expect(
      container.read(captureFlowVariantProvider),
      CaptureFlowVariant.withoutBottom,
    );
  });

  testWidgets('locks once the project has an accepted photo', (tester) async {
    final store = _FakeProgressionStore();
    final container = await pump(
      tester,
      progressionStore: store,
      draftStore: _FakeDraftStore(acceptedCount: 2),
    );

    expect(
      find.text('Locked for this capture — start over to change it.'),
      findsOneWidget,
    );

    // Tapping the other option must change nothing and log nothing.
    await tester.ensureVisible(find.text('No — bottom stays hidden'));
    await tester.tap(find.text('No — bottom stays hidden'));
    await tester.pumpAndSettle();
    expect(
      container.read(captureFlowVariantProvider),
      CaptureFlowVariant.withBottom,
    );
    expect(store.variants, isEmpty);
    expect(named(AnalyticsEvents.bottomCaptureOptionSelected), isEmpty);
  });

  testWidgets('no project context → selection still works in-memory',
      (tester) async {
    final container = await pump(tester, projectId: null);
    await tester.ensureVisible(find.text('No — bottom stays hidden'));
    await tester.tap(find.text('No — bottom stays hidden'));
    await tester.pumpAndSettle();
    expect(
      container.read(captureFlowVariantProvider),
      CaptureFlowVariant.withoutBottom,
    );
  });
}
