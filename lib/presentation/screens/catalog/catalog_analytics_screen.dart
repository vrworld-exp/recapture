// lib/presentation/screens/catalog/catalog_analytics_screen.dart
//
// `/catalog/analytics` — what happened after publish (feature 66, surfacing
// 61-65).
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
        title: Text('Analytics', style: Theme.of(context).textTheme.titleLarge),
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
            error: (_, __) => _FailureBody(state: state, onRetry: notifier.refresh),
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
    final kpis = report.summary.kpis;
    final previous = report.summary.previousKpis;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RangeCaption(window: report.summary.window, range: range),
        const SizedBox(height: AppSpacing.md),
        _TileGrid(
          tiles: [
            _TileData(
              id: 'page_views',
              label: 'Catalog views',
              value: kpis.pageViews,
              previous: previous?.pageViews,
            ),
            _TileData(
              id: 'visitors',
              label: 'Unique visitors',
              value: kpis.visitors,
              previous: previous?.visitors,
            ),
            _TileData(
              id: 'product_views',
              label: 'Product views',
              value: kpis.productViews,
              previous: previous?.productViews,
            ),
            _TileData(
              id: 'model_loads',
              label: '3D model loads',
              value: report.topProducts.totalModelLoads,
              // NO DELTA, deliberately. `modelLoads` exists per top-product row
              // and nowhere else — there is no previous-window figure, and
              // fetching the prior range to invent one would double every load
              // of this screen for a single arrow.
              previous: null,
            ),
            _TileData(
              id: 'ar_views',
              label: 'AR launches',
              value: kpis.arViews,
              previous: previous?.arViews,
            ),
          ],
        ),
        if (report.isEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          const _NoDataYet(),
        ] else ...[
          const SizedBox(height: AppSpacing.lg),
          _ChartCard(points: report.timeseries.points),
          const SizedBox(height: AppSpacing.lg),
          _SplitCard(topProducts: report.topProducts),
          const SizedBox(height: AppSpacing.lg),
          _TopProductsCard(topProducts: report.topProducts),
        ],
      ],
    );
  }
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

/// 7 / 30 / 90 and a custom window.
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
    AnalyticsRangePreset.last30,
    AnalyticsRangePreset.last90,
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

// ── Tiles ───────────────────────────────────────────────────────────────────

class _TileData {
  const _TileData({
    required this.id,
    required this.label,
    required this.value,
    required this.previous,
  });

  final String id;
  final String label;
  final int value;

  /// The same counter in the preceding window, or null where there is no
  /// comparison to draw. Null is NOT zero — see [analyticsDelta].
  final int? previous;
}

/// The KPI row, wrapping into as many columns as the width affords.
///
/// The column count is derived from `LayoutBuilder`, which is what makes a
/// narrowed browser window behave like a phone rather than like a squeezed
/// desktop.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.tiles});

  final List<_TileData> tiles;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final columns = width >= 1000
              ? 5
              : width >= 720
                  ? 3
                  : 2;
          const gap = AppSpacing.sm;
          final itemWidth = (width - gap * (columns - 1)) / columns;

          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final tile in tiles)
                SizedBox(
                  width: itemWidth,
                  child: _KpiTile(tile: tile),
                ),
            ],
          );
        },
      );
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

    return AppCard(
      key: ValueKey('analytics_tile_${tile.id}'),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Semantics(
        // The EXACT number reaches a screen reader even when the tile shows
        // "1.2k" — the abbreviation is a visual accommodation, not a redaction.
        label: '${tile.label}: $exact'
            '${delta == null ? '' : ', ${analyticsDeltaLabel(delta)} '
                'versus the previous period'}',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tile.label,
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              maxLines: 2,
            ),
            const SizedBox(height: AppSpacing.xs),
            // The tooltip is where the abbreviation is paid back — on web by
            // hover, on a phone by long-press, both built in.
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
            if (delta != null) ...[
              const SizedBox(height: AppSpacing.xs),
              _DeltaChip(delta: delta),
            ],
          ],
        ),
      ),
    );
  }
}

class _DeltaChip extends StatelessWidget {
  const _DeltaChip({required this.delta});

  final double delta;

  @override
  Widget build(BuildContext context) {
    final rising = delta > 0;
    final flat = delta == 0;
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

  @override
  Widget build(BuildContext context) => AppCard(
        key: const ValueKey('analytics_chart_card'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Day by day',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
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
            if (widget.points.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Text(
                  'No day-by-day data for this range.',
                  key: const ValueKey('analytics_chart_empty'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              )
            else
              AnalyticsChart(
                key: const ValueKey('analytics_chart'),
                points: widget.points,
                series: _series,
              ),
          ],
        ),
      );
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

    return AppCard(
      key: const ValueKey('analytics_split'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('3D vs image-only', style: textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
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
            style: textTheme.bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
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

// ── Top products ────────────────────────────────────────────────────────────

class _TopProductsCard extends StatelessWidget {
  const _TopProductsCard({required this.topProducts});

  final TopProducts topProducts;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      key: const ValueKey('analytics_top_products'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Most viewed', style: textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          if (topProducts.isEmpty)
            Text(
              'No product views in this range yet.',
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            )
          else
            for (var i = 0; i < topProducts.rows.length; i++)
              _TopProductRow(rank: i + 1, row: topProducts.rows[i]),
        ],
      ),
    );
  }
}

class _TopProductRow extends StatelessWidget {
  const _TopProductRow({required this.rank, required this.row});

  final int rank;
  final TopProduct row;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$rank',
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        row.name,
                        style: textTheme.bodyMedium
                            ?.copyWith(color: AppColors.textPrimary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _KindBadge(kind: row.kind),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitle(context),
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Tooltip(
            message: '${analyticsExact(context, row.views)} views',
            child: Text(
              analyticsCompact(context, row.views),
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (!row.isLinkable) return content;

    // An `InkWell` rather than a `GestureDetector`: it is in the traversal
    // order, so Tab reaches it and Enter opens the product — the keyboard pass
    // this screen owes on web.
    return InkWell(
      key: ValueKey('analytics_row_${row.productId}'),
      onTap: () => context.pushNamed(
        AppRouteNames.productDetail,
        pathParameters: {'productId': row.catalogProductId!},
      ),
      child: content,
    );
  }

  /// The second line: AR launches, 3D loads, and — for an unmatched row — the
  /// Mirage id, which is the only identity it has left.
  String _subtitle(BuildContext context) {
    final parts = <String>[
      if (row.arViews > 0) '${analyticsExact(context, row.arViews)} AR',
      if (row.modelLoads > 0)
        '${analyticsExact(context, row.modelLoads)} 3D loads',
    ];
    if (row.kind == TopProductKind.unknown) {
      // No longer in this catalog — deleted, or never ours. The views are real
      // and stay counted; the id is what lets a business tell two of these
      // apart.
      parts.add('No longer in your catalog · ${row.productId}');
    }
    return parts.isEmpty ? 'No AR or 3D activity' : parts.join(' · ');
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final TopProductKind kind;

  @override
  Widget build(BuildContext context) {
    final color = switch (kind) {
      TopProductKind.threeD => AppColors.royalGold,
      TopProductKind.imageOnly => AppColors.focusRing,
      TopProductKind.unknown => AppColors.textMuted,
    };

    return Container(
      key: ValueKey('analytics_badge_${kind.name}'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        kind.label,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: color, fontSize: 11),
      ),
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
            final columns = width >= 1000
                ? 5
                : width >= 720
                    ? 3
                    : 2;
            const gap = AppSpacing.sm;
            final itemWidth = (width - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < 5; i++)
                  SizedBox(width: itemWidth, child: const _SkeletonBox(height: 84)),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        const _SkeletonBox(height: 220),
        const SizedBox(height: AppSpacing.lg),
        const _SkeletonBox(height: 140),
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
