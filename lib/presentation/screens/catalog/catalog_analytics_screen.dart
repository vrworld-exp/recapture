// lib/presentation/screens/catalog/catalog_analytics_screen.dart
//
// `/catalog/analytics` — what happened after publish (feature 66, surfacing
// 61-65), section for section the same dashboard Mirage's own admin shows for
// one restaurant.
//
// THIS SCREEN OPENS ONTO REAL HISTORY. Collection has been running on Mirage's
// public page for months; nothing here starts it, and ReCapture emits no
// customer-facing events of its own. That is why the dashboard is useful on the
// day it ships rather than in a month — and why the one thing it must never do
// is imply the numbers began when the screen did.
//
// IT IS DEFINED BY ITS STATES, NOT ITS HAPPY PATH. Five outcomes, and they must
// read as five different things:
//   • NO CATALOG — the first-run state, not a failure.
//   • NEVER PUBLISHED — "analytics start after you publish" is an instruction.
//     Distinguished from an empty window by asking the CATALOG, not by
//     guessing from zeroes: the backend answers a never-published catalog with
//     a zeroed 200 that is indistinguishable from a quiet week.
//   • A WINDOW WITH NO DATA — zeroed tiles and "no scans yet", NOT an error.
//     Real, honest, and the most likely state for a business that printed its
//     QR yesterday.
//   • UNAVAILABLE — Mirage is asleep or rate-limiting us. A DEGRADATION: the
//     report is missing, nothing is broken and nothing has been lost. Rendered
//     as a soft empty state off F10's code table, never as a crash.
//   • A GENUINE FAILURE — mapped sentence, one retry.
//
// ONE WINDOW, EVERY PANEL. The range control scopes the hero, the tiles, the
// chart and every card under them, so any two can be read against each
// other. The order of the cards is Mirage's own — KPIs, traffic, funnel,
// categories, searches, health, products, zoomed, devices, footer — so a
// business flipping between the two sees the same story told the same way.
//
// LAYOUT COMES FROM CONSTRAINTS, NEVER FROM `kIsWeb`. The tile grid, the chart
// and the split bar all read `LayoutBuilder`; a narrow browser window gets the
// phone layout because it is narrow, not because it is a browser.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_analytics_notifier.dart';
import '../../../application/catalog/catalog_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/analytics_range.dart';
import '../../../domain/entities/catalog.dart';
import '../../../domain/entities/catalog_analytics.dart';
import '../../widgets/app_card.dart';
import '../../widgets/catalog/analytics_chart.dart';
import '../../widgets/catalog/analytics_format.dart';
import '../../widgets/catalog/analytics_panels.dart';
import '../../widgets/catalog/analytics_section_info.dart';
import '../../widgets/catalog/analytics_sparkline.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';

/// Widest the dashboard grows. Past this the tiles stop being a row and start
/// being a horizon, and the chart gains nothing from the extra pixels.
const double kAnalyticsMaxWidth = 1100;

class CatalogAnalyticsScreen extends ConsumerWidget {
  const CatalogAnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => navigateBack(context),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Analytics', style: Theme.of(context).textTheme.titleLarge),
            const AnalyticsInfoHint(section: AnalyticsSection.overview),
          ],
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kAnalyticsMaxWidth),
            child: catalog.when(
              loading: () => const _AnalyticsSkeleton(),
              // The catalog read failing is not the analytics read failing —
              // this is the shell being unavailable, and the honest thing is to
              // say so rather than blame the report.
              error: (error, _) => CatalogMessage(
                key: const ValueKey('analytics_catalog_error'),
                icon: Icons.error_outline,
                title: 'We could not load your catalog',
                body: CatalogFeedback.textForCode(
                  error is CatalogFailure ? error.code : null,
                ),
                actionLabel: 'Try again',
                onAction: () => ref.read(catalogProvider.notifier).refresh(),
              ),
              data: (value) => _Gate(catalog: value),
            ),
          ),
        ),
      ),
    );
  }
}

/// The two states that are decided BEFORE any report is fetched.
///
/// Both are answered by the catalog itself, and asking it is the point: a
/// never-published catalog returns a zeroed 200 from the analytics endpoints
/// that looks exactly like a quiet week, and telling a business "no scans yet"
/// when the truth is "you have not published" sends them to check their QR
/// instead of to the publish button.
class _Gate extends ConsumerWidget {
  const _Gate({required this.catalog});

  final Catalog? catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = catalog;

    if (value == null) {
      return CatalogMessage(
        key: const ValueKey('analytics_no_catalog'),
        icon: Icons.storefront_outlined,
        title: 'No catalog yet',
        body: 'Create your catalog and publish it — your visitor numbers start '
            'from the moment it goes live.',
        actionLabel: 'Back to catalog',
        onAction: () => navigateBack(context),
      );
    }

    if (value.isNeverPublished) {
      return CatalogMessage(
        key: const ValueKey('analytics_never_published'),
        icon: Icons.insights_outlined,
        title: 'Analytics start after you publish',
        body: 'Nothing is being counted yet. Publish your catalog, put the QR '
            'code on your tables, and the numbers appear here.',
        actionLabel: 'Open publish',
        onAction: () => context.pushNamed(AppRouteNames.catalogPublish),
      );
    }

    return const _Dashboard();
  }
}

class _Dashboard extends ConsumerWidget {
  const _Dashboard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(catalogAnalyticsProvider);
    final notifier = ref.read(catalogAnalyticsProvider.notifier);

    return RefreshIndicator(
      onRefresh: notifier.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          AppSpacing.sm,
          AppSpacing.screenPadding,
          AppSpacing.xxxl,
        ),
        children: [
          // The range control stays put across every outcome below it. A
          // dashboard that hides its own controls when a window comes back
          // empty leaves the user with nothing to change but the back button.
          _RangeControl(
            range: state.range,
            onPreset: notifier.selectPreset,
            onCustom: (from, to) => notifier.selectCustom(from: from, to: to),
          ),
          const SizedBox(height: AppSpacing.lg),
          state.report.when(
            loading: () => const _AnalyticsSkeleton(embedded: true),
            error: (_, __) =>
                _FailureBody(state: state, onRetry: notifier.refresh),
            data: (report) => _ReportBody(report: report, range: state.range),
          ),
        ],
      ),
    );
  }
}

/// The unavailable degradation and a genuine failure, told apart.
class _FailureBody extends StatelessWidget {
  const _FailureBody({required this.state, required this.onRetry});

  final CatalogAnalyticsState state;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    // ⚠ THE SENTENCE COMES FROM THE CODE. `CatalogFeedback.textForCode` is
    // F10's table — the same one the toasts use — so nothing the server or a
    // proxy wrote can land on this screen. `ANALYTICS_UNAVAILABLE` has its own
    // entry there, which is what makes the soft wording below possible.
    final body = CatalogFeedback.textForCode(state.failureCode);

    if (state.isUnavailable) {
      return CatalogMessage(
        key: const ValueKey('analytics_unavailable'),
        // Deliberately NOT an error icon. Nothing has broken and nothing has
        // been lost — only the report is missing.
        icon: Icons.cloud_off_outlined,
        title: 'Numbers are not available right now',
        body: body,
        actionLabel: 'Try again',
        onAction: onRetry,
        fillsViewport: false,
      );
    }

    return CatalogMessage(
      key: const ValueKey('analytics_error'),
      icon: Icons.error_outline,
      title: 'We could not load your numbers',
      body: body,
      actionLabel: 'Try again',
      onAction: onRetry,
      fillsViewport: false,
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.report, required this.range});

  final CatalogAnalyticsReport report;
  final AnalyticsRangeSelection range;

  @override
  Widget build(BuildContext context) {
    final summary = report.summary;
    final kpis = summary.kpis;
    final previous = summary.previousKpis;
    final points = report.timeseries.points;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RangeCaption(window: summary.window, range: range),
        const SizedBox(height: AppSpacing.md),
        _KpiRow(
          hero: _HeroData(
            sessions: kpis.sessions,
            previousSessions: previous?.sessions,
            visitors: kpis.visitors,
          ),
          tiles: [
            _TileData(
              id: 'page_views',
              label: 'Catalog opens',
              section: AnalyticsSection.catalogOpens,
              value: kpis.pageViews,
              previous: previous?.pageViews,
              trend: [for (final p in points) p.pageViews],
              color: AppColors.focusRing,
            ),
            _TileData(
              id: 'product_views',
              label: 'Product views',
              section: AnalyticsSection.productViews,
              value: kpis.productViews,
              previous: previous?.productViews,
              trend: [for (final p in points) p.productViews],
              color: AppColors.royalGold,
            ),
            _TileData(
              id: 'ar_views',
              label: 'AR launches',
              section: AnalyticsSection.arLaunches,
              value: kpis.arViews,
              previous: previous?.arViews,
              trend: [for (final p in points) p.arViews],
              color: AppColors.success,
            ),
            _TileData(
              id: 'contact_clicks',
              label: 'Contact clicks',
              section: AnalyticsSection.contactClicks,
              value: kpis.contactClicks,
              previous: previous?.contactClicks,
            ),
            _TileData(
              id: 'browse_taps',
              label: 'Browse taps',
              section: AnalyticsSection.browseTaps,
              value: kpis.menuOpens,
              previous: previous?.menuOpens,
            ),
            _TileData(
              id: 'direct_links',
              label: 'Direct links',
              section: AnalyticsSection.directLinks,
              value: kpis.productPageViews,
              previous: previous?.productPageViews,
            ),
          ],
        ),
        if (report.isEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          const _NoDataYet(),
        ] else ...[
          const SizedBox(height: AppSpacing.lg),
          _ChartCard(points: points),
          const SizedBox(height: AppSpacing.lg),
          // Paired cards from 720 px: the funnel beside the categories, the
          // searches beside the health check — Mirage's own two-up, and the
          // pairs a reader compares. One column below that.
          _Pair(
            first: AnalyticsFunnelCard(stages: summary.funnelStages),
            second: AnalyticsCategoriesCard(rows: summary.topCategories),
          ),
          const SizedBox(height: AppSpacing.lg),
          _Pair(
            first: AnalyticsSearchesCard(
              rows: summary.topSearches,
              total: kpis.searches,
            ),
            second: AnalyticsModelHealthCard(
              health: summary.modelHealth,
              arViews: kpis.arViews,
              arSessions: kpis.arSessions,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AnalyticsTopProductsCard(topProducts: report.topProducts),
          const SizedBox(height: AppSpacing.lg),
          _SplitCard(topProducts: report.topProducts),
          const SizedBox(height: AppSpacing.lg),
          _Pair(
            first: AnalyticsZoomedCard(rows: summary.topZoomed),
            second: AnalyticsDevicesCard(rows: summary.byDevice),
            // The zoomed table wants the room; the device split does not.
            firstFlex: 2,
          ),
          const SizedBox(height: AppSpacing.lg),
          AnalyticsFooter(totalEvents: summary.totalEvents),
        ],
      ],
    );
  }
}

/// Two cards side by side when there is room, stacked when there is not.
///
/// `IntrinsicHeight` so the pair shares a bottom edge — a funnel card that
/// stops 80 px above the categories card beside it reads as a layout bug.
///
/// ⚠ NOTHING INSIDE A PAIR MAY USE `LayoutBuilder`. IntrinsicHeight asks its
/// children for intrinsic dimensions and LayoutBuilder throws when asked —
/// in debug, loudly, on first paint. The paired cards size themselves with
/// flex and Wrap instead.
class _Pair extends StatelessWidget {
  const _Pair({
    required this.first,
    required this.second,
    this.firstFlex = 1,
  });

  final Widget first;
  final Widget second;
  final int firstFlex;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                first,
                const SizedBox(height: AppSpacing.lg),
                second,
              ],
            );
          }
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: firstFlex, child: first),
                const SizedBox(width: AppSpacing.lg),
                Expanded(child: second),
              ],
            ),
          );
        },
      );
}

/// "1 Aug – 31 Aug · compared with the previous 30 days".
///
/// Titled from the window the SERVER resolved, not the one that was asked for:
/// it defaults and caps at 365 days, and a caption built from the request would
/// misdescribe the numbers underneath it whenever the two differ.
class _RangeCaption extends StatelessWidget {
  const _RangeCaption({required this.window, required this.range});

  final AnalyticsWindow window;
  final AnalyticsRangeSelection range;

  @override
  Widget build(BuildContext context) {
    final from = window.fromDate ?? range.fromDate;
    final to = window.toDate ?? range.toDate;
    final days = window.days > 0 ? window.days : range.days;

    final span = from == null || to == null
        ? range.preset.label
        : '${analyticsFullDay(context, from)} – ${analyticsFullDay(context, to)}';

    return Text(
      days > 0 ? '$span · compared with the previous $days days' : span,
      key: const ValueKey('analytics_range_caption'),
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: AppColors.textSecondary),
    );
  }
}

// ── Range control ───────────────────────────────────────────────────────────

/// 7 / 15 / 30 / 90 / 365 and a custom window — Mirage's own five.
///
/// EVERY ONE OF THESE IS A REQUEST. The aggregation is server-side and cached
/// there per resolved range, so switching windows re-reads rather than
/// re-slicing — `visitors` is a distinct count that no client-side filter could
/// reconstruct from a wider window's days.
///
/// `ChoiceChip` rather than a hand-rolled row: it is focusable, it takes Enter
/// and Space from a keyboard, and it announces its selected state — the whole
/// keyboard-and-screen-reader story on web, for free.
class _RangeControl extends StatelessWidget {
  const _RangeControl({
    required this.range,
    required this.onPreset,
    required this.onCustom,
  });

  final AnalyticsRangeSelection range;
  final void Function(AnalyticsRangePreset preset) onPreset;
  final void Function(DateTime from, DateTime to) onCustom;

  static const _presets = [
    AnalyticsRangePreset.last7,
    AnalyticsRangePreset.last15,
    AnalyticsRangePreset.last30,
    AnalyticsRangePreset.last90,
    AnalyticsRangePreset.last365,
  ];

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (final preset in _presets)
            ChoiceChip(
              key: ValueKey('analytics_range_${preset.days}'),
              label: Text(preset.label),
              selected: range.preset == preset,
              onSelected: (_) => onPreset(preset),
            ),
          ChoiceChip(
            key: const ValueKey('analytics_range_custom'),
            avatar: const Icon(Icons.date_range, size: 16),
            label: const Text('Custom'),
            selected: range.preset == AnalyticsRangePreset.custom,
            onSelected: (_) => _pick(context),
          ),
        ],
      );

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      // The backend narrows anything longer to 365 days silently; refusing it
      // here means the control and the numbers never disagree about what was
      // asked for.
      firstDate: now.subtract(const Duration(days: kAnalyticsMaxRangeDays)),
      lastDate: now,
      initialDateRange: range.fromDate != null && range.toDate != null
          ? DateTimeRange(start: range.fromDate!, end: range.toDate!)
          : null,
      helpText: 'Select a date range',
    );
    if (picked == null) return;
    onCustom(picked.start, picked.end);
  }
}

// ── Hero and tiles ──────────────────────────────────────────────────────────

class _HeroData {
  const _HeroData({
    required this.sessions,
    required this.previousSessions,
    required this.visitors,
  });

  final int sessions;
  final int? previousSessions;
  final int visitors;
}

class _TileData {
  const _TileData({
    required this.id,
    required this.label,
    required this.section,
    required this.value,
    required this.previous,
    this.trend,
    this.color = AppColors.royalGold,
  });

  final String id;
  final String label;
  final AnalyticsSection section;
  final int value;

  /// The same counter in the preceding window, or null where there is no
  /// comparison to draw. Null is NOT zero — see [analyticsDelta].
  final int? previous;

  /// Day-by-day values for the sparkline, oldest first. Null for a counter
  /// the timeseries does not carry.
  final List<int>? trend;
  final Color color;
}

/// The hero figure and the six tiles.
///
/// Sessions is the hero, not visitors: QR traffic wipes browser storage per
/// scan, so the visitor count over-counts, and a headline that runs high is
/// the wrong one to quote to a business. Visitors is still shown, as the
/// estimate it is, under the hero.
///
/// The column count is derived from `LayoutBuilder`, which is what makes a
/// narrowed browser window behave like a phone rather than like a squeezed
/// desktop.
class _KpiRow extends StatelessWidget {
  const _KpiRow({required this.hero, required this.tiles});

  final _HeroData hero;
  final List<_TileData> tiles;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          const gap = AppSpacing.sm;

          Widget grid(double gridWidth, int columns) {
            final itemWidth = (gridWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final tile in tiles)
                  SizedBox(width: itemWidth, child: _KpiTile(tile: tile)),
              ],
            );
          }

          // Wide: the hero takes a third, the six tiles fill two rows of
          // three beside it. Narrow: the hero on top, then two columns.
          if (width >= 900) {
            final heroWidth = (width - gap) / 3;
            // IntrinsicHeight, so the hero is as tall as the two tile rows
            // beside it. A bare `stretch` cannot do this here: the row sits in
            // a ListView, whose height is unbounded, and stretching into an
            // unbounded height is the layout error, not the layout. (Nothing
            // inside the hero or a tile uses LayoutBuilder — see `_Pair`.)
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: heroWidth, child: _HeroTile(hero: hero)),
                  const SizedBox(width: gap),
                  Expanded(child: grid(width - heroWidth - gap, 3)),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HeroTile(hero: hero),
              const SizedBox(height: gap),
              grid(width, width >= 560 ? 3 : 2),
            ],
          );
        },
      );
}

class _HeroTile extends StatelessWidget {
  const _HeroTile({required this.hero});

  final _HeroData hero;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final exact = analyticsExact(context, hero.sessions);
    final delta = analyticsDelta(
      current: hero.sessions,
      previous: hero.previousSessions,
    );

    return AppCard(
      key: const ValueKey('analytics_tile_sessions'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Text(
                'SESSIONS',
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              const AnalyticsInfoHint(section: AnalyticsSection.sessions),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Semantics(
            label: 'Sessions: $exact'
                '${delta == null ? '' : ', ${analyticsDeltaLabel(delta)} '
                    'versus the previous period'}',
            excludeSemantics: true,
            child: Tooltip(
              message: exact,
              child: Text(
                analyticsCompact(context, hero.sessions),
                key: const ValueKey('analytics_value_sessions'),
                style: textTheme.displaySmall?.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          delta == null ? const _NoPriorPeriod() : _DeltaChip(delta: delta),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${analyticsExact(context, hero.visitors)} unique visitors '
                  '(estimate — QR scans often open in a private browser, '
                  'which inflates this count)',
                  key: const ValueKey('analytics_visitors'),
                  style:
                      textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
              const AnalyticsInfoHint(section: AnalyticsSection.visitors),
            ],
          ),
        ],
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({required this.tile});

  final _TileData tile;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final exact = analyticsExact(context, tile.value);
    final compact = analyticsCompact(context, tile.value);
    final delta = analyticsDelta(current: tile.value, previous: tile.previous);
    final trend = tile.trend;

    return AppCard(
      key: ValueKey('analytics_tile_${tile.id}'),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  // The EXACT number reaches a screen reader even when the
                  // tile shows "1.2k" — the abbreviation is a visual
                  // accommodation, not a redaction.
                  label: '${tile.label}: $exact'
                      '${delta == null ? '' : ', ${analyticsDeltaLabel(delta)} '
                          'versus the previous period'}',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tile.label,
                        style: textTheme.bodySmall
                            ?.copyWith(color: AppColors.textMuted),
                        maxLines: 2,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      // The tooltip is where the abbreviation is paid back —
                      // on web by hover, on a phone by long-press.
                      Tooltip(
                        message: exact,
                        child: Text(
                          compact,
                          key: ValueKey('analytics_value_${tile.id}'),
                          style: textTheme.titleLarge?.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnalyticsInfoHint(section: tile.section),
            ],
          ),
          if (trend != null && trend.length > 1) ...[
            const SizedBox(height: AppSpacing.xs),
            AnalyticsSparkline(
              key: ValueKey('analytics_sparkline_${tile.id}'),
              values: trend,
              color: tile.color,
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          delta == null ? const _NoPriorPeriod() : _DeltaChip(delta: delta),
        ],
      ),
    );
  }
}

/// What a tile says where there is no comparison to draw.
///
/// Said out loud rather than left blank: an absent arrow next to a present
/// one reads as "this one did not change", which is not what it means.
class _NoPriorPeriod extends StatelessWidget {
  const _NoPriorPeriod();

  @override
  Widget build(BuildContext context) => Text(
        'no prior period',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: AppColors.textMuted),
      );
}

class _DeltaChip extends StatelessWidget {
  const _DeltaChip({required this.delta});

  final double delta;

  @override
  Widget build(BuildContext context) {
    final rising = delta > 0;
    final flat = delta == 0;
    // Up is good for every metric on this dashboard — all of them count
    // engagement.
    final color = flat
        ? AppColors.textMuted
        : rising
            ? AppColors.success
            : AppColors.error;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          flat
              ? Icons.remove
              : rising
                  ? Icons.arrow_upward
                  : Icons.arrow_downward,
          size: 12,
          color: color,
        ),
        const SizedBox(width: 2),
        Text(
          analyticsDeltaLabel(delta),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
        // The suffix gives way before the figure does: on a tile too narrow
        // for both, "+25%" alone still says what happened, and the caption
        // above the tiles says what it is compared against.
        Flexible(
          child: Text(
            ' vs prev period',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }
}

// ── Chart ───────────────────────────────────────────────────────────────────

class _ChartCard extends StatefulWidget {
  const _ChartCard({required this.points});

  final List<AnalyticsPoint> points;

  @override
  State<_ChartCard> createState() => _ChartCardState();
}

class _ChartCardState extends State<_ChartCard> {
  AnalyticsSeries _series = AnalyticsSeries.pageViews;
  bool _table = false;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AnalyticsSectionCard(
      key: const ValueKey('analytics_chart_card'),
      title: 'Traffic over time',
      section: AnalyticsSection.traffic,
      subtitle: 'Daily totals, UTC',
      trailing: SegmentedButton<bool>(
        key: const ValueKey('analytics_traffic_mode'),
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments: const [
          ButtonSegment(value: false, label: Text('Chart')),
          ButtonSegment(value: true, label: Text('Table')),
        ],
        selected: {_table},
        onSelectionChanged: (selection) =>
            setState(() => _table = selection.first),
      ),
      child: widget.points.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Text(
                'No day-by-day data for this range.',
                key: const ValueKey('analytics_chart_empty'),
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            )
          : _table
              ? AnalyticsTrafficTable(points: widget.points)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: [
                        for (final series in AnalyticsSeries.values)
                          ChoiceChip(
                            key: ValueKey('analytics_series_${series.name}'),
                            label: Text(series.shortLabel),
                            selected: _series == series,
                            onSelected: (_) => setState(() => _series = series),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AnalyticsChart(
                      key: const ValueKey('analytics_chart'),
                      points: widget.points,
                      series: _series,
                    ),
                  ],
                ),
    );
  }
}

// ── 3D vs image-only split ──────────────────────────────────────────────────

/// Feature 65 — how much of the attention went to 3D products.
///
/// `Unknown` is a first-class slice, not a rounding error: it is the views
/// earned by products that have since been deleted locally, and hiding it would
/// make this bar disagree with the public page's own totals.
class _SplitCard extends StatelessWidget {
  const _SplitCard({required this.topProducts});

  final TopProducts topProducts;

  static const _order = [
    TopProductKind.threeD,
    TopProductKind.imageOnly,
    TopProductKind.unknown,
  ];

  Color _colorFor(TopProductKind kind) => switch (kind) {
        TopProductKind.threeD => AppColors.royalGold,
        TopProductKind.imageOnly => AppColors.focusRing,
        TopProductKind.unknown => AppColors.disabled,
      };

  @override
  Widget build(BuildContext context) {
    final total = topProducts.totalViews;
    final textTheme = Theme.of(context).textTheme;

    return AnalyticsSectionCard(
      key: const ValueKey('analytics_split'),
      title: '3D vs image-only',
      section: AnalyticsSection.split,
      subtitle: 'Where the product views went',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (total == 0)
            Text(
              'No product views in this range yet.',
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            )
          else ...[
            // Flex weights, not pixel widths — the bar is as wide as it is
            // given and the slices stay proportional at every size.
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.xs),
              child: SizedBox(
                height: 10,
                child: Row(
                  children: [
                    for (final kind in _order)
                      if (topProducts.totalsFor(kind).views > 0)
                        Expanded(
                          flex: topProducts.totalsFor(kind).views,
                          child: ColoredBox(color: _colorFor(kind)),
                        ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            for (final kind in _order)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: _SplitLegendRow(
                  kind: kind,
                  color: _colorFor(kind),
                  totals: topProducts.totalsFor(kind),
                  total: total,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _SplitLegendRow extends StatelessWidget {
  const _SplitLegendRow({
    required this.kind,
    required this.color,
    required this.totals,
    required this.total,
  });

  final TopProductKind kind;
  final Color color;
  final TopProductTotals totals;
  final int total;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final percent = total == 0 ? 0 : (totals.views * 100 / total).round();

    return Row(
      key: ValueKey('analytics_split_${kind.name}'),
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            kind.label,
            style:
                textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
        ),
        Tooltip(
          message: '${analyticsExact(context, totals.views)} views',
          child: Text(
            '$percent% · ${analyticsCompact(context, totals.views)}',
            style: textTheme.bodyMedium?.copyWith(color: AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
}

// ── Empty and loading ───────────────────────────────────────────────────────

/// A window in which nothing happened.
///
/// NOT AN ERROR, and it sits UNDER the zeroed tiles rather than replacing them:
/// zero views is a fact about this range, and a business that just printed its
/// QR needs the next step, not an apology.
class _NoDataYet extends StatelessWidget {
  const _NoDataYet();

  @override
  Widget build(BuildContext context) => CatalogMessage(
        key: const ValueKey('analytics_empty'),
        icon: Icons.qr_code_2,
        title: 'No scans yet',
        body: 'Nobody has opened your catalog in this range. Share your QR '
            'code or your link, then check back.',
        actionLabel: 'Open QR code',
        onAction: () => context.pushNamed(AppRouteNames.catalogQr),
        fillsViewport: false,
      );
}

/// Skeletons, not a spinner.
///
/// The dashboard's shape is stable and known before its numbers are, so showing
/// that shape keeps the tiles from jumping into place — and a spinner on a
/// screen with five tiles and a chart tells the user nothing about what is
/// coming.
class _AnalyticsSkeleton extends StatelessWidget {
  const _AnalyticsSkeleton({this.embedded = false});

  /// Whether it is already inside the dashboard's scroll view (below the range
  /// control) or standing in for the whole screen.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      key: const ValueKey('analytics_loading'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns = width >= 560 ? 3 : 2;
            const gap = AppSpacing.sm;
            final itemWidth = (width - gap * (columns - 1)) / columns;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SkeletonBox(height: 140),
                const SizedBox(height: gap),
                Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (var i = 0; i < 6; i++)
                      SizedBox(
                        width: itemWidth,
                        child: const _SkeletonBox(height: 96),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        const _SkeletonBox(height: 220),
        const SizedBox(height: AppSpacing.lg),
        const _SkeletonBox(height: 180),
        const SizedBox(height: AppSpacing.lg),
        const _SkeletonBox(height: 180),
      ],
    );

    if (embedded) return body;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: body,
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: AppColors.disabled.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      );
}
