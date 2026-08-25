// test/capture/review_grid_screen_test.dart
//
// Screen 7A review grid: renders all supplied captures as badged tiles, a header
// summary with accurate counts, an empty state, downscale-decoded thumbnails with
// a graceful fallback for bad files, tap intent + analytics, and responsive
// columns. Display-only — it never evaluates verdicts or mutates the set.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/domain/entities/review_item.dart';
import 'package:recapture/presentation/screens/capture/review_grid_screen.dart';
import 'package:recapture/presentation/widgets/verdict_badge.dart';
import 'package:recapture/utils/analytics.dart';

ReviewItem _item(
  String id,
  CaptureVerdict verdict, {
  int? ringIndex,
  String? path,
}) =>
    ReviewItem(
      captureId: id,
      filePath: path ?? '/nope/$id.jpg',
      verdict: verdict,
      ringIndex: ringIndex,
      capturedAt: DateTime(2026, 6, 22),
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<ReviewItem> items,
  void Function(ReviewItem)? onTapTile,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ReviewGridScreen(items: items, onTapTile: onTapTile),
    ),
  );
  // Let frameBuilder/errorBuilder settle for the (bad) file paths.
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  tearDown(() => Analytics.testSink = null);

  final _mixed = <ReviewItem>[
    _item('a', CaptureVerdict.accepted, ringIndex: 0),
    _item('b', CaptureVerdict.accepted, ringIndex: 1),
    _item('c', CaptureVerdict.warn, ringIndex: 2),
    _item('d', CaptureVerdict.reject, ringIndex: 3),
  ];

  testWidgets('renders one badged tile per supplied item', (tester) async {
    await _pump(tester, items: _mixed);
    expect(find.text('Review — Level A'), findsOneWidget);
    // One VerdictBadge per tile (summary uses bare Icons, not VerdictBadge).
    expect(find.byType(VerdictBadge), findsNWidgets(4));
    // One downscale-decoded Image per tile.
    expect(find.byType(Image), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('header summary counts match the supplied list', (tester) async {
    await _pump(tester, items: _mixed);
    expect(find.bySemanticsLabel('Accepted: 2'), findsOneWidget);
    expect(find.bySemanticsLabel('Warned: 1'), findsOneWidget);
    expect(find.bySemanticsLabel('Rejected: 1'), findsOneWidget);
  });

  testWidgets('thumbnails downscale-decode (cacheWidth set, not full-res)',
      (tester) async {
    await _pump(tester, items: [_item('a', CaptureVerdict.accepted)]);
    final img = tester.widget<Image>(find.byType(Image));
    expect(img.width, isNull); // sized by the grid cell, not a fixed width
    // ResizeImage wraps the provider with a target cacheWidth.
    expect(img.image, isA<ResizeImage>());
    final resize = img.image as ResizeImage;
    expect(resize.width, isNotNull);
    expect(resize.width, greaterThan(0));
  });

  testWidgets('missing/corrupt files render without crashing', (tester) async {
    // Every item here has a bad path. Each tile has an errorBuilder fallback, so
    // nothing throws and the badges still render. (Decode failure is async and
    // does not surface synchronously in a test pump, so we assert structure +
    // no-crash rather than the fallback glyph — mirrors the completion screen
    // montage test.)
    await _pump(tester, items: _mixed);
    expect(find.byType(Image), findsNWidgets(4));
    expect(find.byType(VerdictBadge), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty list shows the empty state, no grid', (tester) async {
    await _pump(tester, items: const []);
    expect(find.text('No captures yet'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(VerdictBadge), findsNothing);
  });

  testWidgets('all-one-verdict renders and counts correctly', (tester) async {
    await _pump(tester, items: [
      _item('a', CaptureVerdict.accepted),
      _item('b', CaptureVerdict.accepted),
      _item('c', CaptureVerdict.accepted),
    ]);
    expect(find.byType(VerdictBadge), findsNWidgets(3));
    expect(find.bySemanticsLabel('Accepted: 3'), findsOneWidget);
    expect(find.bySemanticsLabel('Warned: 0'), findsOneWidget);
    expect(find.bySemanticsLabel('Rejected: 0'), findsOneWidget);
  });

  testWidgets('tapping a tile emits onTapTile + analytics', (tester) async {
    final taps = <ReviewItem>[];
    final events = <Map<String, Object?>>[];
    Analytics.testSink = (name, props) {
      if (name == AnalyticsEvents.reviewTileTapped) events.add({...props});
    };
    await _pump(tester, items: _mixed, onTapTile: taps.add);

    await tester.tap(find.byType(VerdictBadge).first);
    await tester.pump();

    expect(taps.single.captureId, 'a');
    expect(events.single['capture_id'], 'a');
    expect(events.single['verdict'], 'accepted');
  });

  testWidgets('no onTapTile → tap is inert, no analytics', (tester) async {
    final events = <String>[];
    Analytics.testSink = (name, _) {
      if (name == AnalyticsEvents.reviewTileTapped) events.add(name);
    };
    await _pump(tester, items: _mixed); // onTapTile null
    await tester.tap(find.byType(VerdictBadge).first);
    await tester.pump();
    expect(events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('review_grid_viewed fires once with correct counts',
      (tester) async {
    final events = <Map<String, Object?>>[];
    Analytics.testSink = (name, props) {
      if (name == AnalyticsEvents.reviewGridViewed) events.add({...props});
    };
    await _pump(tester, items: _mixed);
    expect(events.length, 1);
    expect(events.single['total'], 4);
    expect(events.single['accepted'], 2);
    expect(events.single['warned'], 1);
    expect(events.single['rejected'], 1);
  });

  testWidgets('duplicate captureIds do not throw a duplicate-key error',
      (tester) async {
    // Defensive: a re-capture could momentarily share an id.
    await _pump(tester, items: [
      _item('dup', CaptureVerdict.accepted),
      _item('dup', CaptureVerdict.warn),
    ]);
    expect(tester.takeException(), isNull);
    expect(find.byType(VerdictBadge), findsNWidgets(2));
  });

  testWidgets('column count adapts to width (phone vs tablet)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    int columnsAt(double width) {
      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      return delegate.crossAxisCount;
    }

    // Narrow phone width.
    tester.view.physicalSize = const Size(360, 800);
    await _pump(tester, items: _mixed);
    final phoneCols = columnsAt(360);

    // Wide tablet width.
    tester.view.physicalSize = const Size(1100, 800);
    await _pump(tester, items: _mixed);
    final tabletCols = columnsAt(1100);

    expect(phoneCols, lessThan(tabletCols));
    expect(phoneCols, greaterThanOrEqualTo(2));
  });

  testWidgets('large set renders without crashing', (tester) async {
    final many = [
      for (var i = 0; i < 40; i++)
        _item('c$i',
            CaptureVerdict.values[i % CaptureVerdict.values.length],
            ringIndex: i),
    ];
    await _pump(tester, items: many);
    expect(tester.takeException(), isNull);
    // Lazy grid: only on-screen tiles are built, so not all 40 badges exist.
    expect(find.byType(VerdictBadge), findsWidgets);
  });

  testWidgets('each tile announces its verdict (accessible)', (tester) async {
    await _pump(tester, items: [_item('a', CaptureVerdict.warn, ringIndex: 4)]);
    expect(
      find.bySemanticsLabel('Capture, position 5, Warned'),
      findsOneWidget,
    );
  });
}
