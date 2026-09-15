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
// A DAY HERE IS A DAY IN THE BUSINESS'S ZONE. The backend asks Mirage to cut
// the range and bucket the timeseries in `ANALYTICS_TIMEZONE` (IST) and states
// the zone back on every report as `range.timezone`. The screen labels itself
// from that field — never from an assumption — so a backend that changed the
// zone would change the heading with it. Re-bucketing on this side would break
// the one thing that matters: the rows adding up to the summary's totals.
//
// Parsed field by field like every other catalog entity: these DTOs are
// hand-synced with the backend's, so a client one deploy behind must render
// zeroes rather than throw on a key it has not heard of.
import '../catalog/catalog_names.dart';
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
    this.timezone = '',
  });

  /// `YYYY-MM-DD` in [timezone] — kept as the server's own string because that
  /// is what goes back on the next request. Use [fromDate] / [toDate] to render.
  final String from;
  final String to;

  /// Length in days. The summary sends it; the other two reports do not, so it
  /// is derived from the bounds there.
  final int days;

  /// The IANA zone the days are cut in, as the server stated it — e.g.
  /// `Asia/Kolkata`. Empty when the server did not say (an older backend), in
  /// which case the screen says nothing about the zone rather than guessing.
  final String timezone;

  /// The zone as a person reads it on a heading: `IST`, `UTC`, or the IANA
  /// name for anything else. Empty when unknown.
  String get timezoneLabel => switch (timezone) {
        'Asia/Kolkata' || 'Asia/Calcutta' => 'IST',
        'UTC' || 'Etc/UTC' => 'UTC',
        _ => timezone,
      };

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
      timezone: catalogText(map?['timezone']) ?? '',
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

/// The twelve headline counters, exactly the set the backend forwards.
///
/// Mirage's own summary also carries `byRestaurant`, the cross-client panel;
/// the backend never spreads it, so this is the whole vocabulary of counters
/// and there is nothing else to reach for.
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
    this.menuOpens = 0,
    this.productPageViews = 0,
    this.modelLoads = 0,
    this.modelFailures = 0,
  });

  /// Catalog opens — the public page loaded. The top of the funnel.
  final int pageViews;
  final int sessions;

  /// Unique visitors — an ESTIMATE. QR scans often open in a private or
  /// in-app browser that wipes storage per scan, so this runs high.
  final int visitors;

  /// A product opened on the public page.
  final int productViews;

  /// AR launches — the tap, not a confirmed session.
  final int arViews;

  /// AR sessions the device actually entered.
  final int arSessions;
  final int contactClicks;
  final int searches;

  /// Taps on the public page's floating Menu pill — "Browse taps".
  final int menuOpens;

  /// Arrivals that landed straight on one product — "Direct links".
  final int productPageViews;

  /// 3D models that finished loading.
  final int modelLoads;

  /// 3D models that gave up.
  final int modelFailures;

  static const zero = AnalyticsKpis();

  bool get isAllZero =>
      pageViews == 0 &&
      sessions == 0 &&
      visitors == 0 &&
      productViews == 0 &&
      arViews == 0 &&
      arSessions == 0 &&
      contactClicks == 0 &&
      searches == 0 &&
      menuOpens == 0 &&
      productPageViews == 0 &&
      modelLoads == 0 &&
      modelFailures == 0;

  factory AnalyticsKpis.fromMap(Map<String, dynamic>? map) => AnalyticsKpis(
        pageViews: catalogCount(map?['pageViews']),
        sessions: catalogCount(map?['sessions']),
        visitors: catalogCount(map?['visitors']),
        productViews: catalogCount(map?['productViews']),
        arViews: catalogCount(map?['arViews']),
        arSessions: catalogCount(map?['arSessions']),
        contactClicks: catalogCount(map?['contactClicks']),
        searches: catalogCount(map?['searches']),
        menuOpens: catalogCount(map?['menuOpens']),
        productPageViews: catalogCount(map?['productPageViews']),
        modelLoads: catalogCount(map?['modelLoads']),
        modelFailures: catalogCount(map?['modelFailures']),
      );
}

/// One step of "catalog opened → product viewed → AR launched → contact
/// clicked".
///
/// These are ACTIONS, not people: one visitor opening six products adds six
/// to the second stage, so a step can legitimately read higher than the one
/// above it. The dashboard shows the ratio anyway — the trend across ranges is
/// the information, not the absolute drop-off.
class FunnelStage {
  const FunnelStage({
    required this.key,
    required this.label,
    this.count = 0,
  });

  /// Mirage's event type — the stable identity; [label] is display copy.
  final String key;
  final String label;
  final int count;

  factory FunnelStage.fromMap(Map<String, dynamic> map) => FunnelStage(
        key: catalogText(map['key']) ?? '',
        label: catalogText(map['label']) ?? '',
        count: catalogCount(map['count']),
      );
}

/// Sessions on one class of device.
class DeviceShare {
  const DeviceShare({required this.type, this.sessions = 0});

  /// `mobile`, `tablet`, `desktop` or `unknown`, as Mirage classifies the
  /// user agent at ingest.
  final String type;
  final int sessions;

  String get label => switch (type.toLowerCase()) {
        'mobile' => 'Mobile',
        'tablet' => 'Tablet',
        'desktop' => 'Desktop',
        _ => 'Unknown',
      };

  factory DeviceShare.fromMap(Map<String, dynamic> map) => DeviceShare(
        type: catalogText(map['type']) ?? 'unknown',
        sessions: catalogCount(map['sessions']),
      );
}

/// How often one category was opened on the public page.
class CategoryOpens {
  const CategoryOpens({
    required this.name,
    this.opens = 0,
    this.sessions = 0,
  });

  /// The STORED slug form, as it was sent to Mirage. [displayName] is what
  /// goes on the dashboard.
  final String name;
  final int opens;
  final int sessions;

  String get displayName => catalogDisplayName(name);

  factory CategoryOpens.fromMap(Map<String, dynamic> map) => CategoryOpens(
        name: catalogText(map['name']) ?? '',
        opens: catalogCount(map['opens']),
        sessions: catalogCount(map['sessions']),
      );
}

/// A product visitors pinched in to inspect.
///
/// Zooming is deliberate in a way rotating is not, which makes it the sharpest
/// read of genuine curiosity about a model. Three gestures make one counted
/// zoom, so a nudge does not register.
class ZoomedItem {
  const ZoomedItem({
    required this.productId,
    required this.name,
    this.catalogProductId,
    this.zooms = 0,
    this.sessions = 0,
  });

  /// The Mirage item id the public page reported.
  final String productId;

  /// OUR product id, where the row still maps to one. Null when it does not.
  final String? catalogProductId;
  final String name;
  final int zooms;
  final int sessions;

  String get displayName => catalogDisplayName(name);

  bool get isLinkable =>
      catalogProductId != null && catalogProductId!.isNotEmpty;

  factory ZoomedItem.fromMap(Map<String, dynamic> map) => ZoomedItem(
        productId: catalogText(map['productId']) ?? '',
        catalogProductId: catalogText(map['catalogProductId']),
        name: catalogText(map['name']) ?? 'Unknown product',
        zooms: catalogCount(map['zooms']),
        sessions: catalogCount(map['sessions']),
      );
}

/// What visitors typed into the public page's search box.
class SearchQuery {
  const SearchQuery({
    required this.query,
    this.searches = 0,
    this.sessions = 0,
    this.avgResults = 0,
    this.zeroResults = 0,
  });

  /// Already lowercased and trimmed by the public page.
  final String query;
  final int searches;
  final int sessions;

  /// Mean number of products the query matched, to one decimal.
  final double avgResults;

  /// How many of those searches matched nothing — the products a business
  /// may be missing. The column to read before the ranking.
  final int zeroResults;

  factory SearchQuery.fromMap(Map<String, dynamic> map) => SearchQuery(
        query: catalogText(map['query']) ?? '',
        searches: catalogCount(map['searches']),
        sessions: catalogCount(map['sessions']),
        avgResults: _nonNegativeDouble(map['avgResults']),
        zeroResults: catalogCount(map['zeroResults']),
      );
}

/// Why 3D models failed to load, grouped by the viewer's own reason string.
class FailureReason {
  const FailureReason({required this.reason, this.count = 0});

  /// model-viewer's `detail.type`: `loadfailure`, `webglcontextlost`, or
  /// `unknown`. Anything else falls through to [label] as-is.
  final String reason;
  final int count;

  /// The person-readable line. "loadfailure" is a broken or missing asset and
  /// is fixable; "webglcontextlost" is the device giving up and usually is
  /// not — telling them apart is the point of the split.
  String get label => switch (reason) {
        'loadfailure' => 'Model file failed to load',
        'webglcontextlost' => 'Device dropped the 3D canvas',
        'unknown' => 'Unreported',
        _ => reason,
      };

  factory FailureReason.fromMap(Map<String, dynamic> map) => FailureReason(
        reason: catalogText(map['reason']) ?? 'unknown',
        count: catalogCount(map['count']),
      );
}

/// A product whose 3D model keeps failing — the health panel's call to action.
class FailingProduct {
  const FailingProduct({
    required this.productId,
    required this.name,
    this.catalogProductId,
    this.failures = 0,
  });

  final String productId;
  final String? catalogProductId;
  final String name;
  final int failures;

  String get displayName => catalogDisplayName(name);

  bool get isLinkable =>
      catalogProductId != null && catalogProductId!.isNotEmpty;

  factory FailingProduct.fromMap(Map<String, dynamic> map) => FailingProduct(
        productId: catalogText(map['productId']) ?? '',
        catalogProductId: catalogText(map['catalogProductId']),
        name: catalogText(map['name']) ?? 'Unknown product',
        failures: catalogCount(map['failures']),
      );
}

/// Whether the 3D and AR experience actually works on visitors' devices.
///
/// Every other panel assumes it does; this is the one that checks.
class ModelHealth {
  const ModelHealth({
    this.loads = 0,
    this.failures = 0,
    this.failureRate,
    this.samples = 0,
    this.avgLoadMs = 0,
    this.maxLoadMs = 0,
    this.slowLoads = 0,
    this.slowThresholdMs = kDefaultSlowLoadMs,
    this.topFailures = const <FailureReason>[],
    this.failingProducts = const <FailingProduct>[],
  });

  /// Mirage's own SLOW_MODEL_LOAD_MS, for a payload that omits it.
  static const int kDefaultSlowLoadMs = 5000;

  final int loads;
  final int failures;

  /// Percent of attempted loads that failed, or **null when nothing was
  /// attempted** — "no models loaded" and "every model loaded" must not read
  /// alike.
  final double? failureRate;

  /// Loads that carried a usable timing — the denominator behind [avgLoadMs].
  final int samples;
  final int avgLoadMs;
  final int maxLoadMs;
  final int slowLoads;
  final int slowThresholdMs;
  final List<FailureReason> topFailures;
  final List<FailingProduct> failingProducts;

  static const empty = ModelHealth();

  int get attempts => loads + failures;

  factory ModelHealth.fromMap(Map<String, dynamic>? map) {
    final rawReasons = map?['topFailures'];
    final rawProducts = map?['failingProducts'];
    final threshold = catalogCount(map?['slowThresholdMs']);
    final rate = map?['failureRate'];
    return ModelHealth(
      loads: catalogCount(map?['loads']),
      failures: catalogCount(map?['failures']),
      failureRate: rate is num ? rate.toDouble() : null,
      samples: catalogCount(map?['samples']),
      avgLoadMs: catalogCount(map?['avgLoadMs']),
      maxLoadMs: catalogCount(map?['maxLoadMs']),
      slowLoads: catalogCount(map?['slowLoads']),
      slowThresholdMs: threshold > 0 ? threshold : kDefaultSlowLoadMs,
      topFailures: _listOf(rawReasons, FailureReason.fromMap),
      failingProducts: _listOf(rawProducts, FailingProduct.fromMap),
    );
  }
}

/// The summary report: this window's counters, the window before it, and
/// every panel that is computed over the same slice.
class AnalyticsSummary {
  const AnalyticsSummary({
    required this.window,
    this.kpis = AnalyticsKpis.zero,
    this.previousKpis,
    this.totalEvents = 0,
    this.funnel = const <FunnelStage>[],
    this.byDevice = const <DeviceShare>[],
    this.topCategories = const <CategoryOpens>[],
    this.topZoomed = const <ZoomedItem>[],
    this.topSearches = const <SearchQuery>[],
    this.modelHealth = ModelHealth.empty,
  });

  final AnalyticsWindow window;
  final AnalyticsKpis kpis;

  /// The immediately preceding window of equal length, or **null when the
  /// backend has none** — before the first publish, and whenever Mirage does
  /// not return one. Null means "no comparison to draw", which is not the same
  /// as "no change": the dashboard shows no delta at all rather than 0%.
  final AnalyticsKpis? previousKpis;

  /// Every event in the window, of any type — the footer's "N events".
  final int totalEvents;

  /// The four funnel stages as the backend sent them. Prefer [funnelStages],
  /// which falls back to the counters when this is empty.
  final List<FunnelStage> funnel;
  final List<DeviceShare> byDevice;
  final List<CategoryOpens> topCategories;
  final List<ZoomedItem> topZoomed;
  final List<SearchQuery> topSearches;
  final ModelHealth modelHealth;

  static const empty = AnalyticsSummary(window: AnalyticsWindow.empty);

  /// The funnel, always four stages.
  ///
  /// A backend one deploy behind sends no `funnel` block; the same four
  /// numbers are on the counters, so the panel is drawn from those rather than
  /// left blank. When both are present the backend's own list wins, so a
  /// stage Mirage adds or relabels shows up without a client release.
  List<FunnelStage> get funnelStages => funnel.isNotEmpty
      ? funnel
      : [
          FunnelStage(
            key: 'client_page_view',
            label: 'Catalog opened',
            count: kpis.pageViews,
          ),
          FunnelStage(
            key: 'product_detail_opened',
            label: 'Product viewed',
            count: kpis.productViews,
          ),
          FunnelStage(
            key: 'ar_view_clicked',
            label: 'AR launched',
            count: kpis.arViews,
          ),
          FunnelStage(
            key: 'contact_channel_clicked',
            label: 'Contact clicked',
            count: kpis.contactClicks,
          ),
        ];

  factory AnalyticsSummary.fromMap(Map<String, dynamic>? map) {
    final previous = map?['previousKpis'];
    return AnalyticsSummary(
      window: AnalyticsWindow.fromMap(_mapOf(map?['range'])),
      kpis: AnalyticsKpis.fromMap(_mapOf(map?['kpis'])),
      previousKpis: previous is Map<String, dynamic>
          ? AnalyticsKpis.fromMap(previous)
          : null,
      totalEvents: catalogCount(map?['totalEvents']),
      funnel: _listOf(map?['funnel'], FunnelStage.fromMap),
      byDevice: _listOf(map?['byDevice'], DeviceShare.fromMap),
      topCategories: _listOf(map?['topCategories'], CategoryOpens.fromMap),
      topZoomed: _listOf(map?['topZoomed'], ZoomedItem.fromMap),
      topSearches: _listOf(map?['topSearches'], SearchQuery.fromMap),
      modelHealth: ModelHealth.fromMap(_mapOf(map?['modelHealth'])),
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

  /// `YYYY-MM-DD`, a calendar day in the report's zone
  /// ([AnalyticsWindow.timezone]).
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
        AnalyticsSeries.pageViews => 'Catalog opens',
        AnalyticsSeries.productViews => 'Product views',
        AnalyticsSeries.arViews => 'AR launches',
        AnalyticsSeries.sessions => 'Sessions',
      };

  /// The short form for the chart's own selector, where four chips have to fit
  /// across 360 px.
  String get shortLabel => switch (this) {
        AnalyticsSeries.pageViews => 'Opens',
        AnalyticsSeries.productViews => 'Products',
        AnalyticsSeries.arViews => 'AR',
        AnalyticsSeries.sessions => 'Sessions',
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

  /// One row per calendar day. Mirage fills the gaps and the backend neither re-fills
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

  /// The name Mirage reported — the STORED slug form. [displayName] is what
  /// goes on the dashboard.
  final String name;

  /// The name as a person reads it, matching the catalog and the public menu.
  String get displayName => catalogDisplayName(name);
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

/// A list of parsed rows, dropping anything that is not a map rather than
/// failing the whole report on one bad row.
List<T> _listOf<T>(dynamic raw, T Function(Map<String, dynamic>) parse) => [
      if (raw is List)
        for (final item in raw)
          if (item is Map<String, dynamic>) parse(item),
    ];

/// A non-negative decimal, defaulting to 0 for anything unusable.
double _nonNegativeDouble(dynamic raw) =>
    raw is num && raw >= 0 ? raw.toDouble() : 0;
