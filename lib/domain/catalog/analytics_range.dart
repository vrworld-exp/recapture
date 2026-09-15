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
// DATES ARE CALENDAR DAYS IN THE BUSINESS'S ZONE — Indian Standard Time —
// matching the backend's `resolveRange` and the zone it asks Mirage to cut and
// bucket by (`ANALYTICS_TIMEZONE`). A preset is "the last N days ending today
// in IST", whatever the device's clock is set to: a manager checking from a
// laptop still on UTC, or a rep travelling, sees the same window the business
// lives in. The backend echoes the zone back on every report and the screen
// labels itself from that, never from this constant.
import 'package:flutter/foundation.dart' show immutable;

/// The zone every preset is computed in. IST has no daylight saving, so a
/// fixed offset IS the zone — the one thing that makes this safe to do
/// without a timezone database on the client.
const Duration kAnalyticsZoneOffset = Duration(hours: 5, minutes: 30);

/// The IANA name of that zone, as the backend states it in `range.timezone`.
const String kAnalyticsZoneName = 'Asia/Kolkata';

/// The preset windows the range control offers.
enum AnalyticsRangePreset {
  last7,
  last15,
  last30,
  last90,
  last365,
  custom,
}

extension AnalyticsRangePresetX on AnalyticsRangePreset {
  String get label => switch (this) {
        AnalyticsRangePreset.last7 => '7 days',
        AnalyticsRangePreset.last15 => '15 days',
        AnalyticsRangePreset.last30 => '30 days',
        AnalyticsRangePreset.last90 => '90 days',
        AnalyticsRangePreset.last365 => '12 months',
        AnalyticsRangePreset.custom => 'Custom',
      };

  /// How many days back the preset reaches, or null for [custom].
  ///
  /// [last365] is exactly the backend's ceiling ([kAnalyticsMaxRangeDays]),
  /// so it is the widest window that is honoured as asked rather than
  /// silently narrowed.
  int? get days => switch (this) {
        AnalyticsRangePreset.last7 => 7,
        AnalyticsRangePreset.last15 => 15,
        AnalyticsRangePreset.last30 => 30,
        AnalyticsRangePreset.last90 => 90,
        AnalyticsRangePreset.last365 => 365,
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

  /// A preset window ending on [now]'s calendar day in IST.
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
    final end = _zoneDay(now);
    return AnalyticsRangeSelection._(
      preset: preset,
      from: _dayString(end.subtract(Duration(days: days))),
      to: _dayString(end),
    );
  }

  /// An explicit window. Bounds are the CALENDAR DAYS the picker handed back
  /// and are ordered, so a picker that hands back `to` before `from` cannot
  /// produce a request the backend rejects with INVALID_REQUEST.
  ///
  /// The day is read off the value as given, never converted first: the date
  /// picker returns local midnight of the day the user tapped, and converting
  /// that to any other zone can land on the day before — "24 Aug" becoming a
  /// request for the 23rd on every device east of Greenwich.
  factory AnalyticsRangeSelection.custom({
    required DateTime from,
    required DateTime to,
  }) {
    final a = _calendarDay(from);
    final b = _calendarDay(to);
    final start = a.isAfter(b) ? b : a;
    final end = a.isAfter(b) ? a : b;
    return AnalyticsRangeSelection._(
      preset: AnalyticsRangePreset.custom,
      from: _dayString(start),
      to: _dayString(end),
    );
  }

  final AnalyticsRangePreset preset;

  /// `YYYY-MM-DD`, an IST calendar day — sent verbatim as the `from` / `to`
  /// query parameters.
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

  /// The calendar day an instant falls on in IST, as a UTC midnight (so day
  /// arithmetic on it never crosses a local DST boundary).
  static DateTime _zoneDay(DateTime value) {
    final shifted = value.toUtc().add(kAnalyticsZoneOffset);
    return DateTime.utc(shifted.year, shifted.month, shifted.day);
  }

  /// The year-month-day of a value as it stands, ignoring its zone.
  static DateTime _calendarDay(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);

  static String _dayString(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}
