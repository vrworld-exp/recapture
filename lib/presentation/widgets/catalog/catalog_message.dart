// lib/presentation/widgets/catalog/catalog_message.dart
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../app_button.dart';

/// The one centred icon + title + body + optional CTA block every catalog
/// surface uses for its empty, first-run and error states.
///
/// One widget rather than one per state, so they cannot drift apart visually —
/// and, more importantly, so the states stay TOLD APART by their copy rather
/// than by their layout. A catalog with no products and a filter that matches
/// nothing look identical in structure and must never read identically: this
/// widget makes the difference a caller's decision, which is where it belongs.
///
/// Lifted out of `catalog_screen.dart` when the grid landed, because the grid
/// needs the same block for its filtered-empty and error states.
class CatalogMessage extends StatelessWidget {
  const CatalogMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.fillsViewport = true,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// A second, quieter action — "Clear filters" next to "Add product". Rendered
  /// only when both the label and the callback are given.
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  /// Whether this block owns the whole screen (the no-catalog / error states) or
  /// sits inside an already-scrolling list.
  final bool fillsViewport;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final content = Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: AppColors.surface1,
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.royalGold.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
            child: Icon(icon, color: AppColors.textMuted, size: 40),
          ),
          const SizedBox(height: AppSpacing.xxl),
          Text(title, style: textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.sm),
          Text(
            body,
            style: textTheme.bodyMedium
                ?.copyWith(color: AppColors.textSecondary, height: 1.5),
            textAlign: TextAlign.center,
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: AppSpacing.xxl),
            AppButton(
              label: actionLabel!,
              isFullWidth: false,
              // Nullable so a caller CAN name a step that is not wired yet, and
              // the theme greys it. No caller does any more — pass an action
              // with the label rather than shipping a button that does nothing.
              onPressed: onAction,
            ),
          ],
          if (secondaryActionLabel != null && onSecondaryAction != null) ...[
            const SizedBox(height: AppSpacing.sm),
            AppButton.secondary(
              label: secondaryActionLabel!,
              isFullWidth: false,
              onPressed: onSecondaryAction,
            ),
          ],
        ],
      ),
    );

    if (!fillsViewport) return content;

    // Fill the viewport so pull-to-refresh stays available on a short body.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: content),
        ),
      ),
    );
  }
}
