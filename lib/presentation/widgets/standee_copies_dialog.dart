// lib/presentation/widgets/standee_copies_dialog.dart
//
// "Download standee" — how many of THIS code, and laid out how.
//
// IT RETURNS A DECISION, NOT A FILE. The dialog closes with a
// [StandeeSheetChoice] and the CALLER fetches the sheet, so the spinner and any
// failure land on the row that was pressed rather than inside a dialog that is
// already gone — the same split `standee_sheet_dialog.dart` (the batch one)
// and `assign_standee_sheet.dart` use.
//
// ONE DIALOG, THREE SCREENS. The admin's batch screen, the rep's standee list
// and the rep's published history all have a per-row download, and they used
// to download one one-up sheet on the spot. A restaurant is handed SEVERAL
// standees of one code — ten tables, one menu — so every one of those buttons
// now asks the same two questions: how many, and one-up or the grid. The
// screen hands in whichever plan provider is its door (`adminStandeeSheet-
// PlanProvider` or `repStandeeSheetPlanProvider`); nothing else differs.
//
// What a card looks like is not up for discussion here: the square, its size,
// the mark — all of it is the server's. The dialog sends a count and a layout.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../data/repositories/admin_standee_repository.dart'
    show AdminStandeeErrorCodes;
import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/rep_repository.dart' show RepErrorCodes;
import '../../data/repositories/standee_sheet.dart';
import '../../domain/catalog/catalog_error_copy.dart';
import 'app_button.dart';
import 'app_loading_indicator.dart';

/// What the user decided: how many, and laid out how.
class StandeeSheetChoice {
  const StandeeSheetChoice({required this.copies, required this.layout});

  final int copies;
  final StandeeSheetLayout layout;
}

/// Opens the dialog for [code]. Resolves to the choice, or null if the user
/// backed out.
///
/// [plan] is the screen's door to the plan — the admin's or the rep's family
/// provider, already applied to [code].
Future<StandeeSheetChoice?> showStandeeCopiesDialog(
  BuildContext context, {
  required String code,
  required AutoDisposeFutureProvider<StandeeSheetPlan> plan,
}) {
  return showDialog<StandeeSheetChoice>(
    context: context,
    builder: (_) => StandeeCopiesDialog(code: code, plan: plan),
  );
}

/// The dialog body. Public so the widget test can pump it directly.
class StandeeCopiesDialog extends ConsumerStatefulWidget {
  const StandeeCopiesDialog({
    required this.code,
    required this.plan,
    super.key,
  });

  final String code;
  final AutoDisposeFutureProvider<StandeeSheetPlan> plan;

  @override
  ConsumerState<StandeeCopiesDialog> createState() =>
      _StandeeCopiesDialogState();
}

class _StandeeCopiesDialogState extends ConsumerState<StandeeCopiesDialog> {
  /// ONE copy, ONE-UP: exactly the file this button always produced. A user
  /// who opens the dialog and presses Download gets what they used to.
  final _copiesController = TextEditingController(text: '1');
  StandeeSheetLayout _layout = StandeeSheetLayout.single;

  @override
  void initState() {
    super.initState();
    _copiesController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _copiesController.dispose();
    super.dispose();
  }

  int? _copiesFor(StandeeSheetPlan plan) {
    final n = int.tryParse(_copiesController.text.trim());
    if (n == null || n < 1 || n > plan.maxCopies) return null;
    return n;
  }

  void _step(StandeeSheetPlan plan, int delta) {
    final current = int.tryParse(_copiesController.text.trim()) ?? 1;
    _copiesController.text = '${(current + delta).clamp(1, plan.maxCopies)}';
  }

  @override
  Widget build(BuildContext context) {
    final plan = ref.watch(widget.plan);
    final ready = plan.valueOrNull;
    final copies = ready == null ? null : _copiesFor(ready);

    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Download standee'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              // The code, monospaced: an admin who pressed the button on the
              // wrong row finds out here rather than at the printer.
              widget.code,
              style: const TextStyle(
                fontSize: AppTypography.sizeBody,
                color: AppColors.textSecondary,
                fontFamily: 'monospace',
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            plan.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: AppLoadingIndicator()),
              ),
              error: (error, _) => _PlanFailed(
                failure: error is CatalogFailure ? error : null,
                onRetry: () => ref.invalidate(widget.plan),
              ),
              data: (plan) => _Body(
                plan: plan,
                copies: copies,
                layout: _layout,
                controller: _copiesController,
                onStep: (delta) => _step(plan, delta),
                onLayout: (layout) => setState(() => _layout = layout),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('standee_copies_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('standee_copies_download'),
          // Disabled until the plan is in and the number is one the server
          // will take — a 400 after the press would be this dialog's own
          // failure, and it can see it coming.
          onPressed: copies == null
              ? null
              : () => Navigator.of(context).pop(
                    StandeeSheetChoice(copies: copies, layout: _layout),
                  ),
          child: const Text('Download'),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.plan,
    required this.copies,
    required this.layout,
    required this.controller,
    required this.onStep,
    required this.onLayout,
  });

  final StandeeSheetPlan plan;
  final int? copies;
  final StandeeSheetLayout layout;
  final TextEditingController controller;
  final ValueChanged<int> onStep;
  final ValueChanged<StandeeSheetLayout> onLayout;

  @override
  Widget build(BuildContext context) {
    final pages = copies == null ? null : plan.pagesFor(copies!, layout);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const ValueKey('standee_copies_minus'),
              tooltip: 'One fewer',
              onPressed: () => onStep(-1),
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: TextField(
                key: const ValueKey('standee_copies_field'),
                controller: controller,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Copies of this QR',
                  errorText: copies == null
                      ? 'Enter a number from 1 to ${plan.maxCopies}.'
                      : null,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('standee_copies_plus'),
              tooltip: 'One more',
              onPressed: () => onStep(1),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const Text(
          'Layout',
          style: TextStyle(
            fontSize: AppTypography.sizeLabel,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        // The two layouts, described as what comes out of the printer rather
        // than by name: "1 QR per page" is a table stand, "9 per page" is a
        // sheet of cut-out cards. The grid's count is the server's.
        _LayoutOption(
          key: const ValueKey('standee_layout_single'),
          value: StandeeSheetLayout.single,
          selected: layout,
          title: StandeeSheetLayout.single.label,
          detail: 'One large QR on each A4 page.',
          onChanged: onLayout,
        ),
        _LayoutOption(
          key: const ValueKey('standee_layout_grid'),
          value: StandeeSheetLayout.grid,
          selected: layout,
          title: '${plan.perPage} QRs per page',
          detail:
              '${plan.columns} × ${plan.rows} cut-out cards on each A4 page.',
          onChanged: onLayout,
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Pages',
                style: TextStyle(
                  fontSize: AppTypography.sizeBody,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            Text(
              pages == null ? '—' : '$pages',
              key: const ValueKey('standee_copies_pages'),
              style: const TextStyle(
                fontSize: AppTypography.sizeHeadline,
                fontWeight: FontWeight.w600,
                color: AppColors.royalGold,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One radio row. `RadioListTile` would do, but its leading radio and dense
/// padding fight the dialog's width on a phone; this is the same thing laid
/// out for the space.
class _LayoutOption extends StatelessWidget {
  const _LayoutOption({
    required this.value,
    required this.selected,
    required this.title,
    required this.detail,
    required this.onChanged,
    super.key,
  });

  final StandeeSheetLayout value;
  final StandeeSheetLayout selected;
  final String title;
  final String detail;
  final ValueChanged<StandeeSheetLayout> onChanged;

  @override
  Widget build(BuildContext context) {
    final isSelected = value == selected;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: () => onChanged(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: isSelected ? AppColors.royalGold : AppColors.textMuted,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: AppTypography.sizeBody,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    detail,
                    style: const TextStyle(
                      fontSize: AppTypography.sizeLabel,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The plan would not load — or the code was refused outright.
///
/// A REFUSAL IS NOT A RETRY. A retired code, or one this rep does not hold,
/// gets the same answer on every press; everything else — offline, a 5xx —
/// gets the Try again button.
class _PlanFailed extends StatelessWidget {
  const _PlanFailed({required this.failure, required this.onRetry});

  final CatalogFailure? failure;
  final VoidCallback onRetry;

  static const _refusals = {
    AdminStandeeErrorCodes.codeRetired,
    AdminStandeeErrorCodes.resolverNotConfigured,
    AdminStandeeErrorCodes.notFound,
    RepErrorCodes.codeNotFound,
  };

  @override
  Widget build(BuildContext context) {
    final code = failure?.code;
    final refused = _refusals.contains(code);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          catalogErrorSentence(
            code,
            subject: refused ? null : "The sheet couldn't be prepared",
          ),
          key: const ValueKey('standee_copies_plan_error'),
          style: const TextStyle(
            fontSize: AppTypography.sizeBody,
            color: AppColors.textSecondary,
          ),
        ),
        if (!refused) ...[
          const SizedBox(height: AppSpacing.lg),
          AppButton.secondary(
            key: const ValueKey('standee_copies_plan_retry'),
            label: 'Try again',
            onPressed: onRetry,
          ),
        ],
      ],
    );
  }
}
