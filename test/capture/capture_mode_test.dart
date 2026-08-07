// test/capture/capture_mode_test.dart
//
// Meshy capture mode: the domain type, the per-ring counts it resolves, and the
// property the whole feature rests on — that the mode SURVIVES a resume.
//
// The mode is chosen once, at project creation, on a screen the user never sees
// again. If it does not come back on resume, a Meshy project silently becomes a
// 48-photo full capture and the counts the server validates against are wrong.
// That is what most of this file is about.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/capture/capture_mode_provider.dart';
import 'package:recapture/application/capture/progression/level_progression.dart';
import 'package:recapture/application/capture/progression/level_progression_provider.dart';
import 'package:recapture/application/capture/progression/level_progression_store.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/capture/capture_mode.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/presentation/widgets/selectable_option_card.dart';

/// In-memory stand-in for the Hive-backed store (a widget test has no Hive
/// host). Only the project-scoped keys this feature touches.
class _FakeStore extends LevelProgressionStore {
  final Map<String, CaptureMode> modes = {};
  final Map<String, CaptureFlowVariant> variants = {};

  @override
  Future<void> saveMode(String projectId, CaptureMode mode) async {
    modes[projectId] = mode;
  }

  @override
  Future<CaptureMode> loadMode(String projectId) async =>
      modes[projectId] ?? CaptureMode.full;

  @override
  Future<CaptureMode?> loadModeOrNull(String projectId) async => modes[projectId];

  @override
  Future<void> saveVariant(String projectId, CaptureFlowVariant v) async {
    variants[projectId] = v;
  }

  @override
  Future<CaptureFlowVariant> loadVariant(String projectId) async =>
      variants[projectId] ?? CaptureFlowVariant.withBottom;

  @override
  Future<CaptureFlowVariant?> loadVariantOrNull(String projectId) async =>
      variants[projectId];

  @override
  Future<void> save(String projectId, LevelProgression p, {int? savedAtMs}) async {}
  @override
  Future<LevelProgression?> load(String projectId) async => null;
  @override
  Future<void> clear(String projectId) async {
    modes.remove(projectId);
    variants.remove(projectId);
  }

  @override
  Future<void> migrateProject(String fromId, String toId) async {
    final mode = modes.remove(fromId);
    if (mode != null) modes.putIfAbsent(toId, () => mode);
    final variant = variants.remove(fromId);
    if (variant != null) variants.putIfAbsent(toId, () => variant);
  }
}

/// A store that throws on every read — the "Hive unavailable" path.
class _BrokenStore extends _FakeStore {
  @override
  Future<CaptureMode> loadMode(String projectId) async =>
      throw StateError('box unavailable');
}

ProviderContainer _container(LevelProgressionStore store) {
  final c = ProviderContainer(overrides: [
    levelProgressionStoreProvider.overrideWithValue(store),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('CaptureMode — the domain type', () {
    test('wire ids round-trip and never rename', () {
      expect(CaptureMode.full.id, 'full');
      expect(CaptureMode.meshy.id, 'meshy');
      for (final mode in CaptureMode.values) {
        expect(CaptureMode.tryFromId(mode.id), mode);
      }
    });

    test('an unknown or absent id is a FULL capture', () {
      // Every project that existed before this type did. Collapsing them onto
      // the new mode would rewrite the shape of captures already on disk.
      for (final bad in [null, '', 'FULL', 'Meshy', 'guided', 'with_bottom']) {
        expect(CaptureMode.fromId(bad), CaptureMode.full);
        expect(CaptureMode.tryFromId(bad), isNull);
      }
    });

    test('tryFromId distinguishes "never chosen" from an explicit default', () {
      // The reason both parses exist: persistence needs to tell a project that
      // was never asked from one that answered "full".
      expect(CaptureMode.tryFromId(null), isNull);
      expect(CaptureMode.tryFromId('full'), CaptureMode.full);
    });

    test('behavioural rules follow the mode, not a scattered set of ifs', () {
      expect(CaptureMode.full.usesAutoCapture, isTrue);
      expect(CaptureMode.meshy.usesAutoCapture, isFalse);
      expect(CaptureMode.full.usesObjectSize, isTrue);
      expect(CaptureMode.meshy.usesObjectSize, isFalse);
      expect(CaptureMode.full.generatesModelAutomatically, isFalse);
      expect(CaptureMode.meshy.generatesModelAutomatically, isTrue);
    });

    test('shutter label names what the button does in each mode', () {
      // The word tracks usesAutoCapture: a loop-driven shutter says "Auto", a
      // press-only one says "Click".
      expect(CaptureMode.full.shutterLabel, 'Auto');
      expect(CaptureMode.meshy.shutterLabel, 'Click');
    });
  });

  group('per-ring counts', () {
    const config = CaptureConfig.bundledDefault;

    test('full mode is unchanged: 16/16/16 and 24/24', () {
      for (final band in ['mid', 'high', 'low']) {
        expect(
          effectiveSegmentsFor(config, CaptureFlowVariant.withBottom, band),
          16,
        );
      }
      for (final band in ['mid', 'high']) {
        expect(
          effectiveSegmentsFor(config, CaptureFlowVariant.withoutBottom, band),
          24,
        );
      }
      expect(
        expectedPhotoTotalFor(config, CaptureFlowVariant.withBottom),
        48,
      );
    });

    test('meshy resolves 6 on the single eye ring, variant-independent', () {
      int seg(String band, CaptureFlowVariant v) => effectiveSegmentsFor(
            config,
            v,
            band,
            mode: CaptureMode.meshy,
          );
      // The ONLY band Meshy captures is the eye ring — and both variants resolve
      // it identically (Meshy is variant-independent: no top/bottom ring).
      expect(seg('mid', CaptureFlowVariant.withBottom), 6);
      expect(seg('mid', CaptureFlowVariant.withoutBottom), 6);
      // The active band set is just the eye ring, for either variant.
      expect(activeBandIdsFor(CaptureFlowVariant.withBottom, CaptureMode.meshy),
          ['mid']);
      expect(
          activeBandIdsFor(CaptureFlowVariant.withoutBottom, CaptureMode.meshy),
          ['mid']);
    });

    test('total is 6 for both variants — one ring, variant-independent', () {
      expect(
        expectedPhotoTotalFor(config, CaptureFlowVariant.withBottom,
            mode: CaptureMode.meshy),
        6,
      );
      expect(
        expectedPhotoTotalFor(config, CaptureFlowVariant.withoutBottom,
            mode: CaptureMode.meshy),
        6,
      );
    });

    test('meshy never inherits a full-mode fallback count', () {
      // The dangerous failure: the Meshy eye ring silently resolving to 12 (the
      // legacy band count) or 16 would turn the 6-photo ring into a 16-photo one
      // and strand the user mid-capture. Even with a bare config whose 'mid'
      // band carries the legacy segments:12, the Meshy count stays 6.
      const bare = CaptureConfig(
        version: 1,
        pitchBands: [
          PitchBand(id: 'mid', minDegrees: 40, maxDegrees: 110, segments: 12),
        ],
        thresholds: CaptureThresholds(
          minSharpness: 0.45,
          minCoveragePct: 80,
          maxTiltDeltaDeg: 12,
        ),
      );
      expect(
        effectiveSegmentsFor(bare, CaptureFlowVariant.withBottom, 'mid',
            mode: CaptureMode.meshy),
        6,
      );
    });
  });

  group('persistence — the resume property', () {
    test('a saved mode comes back on loadFor', () async {
      final store = _FakeStore();
      final c = _container(store);

      await c.read(captureModeProvider.notifier).select(
            CaptureMode.meshy,
            projectId: 'p1',
          );
      // A brand-new container is the honest model of an app restart: nothing
      // in memory, only what reached the store.
      final restarted = _container(store);
      expect(restarted.read(captureModeProvider), CaptureMode.full);

      final restored =
          await restarted.read(captureModeProvider.notifier).loadFor('p1');

      expect(restored, CaptureMode.meshy);
      expect(restarted.read(captureModeProvider), CaptureMode.meshy);
    });

    test('select() without a project id keeps the choice in memory only', () {
      // The FAB-sheet moment: no project exists yet to key persistence on.
      final store = _FakeStore();
      final c = _container(store);

      c.read(captureModeProvider.notifier).select(CaptureMode.meshy);

      expect(c.read(captureModeProvider), CaptureMode.meshy);
      expect(store.modes, isEmpty);
    });

    test('persistFor writes the pending choice once the id exists', () async {
      final store = _FakeStore();
      final c = _container(store);

      await c.read(captureModeProvider.notifier).select(CaptureMode.meshy);
      await c.read(captureModeProvider.notifier).persistFor('p9');

      expect(store.modes['p9'], CaptureMode.meshy);
    });

    test('an unreadable store degrades to full instead of throwing', () async {
      final c = _container(_BrokenStore());

      final mode = await c.read(captureModeProvider.notifier).loadFor('p1');

      expect(mode, CaptureMode.full);
    });

    test('a project with no stored mode resumes as full', () async {
      final c = _container(_FakeStore());

      expect(
        await c.read(captureModeProvider.notifier).loadFor('never-seen'),
        CaptureMode.full,
      );
    });

    test('migrateProject carries the mode from a temp id to the server id',
        () async {
      // The offline-create path: the project is created with a local
      // `pending_…` id and the outbox swaps in the real one later.
      final store = _FakeStore();
      await store.saveMode('pending_123', CaptureMode.meshy);

      await store.migrateProject('pending_123', 'real-abc');

      expect(await store.loadMode('real-abc'), CaptureMode.meshy);
      expect(await store.loadModeOrNull('pending_123'), isNull);
    });

    test('restore() rehydrates without touching the store', () async {
      final store = _FakeStore();
      final c = _container(store);

      c.read(captureModeProvider.notifier).restore(CaptureMode.meshy);

      expect(c.read(captureModeProvider), CaptureMode.meshy);
      expect(store.modes, isEmpty); // a resume is not a user choice
    });
  });

  group('SelectableOptionCard', () {
    testWidgets('reports the tapped value and marks the selection', (t) async {
      CaptureMode? tapped;
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Column(children: [
            SelectableOptionCard<CaptureMode>(
              title: 'Full Capture',
              subtitle: '48 photos',
              value: CaptureMode.full,
              selected: CaptureMode.full,
              onSelect: (m) => tapped = m,
            ),
            SelectableOptionCard<CaptureMode>(
              title: 'Maya AI Capture',
              subtitle: '6 photos',
              value: CaptureMode.meshy,
              selected: CaptureMode.full,
              onSelect: (m) => tapped = m,
            ),
          ]),
        ),
      ));

      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      await t.tap(find.text('Maya AI Capture'));
      expect(tapped, CaptureMode.meshy);
    });

    testWidgets('locked → the unselected option does not respond', (t) async {
      var taps = 0;
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: SelectableOptionCard<CaptureMode>(
            title: 'Maya AI Capture',
            subtitle: '6 photos',
            value: CaptureMode.meshy,
            selected: CaptureMode.full,
            locked: true,
            onSelect: (_) => taps++,
          ),
        ),
      ));

      await t.tap(find.text('Maya AI Capture'));
      expect(taps, 0);
    });
  });
}
