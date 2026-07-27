// test/capture/capture_summary_screen_test.dart
//
// Capture Summary — per-level cards (accepted/min, coverage %, completeness +
// shortfall, warning indicator), aggregated collapsible warnings, totals, and the
// three actions: Upload (primary, warn-then-allow → upload pipeline), Fix Issues
// (→ greatest-shortfall level's capture, hidden when all complete), Save for later
// (→ projects). Completeness uses evaluateLevelA (80% coverage + ≥1 photo) over the
// live ledger; with the bundled config a level needs ceil(0.8*N) filled segments.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/presentation/screens/capture/capture_summary_screen.dart';
import 'package:recapture/utils/analytics.dart';

/// The historical per-level counts (A=10, B=8, C=12) pinned explicitly via a
/// variant-segments override, so the per-level scenarios below keep their
/// distinct-N semantics (bundled defaults are now 16-16-16 under with_bottom).
class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault.copyWith(
        variantSegments: VariantSegments.fromMap(const {
          'with_bottom': {'mid': 10, 'high': 8, 'low': 12},
        }),
      );
}

/// Three equal-size bands (10 segments each) — for the deterministic tiebreak.
class _EqualBandsConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => const CaptureConfig(
        version: 0,
        pitchBands: [
          PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 10),
          PitchBand(id: 'high', minDegrees: 60, maxDegrees: 90, segments: 10),
          PitchBand(id: 'low', minDegrees: 0, maxDegrees: 30, segments: 10),
        ],
        thresholds: CaptureThresholds(
            minSharpness: 0.45, minCoveragePct: 80, maxTiltDeltaDeg: 12),
        variantSegments: VariantSegments(perVariant: {
          'with_bottom': {'mid': 10, 'high': 10, 'low': 10},
        }),
      );
}

/// Raises the absolute SHOT floor above what coverage alone demands (B needs 9
/// accepted shots against its 7-segment coverage floor), over the same 10/8/12
/// segment shape as [_StubConfigNotifier] — so the shot axis of the hard gate
/// is exercised with coverage satisfied.
class _HighFloorConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault.copyWith(
        variantSegments: VariantSegments.fromMap(const {
          'with_bottom': {'mid': 10, 'high': 8, 'low': 12},
        }),
        uploadMinShots: const UploadMinShots(
          perLevelMinShots: {'B': 9},
        ),
      );
}

/// Coverage-COMPLETE but below a raised completion count floor (B needs 20
/// accepted frames) — the "eligible but incomplete" warn-then-allow shape now
/// that the hard gate itself enforces ring coverage.
class _HighCompletionConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault.copyWith(
        variantSegments: VariantSegments.fromMap(const {
          'with_bottom': {'mid': 10, 'high': 8, 'low': 12},
        }),
        completionThresholds: CompletionThresholds.fromMap(const {
          'B': {'minAcceptedFrames': 20},
        }),
      );
}

/// 'low' band absent from pitchBands — the effective count resolver still
/// yields a real N for Level C (variant defaults), so no placeholder appears.
class _NoLowBandConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => const CaptureConfig(
        version: 0,
        pitchBands: [
          PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 10),
          PitchBand(id: 'high', minDegrees: 60, maxDegrees: 90, segments: 8),
        ],
        thresholds: CaptureThresholds(
            minSharpness: 0.45, minCoveragePct: 80, maxTiltDeltaDeg: 12),
      );
}

CapturedPhotoRecord _accepted(int seg, String path) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 0,
      sensorTimestampNs: seg * 1000 + 1,
    );

void main() {
  late List<({String name, Map<String, Object?> props})> events;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });
  tearDown(() => Analytics.testSink = null);

  List<({String name, Map<String, Object?> props})> named(String name) =>
      events.where((e) => e.name == name).toList();

  LevelCaptureLedgerRegistry registryWith(
    Map<String, int> framesPerBand, {
    Map<String, int> warnedPerBand = const {},
  }) {
    final reg = LevelCaptureLedgerRegistry();
    framesPerBand.forEach((band, n) {
      final ledger = reg.ledgerFor(band);
      for (var i = 0; i < n; i++) {
        ledger.recordAccepted(_accepted(i, '/$band/$i.jpg'));
      }
    });
    warnedPerBand.forEach((band, n) {
      final ledger = reg.ledgerFor(band);
      for (var i = 0; i < n; i++) {
        ledger.recordWarned(WarnedPhotoRecord(
          framePath: '/$band/$i.jpg',
          isUnderexposed: true,
          isOverexposed: false,
          meanLuminance: 10,
          sensorTimestampNs: i + 1,
        ));
      }
    });
    return reg;
  }

  /// FULL MODE ONLY. No `captureModeProvider` override → the provider's default
  /// [CaptureMode.full], which is what every assertion below is scoped to: the
  /// Fix Issues button and the below-min notice/confirm exist in full mode and
  /// are deliberately absent in Meshy (see
  /// test/capture/meshy_one_shot_per_segment_test.dart, which covers that mode
  /// and asserts this full-mode shape alongside it).
  Future<void> pump(
    WidgetTester tester,
    LevelCaptureLedgerRegistry reg, {
    ConfigNotifier Function() config = _StubConfigNotifier.new,
  }) async {
    Widget stub(String label) => Scaffold(body: Text(label));
    final router = GoRouter(
      initialLocation: AppRoutes.captureSummary,
      routes: [
        GoRoute(
            path: AppRoutes.captureSummary,
            builder: (_, __) => const CaptureSummaryScreen()),
        GoRoute(path: AppRoutes.uploading, builder: (_, __) => stub('UPLOADING')),
        GoRoute(path: AppRoutes.projects, builder: (_, __) => stub('PROJECTS')),
        GoRoute(
            path: AppRoutes.levelACapture, builder: (_, __) => stub('CAPTURE A')),
        GoRoute(
            path: AppRoutes.levelBCapture, builder: (_, __) => stub('CAPTURE B')),
        GoRoute(
            path: AppRoutes.levelCCapture, builder: (_, __) => stub('CAPTURE C')),
        GoRoute(
            path: AppRoutes.levelAReview, builder: (_, __) => stub('REVIEW A')),
        GoRoute(
            path: AppRoutes.levelBReview, builder: (_, __) => stub('REVIEW B')),
        GoRoute(
            path: AppRoutes.levelCReview, builder: (_, __) => stub('REVIEW C')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          levelCaptureLedgerRegistryProvider.overrideWithValue(reg),
          captureConfigProvider.overrideWith(config),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
  }

  testWidgets('cards show accepted/min, coverage, completeness + shortfall',
      (tester) async {
    // A complete (8/10=80%), B short (3/8), C complete (10/12).
    await pump(tester, registryWith({'mid': 8, 'high': 3, 'low': 10}));

    expect(find.text('Capture summary'), findsOneWidget);
    expect(find.text('Level A • Eye Ring'), findsOneWidget);
    expect(find.text('8 / 1'), findsOneWidget);
    expect(find.text('3 / 1'), findsOneWidget);
    expect(find.text('10 / 1'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('38%'), findsOneWidget); // 3/8 = 37.5 → 38
    expect(find.text('83%'), findsOneWidget); // 10/12 = 83.3 → 83

    expect(find.text('Complete'), findsNWidgets(2));
    expect(find.text('Incomplete'), findsOneWidget);
    // B needs ceil(0.8*8)=7 segments, has 3 → 4 short. Coverage-short is now a
    // HARD block, so the card's hard-floor hint replaces the soft segment hint.
    expect(find.text('Below upload minimum — add 4 more'), findsOneWidget);
    expect(find.text('Need 4 more segments'), findsNothing);
    expect(find.text('Total photos: 21'), findsOneWidget);
    // Coverage-short B trips the HARD gate (not the soft warn notice): a
    // below-coverage bundle is exactly what POST /jobs would reject.
    expect(find.byKey(const Key('below_min_notice')), findsNothing);
    expect(find.byKey(const Key('upload_gate_notice')), findsOneWidget);
    expect(find.byKey(const Key('summary_fix_issues')), findsOneWidget);
  });

  testWidgets('viewed analytics carries totals + any_level_below_min',
      (tester) async {
    await pump(
      tester,
      registryWith({'mid': 8, 'high': 0, 'low': 10},
          warnedPerBand: {'mid': 2}),
    );
    final viewed = named(AnalyticsEvents.captureSummaryViewed);
    expect(viewed, hasLength(1));
    expect(viewed.first.props['levels_total'], 3);
    expect(viewed.first.props['levels_complete'], 2);
    expect(viewed.first.props['total_accepted_frames'], 18);
    expect(viewed.first.props['total_warning_count'], 2);
    expect(viewed.first.props['any_level_below_min'], true);
  });

  testWidgets('Fix Issues → greatest-shortfall level (B), routes to its capture',
      (tester) async {
    // A & C complete; B empty → only/worst incomplete.
    await pump(tester, registryWith({'mid': 8, 'high': 0, 'low': 10}));

    await tester.tap(find.byKey(const Key('summary_fix_issues')));
    await tester.pumpAndSettle();

    expect(find.text('CAPTURE B'), findsOneWidget);
    final action = named(AnalyticsEvents.captureSummaryAction);
    expect(action, hasLength(1));
    expect(action.first.props['action'], 'fix_issues');
    expect(action.first.props['target_level'], 'B');
  });

  testWidgets('Fix Issues routes to the WORSE of two incomplete levels',
      (tester) async {
    // A short by 2 (6/10→need 8), C short by 8 (2/12→need 10), B complete.
    await pump(tester, registryWith({'mid': 6, 'high': 7, 'low': 2}));

    await tester.tap(find.byKey(const Key('summary_fix_issues')));
    await tester.pumpAndSettle();
    expect(find.text('CAPTURE C'), findsOneWidget);
    expect(named(AnalyticsEvents.captureSummaryAction).first.props['target_level'],
        'C');
  });

  testWidgets('tie in shortfall → deterministic lowest-index (A)',
      (tester) async {
    // Equal bands (10 each): A & B empty (equal shortfall), C complete.
    await pump(
      tester,
      registryWith({'mid': 0, 'high': 0, 'low': 10}),
      config: _EqualBandsConfigNotifier.new,
    );
    await tester.tap(find.byKey(const Key('summary_fix_issues')));
    await tester.pumpAndSettle();
    expect(find.text('CAPTURE A'), findsOneWidget);
  });

  testWidgets('all complete → Fix Issues hidden, no below-min notice',
      (tester) async {
    await pump(tester, registryWith({'mid': 8, 'high': 7, 'low': 10}));
    expect(find.byKey(const Key('summary_fix_issues')), findsNothing);
    expect(find.byKey(const Key('below_min_notice')), findsNothing);
    expect(find.text('Incomplete'), findsNothing);
  });

  testWidgets('Upload (all complete) → kicks off pipeline directly',
      (tester) async {
    await pump(tester, registryWith({'mid': 8, 'high': 7, 'low': 10}));

    await tester.tap(find.byKey(const Key('summary_upload')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('below_min_dialog')), findsNothing);
    expect(find.text('UPLOADING'), findsOneWidget);
    final proceed = named(AnalyticsEvents.captureSummaryProceedToUpload);
    expect(proceed, hasLength(1));
    expect(proceed.first.props['any_level_below_min'], false);
    // The hard gate is satisfied → upload actually initiates + passed milestone.
    expect(named(AnalyticsEvents.uploadInitiated), hasLength(1));
    expect(named(AnalyticsEvents.uploadGatePassed), hasLength(1));
  });

  testWidgets('Upload (eligible but incomplete) → confirm; cancel/confirm',
      (tester) async {
    // Every level clears the hard floor (coverage + shots), but B sits below
    // its raised COMPLETION count (7 accepted vs 20) → warn-then-allow.
    await pump(
      tester,
      registryWith({'mid': 8, 'high': 7, 'low': 10}),
      config: _HighCompletionConfigNotifier.new,
    );

    await tester.tap(find.byKey(const Key('summary_upload')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('below_min_dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('below_min_cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Capture summary'), findsOneWidget);
    expect(named(AnalyticsEvents.captureSummaryProceedToUpload), isEmpty);

    await tester.tap(find.byKey(const Key('summary_upload')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('below_min_confirm')));
    await tester.pumpAndSettle();
    expect(find.text('UPLOADING'), findsOneWidget);
    final proceed = named(AnalyticsEvents.captureSummaryProceedToUpload);
    expect(proceed, hasLength(1));
    expect(proceed.first.props['any_level_below_min'], true);
  });

  testWidgets('Save for later → exits to projects', (tester) async {
    await pump(tester, registryWith({'mid': 8, 'high': 7, 'low': 10}));
    await tester.tap(find.byKey(const Key('summary_save')));
    await tester.pumpAndSettle();
    expect(find.text('PROJECTS'), findsOneWidget);
    final action = named(AnalyticsEvents.captureSummaryAction);
    expect(action.single.props['action'], 'save_for_later');
  });

  testWidgets('Upload double-tap kicks off once', (tester) async {
    await pump(tester, registryWith({'mid': 8, 'high': 7, 'low': 10}));
    final btn = find.byKey(const Key('summary_upload'));
    await tester.tap(btn, warnIfMissed: false);
    await tester.tap(btn, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(named(AnalyticsEvents.captureSummaryProceedToUpload), hasLength(1));
  });

  testWidgets('Fix Issues double-tap navigates once', (tester) async {
    await pump(tester, registryWith({'mid': 8, 'high': 0, 'low': 10}));
    final btn = find.byKey(const Key('summary_fix_issues'));
    await tester.tap(btn, warnIfMissed: false);
    await tester.tap(btn, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(named(AnalyticsEvents.captureSummaryAction), hasLength(1));
  });

  testWidgets('zero warnings → no-warnings state, no expandable', (tester) async {
    await pump(tester, registryWith({'mid': 8, 'high': 7, 'low': 10}));
    expect(find.byKey(const Key('no_warnings')), findsOneWidget);
    expect(find.byKey(const Key('warnings_expansion')), findsNothing);
  });

  testWidgets('warnings present → collapsed list expands + fires analytics',
      (tester) async {
    await pump(
      tester,
      registryWith({'mid': 8, 'high': 7, 'low': 10},
          warnedPerBand: {'mid': 1, 'high': 2}),
    );

    expect(find.byKey(const Key('warnings_expansion')), findsOneWidget);
    expect(find.textContaining('too dark'), findsNothing);
    expect(named(AnalyticsEvents.captureSummaryWarningsExpanded), isEmpty);

    await tester.ensureVisible(find.byKey(const Key('warnings_expansion')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warnings_expansion')));
    await tester.pumpAndSettle();

    expect(find.textContaining('too dark'), findsWidgets);
    final expanded = named(AnalyticsEvents.captureSummaryWarningsExpanded);
    expect(expanded, hasLength(1));
    expect(expanded.first.props['warning_count'], 3);
  });

  testWidgets('missing band → counts resolve via the variant defaults, no crash',
      (tester) async {
    // The 'low' band is absent from the config's pitchBands, but the effective
    // count resolver falls back to the variant defaults (low=16 with_bottom),
    // so Level C still shows a REAL coverage instead of a placeholder.
    await pump(
      tester,
      registryWith({'mid': 8, 'high': 7, 'low': 1}),
      config: _NoLowBandConfigNotifier.new,
    );
    expect(find.text('—'), findsNothing);
    expect(find.text('6%'), findsOneWidget); // low: 1/16 = 6.25 → 6
    expect(find.text('Capture summary'), findsOneWidget);
  });

  testWidgets('per-card tap → review route', (tester) async {
    await pump(tester, registryWith({'mid': 8, 'high': 7, 'low': 10}));
    await tester.tap(find.text('Level B • Top Ring'));
    await tester.pumpAndSettle();
    expect(find.text('REVIEW B'), findsOneWidget);
    final action = named(AnalyticsEvents.captureSummaryAction);
    expect(action.single.props['action'], 'review');
    expect(action.single.props['level'], 'B');
  });

  group('hard upload gate', () {
    testWidgets('level with 0 shots → Upload disabled + gate notice + blocked',
        (tester) async {
      await pump(tester, registryWith({'mid': 8, 'high': 0, 'low': 10}));

      // Disabled: tapping does nothing — no upload, no initiate.
      expect(find.byKey(const Key('upload_gate_notice')), findsOneWidget);
      await tester.tap(find.byKey(const Key('summary_upload')));
      await tester.pumpAndSettle();
      expect(find.text('UPLOADING'), findsNothing);
      expect(named(AnalyticsEvents.uploadInitiated), isEmpty);

      // Blocked analytics fired on the first disabled view, with the deficit —
      // B needs its 7-segment coverage floor (ceil(0.8×8)), not just 1 shot.
      final blocked = named(AnalyticsEvents.uploadGateBlocked);
      expect(blocked, isNotEmpty);
      expect(blocked.first.props['short_levels'], 'B');
      expect(blocked.first.props['total_deficit'], 7);
      expect(blocked.first.props['phase'], 'upload');

      // Card flags the hard-blocked level.
      expect(find.text('Below upload minimum — add 7 more'), findsOneWidget);
    });

    testWidgets('multiple short levels → both listed, total_deficit summed',
        (tester) async {
      await pump(tester, registryWith({'mid': 0, 'high': 0, 'low': 10}));
      final blocked = named(AnalyticsEvents.uploadGateBlocked);
      expect(blocked.first.props['short_levels'], 'A,B');
      // Coverage floors: A ceil(0.8×10)=8, B ceil(0.8×8)=7.
      expect(blocked.first.props['total_deficit'], 15);
      expect(find.byKey(const Key('upload_remedy_A')), findsOneWidget);
      expect(find.byKey(const Key('upload_remedy_B')), findsOneWidget);
    });

    testWidgets('remedy row → routes to that level\'s capture', (tester) async {
      await pump(tester, registryWith({'mid': 8, 'high': 0, 'low': 10}));
      await tester.tap(find.byKey(const Key('upload_remedy_B')));
      await tester.pumpAndSettle();
      expect(find.text('CAPTURE B'), findsOneWidget);
      expect(named(AnalyticsEvents.captureSummaryAction).single.props['action'],
          'fix_issues');
    });

    testWidgets('exactly at the coverage floor is inclusive → not blocked',
        (tester) async {
      // A 8/10, B 7/8, C 10/12 — each exactly at ceil(0.8×N) — is uploadable
      // (and complete, so the upload starts without the warn dialog).
      await pump(tester, registryWith({'mid': 8, 'high': 7, 'low': 10}));
      expect(find.byKey(const Key('upload_gate_notice')), findsNothing);
      await tester.tap(find.byKey(const Key('summary_upload')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('below_min_dialog')), findsNothing);
      expect(find.text('UPLOADING'), findsOneWidget);
    });

    testWidgets('config override raises the SHOT floor (B needs 9)',
        (tester) async {
      // Coverage met everywhere; only B's raised absolute shot minimum
      // (9 > its 7 accepted) blocks — the shot axis in isolation.
      await pump(
        tester,
        registryWith({'mid': 8, 'high': 7, 'low': 10}),
        config: _HighFloorConfigNotifier.new,
      );
      expect(find.byKey(const Key('upload_gate_notice')), findsOneWidget);
      final blocked = named(AnalyticsEvents.uploadGateBlocked);
      expect(blocked.first.props['short_levels'], 'B');
      expect(blocked.first.props['total_deficit'], 2);
    });
  });
}
