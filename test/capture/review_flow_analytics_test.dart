// test/capture/review_flow_analytics_test.dart
//
// The three Screen 7A review-flow funnel events:
//   photo_review_opened  once per screen OPEN (initState; never on rebuild/rotate),
//                        with count/coverage/level context — fires even at 0 photos.
//   photo_deleted        once per completed delete with the ACTUAL count (cancel →
//                        none; partial failure → count actually deleted).
//   photo_retaken        once per completed retake with the ACTUAL count + freed
//                        segments — and the retake's internal delete does NOT also
//                        emit photo_deleted (one event per action).
// Payloads are opaque-id + count only (no PII / file path / image / location), and
// emission is fire-and-forget (a throwing sink never breaks the action/open).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/analytics/review_flow_events.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger.dart';
import 'package:recapture/application/capture/review_actions_controller.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/domain/entities/retake_request.dart';
import 'package:recapture/domain/entities/review_item.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';
import 'package:recapture/presentation/screens/capture/review_grid_screen.dart';
import 'package:recapture/utils/analytics.dart';

CapturedPhotoRecord _rec(String path, int? seg) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 45,
      sensorTimestampNs: 1,
    );

ReviewItem _item(String id, {int? ringIndex}) => ReviewItem(
      captureId: id,
      filePath: '/nope/$id.jpg',
      verdict: CaptureVerdict.accepted,
      ringIndex: ringIndex,
      capturedAt: DateTime(2026, 6, 22),
    );

/// Controller harness with a capturing analytics seam over a real ledger +
/// SegmentCoverage, mirroring review_actions_controller_test's fakes.
class _Harness {
  _Harness({
    required List<CapturedPhotoRecord> records,
    required int segmentCount,
    Set<String> failingPaths = const {},
    bool confirmResult = true,
    int Function()? resultingCoveragePct,
  })  : ledger = LevelCaptureLedger(),
        _failing = failingPaths,
        _confirmResult = confirmResult {
    for (final r in records) {
      ledger.recordAccepted(r);
    }
    coverage = SegmentCoverage.of(
      segmentCount: segmentCount,
      fillCounts: _countsFrom(records, segmentCount),
    );
    analytics = ReviewActionsAnalytics(
      level: CaptureLevel.a,
      projectId: 'proj',
      sessionId: 'sess',
      deviceType: 'android',
      resultingCoveragePct: resultingCoveragePct,
      emit: emitted.add,
    );
  }

  static List<int> _countsFrom(List<CapturedPhotoRecord> recs, int n) {
    final counts = List<int>.filled(n, 0);
    for (final r in recs) {
      final s = r.segmentIndex;
      if (s != null && s >= 0 && s < n) counts[s]++;
    }
    return counts;
  }

  final LevelCaptureLedger ledger;
  SegmentCoverage coverage = SegmentCoverage.of(segmentCount: 1);
  final Set<String> _failing;
  final bool _confirmResult;
  final List<CaptureLevelEvent> emitted = [];
  late final ReviewActionsAnalytics analytics;
  Completer<void>? deleteGate;
  final List<RetakeRequest?> navCalls = [];

  List<CaptureLevelEvent> ofName(String n) =>
      emitted.where((e) => e.name == n).toList();

  ReviewActionsController build() => ReviewActionsController(
        deletePhotoFile: (path) async {
          if (deleteGate != null) await deleteGate!.future;
          return !_failing.contains(path);
        },
        removeFromLedger: ledger.removeAccepted,
        decrementSegment: (i) {
          coverage = coverage.removeCapture(i);
          return coverage.missingSegments.contains(i);
        },
        confirm: (count, kind) async => _confirmResult,
        navigateToCapture: navCalls.add,
        analytics: analytics,
      );
}

void main() {
  // ───────────────────────── photo_review_opened (widget) ────────────────────
  group('photo_review_opened', () {
    tearDown(() => Analytics.testSink = null);

    Future<List<CaptureLevelEvent>> pumpGrid(
      WidgetTester tester, {
      required List<ReviewItem> items,
      int coveragePct = 50,
      String? entryPoint,
      List<CaptureLevelEvent>? sink,
    }) async {
      final captured = sink ?? <CaptureLevelEvent>[];
      await tester.pumpWidget(MaterialApp(
        home: ReviewGridScreen(
          items: items,
          reviewAnalytics: ReviewOpenAnalytics(
            level: CaptureLevel.a,
            projectId: 'proj',
            sessionId: 'sess',
            coveragePct: coveragePct,
            entryPoint: entryPoint,
            emit: captured.add,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      return captured;
    }

    testWidgets('fires once per open with count/coverage/level context',
        (tester) async {
      final captured = await pumpGrid(
        tester,
        items: [_item('a'), _item('b'), _item('c')],
        coveragePct: 42,
        entryPoint: 'capture',
      );
      final opens =
          captured.where((e) => e.name == AnalyticsEvents.photoReviewOpened);
      expect(opens, hasLength(1));
      expect(opens.single.properties, {
        'level': 'A',
        'project_id': 'proj',
        'session_id': 'sess',
        'photo_count': 3,
        'coverage_pct': 42,
        'entry_point': 'capture',
        'device_type': 'android',
      });
    });

    testWidgets('a rebuild + a rotation do NOT re-fire', (tester) async {
      addTearDown(tester.view.reset);
      final captured = <CaptureLevelEvent>[];
      await pumpGrid(tester, items: [_item('a')], sink: captured);
      expect(captured, hasLength(1));

      // Rebuild with an equivalent widget (same State → didUpdateWidget, not init).
      await pumpGrid(tester, items: [_item('a')], sink: captured);
      // Simulate an orientation change (metrics → rebuild, not init).
      tester.view.physicalSize = const Size(800, 360);
      await tester.pump();

      expect(captured, hasLength(1), reason: 'one open only');
    });

    testWidgets('opening with 0 photos fires with photo_count 0', (tester) async {
      final captured = await pumpGrid(tester, items: const []);
      final open =
          captured.singleWhere((e) => e.name == AnalyticsEvents.photoReviewOpened);
      expect(open.properties['photo_count'], 0);
    });

    testWidgets('entry_point omitted when null', (tester) async {
      final captured = await pumpGrid(tester, items: [_item('a')]);
      final open =
          captured.singleWhere((e) => e.name == AnalyticsEvents.photoReviewOpened);
      expect(open.properties.containsKey('entry_point'), isFalse);
    });

    testWidgets('no reviewAnalytics → no photo_review_opened (display-only)',
        (tester) async {
      final events = <String>[];
      Analytics.testSink = (name, _) => events.add(name);
      await tester.pumpWidget(MaterialApp(home: ReviewGridScreen(items: [_item('a')])));
      await tester.pump(const Duration(milliseconds: 50));
      expect(events, contains(AnalyticsEvents.reviewGridViewed));
      expect(events, isNot(contains(AnalyticsEvents.photoReviewOpened)));
    });
  });

  // ───────────────────────────── photo_deleted ───────────────────────────────
  group('photo_deleted', () {
    test('one event per action with the actual count (selection of 3)', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 0), _rec('b.jpg', 1), _rec('c.jpg', 2)],
        segmentCount: 6,
        resultingCoveragePct: () => 50,
      );
      final controller = h.build();

      await controller.deleteSelected({'a.jpg', 'b.jpg', 'c.jpg'});

      final dels = h.ofName(AnalyticsEvents.photoDeleted);
      expect(dels, hasLength(1), reason: 'aggregate, not one-per-photo');
      expect(dels.single.properties['count'], 3);
      expect(dels.single.properties['resulting_coverage_pct'], 50);
      expect(
        dels.single.properties['segments_now_missing'],
        [0, 1, 2],
        reason: 'all three freed, ascending',
      );
      expect(dels.single.properties['level'], 'A');
      expect(dels.single.properties['project_id'], 'proj');
      expect(dels.single.properties['session_id'], 'sess');
    });

    test('cancelled confirm → no event', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 0)],
        segmentCount: 6,
        confirmResult: false,
      );
      await h.build().deleteSelected({'a.jpg'});
      expect(h.ofName(AnalyticsEvents.photoDeleted), isEmpty);
    });

    test('partial failure → count = actually deleted (2 of 3)', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 0), _rec('b.jpg', 1), _rec('c.jpg', 2)],
        segmentCount: 6,
        failingPaths: {'b.jpg'},
      );
      await h.build().deleteSelected({'a.jpg', 'b.jpg', 'c.jpg'});

      final del = h.ofName(AnalyticsEvents.photoDeleted).single;
      expect(del.properties['count'], 2);
      expect(del.properties['segments_now_missing'], [0, 2]);
    });

    test('fully-failed delete → no event', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 0)],
        segmentCount: 6,
        failingPaths: {'a.jpg'},
      );
      await h.build().deleteSelected({'a.jpg'});
      expect(h.ofName(AnalyticsEvents.photoDeleted), isEmpty);
    });

    test('resulting_coverage_pct omitted when no reader supplied', () async {
      final h = _Harness(records: [_rec('a.jpg', 0)], segmentCount: 6);
      await h.build().deleteSelected({'a.jpg'});
      final del = h.ofName(AnalyticsEvents.photoDeleted).single;
      expect(del.properties.containsKey('resulting_coverage_pct'), isFalse);
    });
  });

  // ───────────────────────────── photo_retaken ───────────────────────────────
  group('photo_retaken', () {
    test('one event per action with count + freed segments; no photo_deleted',
        () async {
      final h = _Harness(
        records: [_rec('a.jpg', 3), _rec('b.jpg', 4)],
        segmentCount: 6,
      );
      final controller = h.build();

      await controller.retakeSelected({'a.jpg', 'b.jpg'});

      final rets = h.ofName(AnalyticsEvents.photoRetaken);
      expect(rets, hasLength(1));
      expect(rets.single.properties['count'], 2);
      expect(rets.single.properties['segment_indices'], [3, 4]);
      // The internal delete step must NOT also report a deletion.
      expect(h.ofName(AnalyticsEvents.photoDeleted), isEmpty,
          reason: 'one event per action, not delete+retake');
      // And navigation fired exactly once (no double-fire).
      expect(h.navCalls, hasLength(1));
    });

    test('cancelled retake → no event, no nav', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 3)],
        segmentCount: 6,
        confirmResult: false,
      );
      await h.build().retakeSelected({'a.jpg'});
      expect(h.ofName(AnalyticsEvents.photoRetaken), isEmpty);
      expect(h.navCalls, isEmpty);
    });

    test('fully-failed retake → no event', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 3)],
        segmentCount: 6,
        failingPaths: {'a.jpg'},
      );
      await h.build().retakeSelected({'a.jpg'});
      expect(h.ofName(AnalyticsEvents.photoRetaken), isEmpty);
    });
  });

  // ───────────────────────── privacy + fire-and-forget ───────────────────────
  group('privacy + fire-and-forget', () {
    test('no payload key looks like PII / image / path / location', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 0), _rec('b.jpg', 1)],
        segmentCount: 6,
        resultingCoveragePct: () => 33,
      );
      final c = h.build();
      await c.deleteSelected({'a.jpg'});
      await c.retakeSelected({'b.jpg'});

      const banned = ['email', 'phone', 'name', 'token', 'path', 'image', 'file',
        'lat', 'lng', 'location'];
      expect(h.emitted, isNotEmpty);
      for (final e in h.emitted) {
        for (final k in e.properties.keys) {
          for (final b in banned) {
            expect(k.toLowerCase().contains(b), isFalse, reason: '$k ~ $b');
          }
        }
        // No value should carry a raw frame path either.
        expect(e.properties.values.whereType<String>(),
            isNot(contains(contains('.jpg'))));
      }
    });

    test('a throwing dispatcher does not break the delete action', () async {
      Analytics.testSink = (_, __) => throw StateError('boom');
      addTearDown(() => Analytics.testSink = null);

      // Real emit path (CaptureAnalytics.log) so the throwing sink is exercised.
      final ledger = LevelCaptureLedger()..recordAccepted(_rec('a.jpg', 0));
      var coverage = SegmentCoverage.of(segmentCount: 6, fillCounts: [1, 0, 0, 0, 0, 0]);
      final controller = ReviewActionsController(
        deletePhotoFile: (_) async => true,
        removeFromLedger: ledger.removeAccepted,
        decrementSegment: (i) {
          coverage = coverage.removeCapture(i);
          return coverage.missingSegments.contains(i);
        },
        confirm: (_, __) async => true,
        navigateToCapture: (_) {},
        analytics: ReviewActionsAnalytics(
          level: CaptureLevel.a,
          projectId: 'p',
          sessionId: 's',
          deviceType: 'android',
        ),
      );

      // If the throwing sink leaked, this await would throw and fail the test.
      final result = await controller.deleteSelected({'a.jpg'});
      expect(result.deleted, ['a.jpg'], reason: 'action completed despite sink');
    });
  });
}
