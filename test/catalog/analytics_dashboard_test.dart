// test/catalog/analytics_dashboard_test.dart
//
// The analytics dashboard (feature 66, surfacing 61-65).
//
// What this file exists to catch, in order of how badly the alternative goes:
//   • A RANGE CONTROL THAT FILTERS INSTEAD OF ASKING. The aggregation is
//     server-side and `visitors` is a distinct count — a client that sliced a
//     fetched blob would show a 7-day number that no amount of arithmetic could
//     make correct. Every window change must reach the repository.
//   • THE FOUR STATES READ AS ONE. Loading, a genuinely empty window, Mirage
//     being unavailable, and a real failure are four different sentences, and
//     the cheapest bug on this screen is rendering an outage as "no scans yet"
//     (or worse, an empty week as an error).
//   • RAW UPSTREAM TEXT. The unavailable state is drawn through F10's code
//     table; a server message reaching the screen is the hole that table exists
//     to close.
//   • A CHART THAT ONLY WORKS AT ONE WIDTH. It is asked to be legible from a
//     360 px phone to a 1600 px browser, and nothing about it may be a fixed
//     pixel size.
//
// Hermetic: the repository and the clock are both faked, so no test here reads
// the wall clock or the network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_analytics_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_analytics.dart';
import 'package:recapture/presentation/screens/catalog/catalog_analytics_screen.dart';
import 'package:recapture/presentation/widgets/catalog/analytics_chart.dart';

import 'catalog_entities_test.dart' as golden;
import 'catalog_repo_publish_defaults.dart';

// ── Payloads, in EXACTLY the shape the three endpoints emit ─────────────────
//
// Raw maps rather than constructed entities on purpose: these tests are as much
// about the parse as about the render, and the DTOs are hand-synced with the
// backend's TypeScript.

Map<String, dynamic> summaryPayload({
  String from = '2026-07-25',
  String to = '2026-08-24',
  int days = 30,
  int pageViews = 1247,
  int visitors = 830,
  int productViews = 402,
  int arViews = 96,
  Map<String, dynamic>? previous = const {
    'pageViews': 1000,
    'sessions': 900,
    'visitors': 800,
    'productViews': 400,
    'arViews': 120,
    'arSessions': 100,
    'contactClicks': 10,
    'searches': 5,
  },
}) =>
    {
      'range': {'from': from, 'to': to, 'days': days},
      'kpis': {
        'pageViews': pageViews,
        'sessions': 1100,
        'visitors': visitors,
        'productViews': productViews,
        'arViews': arViews,
        'arSessions': 80,
        'contactClicks': 12,
        'searches': 7,
      },
      'previousKpis': previous,
    };

Map<String, dynamic> zeroSummaryPayload() => {
      'range': {'from': '2026-07-25', 'to': '2026-08-24', 'days': 30},
      'kpis': {
        'pageViews': 0,
        'sessions': 0,
        'visitors': 0,
        'productViews': 0,
        'arViews': 0,
        'arSessions': 0,
        'contactClicks': 0,
        'searches': 0,
      },
      'previousKpis': null,
    };

Map<String, dynamic> timeseriesPayload({int days = 30}) => {
      'range': {'from': '2026-07-25', 'to': '2026-08-24'},
      'points': [
        for (var i = 0; i < days; i++)
          {
            'date': '2026-07-${(25 + i).toString().padLeft(2, '0')}',
            'pageViews': 10 + i,
            'productViews': 4 + i,
            'arViews': i % 5,
            'sessions': 8 + i,
          },
      ],
    };

Map<String, dynamic> topProductsPayload() => {
      'range': {'from': '2026-07-25', 'to': '2026-08-24'},
      'rows': [
        {
          'productId': 'mirage-item-1',
          'catalogProductId': '6a83dd464aea89d1d2d28d60',
          'name': 'Walnut Chair',
          'kind': '3D',
          'views': 220,
          'arViews': 60,
          'modelLoads': 180,
          'sessions': 200,
        },
        {
          'productId': 'mirage-item-2',
          'catalogProductId': '6a83dd464aea89d1d2d28d61',
          'name': 'Ceramic Mug',
          'kind': 'IMAGE_ONLY',
          'views': 120,
          'arViews': 0,
          'modelLoads': 0,
          'sessions': 110,
        },
        {
          // Deleted locally, still counted — the row keeps its Mirage id and
          // its views.
          'productId': 'mirage-item-3',
          'catalogProductId': null,
          'name': 'Old Lamp',
          'kind': 'UNKNOWN',
          'views': 60,
          'arViews': 4,
          'modelLoads': 20,
          'sessions': 55,
        },
      ],
      'totals': {
        '3D': {'views': 220, 'arViews': 60, 'products': 1},
        'IMAGE_ONLY': {'views': 120, 'arViews': 0, 'products': 1},
        'UNKNOWN': {'views': 60, 'arViews': 4, 'products': 1},
      },
    };

Map<String, dynamic> emptyTopProductsPayload() => {
      'range': {'from': '2026-07-25', 'to': '2026-08-24'},
      'rows': <Map<String, dynamic>>[],
      'totals': {
        '3D': {'views': 0, 'arViews': 0, 'products': 0},
        'IMAGE_ONLY': {'views': 0, 'arViews': 0, 'products': 0},
        'UNKNOWN': {'views': 0, 'arViews': 0, 'products': 0},
      },
    };

/// One analytics request, as the fake saw it.
class AnalyticsCall {
  const AnalyticsCall(this.report, this.from, this.to, [this.limit]);

  final String report;
  final String? from;
  final String? to;
  final int? limit;

  @override
  String toString() => '$report($from..$to${limit == null ? '' : ', $limit'})';
}

class FakeAnalyticsRepository
    with CatalogRepoPublishDefaults
    implements CatalogRepository {
  FakeAnalyticsRepository({Catalog? catalog})
      : catalog = catalog ?? Catalog.fromMap(golden.catalogGolden());

  Catalog? catalog;

  /// Every analytics read, in order — the range control's whole contract.
  final List<AnalyticsCall> calls = [];

  Map<String, dynamic> summary = summaryPayload();
  Map<String, dynamic> timeseries = timeseriesPayload();
  Map<String, dynamic> topProducts = topProductsPayload();

  /// Set to fail the next analytics read.
  CatalogFailure? failure;

  List<AnalyticsCall> callsFor(String report) =>
      calls.where((call) => call.report == report).toList();

  @override
  Future<Catalog?> fetch() async => catalog;

  @override
  Future<AnalyticsSummary> fetchAnalyticsSummary({
    String? from,
    String? to,
  }) async {
    calls.add(AnalyticsCall('summary', from, to));
    if (failure != null) throw failure!;
    return AnalyticsSummary.fromMap(summary);
  }

  @override
  Future<AnalyticsTimeseries> fetchAnalyticsTimeseries({
    String? from,
    String? to,
  }) async {
    calls.add(AnalyticsCall('timeseries', from, to));
    if (failure != null) throw failure!;
    return AnalyticsTimeseries.fromMap(timeseries);
  }

  @override
  Future<TopProducts> fetchAnalyticsTopProducts({
    String? from,
    String? to,
    int? limit,
  }) async {
    calls.add(AnalyticsCall('top-products', from, to, limit));
    if (failure != null) throw failure!;
    return TopProducts.fromMap(topProducts);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not exercised here');
}

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// A frozen clock, so a preset's `from`/`to` can be asserted literally.
DateTime get _now => DateTime.utc(2026, 8, 24);

Widget harness(FakeAnalyticsRepository repo) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(repo),
        analyticsClockProvider.overrideWithValue(() => _now),
      ],
      child: const MaterialApp(home: CatalogAnalyticsScreen()),
    );

/// Renders at a given window size — the two extremes the chart owes.
Future<void> pumpAt(
  WidgetTester tester,
  Widget widget, {
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
  // ── The range control ─────────────────────────────────────────────────────

  testWidgets('opens on the 30-day window, as the backend defaults to',
      (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    // All three reports, for one window, in one pass.
    expect(repo.calls.length, 3);
    expect(repo.callsFor('summary').single.from, '2026-07-25');
    expect(repo.callsFor('summary').single.to, '2026-08-24');
    // The list is asked for at the dashboard's own limit, not the backend cap.
    expect(repo.callsFor('top-products').single.limit, kTopProductsLimit);
  });

  testWidgets('switching the range issues a NEW request, not a local filter',
      (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));
    repo.calls.clear();

    await tester.tap(find.byKey(const ValueKey('analytics_range_7')));
    await tester.pumpAndSettle();

    // Three fresh reads, all bounded to the seven-day window.
    expect(repo.calls.length, 3);
    for (final call in repo.calls) {
      expect(call.from, '2026-08-17', reason: '${call.report} asked for $call');
      expect(call.to, '2026-08-24');
    }

    await tester.tap(find.byKey(const ValueKey('analytics_range_90')));
    await tester.pumpAndSettle();
    expect(repo.callsFor('summary').last.from, '2026-05-26');
  });

  testWidgets('re-tapping the selected range spends no request', (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));
    repo.calls.clear();

    await tester.tap(find.byKey(const ValueKey('analytics_range_30')));
    await tester.pumpAndSettle();

    expect(repo.calls, isEmpty);
  });

  // ── States ────────────────────────────────────────────────────────────────

  testWidgets('a never-published catalog is told to publish, not that it is '
      'quiet', (tester) async {
    final repo = FakeAnalyticsRepository(
      catalog: Catalog.fromMap({
        ...golden.catalogGolden(),
        'status': 'DRAFT',
        'lastPublishedAt': null,
        'isProvisioned': false,
      }),
    );
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    expect(find.byKey(const ValueKey('analytics_never_published')),
        findsOneWidget);
    expect(find.textContaining('Analytics start after you publish'),
        findsOneWidget);
    // And crucially, no report was fetched for a catalog that has none.
    expect(repo.calls, isEmpty);
  });

  testWidgets('an empty window shows zeroed tiles and a next step, not an error',
      (tester) async {
    final repo = FakeAnalyticsRepository()
      ..summary = zeroSummaryPayload()
      ..timeseries = {
        'range': {'from': '2026-07-25', 'to': '2026-08-24'},
        'points': <Map<String, dynamic>>[],
      }
      ..topProducts = emptyTopProductsPayload();

    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    // The tiles are still there, reading zero — that is a fact about the
    // window, and hiding it would leave the user with nothing.
    expect(find.byKey(const ValueKey('analytics_tile_page_views')),
        findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analytics_tile_page_views')),
        matching: find.text('0'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('analytics_empty')), findsOneWidget);
    expect(find.textContaining('No scans yet'), findsOneWidget);
    // Not an error, and not the outage state.
    expect(find.byKey(const ValueKey('analytics_error')), findsNothing);
    expect(find.byKey(const ValueKey('analytics_unavailable')), findsNothing);
  });

  testWidgets('ANALYTICS_UNAVAILABLE degrades softly and never shows the '
      "server's own words", (tester) async {
    final repo = FakeAnalyticsRepository()
      ..failure = const CatalogFailure(
        code: 'ANALYTICS_UNAVAILABLE',
        // The message the API actually sends. It must not reach the screen —
        // the sentence comes from the client's own code table (F10).
        message: 'Analytics are unavailable right now. Please try again shortly.',
        statusCode: 503,
      );

    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    expect(find.byKey(const ValueKey('analytics_unavailable')), findsOneWidget);
    // Distinct from a hard failure.
    expect(find.byKey(const ValueKey('analytics_error')), findsNothing);
    // OUR copy, from the mapped code.
    expect(find.textContaining('Nothing has been lost'), findsOneWidget);
    // NOT the upstream sentence.
    expect(
      find.textContaining('Please try again shortly'),
      findsNothing,
      reason: 'the server message reached the UI',
    );
  });

  testWidgets('the unavailable state retries the same window', (tester) async {
    final repo = FakeAnalyticsRepository()
      ..failure = const CatalogFailure(
        code: 'ANALYTICS_UNAVAILABLE',
        message: 'upstream prose',
        statusCode: 503,
      );

    await pumpAt(tester, harness(repo), size: const Size(900, 1600));
    repo.failure = null;
    repo.calls.clear();

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(repo.calls.length, 3);
    expect(repo.callsFor('summary').single.from, '2026-07-25');
    // And the dashboard is back.
    expect(find.byKey(const ValueKey('analytics_top_products')), findsOneWidget);
  });

  testWidgets('a genuine failure is a different state with a mapped sentence',
      (tester) async {
    final repo = FakeAnalyticsRepository()
      ..failure = const CatalogFailure(
        code: 'OFFLINE',
        message: 'ignored',
        isOffline: true,
      );

    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    expect(find.byKey(const ValueKey('analytics_error')), findsOneWidget);
    expect(find.byKey(const ValueKey('analytics_unavailable')), findsNothing);
    // Offline reads differently from a server problem — nothing the user typed
    // was wrong and the fix is not on this screen.
    expect(find.textContaining("You're offline"), findsOneWidget);
  });

  // ── Metrics, badges and the split ─────────────────────────────────────────

  testWidgets('all six metrics render', (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    for (final id in const [
      'page_views',
      'visitors',
      'product_views',
      'model_loads',
      'ar_views',
    ]) {
      expect(find.byKey(ValueKey('analytics_tile_$id')), findsOneWidget,
          reason: 'missing tile $id');
    }
    // The sixth and seventh: the split and the list it is computed from.
    expect(find.byKey(const ValueKey('analytics_split')), findsOneWidget);
    expect(find.byKey(const ValueKey('analytics_top_products')), findsOneWidget);
  });

  testWidgets('3D model loads are summed from the rows, since the summary '
      'carries no such counter', (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    // 180 (Walnut Chair) + 0 (Ceramic Mug) + 20 (the deleted row).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analytics_tile_model_loads')),
        matching: find.text('200'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('large numbers abbreviate and keep the exact value in a tooltip',
      (tester) async {
    final repo = FakeAnalyticsRepository()
      ..summary = summaryPayload(pageViews: 1247);
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    expect(find.byKey(const ValueKey('analytics_value_page_views')),
        findsOneWidget);
    expect(
      (tester.widget<Text>(
        find.byKey(const ValueKey('analytics_value_page_views')),
      )).data,
      '1.2k',
    );

    // The exact figure is one hover or long-press away, grouped by the locale.
    final tooltip = tester.widget<Tooltip>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('analytics_value_page_views')),
            matching: find.byType(Tooltip),
          )
          .first,
    );
    expect(tooltip.message, '1,247');
  });

  testWidgets('every top-products row carries its type badge', (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    expect(find.byKey(const ValueKey('analytics_badge_threeD')), findsWidgets);
    expect(find.byKey(const ValueKey('analytics_badge_imageOnly')), findsWidgets);
    expect(find.byKey(const ValueKey('analytics_badge_unknown')), findsWidgets);
  });

  testWidgets('a product deleted locally stays counted, named Unknown and '
      'shown with its Mirage id', (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    expect(find.textContaining('mirage-item-3'), findsOneWidget);
    expect(find.textContaining('No longer in your catalog'), findsOneWidget);
    // Its views are still in the split: 60 of 400 is 15%.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analytics_split_unknown')),
        matching: find.textContaining('15%'),
      ),
      findsOneWidget,
    );
    // And the row is NOT tappable — there is nothing left to open.
    expect(find.byKey(const ValueKey('analytics_row_mirage-item-3')),
        findsNothing);
    expect(find.byKey(const ValueKey('analytics_row_mirage-item-1')),
        findsOneWidget);
  });

  // ── The chart ─────────────────────────────────────────────────────────────

  testWidgets('the chart is legible at 360 px and at 1600 px', (tester) async {
    for (final size in const [Size(360, 1400), Size(1600, 1200)]) {
      final repo = FakeAnalyticsRepository()
        ..timeseries = timeseriesPayload(days: 90);

      await pumpAt(tester, harness(repo), size: size);

      expect(find.byKey(const ValueKey('analytics_chart')), findsOneWidget,
          reason: 'no chart at ${size.width}px');

      final box = tester.getSize(find.byKey(const ValueKey('analytics_chart')));
      // It fills the width it is given and stays inside the sane band — no
      // fixed pixel geometry, no billboard on a wide window.
      expect(box.width, lessThanOrEqualTo(size.width));
      expect(box.height, greaterThanOrEqualTo(kAnalyticsChartMinHeight));
      expect(box.height, lessThanOrEqualTo(kAnalyticsChartMaxHeight));

      // The real assertion: nothing overflowed at either extreme.
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('switching the chart series redraws without re-fetching',
      (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));
    repo.calls.clear();

    await tester.tap(find.byKey(const ValueKey('analytics_series_arViews')));
    await tester.pumpAndSettle();

    // The series lives in one already-fetched payload — changing it is a
    // repaint, not a request. The RANGE is the thing that costs a round trip.
    expect(repo.calls, isEmpty);
    expect(find.byKey(const ValueKey('analytics_chart')), findsOneWidget);
  });

  testWidgets('an empty timeseries says so instead of drawing an empty axis',
      (tester) async {
    final repo = FakeAnalyticsRepository()
      ..timeseries = {
        'range': {'from': '2026-07-25', 'to': '2026-08-24'},
        'points': <Map<String, dynamic>>[],
      };
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));

    expect(find.byKey(const ValueKey('analytics_chart_empty')), findsOneWidget);
    expect(find.byType(AnalyticsChart), findsNothing);
  });
}
