// test/catalog/analytics_entities_test.dart
//
// Golden-JSON parsing for the ANALYTICS entities (F12; features 61-66).
//
// The sibling of `catalog_entities_test.dart`, split out because the analytics
// DTOs have a different provenance and a different failure mode. The catalog
// DTOs are ours end to end; these are a PROXY of Mirage's own reports, reshaped
// by `catalogAnalyticsService.ts`, and Mirage has no tests and no type checking
// (AGENTS.md). So there are two ways a field can go quiet here — the backend
// renames it, or Mirage stops sending it and the backend's own `num()` coercion
// turns the absence into a silent zero — and neither shows up as an error
// anywhere. It shows up as a dashboard reading 0 that nobody questions, because
// 0 is a legitimate answer on this screen.
//
// That is the specific thing this file defends: **a zero must never be
// indistinguishable from a parse failure.** Every counter is given a DISTINCT
// non-zero value in the golden below, so a field that stops parsing collapses
// to 0 and fails its assertion instead of quietly matching a neighbour.
//
// Hand-synced with `recapture-api/src/services/catalogAnalyticsService.ts` —
// `AnalyticsSummaryDto`, `AnalyticsTimeseriesPointDto`, `TopProductDto`,
// `TopProductsDto`. No shared package, no codegen; this file is the contract.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/catalog_analytics.dart';

// ── Goldens ─────────────────────────────────────────────────────────────────

/// Exactly what the `/catalog/analytics/summary` envelope's `data` carries.
///
/// Every counter is distinct and non-zero on purpose — see the header.
Map<String, dynamic> summaryGolden() => {
      'range': {'from': '2026-07-27', 'to': '2026-08-25', 'days': 30},
      'kpis': {
        'pageViews': 1247,
        'sessions': 913,
        'visitors': 604,
        'productViews': 388,
        'arViews': 152,
        'arSessions': 141,
        'contactClicks': 76,
        'searches': 42,
      },
      'previousKpis': {
        'pageViews': 1050,
        'sessions': 820,
        'visitors': 559,
        'productViews': 301,
        'arViews': 129,
        'arSessions': 118,
        'contactClicks': 61,
        'searches': 35,
      },
    };

/// Exactly what `/catalog/analytics/timeseries` carries.
Map<String, dynamic> timeseriesGolden() => {
      'range': {'from': '2026-08-23', 'to': '2026-08-25', 'days': 3},
      'points': [
        {
          'date': '2026-08-23',
          'pageViews': 41,
          'productViews': 17,
          'arViews': 6,
          'sessions': 29,
        },
        {
          'date': '2026-08-24',
          'pageViews': 58,
          'productViews': 23,
          'arViews': 9,
          'sessions': 37,
        },
        {
          'date': '2026-08-25',
          'pageViews': 33,
          'productViews': 11,
          'arViews': 4,
          'sessions': 22,
        },
      ],
    };

/// Exactly what `/catalog/analytics/top-products` carries.
Map<String, dynamic> topProductsGolden() => {
      'range': {'from': '2026-07-27', 'to': '2026-08-25', 'days': 30},
      'rows': [
        {
          'productId': 'mirage-item-001',
          'catalogProductId': '6a83dd464aea89d1d2d28d60',
          'name': 'Walnut Chair',
          'kind': '3D',
          'views': 210,
          'arViews': 64,
          'modelLoads': 118,
          'sessions': 173,
        },
        {
          'productId': 'mirage-item-002',
          'catalogProductId': '6a83dd464aea89d1d2d28d61',
          'name': 'Ceramic Mug',
          'kind': 'IMAGE_ONLY',
          'views': 96,
          'arViews': 0,
          'modelLoads': 0,
          'sessions': 81,
        },
        {
          // Deleted locally: still counted, still named, and unlinkable.
          'productId': 'mirage-item-003',
          'catalogProductId': null,
          'name': 'Oak Stool',
          'kind': 'UNKNOWN',
          'views': 54,
          'arViews': 7,
          'modelLoads': 31,
          'sessions': 48,
        },
      ],
      'totals': {
        '3D': {'views': 210, 'arViews': 64, 'products': 1},
        'IMAGE_ONLY': {'views': 96, 'arViews': 0, 'products': 1},
        'UNKNOWN': {'views': 54, 'arViews': 7, 'products': 1},
      },
    };

void main() {
  group('AnalyticsWindow', () {
    test('parses the golden DTO field by field', () {
      final window = AnalyticsSummary.fromMap(summaryGolden()).window;

      expect(window.from, '2026-07-27');
      expect(window.to, '2026-08-25');
      expect(window.days, 30);
    });

    test('takes the SERVER resolved range, not the requested one', () {
      // The server defaults and caps at 365 days. A dashboard titled from the
      // request would misdescribe the numbers underneath it whenever the two
      // differ, which is exactly when the caption matters most.
      final map = summaryGolden()
        ..['range'] = {'from': '2025-08-25', 'to': '2026-08-25', 'days': 365};

      expect(AnalyticsSummary.fromMap(map).window.days, 365);
    });

    test('derives days when the backend omits the count', () {
      final map = summaryGolden()
        ..['range'] = {'from': '2026-08-18', 'to': '2026-08-25'};

      expect(AnalyticsSummary.fromMap(map).window.days, 7);
    });
  });

  group('AnalyticsKpis', () {
    test('parses all eight counters field by field', () {
      final kpis = AnalyticsSummary.fromMap(summaryGolden()).kpis;

      expect(kpis.pageViews, 1247);
      expect(kpis.sessions, 913);
      expect(kpis.visitors, 604);
      expect(kpis.productViews, 388);
      expect(kpis.arViews, 152);
      expect(kpis.arSessions, 141);
      expect(kpis.contactClicks, 76);
      expect(kpis.searches, 42);
    });

    test('the previous window parses too, and is a DIFFERENT set of numbers',
        () {
      // Reading `kpis` for both would make every delta read 0% — a wrong
      // answer that looks like a plausible one.
      final summary = AnalyticsSummary.fromMap(summaryGolden());

      expect(summary.previousKpis, isNotNull);
      expect(summary.previousKpis!.pageViews, 1050);
      expect(summary.previousKpis!.visitors, 559);
      expect(summary.previousKpis!.arViews, 129);
      expect(summary.previousKpis!.pageViews, isNot(summary.kpis.pageViews));
    });

    test('an absent previous window is null, not zero', () {
      // Null means "no comparison to draw" — before the first publish there is
      // no prior window at all. Zero would mean the shop had 0 views then,
      // which the dashboard would render as a triumphant +infinity.
      final map = summaryGolden()..remove('previousKpis');
      final summary = AnalyticsSummary.fromMap(map);

      expect(summary.previousKpis, isNull);
      expect(summary.kpis.pageViews, 1247, reason: 'this window still parses');
    });

    test('a null previous window is also null, not an empty Kpis', () {
      final map = summaryGolden()..['previousKpis'] = null;

      expect(AnalyticsSummary.fromMap(map).previousKpis, isNull);
    });

    test('isAllZero is true only when every counter is zero', () {
      expect(AnalyticsKpis.zero.isAllZero, isTrue);
      expect(AnalyticsSummary.fromMap(summaryGolden()).kpis.isAllZero, isFalse);

      // One lonely non-zero counter is still activity. A range where the only
      // event was a contact click is not an empty range.
      final map = summaryGolden()
        ..['kpis'] = {'contactClicks': 1};
      expect(AnalyticsSummary.fromMap(map).kpis.isAllZero, isFalse);
    });

    test('tolerates a truncated summary without crashing', () {
      expect(AnalyticsSummary.fromMap(null).kpis.isAllZero, isTrue);
      expect(AnalyticsSummary.fromMap({}).kpis.isAllZero, isTrue);
      expect(AnalyticsSummary.fromMap({'kpis': 'nonsense'}).kpis.isAllZero,
          isTrue);
    });

    test('ignores unknown counters from a newer server', () {
      // Built as an explicit Map<String, dynamic> because that is what
      // `jsonDecode` produces for a nested object, and the entity rightly
      // refuses anything else rather than guessing at a dynamic map.
      final map = summaryGolden()
        ..['kpis'] = <String, dynamic>{
          ...summaryGolden()['kpis'] as Map<String, dynamic>,
          'checkouts': 9,
        };

      expect(AnalyticsSummary.fromMap(map).kpis.pageViews, 1247);
      expect(AnalyticsSummary.fromMap(map).kpis.searches, 42);
    });
  });

  group('AnalyticsTimeseries', () {
    test('parses every point field by field', () {
      final series = AnalyticsTimeseries.fromMap(timeseriesGolden());

      expect(series.points, hasLength(3));
      final middle = series.points[1];
      expect(middle.date, '2026-08-24');
      expect(middle.pageViews, 58);
      expect(middle.productViews, 23);
      expect(middle.arViews, 9);
      expect(middle.sessions, 37);
    });

    test('keeps the backend ORDER — it must not re-sort', () {
      // Mirage gap-fills and returns an ascending, continuous axis. Re-sorting
      // here would invent an order the summary totals disagree with.
      final dates = [
        for (final point in AnalyticsTimeseries.fromMap(timeseriesGolden()).points)
          point.date,
      ];

      expect(dates, ['2026-08-23', '2026-08-24', '2026-08-25']);
    });

    test('a point exposes its UTC day for the axis', () {
      final point = AnalyticsTimeseries.fromMap(timeseriesGolden()).points.first;

      expect(point.day, DateTime.parse('2026-08-23'));
    });

    test('drops malformed rows instead of failing the whole chart', () {
      final map = timeseriesGolden()
        ..['points'] = [
          {'date': '2026-08-24', 'pageViews': 58},
          'not a row',
          42,
        ];
      final series = AnalyticsTimeseries.fromMap(map);

      expect(series.points, hasLength(1));
      expect(series.points.single.pageViews, 58);
      // The absent counters fall back to zero rather than throwing.
      expect(series.points.single.arViews, 0);
    });

    test('tolerates an absent or non-list points block', () {
      expect(AnalyticsTimeseries.fromMap(null).isEmpty, isTrue);
      expect(AnalyticsTimeseries.fromMap({}).isEmpty, isTrue);
      expect(AnalyticsTimeseries.fromMap({'points': 'nope'}).isEmpty, isTrue);
    });

    test('every series reads its own field off a point', () {
      // The chart's selector maps a chip to a field. Two chips reading the same
      // field is a bug that looks like "the data is the same" on screen.
      final point = AnalyticsTimeseries.fromMap(timeseriesGolden()).points[1];
      final values = {
        for (final series in AnalyticsSeries.values) series: series.valueOf(point),
      };

      expect(values[AnalyticsSeries.pageViews], 58);
      expect(values[AnalyticsSeries.productViews], 23);
      expect(values[AnalyticsSeries.arViews], 9);
      expect(values[AnalyticsSeries.sessions], 37);
      expect(values.values.toSet(), hasLength(4));
    });
  });

  group('TopProducts', () {
    test('parses every row field by field', () {
      final report = TopProducts.fromMap(topProductsGolden());
      final first = report.rows.first;

      expect(report.rows, hasLength(3));
      expect(first.productId, 'mirage-item-001');
      expect(first.catalogProductId, '6a83dd464aea89d1d2d28d60');
      expect(first.name, 'Walnut Chair');
      expect(first.kind, TopProductKind.threeD);
      expect(first.views, 210);
      expect(first.arViews, 64);
      expect(first.modelLoads, 118);
      expect(first.sessions, 173);
    });

    test('every kind string maps to its enum', () {
      final kinds = [
        for (final row in TopProducts.fromMap(topProductsGolden()).rows) row.kind,
      ];

      expect(kinds, [
        TopProductKind.threeD,
        TopProductKind.imageOnly,
        TopProductKind.unknown,
      ]);
    });

    test('the API values match the backend TOP_PRODUCT_KINDS exactly', () {
      // `recapture-api/src/services/catalogAnalyticsService.ts`:
      //   export const TOP_PRODUCT_KINDS = ['3D', 'IMAGE_ONLY', 'UNKNOWN']
      expect(TopProductKind.threeD.apiValue, '3D');
      expect(TopProductKind.imageOnly.apiValue, 'IMAGE_ONLY');
      expect(TopProductKind.unknown.apiValue, 'UNKNOWN');
    });

    test('an unrecognised kind degrades to unknown rather than throwing', () {
      expect(TopProductKindX.fromApiValue('HOLOGRAM'), TopProductKind.unknown);
      expect(TopProductKindX.fromApiValue(''), TopProductKind.unknown);
      // Case-insensitive, because the backend constant is the contract and a
      // casing drift should not blank a row.
      expect(TopProductKindX.fromApiValue('image_only'),
          TopProductKind.imageOnly);
    });

    test('a locally deleted product stays counted and is unlinkable', () {
      final deleted = TopProducts.fromMap(topProductsGolden()).rows.last;

      expect(deleted.kind, TopProductKind.unknown);
      expect(deleted.catalogProductId, isNull);
      expect(deleted.isLinkable, isFalse,
          reason: 'there is no local product left to open');
      expect(deleted.views, 54, reason: 'the views it earned are real');
      expect(deleted.productId, 'mirage-item-003',
          reason: 'the Mirage id is the only identity it has left, and two '
              'Unknown rows must be tellable apart');
    });

    test('parses the per-kind totals for all three kinds', () {
      final report = TopProducts.fromMap(topProductsGolden());

      expect(report.totalsFor(TopProductKind.threeD).views, 210);
      expect(report.totalsFor(TopProductKind.threeD).arViews, 64);
      expect(report.totalsFor(TopProductKind.threeD).products, 1);
      expect(report.totalsFor(TopProductKind.imageOnly).views, 96);
      expect(report.totalsFor(TopProductKind.unknown).views, 54);
    });

    test('a kind missing from totals reads zero, not null', () {
      final map = topProductsGolden()
        ..['totals'] = {
          '3D': {'views': 210, 'arViews': 64, 'products': 1},
        };
      final report = TopProducts.fromMap(map);

      expect(report.totalsFor(TopProductKind.imageOnly), isNotNull);
      expect(report.totalsFor(TopProductKind.imageOnly).views, 0);
    });

    test('totalViews comes off the TOTALS, not the returned rows', () {
      // The rows are capped by `limit`; the totals are not. Summing rows would
      // make the split bar disagree with itself the moment a catalog has more
      // products than the limit.
      final map = topProductsGolden()..['rows'] = [];
      final report = TopProducts.fromMap(map);

      expect(report.rows, isEmpty);
      expect(report.totalViews, 210 + 96 + 54);
    });

    test('totalModelLoads is summed from the rows, where the field lives', () {
      // Mirage's summary has no model-loads counter — it exists per row only,
      // which is why that tile carries no period-over-period delta.
      expect(TopProducts.fromMap(topProductsGolden()).totalModelLoads,
          118 + 0 + 31);
    });

    test('tolerates a truncated report', () {
      expect(TopProducts.fromMap(null).isEmpty, isTrue);
      expect(TopProducts.fromMap({}).isEmpty, isTrue);
      expect(TopProducts.fromMap({'rows': 'nope'}).isEmpty, isTrue);
      expect(TopProducts.fromMap({}).totalViews, 0);
    });

    test('a row missing its name still renders with a placeholder', () {
      final map = topProductsGolden()
        ..['rows'] = [
          {'productId': 'mirage-item-009', 'kind': '3D', 'views': 5},
        ];

      expect(TopProducts.fromMap(map).rows.single.name, 'Unknown product');
    });
  });

  group('CatalogAnalyticsReport', () {
    test('isEmpty only when all three reports are empty', () {
      final full = CatalogAnalyticsReport(
        summary: AnalyticsSummary.fromMap(summaryGolden()),
        timeseries: AnalyticsTimeseries.fromMap(timeseriesGolden()),
        topProducts: TopProducts.fromMap(topProductsGolden()),
      );

      expect(full.isEmpty, isFalse);
      expect(CatalogAnalyticsReport.empty.isEmpty, isTrue);
    });

    test('a window with counters but no rows is NOT empty', () {
      // A quiet week where the page was opened but nothing was tapped is real
      // data, and must render zeroed tiles rather than the first-run message
      // telling the owner to go publish something they already published.
      final report = CatalogAnalyticsReport(
        summary: AnalyticsSummary.fromMap(summaryGolden()),
        timeseries: AnalyticsTimeseries.empty,
        topProducts: TopProducts.empty,
      );

      expect(report.isEmpty, isFalse);
    });
  });
}
