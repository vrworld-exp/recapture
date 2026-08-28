// lib/application/catalog/catalog_analytics_notifier.dart
//
// The analytics dashboard's state (feature 66, surfacing 61-65).
//
// THREE REQUESTS, ONE ANSWER. Summary, timeseries and top-products are three
// endpoints because they proxy three Mirage reports, but they are one thing on
// screen: the tiles, the chart and the list all describe the SAME window, and a
// screen that could show a 7-day chart under a 90-day tile would be lying in a
// way nobody would notice. So all three are fetched together, for one range,
// and replaced together — there is no state in which half the dashboard has
// moved on.
//
// THE RANGE IS THE REQUEST. Changing 7 → 90 days re-fetches; it does not
// re-slice. See `analytics_range.dart` for why that is not merely
// conservative — `visitors` is a distinct count that no client-side filter can
// reconstruct.
//
// AUTO-DISPOSE, AND NO POLLING. These are minutes-stale aggregates behind a
// server-side cache; a dashboard that polled would wake a sleeping Mirage on a
// timer to redraw numbers nobody is watching. It loads when opened and reloads
// when asked.
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../domain/catalog/analytics_range.dart';
import '../../domain/entities/catalog_analytics.dart';

@immutable
class CatalogAnalyticsState {
  const CatalogAnalyticsState({
    required this.range,
    this.report = const AsyncLoading(),
  });

  /// The window every part of [report] was computed over.
  final AnalyticsRangeSelection range;

  /// The three reports, or the one loading/error state that covers all of them.
  final AsyncValue<CatalogAnalyticsReport> report;

  /// Mirage is unreachable. Distinguished from a plain error because the
  /// screen renders it as a SOFT empty state — nothing is broken, nothing has
  /// been lost, and the only thing missing is the report itself.
  bool get isUnavailable {
    final error = report.error;
    return error is CatalogFailure && error.isAnalyticsUnavailable;
  }

  /// The caller has no catalog at all — the first-run state, not a failure.
  bool get hasNoCatalog {
    final error = report.error;
    return error is CatalogFailure && error.isNoCatalog;
  }

  /// The failure code the screen maps to a sentence, or null when the error is
  /// not one this layer produced.
  ///
  /// A code, never a message: the sentence is the client's to write (F10), and
  /// reading the server's own text here would be the one hole in that.
  String? get failureCode {
    final error = report.error;
    return error is CatalogFailure ? error.code : null;
  }

  CatalogAnalyticsState copyWith({
    AnalyticsRangeSelection? range,
    AsyncValue<CatalogAnalyticsReport>? report,
  }) =>
      CatalogAnalyticsState(
        range: range ?? this.range,
        report: report ?? this.report,
      );
}

/// The clock the range control reads "today" from.
///
/// A seam rather than a bare `DateTime.now()` so a test can assert on the exact
/// `from`/`to` a preset produced. Overridden in tests, never in the app.
final analyticsClockProvider = Provider<DateTime Function()>(
  (ref) => () => DateTime.now().toUtc(),
);

class CatalogAnalyticsNotifier
    extends AutoDisposeNotifier<CatalogAnalyticsState> {
  /// Which load is current. A range switched twice in quick succession leaves
  /// two requests in flight, and the slower one must not be allowed to paint
  /// over the newer answer — the tiles would then disagree with the chip the
  /// user is looking at.
  int _requestId = 0;
  bool _disposed = false;

  CatalogRepository get _repo => ref.read(catalogRepositoryProvider);

  @override
  CatalogAnalyticsState build() {
    // Reset first — Riverpod reuses the notifier instance across a rebuild.
    _disposed = false;
    _requestId = 0;
    ref.onDispose(() => _disposed = true);

    final initial = AnalyticsRangeSelection.preset(
      // 30 days is the backend's own default, so the first paint and the
      // server's untouched answer describe the same window.
      AnalyticsRangePreset.last30,
      now: ref.read(analyticsClockProvider)(),
    );

    scheduleMicrotask(load);
    return CatalogAnalyticsState(range: initial);
  }

  /// Switches to a preset window and re-reads.
  ///
  /// Tapping the chip that is already selected is a NO-OP: it is the most
  /// common accidental tap on this screen, and spending a request on it would
  /// blank a dashboard the user is reading to redraw the identical numbers.
  Future<void> selectPreset(AnalyticsRangePreset preset) {
    if (preset == AnalyticsRangePreset.custom) {
      // `custom` is chosen by picking dates, not by tapping a chip — the screen
      // opens the picker and calls [selectCustom] with the answer.
      return Future<void>.value();
    }
    return _select(
      AnalyticsRangeSelection.preset(
        preset,
        now: ref.read(analyticsClockProvider)(),
      ),
    );
  }

  /// Switches to an explicit window and re-reads.
  Future<void> selectCustom({required DateTime from, required DateTime to}) =>
      _select(AnalyticsRangeSelection.custom(from: from, to: to));

  Future<void> _select(AnalyticsRangeSelection next) {
    if (next == state.range && state.report.hasValue) {
      return Future<void>.value();
    }
    state = CatalogAnalyticsState(range: next);
    return load();
  }

  /// Re-reads the current window — the retry on every error and empty state.
  Future<void> refresh() {
    state = state.copyWith(report: const AsyncLoading());
    return load();
  }

  /// Fetches all three reports for [CatalogAnalyticsState.range].
  ///
  /// `Future.wait` rather than three awaits: they are independent reads behind
  /// the same server-side cache, and serialising them would make the dashboard
  /// three round trips slow for no benefit. The first failure wins — if the
  /// summary is unavailable the chart is too, and three separate error states
  /// for one outage is three times the noise.
  Future<void> load() async {
    final id = ++_requestId;
    final range = state.range;

    try {
      final results = await Future.wait([
        _repo.fetchAnalyticsSummary(from: range.from, to: range.to),
        _repo.fetchAnalyticsTimeseries(from: range.from, to: range.to),
        _repo.fetchAnalyticsTopProducts(
          from: range.from,
          to: range.to,
          limit: kTopProductsLimit,
        ),
      ]);

      if (_disposed || id != _requestId) return;
      state = state.copyWith(
        report: AsyncData(CatalogAnalyticsReport(
          summary: results[0] as AnalyticsSummary,
          timeseries: results[1] as AnalyticsTimeseries,
          topProducts: results[2] as TopProducts,
        )),
      );
    } on CatalogFailure catch (failure, stack) {
      if (_disposed || id != _requestId) return;
      state = state.copyWith(report: AsyncError(failure, stack));
    }
  }
}

/// The dashboard's state. Auto-disposed, so leaving the screen drops the
/// reports rather than holding a window the user has stopped looking at.
final catalogAnalyticsProvider = AutoDisposeNotifierProvider<
    CatalogAnalyticsNotifier, CatalogAnalyticsState>(
  CatalogAnalyticsNotifier.new,
);
