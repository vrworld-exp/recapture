// lib/presentation/widgets/checklist_tooltip_sheet.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/checklist_item.dart';

/// Opens the extended-tooltip bottom sheet for a single [ChecklistItem].
///
/// Uses [showModalBottomSheet] with `isScrollControlled: true` so long
/// tooltip content scrolls internally instead of overflowing. Dismiss via
/// swipe-down, tap-outside, or the close button.
Future<void> showChecklistTooltip(
  BuildContext context,
  ChecklistItem item,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface1,
    barrierColor: AppColors.scrim,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (sheetContext) => _ChecklistTooltipSheet(item: item),
  );
}

class _ChecklistTooltipSheet extends StatelessWidget {
  const _ChecklistTooltipSheet({required this.item});

  final ChecklistItem item;

  @override
  Widget build(BuildContext context) {
    // Cap the sheet at 80% of the screen so it never covers the whole view;
    // content scrolls within that bound when the tooltip is long.
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
