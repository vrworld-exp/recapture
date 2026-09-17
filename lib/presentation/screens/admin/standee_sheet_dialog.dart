// lib/presentation/screens/admin/standee_sheet_dialog.dart
//
// "Download standee sheets" — what is about to be printed, and how many of each.
//
// IT RETURNS A DECISION, NOT A FILE. The dialog closes with the number of
// copies and the CALLER fetches the sheet, so the spinner and any failure land
// on the button the admin pressed (the inventory row, or the batch screen's
// app bar) rather than inside a dialog that is already gone — the same split
// `assign_standee_sheet.dart` uses.
//
// WHY A DIALOG AT ALL, when the button used to download straight away. A
// restaurant is handed SEVERAL standees carrying ONE code — ten tables, one
// menu — so "how many of each" is a real question, and the answer changes the
// file by an order of magnitude: fifty codes at ten copies is fifty-six pages.
// That number belongs on screen before the file is on its way, not in a toast
// after it. So the dialog reads the server's plan (how many codes will print,
// the grid) and does the page arithmetic live as the number is typed.
//
// What a card looks like is not up for discussion here: the layout, the size
// of the square, the mark — all of it is the server's, and the only thing this
// dialog sends is a count.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/admin/batch_sheet_plan.dart';
import '../../../data/repositories/admin_standee_repository.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/catalog_error_copy.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';

/// Opens the dialog for [batchId]. Resolves to the number of copies of each
/// code to print, or null if the admin backed out.
///
/// [label] is the batch's name, shown under the title so an admin who pressed
/// the button on the wrong row finds out HERE rather than at the printer. The
/// batch screen does not hold one and passes nothing.
Future<int?> showStandeeSheetDialog(
  BuildContext context, {
  required String batchId,
  String? label,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => StandeeSheetDialog(batchId: batchId, label: label),
  );
}

/// The dialog body. Public so the widget test can pump it directly.
class StandeeSheetDialog extends ConsumerStatefulWidget {
  const StandeeSheetDialog({required this.batchId, this.label, super.key});

  final String batchId;
  final String? label;

  @override
  ConsumerState<StandeeSheetDialog> createState() => _StandeeSheetDialogState();
}

class _StandeeSheetDialogState extends ConsumerState<StandeeSheetDialog> {
  /// Starts at ONE, which is the plain sheet — the file this button always
  /// produced. An admin who opens the dialog and presses Download gets exactly
  /// what they used to.
  final _copiesController = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    // The counts under the field follow the number as it is typed.
    _copiesController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _copiesController.dispose();
    super.dispose();
  }

  /// The typed number, or null when it is not one the server would accept.
  int? _copiesFor(BatchSheetPlan plan) {
    final n = int.tryParse(_copiesController.text.trim());
    if (n == null || n < 1 || n > plan.maxCopies) return null;
    return n;
  }

  void _step(BatchSheetPlan plan, int delta) {
    final current = int.tryParse(_copiesController.text.trim()) ?? 1;
    final next = (current + delta).clamp(1, plan.maxCopies);
    _copiesController.text = '$next';
  }

  @override
  Widget build(BuildContext context) {
    final plan = ref.watch(batchSheetPlanProvider(widget.batchId));
    final ready = plan.valueOrNull;
    final copies = ready == null ? null : _copiesFor(ready);

    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Download standee sheets'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.label != null) ...[
              Text(
                widget.label!,
                style: const TextStyle(
                  fontSize: AppTypography.sizeBody,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            plan.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: AppLoadingIndicator()),
              ),
              error: (error, _) => _PlanFailed(
                failure: error is CatalogFailure ? error : null,
                onRetry: () =>
                    ref.invalidate(batchSheetPlanProvider(widget.batchId)),
              ),
              data: (plan) => _PlanBody(
                plan: plan,
                copies: copies,
                controller: _copiesController,
                onStep: (delta) => _step(plan, delta),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('standee_sheet_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('standee_sheet_download'),
          // Disabled until the plan is in and the number is one the server
          // will take — a 400 after the press would be this dialog's own
          // failure, and it can see it coming.
          onPressed:
              copies == null ? null : () => Navigator.of(context).pop(copies),
          child: const Text('Download QRs'),
        ),
      ],
    );
  }
}

/// The plan, the field, and the arithmetic under it.
class _PlanBody extends StatelessWidget {
  const _PlanBody({
    required this.plan,
    required this.copies,
    required this.controller,
    required this.onStep,
  });

  final BatchSheetPlan plan;

  /// The valid typed number, or null while the field holds something else.
  final int? copies;
  final TextEditingController controller;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    final skipped = plan.skippedRetired;
    final pages = copies == null ? null : plan.pagesFor(copies!);
    final cards = copies == null ? null : plan.cardsFor(copies!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoRow(
          label: 'Standees',
          value: '${plan.standees}',
          // "48" against a batch of 50 reads as a bug until something says why.
          note: skipped == 0 ? null : '$skipped retired, will be skipped',
          valueKey: const ValueKey('standee_sheet_standees'),
        ),
        _InfoRow(
          label: 'Per page',
          value: '${plan.perPage}',
          note: '${plan.columns} × ${plan.rows} on A4',
          valueKey: const ValueKey('standee_sheet_per_page'),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            IconButton(
              key: const ValueKey('standee_sheet_copies_minus'),
              tooltip: 'One fewer',
              onPressed: () => onStep(-1),
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: TextField(
                key: const ValueKey('standee_sheet_copies'),
                controller: controller,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Copies of each standee',
                  errorText: copies == null
                      ? 'Enter a number from 1 to ${plan.maxCopies}.'
                      : null,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('standee_sheet_copies_plus'),
              tooltip: 'One more',
              onPressed: () => onStep(1),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          // What the number MEANS, in the words the request was made in: one
          // standee is one QR, and this is how many of each get printed. The
          // copies sit side by side, so a restaurant's ten come off together.
          '1 standee = 1 QR. Each code is printed this many times, side by '
          'side, before the next code.',
          style: TextStyle(
            fontSize: AppTypography.sizeLabel,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _InfoRow(
          label: 'QRs in the PDF',
          value: cards == null ? '—' : '$cards',
          valueKey: const ValueKey('standee_sheet_cards'),
        ),
        _InfoRow(
          label: 'Pages',
          value: pages == null ? '—' : '$pages',
          valueKey: const ValueKey('standee_sheet_pages'),
          emphasis: true,
        ),
      ],
    );
  }
}

/// One "label ... value" line, with an optional grey note under the value.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    required this.valueKey,
    this.note,
    this.emphasis = false,
  });

  final String label;
  final String value;
  final Key valueKey;
  final String? note;

  /// The page count is the one number an admin is here to see.
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: AppTypography.sizeBody,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                key: valueKey,
                style: TextStyle(
                  fontSize: emphasis
                      ? AppTypography.sizeHeadline
                      : AppTypography.sizeBody,
                  fontWeight: FontWeight.w600,
                  color: emphasis ? AppColors.royalGold : AppColors.textPrimary,
                ),
              ),
              if (note != null)
                Text(
                  note!,
                  style: const TextStyle(
                    fontSize: AppTypography.sizeLabel,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The plan would not load — or the sheet was refused outright.
///
/// A REFUSAL IS NOT A RETRY. `BATCH_TOO_LARGE` and `NOTHING_TO_PRINT` name a
/// different button as the way out (the vendor CSV; a replacement mint), and
/// an admin who retries them gets the same answer. Everything else — offline,
/// a 5xx — gets the Try again button.
class _PlanFailed extends StatelessWidget {
  const _PlanFailed({required this.failure, required this.onRetry});

  final CatalogFailure? failure;
  final VoidCallback onRetry;

  static const _refusals = {
    AdminStandeeErrorCodes.batchTooLarge,
    AdminStandeeErrorCodes.nothingToPrint,
    AdminStandeeErrorCodes.resolverNotConfigured,
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
          key: const ValueKey('standee_sheet_plan_error'),
          style: const TextStyle(
            fontSize: AppTypography.sizeBody,
            color: AppColors.textSecondary,
          ),
        ),
        if (!refused) ...[
          const SizedBox(height: AppSpacing.lg),
          AppButton.secondary(
            key: const ValueKey('standee_sheet_plan_retry'),
            label: 'Try again',
            onPressed: onRetry,
          ),
        ],
      ],
    );
  }
}
