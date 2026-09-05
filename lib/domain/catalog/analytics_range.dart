// lib/domain/catalog/analytics_range.dart
//
// Which window the dashboard is asking about.
//
// THE RANGE IS PART OF THE REQUEST, NOT A FILTER OVER A FETCHED BLOB. Mirage
// aggregates server-side and the backend caches per resolved range, so changing
// 7 → 90 days is a new read, not a re-slice of something already on the client.
// A client-side filter would also be a lie at the edges: the 90-day answer
// contains days the 7-day request never asked for, and `visitors` is a DISTINCT
// count that cannot be re-derived by adding days together.
//
// Dates are UTC DAYS, matching the backend's own `resolveRange` and Mirage's
// `timezone: "UTC"` bucketing. Building them from the device's local midnight
// would ask for a window an hour or thirteen away from the one the numbers are
// bucketed into.
import 'package:flutter/foundation.dart' show immutable;

/// The preset windows the range control offers.
enum AnalyticsRangePreset {
  last7,
  last30,
  last90,
  custom,
}

extension AnalyticsRangePresetX on AnalyticsRangePreset {
  String get label => switch (this) {
        AnalyticsRangePreset.last7 => '7 days',
        AnalyticsRangePreset.last30 => '30 days',
        AnalyticsRangePreset.last90 => '90 days',
        AnalyticsRangePreset.custom => 'Custom',
      };

  /// How many days back the preset reaches, or null for [custom].
  int? get days => switch (this) {
        AnalyticsRangePreset.last7 => 7,
        AnalyticsRangePreset.last30 => 30,
        AnalyticsRangePreset.last90 => 90,
        AnalyticsRangePreset.custom => null,
      };
}

/// The longest window the backend will honour. Asking for more is silently
/// narrowed server-side, so the picker refuses it up front instead — a range
/// control whose answer disagrees with what it shows is worse than one that
/// says no.
const int kAnalyticsMaxRangeDays = 365;

/// A chosen window, in the exact form the request takes.
@immutable
class AnalyticsRangeSelection {
  const AnalyticsRangeSelection._({
    required this.preset,
    required this.from,
    required this.to,
  });

  /// A preset window ending [now] (UTC).
  ///
  /// [now] is injected rather than read from the clock inside, because a
  /// notifier that reads the wall clock is a test that cannot assert on the
  /// request it produced.
  factory AnalyticsRangeSelection.preset(
    AnalyticsRangePreset preset, {
    required DateTime now,
  }) {
    final days = preset.days;
    if (days == null) {
      // `custom` has no implicit bounds; a caller reaching here means a bug, so
      // fall back to the same default the backend uses rather than an
      // unbounded request.
      return AnalyticsRangeSelection.preset(
        AnalyticsRangePreset.last30,
        now: now,
      );
    }
    final end = _utcDay(now);
    return AnalyticsRangeSelection._(
      preset: preset,
      from: _dayString(end.subtract(Duration(days: days))),
      to: _dayString(end),
    );
  }

  /// An explicit window. Bounds are normalised to UTC days and ordered, so a
  /// picker that hands back `to` before `from` cannot produce a request the
  /// backend rejects with INVALID_REQUEST.
  factory AnalyticsRangeSelection.custom({
    required DateTime from,
    required DateTime to,
  }) {
    final a = _utcDay(from);
    final b = _utcDay(to);
    final start = a.isAfter(b) ? b : a;
    final end = a.isAfter(b) ? a : b;
    return AnalyticsRangeSelection._(
      preset: AnalyticsRangePreset.custom,
      from: _dayString(start),
      to: _dayString(end),
    );
  }

  final AnalyticsRangePreset preset;

  /// `YYYY-MM-DD`, UTC — sent verbatim as the `from` / `to` query parameters.
  final String from;
  final String to;

  DateTime? get fromDate => DateTime.tryParse(from);
  DateTime? get toDate => DateTime.tryParse(to);

  /// The span in days, for the "vs previous 30 days" caption.
  int get days {
    final start = fromDate;
    final end = toDate;
    if (start == null || end == null) return preset.days ?? 0;
    return end.difference(start).inDays;
  }

  /// Identity for "is this a different request?". The notifier compares
  /// selections to decide whether a tap on the already-selected chip should
  /// spend a request — it should not.
  @override
  bool operator ==(Object other) =>
      other is AnalyticsRangeSelection &&
      other.preset == preset &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(preset, from, to);

  @override
  String toString() => 'AnalyticsRangeSelection(${preset.name}: $from..$to)';

  /// Midnight UTC on the same calendar day, discarding the time.
  static DateTime _utcDay(DateTime value) {
    final utc = value.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day);
  }

  static String _dayString(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}
