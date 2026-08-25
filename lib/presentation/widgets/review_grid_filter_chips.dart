// lib/presentation/widgets/review_grid_filter_chips.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_spacing.dart';
import '../../application/capture/review_grid_providers.dart';
import '../../domain/entities/review_grid_filter.dart';

/// The "All" / "Warned" filter chip row for Screen 7A's review grid. Tapping a
/// chip updates [reviewGridFilterProvider] for [levelId]; the chip labels carry
/// live counts ("All (28)" / "Warned (4)").
///
/// Generic over the level id (a PitchBand.id string) — the parent screen passes
/// the level it is reviewing (Level A Eye Ring = "mid"). Display + intent only:
/// it reads the derived count providers and writes the filter state; it does not
/// render the grid or mutate the ledger.
class ReviewGridFilterChips extends ConsumerWidget {
  const ReviewGridFilterChips({super.key, required this.levelId});

  /// The level whose review grid these chips filter (a PitchBand.id).
  final String levelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeFilter = ref.watch(reviewGridFilterProvider(levelId));
    final totalCount = ref.watch(reviewGridTotalCountProvider(levelId));
    final warnedCount = ref.watch(reviewGridWarnedCountProvider(levelId));

    return Semantics(
      container: true,
      label: 'Review grid filter',
      child: Wrap(
        spacing: AppSpacing.sm,
        children: [
          ChoiceChip(
            key: const Key('review_grid_filter_chip_all'),
            label: Text('All ($totalCount)'),
            selected: activeFilter == ReviewGridFilter.all,
            onSelected: (_) => ref
                .read(reviewGridFilterProvider(levelId).notifier)
                .state = ReviewGridFilter.all,
          ),
          ChoiceChip(
            key: const Key('review_grid_filter_chip_warned'),
            label: Text('Warned ($warnedCount)'),
            selected: activeFilter == ReviewGridFilter.warned,
            // Disabled (not hidden) when there are no warned photos: nothing to
            // filter to, and disabling keeps the layout stable as the count goes
            // 0 → nonzero during a live session.
            //
            // NOTE: if the active filter is already `warned` when the count drops
            // to 0 (e.g. a retake removed the only warned photo), the chip stays
            // selected-but-disabled. We deliberately do NOT auto-reset the filter
            // to `all` here — that defensive reset belongs to the screen
            // controller that owns retake logic, which is out of scope for this
            // widget.
            onSelected: warnedCount == 0
                ? null
                : (_) => ref
                    .read(reviewGridFilterProvider(levelId).notifier)
                    .state = ReviewGridFilter.warned,
          ),
        ],
      ),
    );
  }
}
