// lib/presentation/widgets/catalog/analytics_format.dart
//
// How the dashboard writes numbers and dates.
//
// LOCALE FORMATTING WITHOUT A NEW DEPENDENCY. `MaterialLocalizations` already
// carries `formatDecimal` and the date formatters, on every platform this app
// targets, and it is the seam that starts honouring the device's locale the
// moment `GlobalMaterialLocalizations` is added to the app. Reaching for `intl`
// to group thousands would add a package to do what the framework already does
// (AGENTS.md: no new dependency without justification).
//
// ABBREVIATE, BUT NEVER LOSE THE NUMBER. A tile reading "1.2k" is legible at
// 360 px in a way "1,247" is not, and a business owner who wants the exact
// figure must always be one hover or one tap from it — every call site that
// uses [analyticsCompact] pairs it with [analyticsExact] in a tooltip and in
// the semantics label, so the precise value reaches a screen reader too.
import 'package:flutter/material.dart';

/// The full number, grouped the way the device's locale groups it.
String analyticsExact(BuildContext context, int value) =>
    MaterialLocalizations.of(context).formatDecimal(value);

/// The short form for a tile or an axis label: `947`, `1.2k`, `3.4M`.
///
/// Below 1,000 this IS [analyticsExact] — there is nothing to save and a
/// grouped three-digit number is already short.
///
/// ⚠ The scaled form uses a `.` before the unit rather than the locale's own
/// decimal separator: `formatDecimal` formats integers, and the framework
/// exposes no separator to borrow. That is a deliberately small inaccuracy in
/// the ABBREVIATION only — the exact value beside it is fully localised, which
/// is the one that has to be right.
String analyticsCompact(BuildContext context, int value) {
  if (value.abs() < 1000) return analyticsExact(context, value);

  final negative = value < 0;
  final magnitude = value.abs();

  final (scaled, unit) = magnitude >= 1000000000
      ? (magnitude / 1000000000, 'B')
      : magnitude >= 1000000
          ? (magnitude / 1000000, 'M')
          : (magnitude / 1000, 'k');

  // One decimal below 10 ("1.2k"), none above it ("12k") — the digit stops
  // earning its width once the leading figure has two of its own.
  final text = scaled >= 10
      ? scaled.round().toString()
      : scaled.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');

  return '${negative ? '-' : ''}$text$unit';
}

/// A short day label for a chart axis or a tooltip — "Aug 24" in an English
/// locale, and the locale's own order elsewhere.
String analyticsShortDay(BuildContext context, DateTime day) =>
    MaterialLocalizations.of(context).formatShortMonthDay(day);

/// A full date, for the range caption where the ambiguity of "Aug 24" across a
/// year boundary would matter.
String analyticsFullDay(BuildContext context, DateTime day) =>
    MaterialLocalizations.of(context).formatMediumDate(day);

/// The period-over-period change, as a percentage of the previous window.
///
/// Returns null when there is NO COMPARISON TO DRAW — no previous window, or a
/// previous window of zero. That is not the same as "no change": a shop that
/// went from 0 to 40 views did not grow by 0%, and rendering an arrow there
/// would be inventing a baseline that does not exist.
double? analyticsDelta({required int current, required int? previous}) {
  if (previous == null || previous == 0) return null;
  return (current - previous) / previous;
}

/// The delta as the tile prints it: `+18%`, `-4%`, `0%`.
String analyticsDeltaLabel(double delta) {
  final percent = (delta * 100).round();
  return '${percent > 0 ? '+' : ''}$percent%';
}
