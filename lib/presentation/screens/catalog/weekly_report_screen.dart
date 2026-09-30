// lib/presentation/screens/catalog/weekly_report_screen.dart
//
// The weekly value report (more-customization Stage 9, Part E):
//   • [WeeklyReportScreen] — `/catalog/reports/:weekStart`, where the Monday
//     notification lands: KPIs with ▲▼ deltas, the 7-day bars, the top three
//     dishes, the busiest-hours heat strip, and the tips as action cards that
//     open the screen that fixes them. "Share as image" renders the summary
//     card to a PNG and hands it to the share sheet / browser download.
//   • [WeeklyReportsScreen] — `/catalog/reports`, the last twelve weeks and the
//     owner's on/off switch.
//
// Both take an optional [repCatalogId]: a rep reads a delegated restaurant's
// reports through the same screens, read-only (no switch, no tip actions —
// fixing the menu is the rep's dish editor's job, not this screen's).
//
// Everything here is a READ of a report the worker already built; nothing is
// computed on the phone except layout, so the notification, this screen and
// the shared image can never tell three different stories.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/catalog_qr_service.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/weekly_report_repository.dart';
import '../../../domain/catalog/weekly_report.dart';
import '../../widgets/app_card.dart';
import '../../widgets/catalog/catalog_message.dart';

const double _kMaxWidth = 720;
const _kWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _count(int n) {
  final s = n.toString();
  if (s.length <= 3) return s;
  // Indian grouping: 1,240 · 12,40,000.
  final last3 = s.substring(s.length - 3);
  var rest = s.substring(0, s.length - 3);
  final parts = <String>[];
  while (rest.length > 2) {
    parts.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) parts.insert(0, rest);
  return '${parts.join(',')},$last3';
}

String _errorText(Object error) =>
    error is CatalogFailure ? error.message : 'Something went wrong. Please try again.';

// ── One report ─────────────────────────────────────────────────────────────

class WeeklyReportScreen extends ConsumerStatefulWidget {
  const WeeklyReportScreen({super.key, required this.weekStart, this.repCatalogId});

  /// `YYYY-MM-DD`, or `latest`.
  final String weekStart;
  final String? repCatalogId;

  @override
  ConsumerState<WeeklyReportScreen> createState() => _WeeklyReportScreenState();
}

class _WeeklyReportScreenState extends ConsumerState<WeeklyReportScreen> {
  final _shareKey = GlobalKey();
  bool _sharing = false;

  Future<void> _share(WeeklyReport report) async {
    final boundary = _shareKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || _sharing) return;
    setState(() => _sharing = true);
    try {
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('no bytes');
      await ref.read(qrDelivererProvider).deliver(QrDownloadFile(
            bytes: data.buffer.asUint8List(),
            fileName: 'menu-week-${report.weekStart}.png',
            mimeType: 'image/png',
          ));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create the image. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _openTip(WeeklyReportTip tip) {
    final productId = tip.productId;
    switch (tip.action) {
      case TipAction.product:
      case TipAction.modelGeneration:
        if (productId != null) {
          context.push(AppRoutes.productDetail.replaceFirst(':productId', productId));
        }
      case TipAction.publish:
        context.push(AppRoutes.catalogPublish);
      case TipAction.addProduct:
        context.push(AppRoutes.productNew);
      case TipAction.qr:
        context.push(AppRoutes.catalogQr);
      case TipAction.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = (widget.weekStart, widget.repCatalogId);
    final async = ref.watch(weeklyReportProvider(key));
    final report = async.valueOrNull;

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(report == null ? 'Weekly report' : 'Week of ${report.label}'),
        actions: [
          if (report != null)
            IconButton(
              tooltip: 'Share as image',
              icon: _sharing
                  ? const SizedBox.square(
                      dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.ios_share),
              onPressed: _sharing ? null : () => _share(report),
            ),
          IconButton(
            tooltip: 'All weeks',
            icon: const Icon(Icons.history),
            onPressed: () => context.push(widget.repCatalogId == null
                ? AppRoutes.catalogReports
                : AppRoutes.repCatalogReports.replaceFirst(':id', widget.repCatalogId!)),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.insights_outlined,
          title: error is CatalogFailure && error.code == 'REPORT_NOT_FOUND'
              ? 'No report for this week'
              : 'Report unavailable',
          body: error is CatalogFailure && error.code == 'REPORT_NOT_FOUND'
              ? 'Reports are made every Monday morning for the week before, once your menu is live.'
              : _errorText(error),
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(weeklyReportProvider(key)),
        ),
        data: (report) => _ReportBody(
          report: report,
          shareKey: _shareKey,
          onTip: widget.repCatalogId == null ? _openTip : null,
        ),
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.report, required this.shareKey, this.onTip});

  final WeeklyReport report;
  final GlobalKey shareKey;
  final void Function(WeeklyReportTip)? onTip;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kMaxWidth),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          children: [
            RepaintBoundary(key: shareKey, child: _SummaryCard(report: report)),
            const SizedBox(height: AppSpacing.lg),
            if (report.tips.isNotEmpty) ...[
              const _SectionTitle('Tips for this week'),
              for (final tip in report.tips) _TipCard(tip: tip, onTap: onTip),
              const SizedBox(height: AppSpacing.lg),
            ],
            const _SectionTitle('Menu views by day'),
            AppCard(child: _DailyBars(values: report.daily)),
            const SizedBox(height: AppSpacing.lg),
            if (report.topDishes.isNotEmpty) ...[
              const _SectionTitle('Top dishes'),
              AppCard(
                child: Column(
                  children: [
                    for (var i = 0; i < report.topDishes.length; i++)
                      _DishRow(rank: i + 1, dish: report.topDishes[i]),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
            const _SectionTitle('Busiest hours'),
            AppCard(child: _HeatStrip(hourly: report.hourly)),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: AppColors.textSecondary, fontWeight: FontWeight.w600),
        ),
      );
}

/// The shareable card — self-contained, opaque, readable with no app around it.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.report});
  final WeeklyReport report;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final top = report.topDishes.isEmpty ? null : report.topDishes.first;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Last week · ${report.label}',
              style: text.labelLarge?.copyWith(color: AppColors.textMuted)),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${_count(report.menuViews)} people saw our menu',
            style: text.headlineSmall
                ?.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
          ),
          if (report.menuViewsDelta != null) ...[
            const SizedBox(height: AppSpacing.xs),
            _Delta(pct: report.menuViewsDelta!, suffix: ' vs previous week'),
          ],
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.md,
            children: [
              _Kpi(label: 'Visitors', value: report.uniqueVisitors, delta: report.visitorsDelta),
              _Kpi(label: 'QR scans', value: report.qrScans),
              _Kpi(label: 'AR views', value: report.arViews, delta: report.arViewsDelta),
            ],
          ),
          if (top != null || report.busiestLabel != null) const SizedBox(height: AppSpacing.lg),
          if (top != null)
            Text('🏆 Top dish: ${top.name} (${_count(top.views)} views)',
                style: text.bodyMedium?.copyWith(color: AppColors.textSecondary)),
          if (report.busiestLabel != null)
            Text('⏰ Busiest: ${report.busiestLabel}',
                style: text.bodyMedium?.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, this.delta});
  final String label;
  final int value;
  final double? delta;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_count(value),
              style: text.titleLarge
                  ?.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w700)),
          Text(label, style: text.bodySmall?.copyWith(color: AppColors.textMuted)),
          if (delta != null) _Delta(pct: delta!),
        ],
      ),
    );
  }
}

class _Delta extends StatelessWidget {
  const _Delta({required this.pct, this.suffix = ''});
  final double pct;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final up = pct >= 0;
    final value = pct.abs() >= 10 ? pct.abs().round().toString() : pct.abs().toStringAsFixed(1);
    return Text(
      '${up ? '▲' : '▼'} $value%$suffix',
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: up ? AppColors.success : AppColors.error, fontWeight: FontWeight.w600),
    );
  }
}

class _TipCard extends StatelessWidget {
  const _TipCard({required this.tip, this.onTap});
  final WeeklyReportTip tip;
  final void Function(WeeklyReportTip)? onTap;

  @override
  Widget build(BuildContext context) {
    final actionable = onTap != null && tip.action != TipAction.none;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        onTap: actionable ? () => onTap!(tip) : null,
        child: Row(
          children: [
            const Text('💡', style: TextStyle(fontSize: 20)),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(tip.text,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textPrimary)),
            ),
            if (actionable) const Icon(Icons.chevron_right, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

class _DailyBars extends StatelessWidget {
  const _DailyBars({required this.values});
  final List<int> values;

  @override
  Widget build(BuildContext context) {
    final days = List.generate(7, (i) => i < values.length ? values[i] : 0);
    final peak = days.fold<int>(0, (a, b) => a > b ? a : b);
    final small = Theme.of(context).textTheme.labelSmall?.copyWith(color: AppColors.textMuted);
    return SizedBox(
      height: 140,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(_count(days[i]), style: small),
                    const SizedBox(height: 4),
                    Container(
                      height: peak == 0 ? 2 : 2 + 90 * days[i] / peak,
                      decoration: BoxDecoration(
                        color: AppColors.royalGold,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(_kWeekdays[i], style: small),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DishRow extends StatelessWidget {
  const _DishRow({required this.rank, required this.dish});
  final int rank;
  final WeeklyReportDish dish;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final thumb = dish.thumbnailUrl;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text('$rank', style: text.titleSmall?.copyWith(color: AppColors.royalGold)),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.square(
              dimension: 44,
              child: thumb == null
                  ? const ColoredBox(
                      color: AppColors.surface2,
                      child: Icon(Icons.restaurant, color: AppColors.textMuted, size: 20))
                  : Image.network(
                      thumb,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const ColoredBox(color: AppColors.surface2),
                    ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(dish.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(color: AppColors.textPrimary)),
          ),
          Text('${_count(dish.views)} views',
              style: text.bodySmall?.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

/// 7 rows × 24 cells; the brighter the cell, the more menu views that hour.
class _HeatStrip extends StatelessWidget {
  const _HeatStrip({required this.hourly});
  final List<List<int>> hourly;

  @override
  Widget build(BuildContext context) {
    final peak = hourly.expand((r) => r).fold<int>(0, (a, b) => a > b ? a : b);
    final small = Theme.of(context).textTheme.labelSmall?.copyWith(color: AppColors.textMuted);
    if (peak == 0) {
      return Text('No menu views to chart yet.', style: small);
    }
    return Column(
      children: [
        for (var d = 0; d < 7; d++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(
              children: [
                SizedBox(width: 32, child: Text(_kWeekdays[d], style: small)),
                for (var h = 0; h < 24; h++)
                  Expanded(
                    child: Container(
                      height: 14,
                      margin: const EdgeInsets.symmetric(horizontal: 0.75),
                      decoration: BoxDecoration(
                        color: hourly[d][h] == 0
                            ? AppColors.surface2
                            : AppColors.mirageRed
                                .withValues(alpha: 0.2 + 0.8 * hourly[d][h] / peak),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Row(
          children: [
            const SizedBox(width: 32),
            Expanded(child: Text('12 am', style: small)),
            Expanded(child: Center(child: Text('12 pm', style: small))),
            Expanded(child: Align(alignment: Alignment.centerRight, child: Text('11 pm', style: small))),
          ],
        ),
      ],
    );
  }
}

// ── History ────────────────────────────────────────────────────────────────

class WeeklyReportsScreen extends ConsumerStatefulWidget {
  const WeeklyReportsScreen({super.key, this.repCatalogId});

  final String? repCatalogId;

  @override
  ConsumerState<WeeklyReportsScreen> createState() => _WeeklyReportsScreenState();
}

class _WeeklyReportsScreenState extends ConsumerState<WeeklyReportsScreen> {
  bool _saving = false;

  Future<void> _toggle(bool enabled) async {
    setState(() => _saving = true);
    try {
      await ref.read(weeklyReportRepositoryProvider).setWeeklyEnabled(enabled);
      ref.invalidate(weeklyReportHistoryProvider(null));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_errorText(error))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _open(String weekStart) {
    final rep = widget.repCatalogId;
    context.push(rep == null
        ? AppRoutes.catalogReport.replaceFirst(':weekStart', weekStart)
        : AppRoutes.repCatalogReport
            .replaceFirst(':id', rep)
            .replaceFirst(':weekStart', weekStart));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(weeklyReportHistoryProvider(widget.repCatalogId));
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Weekly reports'),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => CatalogMessage(
          icon: Icons.insights_outlined,
          title: 'Reports unavailable',
          body: _errorText(error),
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(weeklyReportHistoryProvider(widget.repCatalogId)),
        ),
        data: (history) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kMaxWidth),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              children: [
                if (history.weeklyEnabled != null)
                  AppCard(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Monday report'),
                      subtitle: const Text(
                          'Every Monday morning: last week\'s menu views, top dishes and tips.'),
                      value: history.weeklyEnabled!,
                      onChanged: _saving ? null : _toggle,
                    ),
                  ),
                const SizedBox(height: AppSpacing.lg),
                if (history.reports.isEmpty)
                  Text(
                    'Your first report arrives the Monday after your menu goes live.',
                    style: text.bodyMedium?.copyWith(color: AppColors.textSecondary),
                  )
                else
                  for (final row in history.reports)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        onTap: () => _open(row.weekStart),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(row.label,
                                  style: text.bodyLarge?.copyWith(color: AppColors.textPrimary)),
                            ),
                            Text('${_count(row.menuViews)} views',
                                style: text.bodyMedium?.copyWith(color: AppColors.textSecondary)),
                            if (row.delta != null) ...[
                              const SizedBox(width: AppSpacing.sm),
                              _Delta(pct: row.delta!),
                            ],
                            const Icon(Icons.chevron_right, color: AppColors.textMuted),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
