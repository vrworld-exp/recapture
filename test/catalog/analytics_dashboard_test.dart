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
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_analytics_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/catalog/analytics_range.dart';
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
  int contactClicks = 12,
  Map<String, dynamic>? previous = const {
    'pageViews': 1000,
    'sessions': 900,
    'visitors': 800,
    'productViews': 400,
    'arViews': 120,
    'arSessions': 100,
    'contactClicks': 10,
    'searches': 5,
    'menuOpens': 4,
    'productPageViews': 2,
    'modelLoads': 150,
    'modelFailures': 3,
  },
  List<Map<String, dynamic>>? funnel,
  List<Map<String, dynamic>> topCategories = const [
    {'name': 'starters', 'opens': 40, 'sessions': 30},
    {'name': 'mains', 'opens': 25, 'sessions': 20},
  ],
  List<Map<String, dynamic>> topSearches = const [
    {
      'query': 'paneer',
      'searches': 9,
      'sessions': 7,
      'avgResults': 2.5,
      'zeroResults': 0,
    },
    {
      'query': 'sushi',
      'searches': 4,
      'sessions': 4,
      'avgResults': 0,
      'zeroResults': 4,
    },
  ],
}) =>
    {
      'range': {
        'from': from,
        'to': to,
        'days': days,
        'timezone': 'Asia/Kolkata',
      },
      'kpis': {
        'pageViews': pageViews,
        'sessions': 1100,
        'visitors': visitors,
        'productViews': productViews,
        'arViews': arViews,
        'arSessions': 80,
        'contactClicks': contactClicks,
        'searches': 7,
        'menuOpens': 5,
        'productPageViews': 3,
        'modelLoads': 200,
        'modelFailures': 4,
      },
      'previousKpis': previous,
      'totalEvents': 3210,
      'funnel': funnel ??
          [
            {
              'key': 'client_page_view',
              'label': 'Catalog opened',
              'count': pageViews
            },
            {
              'key': 'product_detail_opened',
              'label': 'Product viewed',
              'count': productViews,
            },
            {
              'key': 'ar_view_clicked',
              'label': 'AR launched',
              'count': arViews
            },
            {
              'key': 'contact_channel_clicked',
              'label': 'Contact clicked',
              'count': contactClicks,
            },
          ],
      'byDevice': [
        {'type': 'mobile', 'sessions': 700},
        {'type': 'desktop', 'sessions': 400},
      ],
      'topCategories': topCategories,
      'topZoomed': [
        {
          'productId': 'mirage-item-1',
          'catalogProductId': '6a83dd464aea89d1d2d28d60',
          'name': 'Walnut Chair',
          'zooms': 6,
          'sessions': 7,
        },
      ],
      'topSearches': topSearches,
      'modelHealth': {
        'loads': 200,
        'failures': 4,
        'failureRate': 2.0,
        'samples': 200,
        'avgLoadMs': 1000,
        'maxLoadMs': 4000,
        'slowLoads': 0,
        'slowThresholdMs': 5000,
        'topFailures': [
          {'reason': 'loadfailure', 'count': 4},
        ],
        'failingProducts': [
          {
            'productId': 'mirage-item-1',
            'catalogProductId': '6a83dd464aea89d1d2d28d60',
            'name': 'Walnut Chair',
            'failures': 4,
          },
        ],
      },
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
        'menuOpens': 0,
        'productPageViews': 0,
        'modelLoads': 0,
        'modelFailures': 0,
      },
      'previousKpis': null,
      'totalEvents': 0,
      'funnel': <Map<String, dynamic>>[],
      'byDevice': <Map<String, dynamic>>[],
      'topCategories': <Map<String, dynamic>>[],
      'topZoomed': <Map<String, dynamic>>[],
      'topSearches': <Map<String, dynamic>>[],
      'modelHealth': {
        'loads': 0,
        'failures': 0,
        'failureRate': null,
        'samples': 0,
        'avgLoadMs': 0,
        'maxLoadMs': 0,
        'slowLoads': 0,
        'slowThresholdMs': 5000,
        'topFailures': <Map<String, dynamic>>[],
        'failingProducts': <Map<String, dynamic>>[],
      },
    };

Map<String, dynamic> timeseriesPayload({int days = 30}) => {
      'range': {
        'from': '2026-07-25',
        'to': '2026-08-24',
        'timezone': 'Asia/Kolkata',
      },
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

  /// Held open to keep a read IN FLIGHT, so a test can have two windows racing.
  ///
  /// Captured at call entry, not awaited from the field: clearing it between
  /// two requests is how a test makes the FIRST one slow and the second one
  /// fast, which is the only ordering that exercises the stale-answer guard.
  Completer<void>? gate;

  List<AnalyticsCall> callsFor(String report) =>
      calls.where((call) => call.report == report).toList();

  @override
  Future<Catalog?> fetch() async => catalog;

  @override
  Future<AnalyticsSummary> fetchAnalyticsSummary({
    String? from,
    String? to,
  }) async {
    // Payload AND failure are snapshotted at call entry, before the gate.
    // Reading the fields after the await would hand a held-open request
    // whatever the test set for the NEXT one — which silently turns a
    // stale-answer race into two identical answers, and a guard test that
    // passes with the guard deleted.
    final held = gate;
    final payload = summary;
    final failed = failure;
    calls.add(AnalyticsCall('summary', from, to));
    if (held != null) await held.future;
    if (failed != null) throw failed;
    return AnalyticsSummary.fromMap(payload);
  }

  @override
  Future<AnalyticsTimeseries> fetchAnalyticsTimeseries({
    String? from,
    String? to,
  }) async {
    final held = gate;
    final payload = timeseries;
    final failed = failure;
    calls.add(AnalyticsCall('timeseries', from, to));
    if (held != null) await held.future;
    if (failed != null) throw failed;
    return AnalyticsTimeseries.fromMap(payload);
  }

  @override
  Future<TopProducts> fetchAnalyticsTopProducts({
    String? from,
    String? to,
    int? limit,
  }) async {
    final held = gate;
    final payload = topProducts;
    final failed = failure;
    calls.add(AnalyticsCall('top-products', from, to, limit));
    if (held != null) await held.future;
    if (failed != null) throw failed;
    return TopProducts.fromMap(payload);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} is not exercised here');
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

    // The two presets added to match Mirage's own strip. 12 months is exactly
    // the backend's ceiling, so it is honoured as asked, never narrowed.
    await tester.tap(find.byKey(const ValueKey('analytics_range_15')));
    await tester.pumpAndSettle();
    expect(repo.callsFor('summary').last.from, '2026-08-09');

    await tester
        .ensureVisible(find.byKey(const ValueKey('analytics_range_365')));
    await tester.tap(find.byKey(const ValueKey('analytics_range_365')));
    await tester.pumpAndSettle();
    expect(repo.callsFor('summary').last.from, '2025-08-24');
  });

  testWidgets('re-tapping the selected range spends no request',
      (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 1600));
    repo.calls.clear();

    await tester.tap(find.byKey(const ValueKey('analytics_range_30')));
    await tester.pumpAndSettle();

    expect(repo.calls, isEmpty);
  });

  // ── States ────────────────────────────────────────────────────────────────

  testWidgets(
      'a never-published catalog is told to publish, not that it is '
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

  testWidgets(
      'an empty window shows zeroed tiles and a next step, not an error',
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

  testWidgets(
      'ANALYTICS_UNAVAILABLE degrades softly and never shows the '
      "server's own words", (tester) async {
    final repo = FakeAnalyticsRepository()
      ..failure = const CatalogFailure(
        code: 'ANALYTICS_UNAVAILABLE',
        // The message the API actually sends. It must not reach the screen —
        // the sentence comes from the client's own code table (F10).
        message:
            'Analytics are unavailable right now. Please try again shortly.',
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
    expect(
        find.byKey(const ValueKey('analytics_top_products')), findsOneWidget);
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

  testWidgets('the hero, all six tiles and every section render',
      (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    // Sessions is the hero; the six tiles are Mirage's own six.
    expect(
        find.byKey(const ValueKey('analytics_tile_sessions')), findsOneWidget);
    expect(find.byKey(const ValueKey('analytics_visitors')), findsOneWidget);
    for (final id in const [
      'page_views',
      'product_views',
      'ar_views',
      'contact_clicks',
      'browse_taps',
      'direct_links',
    ]) {
      expect(find.byKey(ValueKey('analytics_tile_$id')), findsOneWidget,
          reason: 'missing tile $id');
    }
    // The three tiles the timeseries carries get a sparkline; the rest do not
    // — there is no day-by-day series to draw for them.
    expect(find.byKey(const ValueKey('analytics_sparkline_page_views')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('analytics_sparkline_contact_clicks')),
        findsNothing);

    // Every card, in Mirage's order.
    for (final key in const [
      'analytics_chart_card',
      'analytics_funnel',
      'analytics_categories',
      'analytics_searches',
      'analytics_health',
      'analytics_top_products',
      'analytics_split',
      'analytics_zoomed',
      'analytics_devices',
      'analytics_footer',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: 'missing $key');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('browse taps and direct links read the two navigation counters',
      (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('analytics_value_browse_taps')))
          .data,
      '5',
    );
    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('analytics_value_direct_links')))
          .data,
      '3',
    );
  });

  testWidgets('a tile with no prior window says so instead of showing nothing',
      (tester) async {
    final repo = FakeAnalyticsRepository()
      ..summary = summaryPayload(previous: null);
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analytics_tile_page_views')),
        matching: find.text('no prior period'),
      ),
      findsOneWidget,
    );
  });

  // ── The zone ──────────────────────────────────────────────────────────────
  //
  // A day on this screen is a day in IST. The presets are cut on the IST
  // calendar whatever the device clock says, and the headings take the zone
  // from the report itself.

  testWidgets('a preset ends on TODAY IN IST, not on the UTC date',
      (tester) async {
    final repo = FakeAnalyticsRepository();
    // 20:00 UTC on the 23rd is 01:30 on the 24th in Kolkata.
    await pumpAt(
      tester,
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_StubAuth.new),
          catalogRepositoryProvider.overrideWithValue(repo),
          analyticsClockProvider.overrideWithValue(
            () => DateTime.utc(2026, 8, 23, 20),
          ),
        ],
        child: const MaterialApp(home: CatalogAnalyticsScreen()),
      ),
      size: const Size(900, 1600),
    );

    expect(repo.callsFor('summary').single.to, '2026-08-24');
    expect(repo.callsFor('summary').single.from, '2026-07-25');
  });

  test('a custom window keeps the calendar day the picker handed back', () {
    // The picker returns LOCAL midnight of the tapped day. On any device east
    // of Greenwich, converting that to UTC first lands on the day before.
    final selection = AnalyticsRangeSelection.custom(
      from: DateTime(2026, 8, 1),
      to: DateTime(2026, 8, 24),
    );
    expect(selection.from, '2026-08-01');
    expect(selection.to, '2026-08-24');
  });

  testWidgets('the chart and the footer name the zone the report states',
      (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    expect(find.text('Daily totals, IST'), findsOneWidget);
    expect(find.text('Reported on server receive time, days in IST'),
        findsOneWidget);
  });

  testWidgets('a report that states no zone makes no claim about one',
      (tester) async {
    final summary = summaryPayload();
    final timeseries = timeseriesPayload();
    (summary['range'] as Map<String, dynamic>).remove('timezone');
    (timeseries['range'] as Map<String, dynamic>).remove('timezone');
    final repo = FakeAnalyticsRepository()
      ..summary = summary
      ..timeseries = timeseries;
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    expect(find.text('Reported on server receive time'), findsOneWidget);
    expect(find.textContaining('IST'), findsNothing);
  });

  // ── The funnel ────────────────────────────────────────────────────────────

  testWidgets('the funnel captions each stage as a share of the one above it',
      (tester) async {
    final repo = FakeAnalyticsRepository()
      ..summary = summaryPayload(
        pageViews: 36,
        productViews: 10,
        arViews: 12,
        contactClicks: 4,
      );
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    final funnel = find.byKey(const ValueKey('analytics_funnel'));
    // 10 of 36, 12 of 10 (actions, not people — a stage CAN exceed the one
    // above it), 4 of 12.
    expect(find.descendant(of: funnel, matching: find.text('28% of previous')),
        findsOneWidget);
    expect(find.descendant(of: funnel, matching: find.text('120% of previous')),
        findsOneWidget);
    expect(find.descendant(of: funnel, matching: find.text('33% of previous')),
        findsOneWidget);
    // The top stage has nothing above it.
    expect(
        find.descendant(
            of: funnel, matching: find.textContaining('of previous')),
        findsNWidgets(3));
  });

  testWidgets(
      'the funnel is drawn from the counters when the backend sends '
      'no funnel block', (tester) async {
    final payload = summaryPayload(pageViews: 50, productViews: 25)
      ..remove('funnel');
    final repo = FakeAnalyticsRepository()..summary = payload;
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('analytics_funnel')),
        matching: find.text('50% of previous'),
      ),
      findsOneWidget,
    );
  });

  // ── The health panel ──────────────────────────────────────────────────────

  testWidgets('3D & AR health reads the summary, not the product rows',
      (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    // 200 from modelHealth.loads — NOT 180 + 0 + 20 summed off top-products.
    expect(
      tester
          .widget<Text>(find
              .byKey(const ValueKey('analytics_health_value_models_loaded')))
          .data,
      '200',
    );
    // AR entered: 80 sessions of 96 taps.
    expect(find.textContaining('83.3% of 96 AR taps'), findsOneWidget);
    expect(find.textContaining('1.0s average over 200 timed'), findsOneWidget);
    expect(find.textContaining('2% of attempted loads'), findsOneWidget);
    // The reason is humanised, and the failing model is named.
    expect(find.text('Model file failed to load'), findsOneWidget);
    expect(find.byKey(const ValueKey('analytics_failing_mirage-item-1')),
        findsOneWidget);
  });

  // ── Leaderboards ──────────────────────────────────────────────────────────

  testWidgets(
      'searches show what was typed and flag the ones that found '
      'nothing', (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    final card = find.byKey(const ValueKey('analytics_searches'));
    expect(find.descendant(of: card, matching: find.text('paneer')),
        findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('sushi')),
        findsOneWidget);
    expect(
      find.descendant(
          of: card, matching: find.textContaining('1 query found nothing')),
      findsOneWidget,
    );
  });

  testWidgets('an empty search list explains itself', (tester) async {
    final repo = FakeAnalyticsRepository()
      ..summary = summaryPayload(topSearches: const []);
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    expect(find.textContaining('No searches in this range.'), findsOneWidget);
    expect(find.textContaining('browsed rather than searched'), findsOneWidget);
  });

  testWidgets('categories are shown by display name with a More past five',
      (tester) async {
    final repo = FakeAnalyticsRepository()
      ..summary = summaryPayload(
        topCategories: [
          for (var i = 0; i < 7; i++)
            {'name': 'category_$i', 'opens': 70 - i * 10, 'sessions': 5},
        ],
      );
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    // Slug in, display name out.
    expect(find.text('category 0'), findsOneWidget);
    expect(find.text('category_0'), findsNothing);
    // Five, then More (7) — which expands in place.
    expect(find.text('category 5'), findsNothing);
    final more = find.byKey(const ValueKey('analytics_categories_more'));
    expect(find.descendant(of: more, matching: find.text('More (7)')),
        findsOneWidget);
    final button = find.descendant(of: more, matching: find.byType(TextButton));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('category 6'), findsOneWidget);
  });

  testWidgets('devices split sessions and print each share', (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    final card = find.byKey(const ValueKey('analytics_devices'));
    // 700 of 1100 and 400 of 1100.
    expect(
        find.descendant(of: card, matching: find.text('64%')), findsOneWidget);
    expect(
        find.descendant(of: card, matching: find.text('36%')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Mobile')),
        findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Desktop')),
        findsOneWidget);
  });

  testWidgets('the footer states the event count and the provenance',
      (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    final footer = find.byKey(const ValueKey('analytics_footer'));
    expect(
        find.descendant(
            of: footer, matching: find.text('3,210 events in range')),
        findsOneWidget);
    expect(
      find.descendant(
        of: footer,
        matching: find.text('Reported on server receive time, days in IST'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'the top-products table re-sorts on a column tap without '
      're-fetching', (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));
    repo.calls.clear();

    // Ranked by views: Walnut Chair (220) leads.
    final rows = find.byKey(const ValueKey('analytics_top_products'));
    final chairY = tester
        .getTopLeft(
            find.descendant(of: rows, matching: find.text('Walnut Chair')))
        .dy;
    final mugY = tester
        .getTopLeft(
            find.descendant(of: rows, matching: find.text('Ceramic Mug')))
        .dy;
    expect(chairY, lessThan(mugY));

    // AR rate: 60 of 220 is 27%; the image-only row has none.
    expect(
        find.descendant(of: rows, matching: find.text('27%')), findsOneWidget);
    expect(
        find.descendant(of: rows, matching: find.text('0%')), findsOneWidget);

    // Sort by AR views: the deleted row (4) now outranks the mug (0).
    await tester.ensureVisible(find.text('AR views'));
    await tester.tap(find.text('AR views'));
    await tester.pumpAndSettle();
    final lampY = tester
        .getTopLeft(find.descendant(of: rows, matching: find.text('Old Lamp')))
        .dy;
    final mugY2 = tester
        .getTopLeft(
            find.descendant(of: rows, matching: find.text('Ceramic Mug')))
        .dy;
    expect(lampY, lessThan(mugY2));
    expect(repo.calls, isEmpty);
  });

  // ── Info hints ────────────────────────────────────────────────────────────

  testWidgets('the (i) beside a section opens its explainer', (tester) async {
    final repo = FakeAnalyticsRepository();
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));

    await tester.tap(find.byKey(const ValueKey('analytics_info_sessions')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('analytics_info_sheet_sessions')),
        findsOneWidget);
    expect(find.textContaining('Not the same as QR scans'), findsOneWidget);
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
    expect(
        find.byKey(const ValueKey('analytics_badge_imageOnly')), findsWidgets);
    expect(find.byKey(const ValueKey('analytics_badge_unknown')), findsWidgets);
  });

  testWidgets(
      'a product deleted locally stays counted, named Unknown and '
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
      // The chart is above the fold at both sizes; the assertion that
      // matters — nothing overflowed — covers every card that was laid out.
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

  testWidgets('the Table toggle shows exact daily figures, newest first',
      (tester) async {
    final repo = FakeAnalyticsRepository()
      ..timeseries = timeseriesPayload(days: 3);
    await pumpAt(tester, harness(repo), size: const Size(900, 3200));
    repo.calls.clear();

    await tester.tap(find.text('Table'));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('analytics_traffic_table')), findsOneWidget);
    expect(find.byType(AnalyticsChart), findsNothing);
    // Jul 27 (12 opens) is above Jul 26 (11 opens).
    final table = find.byKey(const ValueKey('analytics_traffic_table'));
    final newest = tester
        .getTopLeft(find.descendant(of: table, matching: find.text('12')))
        .dy;
    final oldest = tester
        .getTopLeft(find.descendant(of: table, matching: find.text('11')))
        .dy;
    expect(newest, lessThan(oldest));
    expect(repo.calls, isEmpty);
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

  // ── Stale answers ─────────────────────────────────────────────────────────
  //
  // The notifier sequences its loads with a request id. Without that guard, a
  // range switched twice in quick succession leaves two reads in flight and
  // whichever the network happens to finish LAST wins — so the tiles settle on
  // a window the user is no longer looking at, under a chip that says
  // otherwise. It is invisible on a fast connection and permanent on a slow
  // one, which is the worst combination to find in the field.

  group('a slow answer never paints over a newer one', () {
    // Plain `test`, not `testWidgets`: there is no widget here, and
    // `testWidgets` runs the body inside a fake-async zone where the
    // notifier's own `scheduleMicrotask(load)` never fires without a pump —
    // the future would simply never complete.
    test('the superseded window is discarded, not rendered', () async {
      final repo = FakeAnalyticsRepository();
      final container = ProviderContainer(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(repo),
          analyticsClockProvider.overrideWithValue(() => _now),
        ],
      );
      addTearDown(container.dispose);

      // The provider is AUTO-DISPOSE: without a live listener it is thrown
      // away the instant `read` returns, and the next read rebuilds it back at
      // the default 30-day window — so the race under test would never happen.
      container.listen(catalogAnalyticsProvider, (_, __) {});
      final notifier = container.read(catalogAnalyticsProvider.notifier);
      await notifier.load();

      // The 7-day read is made SLOW and left in flight.
      final slow = Completer<void>();
      repo
        ..gate = slow
        ..summary = summaryPayload(pageViews: 7, from: '2026-08-17', days: 7);
      final sevenDay = notifier.selectPreset(AnalyticsRangePreset.last7);

      // The 90-day read is made FAST and allowed to finish first.
      repo
        ..gate = null
        ..summary = summaryPayload(pageViews: 90, from: '2026-05-26', days: 90);
      await notifier.selectPreset(AnalyticsRangePreset.last90);

      expect(container.read(catalogAnalyticsProvider).range.preset,
          AnalyticsRangePreset.last90);

      // Now the superseded 7-day answer lands. It must be dropped on the floor.
      slow.complete();
      await sevenDay;
      await Future<void>.delayed(Duration.zero);

      final state = container.read(catalogAnalyticsProvider);
      expect(state.range.preset, AnalyticsRangePreset.last90,
          reason: 'the chip the user is looking at');
      expect(
        state.report.value?.summary.kpis.pageViews,
        90,
        reason: 'the tiles must describe the window the range control shows — '
            'a late 7-day answer overwriting them is the exact bug the '
            'request-id guard exists to prevent',
      );
    });

    test('a superseded FAILURE does not replace a good newer answer', () async {
      // The same race with the slow read failing. An error state is just as
      // damaging out of order: the dashboard would show a retry prompt over a
      // window that had in fact loaded fine.
      final repo = FakeAnalyticsRepository();
      final container = ProviderContainer(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(repo),
          analyticsClockProvider.overrideWithValue(() => _now),
        ],
      );
      addTearDown(container.dispose);

      // The provider is AUTO-DISPOSE: without a live listener it is thrown
      // away the instant `read` returns, and the next read rebuilds it back at
      // the default 30-day window — so the race under test would never happen.
      container.listen(catalogAnalyticsProvider, (_, __) {});
      final notifier = container.read(catalogAnalyticsProvider.notifier);
      await notifier.load();

      final slow = Completer<void>();
      repo
        ..gate = slow
        ..failure = const CatalogFailure(code: 'INTERNAL_ERROR', message: 'x');
      final doomed = notifier.selectPreset(AnalyticsRangePreset.last7);

      repo
        ..gate = null
        ..failure = null
        ..summary = summaryPayload(pageViews: 90);
      await notifier.selectPreset(AnalyticsRangePreset.last90);

      slow.complete();
      await doomed;
      await Future<void>.delayed(Duration.zero);

      final state = container.read(catalogAnalyticsProvider);
      expect(state.report.hasError, isFalse,
          reason: 'the newer window loaded fine; a stale failure must not '
              'put a retry prompt over it');
      expect(state.report.value?.summary.kpis.pageViews, 90);
    });
  });
}
