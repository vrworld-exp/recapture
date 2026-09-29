// lib/presentation/widgets/catalog/dish_badge_chip.dart
//
// How a Stage 5 badge LOOKS in the app — the same icon family and colour words
// the public menu uses (mirage-fe features/menu/dishDetails.tsx). `Brand` and
// `Accent` follow the menu theme there; here they show ReCapture's own red and
// gold, which is Basalt — close enough for the owner to recognise the badge.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../domain/catalog/dish_details.dart';

IconData badgeIconData(BadgeIcon icon) => switch (icon) {
      BadgeIcon.flame => Icons.local_fire_department,
      BadgeIcon.star => Icons.star,
      BadgeIcon.sparkles => Icons.auto_awesome,
      BadgeIcon.leaf => Icons.eco,
      BadgeIcon.chefHat => Icons.restaurant_menu,
      BadgeIcon.crown => Icons.workspace_premium,
      BadgeIcon.heart => Icons.favorite,
      BadgeIcon.thumbsUp => Icons.thumb_up,
      BadgeIcon.clock => Icons.schedule,
      BadgeIcon.percent => Icons.percent,
    };

Color badgeColor(BadgeColor color) => switch (color) {
      BadgeColor.primary => AppColors.mirageRed,
      BadgeColor.accent => AppColors.royalGold,
      BadgeColor.red => const Color(0xFFF87171),
      BadgeColor.green => const Color(0xFF4ADE80),
      BadgeColor.blue => const Color(0xFF38BDF8),
      BadgeColor.orange => const Color(0xFFFB923C),
    };

class DishBadgeChip extends StatelessWidget {
  const DishBadgeChip({super.key, required this.badge});

  final CatalogBadge badge;

  @override
  Widget build(BuildContext context) {
    final color = badgeColor(badge.color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(badgeIconData(badge.icon), size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            badge.label.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}
