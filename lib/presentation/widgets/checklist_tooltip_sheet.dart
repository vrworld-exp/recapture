// lib/presentation/widgets/checklist_tooltip_sheet.dart
import 'package:flutter/cupertino.dart' show showCupertinoModalPopup;
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/checklist_item.dart';
import '../../utils/analytics.dart';

/// Single, platform-adaptive entry point for a checklist item's tip/detail
/// surface (the Pre-Capture Checklist opens this on item tap):
///   - Android (and the default) → Material modal bottom sheet
///   - iOS / macOS               → Cupertino modal popup
///
/// Callers never branch on platform — they just call this. The same content
/// widget ([_TipBody]) renders in both; only the container differs. Platform is
/// read from `Theme.of(context).platform` so tests can force either side via
/// `Theme`/`debugDefaultTargetPlatformOverride`.
///
/// A guard prevents a second tip from stacking on top of an open one.
Future<void> showChecklistTooltip(BuildContext context, ChecklistItem item) {
  if (_tipVisible) return Future<void>.value(); // no stacking
  _tipVisible = true;

  final platform = Theme.of(context).platform;
  final isCupertino =
      platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

  // One genuine open per call: the stacking guard above already collapsed a
  // rapid double-tap into a single open, and this runs on the open action (not
  // on rebuilds while the tip stays up). Each real open is a distinct
  // interaction and SHOULD count. Fire-and-forget; never blocks presenting.
  Analytics.logEvent(AnalyticsEvents.precaptureTipOpened, {
    'item_id': item.id,
    'presentation': isCupertino ? 'popover' : 'bottom_sheet',
  });

  final Future<void> shown = isCupertino
      ? showCupertinoModalPopup<void>(
          context: context,
          barrierColor: AppColors.scrim,
          builder: (_) => _CupertinoTipSurface(item: item),
        )
      : showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          backgroundColor: AppColors.surface1,
          barrierColor: AppColors.scrim,
          showDragHandle: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
          ),
          builder: (_) => _TipBody(item: item),
        );

  return shown.whenComplete(() => _tipVisible = false);
}

/// True while a tip surface is on screen — blocks stacking. Reset when the
/// surface is dismissed (see [showChecklistTooltip]).
bool _tipVisible = false;

/// Resets the no-stacking guard between tests (the flag is process-global).
@visibleForTesting
void debugResetChecklistTooltipGuard() => _tipVisible = false;

/// iOS container: a themed bottom surface (Cupertino modal popup provides no
/// background/shape of its own) wrapping the SAME [_TipBody] as Android.
class _CupertinoTipSurface extends StatelessWidget {
  const _CupertinoTipSurface({required this.item});

  final ChecklistItem item;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Grab handle for parity with the Android drag handle.
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textMuted,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Flexible(child: _TipBody(item: item)),
          ],
        ),
      ),
    );
  }
}

/// The shared tip content — identical on both platforms. Header (icon badge +
/// title + close) over the scrollable body; capped at 80% of the screen so it
/// never covers the whole view and scrolls internally when long.
class _TipBody extends StatelessWidget {
  const _TipBody({required this.item});

  final ChecklistItem item;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xxl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: AppColors.mirageRed,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(item.icon, color: Colors.white, size: AppSpacing.xxl),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      item.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                item.tooltipContent,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.textSecondary, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
