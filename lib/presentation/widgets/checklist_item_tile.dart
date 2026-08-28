// lib/presentation/widgets/checklist_item_tile.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/checklist_item.dart';
import 'app_card.dart';
import 'checklist_tooltip_sheet.dart';

/// A single tappable checklist row.
///
/// Tapping anywhere on the tile toggles acknowledgment. The info button and
/// the checkbox carry their own tap recognizers, so they win the gesture
/// arena over the card's [InkWell] — tapping the info icon opens the tooltip
/// without also toggling the checkbox.
class ChecklistItemTile extends StatelessWidget {
  const ChecklistItemTile({
    super.key,
    required this.item,
    required this.isChecked,
    required this.onToggle,
  });

  final ChecklistItem item;
  final bool isChecked;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => onToggle(!isChecked),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              color: AppColors.mirageRed,
              shape: BoxShape.circle,
            ),
            child: Icon(item.icon, color: Colors.white, size: AppSpacing.lg),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.title,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'More info',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      iconSize: 18,
                      icon: const Icon(
                        Icons.info_outline,
                        color: AppColors.textMuted,
                      ),
                      onPressed: () => showChecklistTooltip(context, item),
                    ),
                  ],
                ),
                Text(
                  item.shortDescription,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Checkbox(
            value: isChecked,
            onChanged: (value) => onToggle(value ?? false),
            activeColor: AppColors.mirageRed,
            checkColor: Colors.white,
            side: const BorderSide(color: AppColors.disabled, width: 1.5),
          ),
        ],
      ),
    );
  }
}
