// lib/presentation/widgets/model_choice_tile.dart
//
// One SELECTABLE 3D model, for the product model picker.
//
// A sibling of [ModelRow] rather than a mode of it, because the affordance is
// the whole difference: a history row's chevron says "open this", and in a
// picker that would be a lie — the tap SELECTS. Every visual term the two share
// (thumbnail, stamp, status word, `OPT` / origin badges, `formatBytes`) comes
// from model_presentation.dart, so the picker cannot drift from the history it
// is picking out of.
//
// Two deliberate rules, both from the backend:
//
//  1. Only a SUCCEEDED model with a GLB is selectable. `resolveOwnedModel`
//     returns MODEL_NOT_READY for anything else, so a selectable pending tile
//     is a guaranteed round-trip failure — [ProjectModelView.isViewable] is the
//     only test, never a rule re-derived from status alone.
//  2. Pending and FAILED records are still SHOWN. A capture whose regenerate is
//     mid-flight has to say so; hiding the row makes the app look like it lost
//     a model. They render dimmed, with one line of reason and no radio.
//
// Props in, callbacks out: no repository, no provider, no navigation.
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/project_model.dart';
import 'model_presentation.dart';

/// Why an unselectable model cannot be chosen — one plain line, no error code.
String unselectableModelReason(ProjectModelView model) {
  if (model.status.isPending) {
    return 'Still building — you can pick this once it finishes.';
  }
  return "This one didn't finish.";
}

class ModelChoiceTile extends StatelessWidget {
  const ModelChoiceTile({
    super.key,
    required this.model,
    required this.selected,
    required this.onSelect,
    required this.onPreview,
    this.isCurrent = false,
    this.enabled = true,
  });

  final ProjectModelView model;

  /// Radio semantics: a product has exactly one `sourceModelId`, so exactly one
  /// tile in a list is ever selected.
  final bool selected;

  /// Called on tap and on the radio. Never called for an unselectable model —
  /// the tile makes itself inert rather than relying on the caller to check.
  final VoidCallback onSelect;

  /// Opens this model in the 3D viewer. A SEPARATE affordance from select (one
  /// gesture doing both means every comparison changes the answer).
  final VoidCallback onPreview;

  /// True for the model the product is using right now (the change-model flow).
  final bool isCurrent;

  /// False while a submit is in flight — the whole picker goes read-only rather
  /// than letting a selection change under a request already on the wire.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewable = model.isViewable;
    final selectable = viewable && enabled;
    final origin = model.source.badgeLabel;
    final size = formatBytes(model.sizeBytes);

    final tile = Material(
      color: selected
          ? AppColors.royalGold.withValues(alpha: 0.08)
          : AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        // Null onTap is what makes a pending/failed tile inert, and it is also
        // what drops it out of focus traversal — a keyboard user on web cannot
        // land on a choice they are not allowed to make.
        onTap: selectable ? onSelect : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: selected
                  ? AppColors.royalGold.withValues(alpha: 0.6)
                  : AppColors.textMuted.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The radio is present ONLY on a selectable tile: an empty circle
              // beside a still-building model reads as "choose me", which the
              // server would then refuse.
              //
              // Drawn rather than a Material [Radio]: a real Radio now wants a
              // RadioGroup ancestor to own the group value, which would make
              // this tile unusable on its own. The whole tile is already the
              // tap target, and the Semantics wrapper below carries the
              // mutually-exclusive/selected state a screen reader needs — so
              // the control here only has to LOOK like what it is.
              if (viewable)
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  key: ValueKey(
                    selected ? 'model_radio_on' : 'model_radio_off',
                  ),
                  size: 20,
                  color:
                      selected ? AppColors.royalGold : AppColors.textSecondary,
                )
              else
                const SizedBox(width: 20),
              const SizedBox(width: AppSpacing.md),
              ModelThumbnail(model: model),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${modelStamp(model.createdAt)} · '
                      '${modelStatusLabel(model.status)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    // Wrap, not a Row: a tile can carry Current + OPT + a size
                    // + an origin badge at once, which no 360dp phone fits on
                    // one line.
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      children: [
                        if (isCurrent) const _CurrentChip(),
                        if (model.isOptimized) ModelOptBadge(model: model),
                        // An OPT badge already carries the size; repeating it
                        // beside itself is noise.
                        if (!model.isOptimized && size != null)
                          Text(
                            size,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: AppColors.textMuted),
                          ),
                        if (model.isAutoGenerated)
                          Text(
                            kAutoGeneratedBadgeLabel,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: AppColors.textMuted),
                          ),
                        // Null for an `optimized` record, which has no origin
                        // of its own to claim — see ModelSource.badgeLabel.
                        if (origin != null) ModelSourceBadge(label: origin),
                      ],
                    ),
                    if (!viewable) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        unselectableModelReason(model),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // Its own control, keyboard-reachable, disabled on anything with
              // nothing to render.
              TextButton(
                onPressed: viewable && enabled ? onPreview : null,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.bodySmall,
                ),
                child: const Text('Preview'),
              ),
            ],
          ),
        ),
      ),
    );

    return Semantics(
      inMutuallyExclusiveGroup: viewable,
      selected: selected,
      // Dimmed rather than hidden: the user must see that the capture HAS this
      // record, just not that they can pick it yet.
      child: viewable ? tile : Opacity(opacity: 0.55, child: tile),
    );
  }
}

/// Marks the model the product is pointing at right now, so "which one am I
/// changing away from" never has to be remembered.
class _CurrentChip extends StatelessWidget {
  const _CurrentChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('model_current_chip'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.royalGold),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        'Current',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: AppColors.royalGold),
      ),
    );
  }
}
