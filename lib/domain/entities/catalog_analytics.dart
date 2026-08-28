// lib/domain/entities/catalog_analytics.dart
//
// The catalog's customer-facing numbers (features 61-66), as the dashboard
// reads them.
//
// THREE REPORTS, ONE WINDOW. The backend exposes summary, timeseries and
// top-products separately because each proxies a different Mirage report, and
// each carries the resolved range back. They are modelled separately here for
// the same reason — but [CatalogAnalyticsReport] binds the three that were
// fetched for ONE window, so nothing on screen can mix a 7-day chart with a
// 90-day tile.
//
// ⚠ A DAY HERE IS A UTC DAY. Mirage buckets on `receivedAt` with an explicit
// `timezone: "UTC"`, and the range filter is UTC too, so a shop closing at 1am
// local sees that evening split across two rows. Deliberate, and documented
// upstream in `catalogAnalyticsService.ts` — inventing a local day on this side
// would produce points that do not add up to the summary's totals.
//
// Parsed field by field like every other catalog entity: these DTOs are
// hand-synced with the backend's, so a client one deploy behind must render
// zeroes rather than throw on a key it has not heard of.
import 'catalog_json.dart';

/// The window a report covers, as the server resolved it.
///
/// The server is the authority on this, not the client: it defaults, caps at
/// 365 days, and its answer is what the numbers were actually computed over. A
/// dashboard that titled itself from the REQUESTED range would lie whenever the
/// two differ.
class AnalyticsWindow {
  const AnalyticsWindow({
    required this.from,
    required this.to,
    required this.days,
  });

  /// `YYYY-MM-DD`, UTC — kept as the server's own string because that is what
  /// goes back on the next request. Use [fromDate] / [toDate] to render.
  final String from;
  final String to;

  /// Length in days. The summary sends it; the other two reports do not, so it
  /// is derived from the bounds there.
  final int days;

  DateTime? get fromDate => DateTime.tryParse(from);
  DateTime? get toDate => DateTime.tryParse(to);

  static const empty = AnalyticsWindow(from: '', to: '', days: 0);

  factory AnalyticsWindow.fromMap(Map<String, dynamic>? map) {
    final from = catalogText(map?['from']) ?? '';
    final to = catalogText(map?['to']) ?? '';
    final stated = catalogCount(map?['days']);
    return AnalyticsWindow(
      from: from,
      to: to,
      days: stated > 0 ? stated : _spanDays(from, to),
    );
  }

  static int _spanDays(String from, String to) {
    final start = DateTime.tryParse(from);
    final end = DateTime.tryParse(to);
    if (start == null || end == null) return 0;
    final span = end.difference(start).inDays;
    return span > 0 ? span : 0;
  }
}

/// The eight headline counters, exactly the set the backend forwards.
///
/// Mirage's own summary also carries cross-restaurant panels; the backend
/// refuses to spread them (`toKpis`), so this is the whole vocabulary and there
/// is nothing else to reach for.
class AnalyticsKpis {
  const AnalyticsKpis({
    this.pageViews = 0,
    this.sessions = 0,
    this.visitors = 0,
    this.productViews = 0,
    this.arViews = 0,
    this.arSessions = 0,
    this.contactClicks = 0,
    this.searches = 0,
  });

  /// Catalog views — the public page opened.
  final int pageViews;
  final int sessions;

  /// Unique visitors.
  final int visitors;

  /// A product opened on the public page.
  final int productViews;

  /// AR launches.
  final int arViews;
  final int arSessions;
  final int contactClicks;
  final int searches;

  static const zero = AnalyticsKpis();

  bool get isAllZero =>
      pageViews == 0 &&
      sessions == 0 &&
      visitors == 0 &&
      productViews == 0 &&
      arViews == 0 &&
      arSessions == 0 &&
      contactClicks == 0 &&
      searches == 0;

  factory AnalyticsKpis.fromMap(Map<String, dynamic>? map) => AnalyticsKpis(
        pageViews: catalogCount(map?['pageViews']),
        sessions: catalogCount(map?['sessions']),
        visitors: catalogCount(map?['visitors']),
        productViews: catalogCount(map?['productViews']),
        arViews: catalogCount(map?['arViews']),
        arSessions: catalogCount(map?['arSessions']),
        contactClicks: catalogCount(map?['contactClicks']),
        searches: catalogCount(map?['searches']),
      );
}

/// The summary report: this window's counters and the one before it.
class AnalyticsSummary {
  const AnalyticsSummary({
    required this.window,
    this.kpis = AnalyticsKpis.zero,
    this.previousKpis,
  });

  final AnalyticsWindow window;
  final AnalyticsKpis kpis;

  /// The immediately preceding window of equal length, or **null when the
  /// backend has none** — before the first publish, and whenever Mirage does
  /// not return one. Null means "no comparison to draw", which is not the same
  /// as "no change": the dashboard shows no delta at all rather than 0%.
  final AnalyticsKpis? previousKpis;

  static const empty = AnalyticsSummary(window: AnalyticsWindow.empty);

  factory AnalyticsSummary.fromMap(Map<String, dynamic>? map) {
    final previous = map?['previousKpis'];
    return AnalyticsSummary(
      window: AnalyticsWindow.fromMap(_mapOf(map?['range'])),
      kpis: AnalyticsKpis.fromMap(_mapOf(map?['kpis'])),
      previousKpis: previous is Map<String, dynamic>
          ? AnalyticsKpis.fromMap(previous)
          : null,
    );
  }
}

/// One UTC day of the timeseries.
class AnalyticsPoint {
  const AnalyticsPoint({
    required this.date,
    this.pageViews = 0,
    this.productViews = 0,
    this.arViews = 0,
    this.sessions = 0,
  });

  /// `YYYY-MM-DD`, UTC.
  final String date;
  final int pageViews;
  final int productViews;
  final int arViews;
  final int sessions;

  DateTime? get day => DateTime.tryParse(date);

  factory AnalyticsPoint.fromMap(Map<String, dynamic> map) => AnalyticsPoint(
        date: catalogText(map['date']) ?? '',
        pageViews: catalogCount(map['pageViews']),
        productViews: catalogCount(map['productViews']),
        arViews: catalogCount(map['arViews']),
        sessions: catalogCount(map['sessions']),
      );
}

/// The four series a point carries, as the chart's selector offers them.
///
/// An enum rather than four getters on the chart, so "which series is on
/// screen" is one value that the axis label, the tooltip and the legend all
/// read — three places that must never disagree about what is being drawn.
enum AnalyticsSeries { pageViews, productViews, arViews, sessions }

extension AnalyticsSeriesX on AnalyticsSeries {
  String get label => switch (this) {
        AnalyticsSeries.pageViews => 'Catalog views',
        AnalyticsSeries.productViews => 'Product views',
        AnalyticsSeries.arViews => 'AR launches',
        AnalyticsSeries.sessions => 'Visits',
      };

  /// The short form for the chart's own selector, where four chips have to fit
  /// across 360 px.
  String get shortLabel => switch (this) {
        AnalyticsSeries.pageViews => 'Views',
        AnalyticsSeries.productViews => 'Products',
        AnalyticsSeries.arViews => 'AR',
        AnalyticsSeries.sessions => 'Visits',
      };

  int valueOf(AnalyticsPoint point) => switch (this) {
        AnalyticsSeries.pageViews => point.pageViews,
        AnalyticsSeries.productViews => point.productViews,
        AnalyticsSeries.arViews => point.arViews,
        AnalyticsSeries.sessions => point.sessions,
      };
}

/// The timeseries report.
class AnalyticsTimeseries {
  const AnalyticsTimeseries({
    required this.window,
    this.points = const <AnalyticsPoint>[],
  });

  final AnalyticsWindow window;

  /// One row per UTC day. Mirage fills the gaps and the backend neither re-fills
  /// nor re-sorts, so this is already a continuous, ascending axis — the chart
  /// must not sort it again and invent an order the totals disagree with.
  final List<AnalyticsPoint> points;

  static const empty = AnalyticsTimeseries(window: AnalyticsWindow.empty);

  bool get isEmpty => points.isEmpty;

  factory AnalyticsTimeseries.fromMap(Map<String, dynamic>? map) {
    final raw = map?['points'];
    return AnalyticsTimeseries(
      window: AnalyticsWindow.fromMap(_mapOf(map?['range'])),
      points: [
        if (raw is List)
          for (final item in raw)
            if (item is Map<String, dynamic>) AnalyticsPoint.fromMap(item),
      ],
    );
  }
}

/// Whether a top-products row is a 3D product, an image-only one, or a row that
/// no longer maps to anything in this catalog (feature 65).
///
/// [unknown] is NOT an error and NOT dropped: a product deleted locally keeps
/// the views it earned, and "the thing we deleted was the most viewed one" is
/// worth knowing. Its numbers stay in the totals so they agree with the public
/// page's own.
enum TopProductKind { threeD, imageOnly, unknown }

extension TopProductKindX on TopProductKind {
  String get label => switch (this) {
        TopProductKind.threeD => '3D',
        TopProductKind.imageOnly => 'Image only',
        TopProductKind.unknown => 'Unknown',
      };

  /// API string value — must match the backend `TOP_PRODUCT_KINDS` exactly.
  String get apiValue => switch (this) {
        TopProductKind.threeD => '3D',
        TopProductKind.imageOnly => 'IMAGE_ONLY',
        TopProductKind.unknown => 'UNKNOWN',
      };

  static TopProductKind fromApiValue(String value) =>
      switch (value.toUpperCase()) {
        '3D' => TopProductKind.threeD,
        'IMAGE_ONLY' => TopProductKind.imageOnly,
        _ => TopProductKind.unknown,
      };
}

/// One row of the top-products table.
class TopProduct {
  const TopProduct({
    required this.productId,
    required this.name,
    required this.kind,
    this.catalogProductId,
    this.views = 0,
    this.arViews = 0,
    this.modelLoads = 0,
    this.sessions = 0,
  });

  /// The Mirage item id the public page reported. Always present — it is the
  /// only identity an unmatched row has, and the row still shows it so a
  /// business can tell two `Unknown` rows apart.
  final String productId;

  /// OUR product id, where the row still maps to a product in this catalog.
  /// Null for a [TopProductKind.unknown] row, which is exactly what makes it
  /// unlinkable.
  final String? catalogProductId;

  final String name;
  final TopProductKind kind;
  final int views;
  final int arViews;

  /// 3D model loads on the public page. Only ever non-zero on a 3D row.
  final int modelLoads;
  final int sessions;

  /// Whether tapping this row can open the product editor.
  bool get isLinkable =>
      catalogProductId != null && catalogProductId!.isNotEmpty;

  factory TopProduct.fromMap(Map<String, dynamic> map) => TopProduct(
        productId: catalogText(map['productId']) ?? '',
        catalogProductId: catalogText(map['catalogProductId']),
        name: catalogText(map['name']) ?? 'Unknown product',
        kind: TopProductKindX.fromApiValue(
          catalogText(map['kind']) ?? 'UNKNOWN',
        ),
        views: catalogCount(map['views']),
        arViews: catalogCount(map['arViews']),
        modelLoads: catalogCount(map['modelLoads']),
        sessions: catalogCount(map['sessions']),
      );
}

/// The per-type totals behind the 3D-vs-image split (feature 65).
class TopProductTotals {
  const TopProductTotals({
    this.views = 0,
    this.arViews = 0,
    this.products = 0,
  });

  final int views;
  final int arViews;

  /// How many rows of this type are in the report.
  final int products;

  static const zero = TopProductTotals();

  factory TopProductTotals.fromMap(Map<String, dynamic>? map) =>
      TopProductTotals(
        views: catalogCount(map?['views']),
        arViews: catalogCount(map?['arViews']),
        products: catalogCount(map?['products']),
      );
}

/// The top-products report, rows plus the split.
class TopProducts {
  const TopProducts({
    required this.window,
    this.rows = const <TopProduct>[],
    this.totals = const <TopProductKind, TopProductTotals>{},
  });

  final AnalyticsWindow window;
  final List<TopProduct> rows;
  final Map<TopProductKind, TopProductTotals> totals;

  static const empty = TopProducts(window: AnalyticsWindow.empty);

  bool get isEmpty => rows.isEmpty;

  TopProductTotals totalsFor(TopProductKind kind) =>
      totals[kind] ?? TopProductTotals.zero;

  /// Views across every type — the denominator of the split bar. Read off the
  /// TOTALS rather than summed from [rows] so a truncated `limit` cannot make
  /// the split disagree with itself.
  int get totalViews => totals.values.fold(0, (sum, t) => sum + t.views);

  /// 3D model loads across the report.
  ///
  /// Summed from the rows because the backend carries `modelLoads` PER ROW and
  /// nowhere else — Mirage's summary has no such counter. That is also why this
  /// tile has no period-over-period delta: there is no previous-window number
  /// to compare it against, and inventing one by re-fetching the prior range
  /// would double every dashboard load for a single arrow.
  int get totalModelLoads => rows.fold(0, (sum, row) => sum + row.modelLoads);

  factory TopProducts.fromMap(Map<String, dynamic>? map) {
    final rawRows = map?['rows'];
    final rawTotals = map?['totals'];
    return TopProducts(
      window: AnalyticsWindow.fromMap(_mapOf(map?['range'])),
      rows: [
        if (rawRows is List)
          for (final item in rawRows)
            if (item is Map<String, dynamic>) TopProduct.fromMap(item),
      ],
      totals: {
        for (final kind in TopProductKind.values)
          kind: TopProductTotals.fromMap(
            rawTotals is Map ? _mapOf(rawTotals[kind.apiValue]) : null,
          ),
      },
    );
  }
}

/// The three reports for ONE window.
///
/// Bound together so the screen cannot render a 7-day chart under a 90-day
/// tile: the notifier fetches all three for the same range and replaces all
/// three at once, and there is no way to hold half of a newer answer.
class CatalogAnalyticsReport {
  const CatalogAnalyticsReport({
    required this.summary,
    required this.timeseries,
    required this.topProducts,
  });

  final AnalyticsSummary summary;
  final AnalyticsTimeseries timeseries;
  final TopProducts topProducts;

  static const empty = CatalogAnalyticsReport(
    summary: AnalyticsSummary.empty,
    timeseries: AnalyticsTimeseries.empty,
    topProducts: TopProducts.empty,
  );

  /// Nothing happened in this window.
  ///
  /// A LEGITIMATE, NON-ERROR STATE: a range before the business published, a
  /// quiet week, a catalog whose QR has not been put on the tables yet. The
  /// dashboard renders zeroed tiles and says so — it does not show a failure.
  bool get isEmpty =>
      summary.kpis.isAllZero && timeseries.isEmpty && topProducts.isEmpty;
}

Map<String, dynamic>? _mapOf(dynamic raw) =>
    raw is Map<String, dynamic> ? raw : null;
