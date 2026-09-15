// lib/presentation/widgets/catalog/analytics_panels.dart
//
// The dashboard's panels below the KPI row — the funnel, the leaderboards,
// the health check, the device split and the footer.
//
// EVERY PANEL READS THE SAME WINDOW. All of them are drawn from the ONE
// summary the notifier fetched for the selected range, which is what lets a
// reader put any two cards side by side. None of them fetches anything, none
// of them holds state that outlives a range switch except "which column am I
// sorted by" and "is the full list open" — both of which are legitimately the
// reader's, not the data's.
//
// FIVE ROWS, THEN MORE. Every leaderboard shows its top five and a "More (N)"
// that expands the rest in place. Five is what fits under a thumb; expanding
// in place rather than in a popup keeps the rest of the dashboard in view for
// the comparison the reader was in the middle of making.
//
// LAYOUT COMES FROM CONSTRAINTS, NEVER FROM `kIsWeb`. Tables give the name
// column whatever is left after the number columns, and a narrow window gets
// the narrow layout because it is narrow.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/entities/catalog_analytics.dart';
import '../app_card.dart';
import 'analytics_format.dart';
import 'analytics_section_info.dart';

/// How many rows a leaderboard shows before "More".
const int kAnalyticsVisibleRows = 5;

// ── Shared frame ────────────────────────────────────────────────────────────

/// A titled card with its (i), an optional subtitle and an optional trailing
/// control. Every panel below uses it, so every panel reads the same way.
class AnalyticsSectionCard extends StatelessWidget {
  const AnalyticsSectionCard({
    super.key,
    required this.title,
    required this.section,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final AnalyticsSection section;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(title, style: textTheme.titleMedium),
                        ),
                        AnalyticsInfoHint(section: section),
                      ],
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: textTheme.bodySmall
                            ?.copyWith(color: AppColors.textMuted),
                      ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }
}

/// The one-line "nothing here" a panel shows for a quiet range. Not an
/// error: zero is a fact about the window.
class _PanelEmpty extends StatelessWidget {
  const _PanelEmpty({required this.title, this.body});

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.lg,
        horizontal: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: AppColors.disabled.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: Column(
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style:
                textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
          if (body != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              body!,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// "More (7)" / "Show less" under a truncated list.
class _MoreButton extends StatelessWidget {
  const _MoreButton({
    super.key,
    required this.total,
    required this.expanded,
    required this.onPressed,
  });

  final int total;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: onPressed,
          child: Text(expanded ? 'Show less' : 'More ($total)'),
        ),
      );
}

/// A table that scrolls sideways rather than squeezing its name column to
/// nothing.
///
/// Below [minWidth] the table keeps that width and the CARD scrolls it — the
/// same answer Mirage gives (its tables carry a min-width and scroll). The
/// alternative, shrinking the number columns until the name is three
/// characters and an ellipsis, makes the leaderboard unreadable at exactly
/// the width most of its readers hold.
class _ScrollX extends StatelessWidget {
  const _ScrollX({required this.minWidth, required this.child});

  final double minWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= minWidth) return child;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: minWidth, child: child),
          );
        },
      );
}

/// A row's number, right-aligned, with the exact value in a tooltip.
class _Figure extends StatelessWidget {
  const _Figure(this.value, {this.width = 56, this.emphasis = false});

  final int value;
  final double width;
  final bool emphasis;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: Tooltip(
          message: analyticsExact(context, value),
          child: Text(
            analyticsCompact(context, value),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: emphasis
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontWeight: emphasis ? FontWeight.w600 : FontWeight.w400,
                ),
          ),
        ),
      );
}

/// A column heading, optionally a sort control.
class _Heading extends StatelessWidget {
  const _Heading(
    this.label, {
    this.width,
    this.align = TextAlign.right,
    this.sorted = false,
    this.onSort,
  });

  final String label;
  final double? width;
  final TextAlign align;
  final bool sorted;
  final VoidCallback? onSort;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: sorted ? AppColors.textPrimary : AppColors.textMuted,
          fontWeight: FontWeight.w600,
        );
    final text = Text(
      sorted ? '$label ▼' : label,
      textAlign: align,
      style: style,
      overflow: TextOverflow.ellipsis,
    );
    final child = onSort == null
        ? text
        : InkWell(
            onTap: onSort,
            child: Semantics(
              button: true,
              selected: sorted,
              label: 'Sort by $label',
              child: text,
            ),
          );
    return width == null
        ? Expanded(child: child)
        : SizedBox(width: width, child: child);
  }
}

// ── Conversion funnel ───────────────────────────────────────────────────────

/// Four stages, each bar drawn against the TOP of the funnel, each caption
/// the share of the stage directly above it.
class AnalyticsFunnelCard extends StatelessWidget {
  const AnalyticsFunnelCard({super.key, required this.stages});

  final List<FunnelStage> stages;

  @override
  Widget build(BuildContext context) {
    final top = stages.isEmpty ? 0 : stages.first.count;
    final textTheme = Theme.of(context).textTheme;

    return AnalyticsSectionCard(
      key: const ValueKey('analytics_funnel'),
      title: 'Conversion funnel',
      section: AnalyticsSection.funnel,
      subtitle: 'Share of the previous step reaching each stage',
      child: top == 0
          ? const _PanelEmpty(title: 'No catalog opens in this range.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < stages.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: _FunnelRow(
                      stage: stages[i],
                      previous: i == 0 ? null : stages[i - 1],
                      top: top,
                    ),
                  ),
                Text(
                  'Bar length is each stage against the top of the funnel.',
                  style:
                      textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
    );
  }
}

class _FunnelRow extends StatelessWidget {
  const _FunnelRow({
    required this.stage,
    required this.previous,
    required this.top,
  });

  final FunnelStage stage;
  final FunnelStage? previous;
  final int top;

  /// "28% of previous", or null on the first stage and after a zero stage —
  /// a share of nothing is not 0%, it is undefined.
  String? get _conversion {
    final prev = previous;
    if (prev == null || prev.count == 0) return null;
    final pct = stage.count / prev.count * 100;
    // Whole percent from 10 up; one decimal below it, where "2.5%" and "3%"
    // are different pieces of information about a small funnel.
    final text = pct >= 10 ? pct.round().toString() : analyticsRate(pct);
    return '$text% of previous';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final share = top == 0 ? 0.0 : (stage.count / top).clamp(0.0, 1.0);
    final conversion = _conversion;

    return Column(
      key: ValueKey('analytics_funnel_${stage.key}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                stage.label,
                style: textTheme.bodyMedium
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            ),
            if (conversion != null) ...[
              Text(
                conversion,
                style:
                    textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            _Figure(stage.count, width: 48, emphasis: true),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                // Flex weights, so the bar is proportional at every width.
                // A stage above the top (six products opened in one visit)
                // is clamped rather than overflowing the card.
                Expanded(
                  flex: (share * 1000)
                      .round()
                      .clamp(stage.count > 0 ? 8 : 0, 1000),
                  child: const ColoredBox(color: AppColors.royalGold),
                ),
                Expanded(
                  flex: 1000 -
                      (share * 1000)
                          .round()
                          .clamp(stage.count > 0 ? 8 : 0, 1000),
                  child: ColoredBox(
                      color: AppColors.disabled.withValues(alpha: 0.25)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Categories opened ───────────────────────────────────────────────────────

class AnalyticsCategoriesCard extends StatefulWidget {
  const AnalyticsCategoriesCard({super.key, required this.rows});

  final List<CategoryOpens> rows;

  @override
  State<AnalyticsCategoriesCard> createState() =>
      _AnalyticsCategoriesCardState();
}

class _AnalyticsCategoriesCardState extends State<AnalyticsCategoriesCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final visible =
        _expanded ? rows : rows.take(kAnalyticsVisibleRows).toList();
    final max = rows.fold<int>(1, (m, r) => r.opens > m ? r.opens : m);
    final textTheme = Theme.of(context).textTheme;

    return AnalyticsSectionCard(
      key: const ValueKey('analytics_categories'),
      title: 'Categories opened',
      section: AnalyticsSection.categories,
      subtitle: 'Top $kAnalyticsVisibleRows by opens',
      child: rows.isEmpty
          ? const _PanelEmpty(
              title: 'No category opens in this range.',
              body:
                  'Visitors stayed on the default view or arrived by direct link.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in visible)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Column(
                      key: ValueKey('analytics_category_${row.name}'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                row.displayName,
                                style: textTheme.bodyMedium
                                    ?.copyWith(color: AppColors.textPrimary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Tooltip(
                              message:
                                  '${analyticsExact(context, row.sessions)} sessions',
                              child:
                                  _Figure(row.opens, width: 48, emphasis: true),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                          child: SizedBox(
                            height: 4,
                            child: Row(
                              children: [
                                Expanded(
                                  flex: (row.opens * 1000 / max)
                                      .round()
                                      .clamp(8, 1000),
                                  child: const ColoredBox(
                                      color: AppColors.focusRing),
                                ),
                                Expanded(
                                  flex: 1000 -
                                      (row.opens * 1000 / max)
                                          .round()
                                          .clamp(8, 1000),
                                  child: const SizedBox.shrink(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (rows.length > kAnalyticsVisibleRows)
                  _MoreButton(
                    key: const ValueKey('analytics_categories_more'),
                    total: rows.length,
                    expanded: _expanded,
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
              ],
            ),
    );
  }
}

// ── Searches ────────────────────────────────────────────────────────────────

class AnalyticsSearchesCard extends StatefulWidget {
  const AnalyticsSearchesCard(
      {super.key, required this.rows, required this.total});

  final List<SearchQuery> rows;

  /// The summary's `searches` counter — every search, not just the top 20.
  final int total;

  @override
  State<AnalyticsSearchesCard> createState() => _AnalyticsSearchesCardState();
}

class _AnalyticsSearchesCardState extends State<AnalyticsSearchesCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final visible =
        _expanded ? rows : rows.take(kAnalyticsVisibleRows).toList();
    final textTheme = Theme.of(context).textTheme;
    final emptyQueries = rows.where((r) => r.zeroResults > 0).length;

    return AnalyticsSectionCard(
      key: const ValueKey('analytics_searches'),
      title: 'Searches',
      section: AnalyticsSection.searches,
      subtitle: 'What visitors typed into the search box',
      child: rows.isEmpty
          ? const _PanelEmpty(
              title: 'No searches in this range.',
              body: 'A query is recorded once the typing settles and it is at '
                  'least two characters long. An empty list means visitors '
                  'browsed rather than searched.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    _Heading('Query', align: TextAlign.left),
                    _Heading('Searches', width: 64),
                    _Heading('Found', width: 52),
                    _Heading('Empty', width: 52),
                  ],
                ),
                const Divider(height: AppSpacing.md),
                for (final row in visible)
                  Padding(
                    key: ValueKey('analytics_search_${row.query}'),
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.query,
                            style: textTheme.bodyMedium
                                ?.copyWith(color: AppColors.textPrimary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Tooltip(
                          message:
                              'in ${analyticsExact(context, row.sessions)} sessions',
                          child:
                              _Figure(row.searches, width: 64, emphasis: true),
                        ),
                        SizedBox(
                          width: 52,
                          child: Text(
                            row.avgResults.toStringAsFixed(1),
                            textAlign: TextAlign.right,
                            style: textTheme.bodyMedium
                                ?.copyWith(color: AppColors.textSecondary),
                          ),
                        ),
                        SizedBox(
                          width: 52,
                          child: Tooltip(
                            message: row.zeroResults > 0
                                ? '${row.zeroResults} of these searches matched no product'
                                : 'Every search matched something',
                            child: Text(
                              analyticsExact(context, row.zeroResults),
                              textAlign: TextAlign.right,
                              style: textTheme.bodyMedium?.copyWith(
                                color: row.zeroResults > 0
                                    ? AppColors.warning
                                    : AppColors.textMuted,
                                fontWeight: row.zeroResults > 0
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (rows.length > kAnalyticsVisibleRows)
                  _MoreButton(
                    key: const ValueKey('analytics_searches_more'),
                    total: rows.length,
                    expanded: _expanded,
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${analyticsExact(context, widget.total)} searches in range'
                  '${emptyQueries > 0 ? ' · $emptyQueries quer${emptyQueries == 1 ? 'y' : 'ies'} found nothing' : ''}',
                  style:
                      textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
    );
  }
}

// ── 3D & AR health ──────────────────────────────────────────────────────────

/// Above this share of failed loads the figure turns red.
const double kFailureRateAlarmPct = 5;

String analyticsMillis(int ms) =>
    ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)}s' : '${ms}ms';

class AnalyticsModelHealthCard extends StatelessWidget {
  const AnalyticsModelHealthCard({
    super.key,
    required this.health,
    required this.arViews,
    required this.arSessions,
  });

  final ModelHealth health;
  final int arViews;
  final int arSessions;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Share of AR taps that became a real session. Null rather than 0% when
    // nobody tapped — the two must not read alike.
    final arEntryRate = arViews > 0 ? arSessions / arViews * 100 : null;
    final rate = health.failureRate;
    final alarmed = rate != null && rate >= kFailureRateAlarmPct;
    final nothing = health.attempts == 0 && arViews == 0;

    final figures = [
      _HealthFigure(
        id: 'ar_entered',
        label: 'AR entered',
        value: arSessions,
        hint: arEntryRate == null
            ? 'No AR taps in this range'
            : '${analyticsRate(arEntryRate)}% of '
                '${analyticsExact(context, arViews)} AR taps',
      ),
      _HealthFigure(
        id: 'models_loaded',
        label: 'Models loaded',
        value: health.loads,
        hint: health.samples > 0
            ? '${analyticsMillis(health.avgLoadMs)} average over ${analyticsExact(context, health.samples)} timed'
            : 'No timed loads',
      ),
      _HealthFigure(
        id: 'load_failures',
        label: 'Load failures',
        value: health.failures,
        hint: rate == null
            ? 'No loads attempted'
            : '${analyticsRate(rate)}% of attempted loads',
        color: alarmed ? AppColors.error : null,
      ),
      _HealthFigure(
        id: 'slow_loads',
        label: 'Slow loads',
        value: health.slowLoads,
        hint: 'Over ${analyticsMillis(health.slowThresholdMs)} to appear',
        color: health.slowLoads > 0 ? AppColors.warning : null,
      ),
    ];

    return AnalyticsSectionCard(
      key: const ValueKey('analytics_health'),
      title: '3D & AR health',
      section: AnalyticsSection.modelHealth,
      subtitle: 'Whether the models load and AR actually starts',
      child: nothing
          ? const _PanelEmpty(
              title: 'No 3D or AR activity in this range.',
              body: 'Model loads and AR sessions are counted as visitors open '
                  '3D products on the public page.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Two by two at every width. NOT a LayoutBuilder: this card
                // sits inside the dashboard's `_Pair`, whose IntrinsicHeight
                // asks its children for intrinsic dimensions, and a
                // LayoutBuilder throws when asked. Two rows of two also reads
                // fine in a half-width card, which is where this lives on a
                // wide window anyway.
                for (var i = 0; i < figures.length; i += 2)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i + 2 < figures.length ? AppSpacing.md : 0,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: figures[i]),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: i + 1 < figures.length
                              ? figures[i + 1]
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                if (health.topFailures.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    'Why they failed',
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  for (final reason in health.topFailures)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              reason.label,
                              style: textTheme.bodyMedium
                                  ?.copyWith(color: AppColors.textSecondary),
                            ),
                          ),
                          _Figure(reason.count, width: 48),
                        ],
                      ),
                    ),
                ],
                if (health.failingProducts.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Models to fix first',
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  for (final product in health.failingProducts)
                    _FailingProductRow(product: product),
                ],
              ],
            ),
    );
  }
}

class _HealthFigure extends StatelessWidget {
  const _HealthFigure({
    required this.id,
    required this.label,
    required this.value,
    required this.hint,
    this.color,
  });

  final String id;
  final String label;
  final int value;
  final String hint;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: '$label: ${analyticsExact(context, value)}. $hint',
      excludeSemantics: true,
      child: Column(
        key: ValueKey('analytics_health_$id'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted)),
          const SizedBox(height: 2),
          Tooltip(
            message: analyticsExact(context, value),
            child: Text(
              analyticsCompact(context, value),
              key: ValueKey('analytics_health_value_$id'),
              style: textTheme.titleLarge?.copyWith(
                color: color ?? AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(hint,
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

class _FailingProductRow extends StatelessWidget {
  const _FailingProductRow({required this.product});

  final FailingProduct product;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              product.displayName,
              style:
                  textTheme.bodyMedium?.copyWith(color: AppColors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              analyticsExact(context, product.failures),
              textAlign: TextAlign.right,
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (!product.isLinkable) return row;
    return InkWell(
      key: ValueKey('analytics_failing_${product.productId}'),
      onTap: () => context.pushNamed(
        AppRouteNames.productDetail,
        pathParameters: {'productId': product.catalogProductId!},
      ),
      child: row,
    );
  }
}

// ── Top products ────────────────────────────────────────────────────────────

/// Which column the leaderboard is ranked by.
enum TopProductSort { views, arViews, sessions }

extension TopProductSortX on TopProductSort {
  String get label => switch (this) {
        TopProductSort.views => 'Views',
        TopProductSort.arViews => 'AR views',
        TopProductSort.sessions => 'Sessions',
      };

  int valueOf(TopProduct row) => switch (this) {
        TopProductSort.views => row.views,
        TopProductSort.arViews => row.arViews,
        TopProductSort.sessions => row.sessions,
      };
}

/// The product leaderboard, sortable, five rows then More.
///
/// Re-sorting re-picks WHICH five surface, not just their order — a product
/// with few views but every one of them launched in AR is exactly the row a
/// business wants to find by sorting on AR.
class AnalyticsTopProductsCard extends StatefulWidget {
  const AnalyticsTopProductsCard({super.key, required this.topProducts});

  final TopProducts topProducts;

  @override
  State<AnalyticsTopProductsCard> createState() =>
      _AnalyticsTopProductsCardState();
}

class _AnalyticsTopProductsCardState extends State<AnalyticsTopProductsCard> {
  TopProductSort _sort = TopProductSort.views;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.topProducts.rows]
      ..sort((a, b) => _sort.valueOf(b).compareTo(_sort.valueOf(a)));
    final visible =
        _expanded ? sorted : sorted.take(kAnalyticsVisibleRows).toList();

    return AnalyticsSectionCard(
      key: const ValueKey('analytics_top_products'),
      title: 'Top products',
      section: AnalyticsSection.products,
      subtitle: 'Ranked by the selected column',
      child: sorted.isEmpty
          ? const _PanelEmpty(title: 'No product views in this range yet.')
          : _ScrollX(
              minWidth: 480,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const _Heading('Product', align: TextAlign.left),
                      for (final sort in TopProductSort.values)
                        _Heading(
                          sort.label,
                          width: sort == TopProductSort.arViews ? 64 : 60,
                          sorted: _sort == sort,
                          onSort: () => setState(() => _sort = sort),
                        ),
                      const _Heading('AR rate', width: 56),
                    ],
                  ),
                  const Divider(height: AppSpacing.md),
                  for (final row in visible)
                    _TopProductRow(row: row, sort: _sort),
                  if (sorted.length > kAnalyticsVisibleRows)
                    _MoreButton(
                      key: const ValueKey('analytics_top_products_more'),
                      total: sorted.length,
                      expanded: _expanded,
                      onPressed: () => setState(() => _expanded = !_expanded),
                    ),
                ],
              ),
            ),
    );
  }
}

class _TopProductRow extends StatelessWidget {
  const _TopProductRow({required this.row, required this.sort});

  final TopProduct row;
  final TopProductSort sort;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final arRate =
        row.views > 0 ? (row.arViews / row.views * 100).round() : null;

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        row.displayName,
                        style: textTheme.bodyMedium
                            ?.copyWith(color: AppColors.textPrimary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    TopProductKindBadge(kind: row.kind),
                  ],
                ),
                if (row.kind == TopProductKind.unknown)
                  // No longer in this catalog — deleted, or never ours. The
                  // views are real and stay counted; the id is what lets a
                  // business tell two of these apart.
                  Text(
                    'No longer in your catalog · ${row.productId}',
                    style: textTheme.bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          for (final column in TopProductSort.values)
            _Figure(
              column.valueOf(row),
              width: column == TopProductSort.arViews ? 64 : 60,
              emphasis: column == sort,
            ),
          SizedBox(
            width: 56,
            child: Text(
              arRate == null ? '—' : '$arRate%',
              textAlign: TextAlign.right,
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );

    if (!row.isLinkable) return content;

    // An `InkWell` rather than a `GestureDetector`: it is in the traversal
    // order, so Tab reaches it and Enter opens the product — the keyboard
    // pass this screen owes on web.
    return InkWell(
      key: ValueKey('analytics_row_${row.productId}'),
      onTap: () => context.pushNamed(
        AppRouteNames.productDetail,
        pathParameters: {'productId': row.catalogProductId!},
      ),
      child: content,
    );
  }
}

class TopProductKindBadge extends StatelessWidget {
  const TopProductKindBadge({super.key, required this.kind});

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
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 1),
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

// ── Zoomed items ────────────────────────────────────────────────────────────

class AnalyticsZoomedCard extends StatefulWidget {
  const AnalyticsZoomedCard({super.key, required this.rows});

  final List<ZoomedItem> rows;

  @override
  State<AnalyticsZoomedCard> createState() => _AnalyticsZoomedCardState();
}

class _AnalyticsZoomedCardState extends State<AnalyticsZoomedCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final visible =
        _expanded ? rows : rows.take(kAnalyticsVisibleRows).toList();
    final textTheme = Theme.of(context).textTheme;

    return AnalyticsSectionCard(
      key: const ValueKey('analytics_zoomed'),
      title: 'Zoomed items',
      section: AnalyticsSection.zoomed,
      subtitle: 'Models visitors zoomed into — top $kAnalyticsVisibleRows',
      child: rows.isEmpty
          ? const _PanelEmpty(
              title: 'No zooms in this range.',
              body: 'Counted only for products with a 3D model, and only after '
                  'three pinch gestures on one model.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    _Heading('Item', align: TextAlign.left),
                    _Heading('Zooms', width: 56),
                    _Heading('Sessions', width: 64),
                  ],
                ),
                const Divider(height: AppSpacing.md),
                for (final row in visible)
                  _LinkableRow(
                    key: ValueKey('analytics_zoom_${row.productId}'),
                    catalogProductId:
                        row.isLinkable ? row.catalogProductId : null,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              row.displayName,
                              style: textTheme.bodyMedium
                                  ?.copyWith(color: AppColors.textPrimary),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          _Figure(row.zooms, width: 56, emphasis: true),
                          _Figure(row.sessions, width: 64),
                        ],
                      ),
                    ),
                  ),
                if (rows.length > kAnalyticsVisibleRows)
                  _MoreButton(
                    key: const ValueKey('analytics_zoomed_more'),
                    total: rows.length,
                    expanded: _expanded,
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
              ],
            ),
    );
  }
}

/// A row that opens the product editor when it still maps to one of ours.
class _LinkableRow extends StatelessWidget {
  const _LinkableRow(
      {super.key, required this.catalogProductId, required this.child});

  final String? catalogProductId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final id = catalogProductId;
    if (id == null) return child;
    return InkWell(
      onTap: () => context.pushNamed(
        AppRouteNames.productDetail,
        pathParameters: {'productId': id},
      ),
      child: child,
    );
  }
}

// ── Devices ─────────────────────────────────────────────────────────────────

class AnalyticsDevicesCard extends StatelessWidget {
  const AnalyticsDevicesCard({super.key, required this.rows});

  final List<DeviceShare> rows;

  @override
  Widget build(BuildContext context) {
    final total = rows.fold<int>(0, (sum, r) => sum + r.sessions);
    final textTheme = Theme.of(context).textTheme;

    return AnalyticsSectionCard(
      key: const ValueKey('analytics_devices'),
      title: 'Devices',
      section: AnalyticsSection.devices,
      subtitle: 'Sessions by device type',
      child: total == 0
          ? const _PanelEmpty(title: 'No sessions in this range.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  child: SizedBox(
                    height: 10,
                    child: Row(
                      children: [
                        for (final row in rows)
                          if (row.sessions > 0)
                            Expanded(
                              flex: row.sessions,
                              child: ColoredBox(color: _colorFor(row.type)),
                            ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Row(
                      key: ValueKey('analytics_device_${row.type}'),
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: _colorFor(row.type),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            row.label,
                            style: textTheme.bodyMedium
                                ?.copyWith(color: AppColors.textSecondary),
                          ),
                        ),
                        _Figure(row.sessions, width: 48),
                        SizedBox(
                          width: 44,
                          child: Text(
                            '${(row.sessions * 100 / total).round()}%',
                            textAlign: TextAlign.right,
                            style: textTheme.bodyMedium?.copyWith(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  static Color _colorFor(String type) => switch (type.toLowerCase()) {
        'mobile' => AppColors.royalGold,
        'tablet' => AppColors.goldGlow,
        'desktop' => AppColors.focusRing,
        _ => AppColors.disabled,
      };
}

// ── Traffic table ───────────────────────────────────────────────────────────

/// The chart's Table view: one row per UTC day, exact figures.
///
/// Newest first — a reader switching to the table wants today, and the chart
/// already showed them the shape in date order.
class AnalyticsTrafficTable extends StatelessWidget {
  const AnalyticsTrafficTable({super.key, required this.points});

  final List<AnalyticsPoint> points;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final rows = points.reversed.toList();

    return _ScrollX(
      minWidth: 400,
      child: Column(
        key: const ValueKey('analytics_traffic_table'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              _Heading('Day', align: TextAlign.left),
              _Heading('Opens', width: 56),
              _Heading('Products', width: 68),
              _Heading('AR', width: 48),
              _Heading('Sessions', width: 68),
            ],
          ),
          const Divider(height: AppSpacing.md),
          // Bounded, and scrolling inside the card: a 365-day table is not a
          // thing the page should be 365 rows taller for.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final point = rows[index];
                final day = point.day;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          day == null
                              ? point.date
                              : analyticsShortDay(context, day),
                          style: textTheme.bodyMedium
                              ?.copyWith(color: AppColors.textSecondary),
                        ),
                      ),
                      _Figure(point.pageViews, width: 56),
                      _Figure(point.productViews, width: 68),
                      _Figure(point.arViews, width: 48),
                      _Figure(point.sessions, width: 68),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── Footer ──────────────────────────────────────────────────────────────────

/// The provenance line under everything: how many events, on whose clock,
/// with what excluded, and how stale.
class AnalyticsFooter extends StatelessWidget {
  const AnalyticsFooter({super.key, required this.totalEvents});

  final int totalEvents;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: AppColors.textMuted);
    return Wrap(
      key: const ValueKey('analytics_footer'),
      spacing: AppSpacing.lg,
      runSpacing: AppSpacing.xs,
      children: [
        Text('${analyticsExact(context, totalEvents)} events in range',
            style: style),
        Text('Reported on server receive time (UTC)', style: style),
        Text('Bots and uptime pingers excluded at ingest', style: style),
        Text('Cached up to 5 minutes', style: style),
      ],
    );
  }
}
