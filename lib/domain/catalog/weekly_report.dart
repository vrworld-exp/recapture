// lib/domain/catalog/weekly_report.dart
//
// The owner's weekly value report (more-customization Stage 9), as
// `GET /catalog/reports/:weekStart` returns it. Built and stored by the worker
// every Monday; this side only reads it.
//
// Every parser is lenient in the house way: a missing or wrong-typed field
// reads as zero / empty, never a crash — the report is a courtesy screen and
// an older or newer API must not break it.

int _int(Object? v) => v is num ? v.toInt() : 0;
double? _pct(Object? v) => v is num ? v.toDouble() : null;
String _str(Object? v) => v is String ? v : '';
List<Object?> _list(Object? v) => v is List ? v : const [];
Map<String, dynamic> _map(Object? v) => v is Map<String, dynamic> ? v : const {};

/// Where a tip's action card takes the owner.
enum TipAction {
  product,
  publish,
  modelGeneration,
  addProduct,
  qr,
  none;

  static TipAction fromApiValue(String value) => switch (value) {
        'PRODUCT' => TipAction.product,
        'PUBLISH' => TipAction.publish,
        'MODEL_GENERATION' => TipAction.modelGeneration,
        'ADD_PRODUCT' => TipAction.addProduct,
        'QR' => TipAction.qr,
        _ => TipAction.none,
      };
}

class WeeklyReportTip {
  const WeeklyReportTip({required this.id, required this.text, required this.action, this.productId});

  final String id;
  final String text;
  final TipAction action;
  final String? productId;

  factory WeeklyReportTip.fromMap(Map<String, dynamic> map) => WeeklyReportTip(
        id: _str(map['id']),
        text: _str(map['text']),
        action: TipAction.fromApiValue(_str(map['action'])),
        productId: map['productId'] is String ? map['productId'] as String : null,
      );
}

class WeeklyReportDish {
  const WeeklyReportDish({
    required this.name,
    required this.views,
    required this.arViews,
    this.catalogProductId,
    this.thumbnailUrl,
  });

  final String name;
  final int views;
  final int arViews;
  final String? catalogProductId;
  final String? thumbnailUrl;

  factory WeeklyReportDish.fromMap(Map<String, dynamic> map) => WeeklyReportDish(
        name: _str(map['name']),
        views: _int(map['views']),
        arViews: _int(map['arViews']),
        catalogProductId: map['catalogProductId'] is String ? map['catalogProductId'] as String : null,
        thumbnailUrl: map['thumbnailUrl'] is String ? map['thumbnailUrl'] as String : null,
      );
}

class WeeklyReport {
  const WeeklyReport({
    required this.weekStart,
    required this.label,
    required this.menuViews,
    required this.uniqueVisitors,
    required this.qrScans,
    required this.arViews,
    required this.menuViewsDelta,
    required this.visitorsDelta,
    required this.arViewsDelta,
    required this.topDishes,
    required this.daily,
    required this.hourly,
    required this.tips,
    this.busiestLabel,
  });

  /// `YYYY-MM-DD`, the Monday.
  final String weekStart;

  /// "22–28 Sep".
  final String label;
  final int menuViews;
  final int uniqueVisitors;
  final int qrScans;
  final int arViews;

  /// Percent vs the previous week; null when that week was too small to compare.
  final double? menuViewsDelta;
  final double? visitorsDelta;
  final double? arViewsDelta;
  final List<WeeklyReportDish> topDishes;

  /// Seven menu-view counts, Monday first.
  final List<int> daily;

  /// 7 × 24 menu views, Monday first — the heat strip.
  final List<List<int>> hourly;
  final List<WeeklyReportTip> tips;

  /// "Saturday 8–9 pm", preformatted by the server.
  final String? busiestLabel;

  factory WeeklyReport.fromMap(Map<String, dynamic> map) {
    final metrics = _map(map['metrics']);
    final delta = _map(metrics['deltaPct']);
    final hourlyRaw = _list(metrics['hourly']);
    return WeeklyReport(
      weekStart: _str(map['weekStart']),
      label: _str(map['label']),
      menuViews: _int(metrics['menuViews']),
      uniqueVisitors: _int(metrics['uniqueVisitors']),
      qrScans: _int(metrics['qrScans']),
      arViews: _int(metrics['arViews']),
      menuViewsDelta: _pct(delta['menuViews']),
      visitorsDelta: _pct(delta['uniqueVisitors']),
      arViewsDelta: _pct(delta['arViews']),
      topDishes: _list(metrics['topDishes'])
          .whereType<Map<String, dynamic>>()
          .map(WeeklyReportDish.fromMap)
          .toList(growable: false),
      daily: _list(metrics['daily'])
          .whereType<Map<String, dynamic>>()
          .map((d) => _int(d['menuViews']))
          .toList(growable: false),
      hourly: List.generate(7, (d) {
        final row = d < hourlyRaw.length ? _list(hourlyRaw[d]) : const <Object?>[];
        return List.generate(24, (h) => h < row.length ? _int(row[h]) : 0, growable: false);
      }, growable: false),
      tips: _list(map['tips'])
          .whereType<Map<String, dynamic>>()
          .map(WeeklyReportTip.fromMap)
          .toList(growable: false),
      busiestLabel: map['busiestLabel'] is String ? map['busiestLabel'] as String : null,
    );
  }
}

/// One row of the history list.
class WeeklyReportSummary {
  const WeeklyReportSummary({
    required this.weekStart,
    required this.label,
    required this.menuViews,
    this.delta,
  });

  final String weekStart;
  final String label;
  final int menuViews;
  final double? delta;

  factory WeeklyReportSummary.fromMap(Map<String, dynamic> map) => WeeklyReportSummary(
        weekStart: _str(map['weekStart']),
        label: _str(map['label']),
        menuViews: _int(map['menuViews']),
        delta: _pct(map['deltaPct']),
      );
}

/// The history plus the owner's on/off switch (absent for a rep's read).
class WeeklyReportHistory {
  const WeeklyReportHistory({required this.reports, this.weeklyEnabled});

  final List<WeeklyReportSummary> reports;

  /// Null when the caller is a rep — the switch is the owner's alone.
  final bool? weeklyEnabled;

  factory WeeklyReportHistory.fromMap(Map<String, dynamic>? map) {
    final data = map ?? const <String, dynamic>{};
    final prefs = data['prefs'];
    return WeeklyReportHistory(
      reports: _list(data['reports'])
          .whereType<Map<String, dynamic>>()
          .map(WeeklyReportSummary.fromMap)
          .toList(growable: false),
      weeklyEnabled: prefs is Map<String, dynamic> ? prefs['weekly'] != false : null,
    );
  }
}
