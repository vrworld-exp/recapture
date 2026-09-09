// lib/presentation/screens/admin/admin_batch_detail_screen.dart
//
// One batch's codes, and the two ways a code leaves the building.
//
// PER CODE — a printable PDF sheet the admin sends to a rep, who prints it and
// puts it on a table. This is the PILOT path: it needs no print vendor, and the
// QR it renders is byte-identical to the one a vendor would print, because both
// come from the same server-side composer.
//
// PER BATCH — two files. The vendor CSV, unchanged since stage 2, and the
// PRINTABLE SHEET: the whole run laid out six standees to an A4 page with cut
// guides, as many pages as it takes. They are not alternatives. The CSV is for
// a print shop that will manufacture standees; the sheet is for the office
// printer, today, and it is what makes a fifty-code batch usable before a
// vendor is engaged — the per-code download would be fifty presses and fifty
// sheets of paper for fifty squares.
//
// A retired code offers NEITHER. Reprinting one produces a sheet that resolves
// to the fallback page, and the whole cost of that lands after somebody has
// printed it and stood it on a table.
//
// ASSIGNMENT sits beside the download and answers the question the download
// could not: WHO has this standee. Sending a PDF told nobody anything, so two
// reps could be sent the same code and find out at a table. Assigning it puts
// the code on one rep's own list instead. It is ADVISORY — the code is not
// reserved, and any rep can still activate any free standee — so this button
// changes what people can SEE, never what they may do.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/admin/admin_batch_codes_notifier.dart';
import '../../../data/repositories/admin_standee_repository.dart';
import '../../../domain/entities/qr_standee.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import 'assign_standee_sheet.dart';

class AdminBatchDetailScreen extends ConsumerWidget {
  const AdminBatchDetailScreen({required this.batchId, super.key});

  final String batchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = adminBatchCodesProvider(batchId);
    final state = ref.watch(provider);
    final notifier = ref.read(provider.notifier);

    ref.listen<AdminBatchCodesState>(provider, (previous, next) {
      final failure = next.failure;
      final changed = failure?.code != previous?.failure?.code ||
          next.notice != previous?.notice;
      if (!changed) return;

      final messenger = CatalogFeedback.of(context);
      if (failure != null) {
        CatalogFeedback.failure(
          messenger,
          failure,
          subject: 'That file could not be saved',
        );
      } else if (next.notice != null) {
        CatalogFeedback.confirm(messenger, next.notice!);
      }
    });

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        title: const Text('Standees'),
        actions: [
          IconButton(
            key: const ValueKey('admin_batch_assign_all'),
            tooltip: 'Assign the whole batch',
            onPressed: state.bulkBusy
                ? null
                : () => _assignBatch(context, notifier, batchId, state),
            icon: state.bulkBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.person_add_alt_1_outlined),
          ),
          IconButton(
            key: const ValueKey('admin_batch_sheet'),
            tooltip: 'Download printable standee sheets',
            onPressed:
                state.downloadingSheet ? null : notifier.deliverBatchSheet,
            icon: state.downloadingSheet
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_outlined),
          ),
          IconButton(
            key: const ValueKey('admin_batch_csv'),
            tooltip: 'Download the print vendor CSV',
            onPressed: state.downloadingCsv ? null : notifier.deliverCsv,
            icon: state.downloadingCsv
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.table_view_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: notifier.load,
          child: state.codes.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (_, __) => _Message(
              title: "Couldn't load this batch.",
              body: 'Check your connection and pull down to try again.',
              onRetry: notifier.load,
            ),
            data: (codes) => codes.isEmpty
                ? const _Message(
                    title: 'This batch is empty.',
                    body: 'Nothing was minted into it.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    // One extra row at the end: the "load more" control, or
                    // nothing when the batch is fully loaded.
                    itemCount: codes.length + (state.hasMore ? 1 : 0),
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (_, i) {
                      if (i == codes.length) {
                        return Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.md),
                          child: AppButton.secondary(
                            label: 'Load more',
                            isLoading: state.loadingMore,
                            onPressed:
                                state.loadingMore ? null : notifier.loadMore,
                          ),
                        );
                      }
                      final code = codes[i];
                      return _CodeTile(
                        code: code,
                        busy: state.isBusy(code.code),
                        onSend: code.state.isPrintable
                            ? () => notifier.deliverStandee(
                                  code.code,
                                  format: StandeeQrFormat.pdf,
                                )
                            : null,
                        // Offered for the same states that can be printed. A
                        // RETIRED standee is refused by the endpoint anyway, and
                        // handing one to a rep would put a row on their list
                        // that they can do nothing with.
                        onAssign: code.state.isPrintable
                            ? () => _assign(context, notifier, code)
                            : null,
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

/// The whole batch at once — the other half of bulk assignment.
///
/// Minting covers a run created for a known rep. This covers everything else:
/// a batch minted before anyone knew who was carrying it, a rep who left, a
/// territory that moved. Without it an admin is back to one row at a time,
/// which is the problem the bulk path exists to remove.
///
/// "Return all to stock" is offered whenever ANY LOADED ROW has a holder.
/// That is a deliberate approximation: rows on pages the admin has not
/// scrolled to are unknown here, and the endpoint is idempotent, so the worst
/// case is an offered action that clears nothing and says so. Hiding it
/// because the visible page happens to be unassigned would be worse — the
/// control would vanish depending on how far somebody had scrolled.
Future<void> _assignBatch(
  BuildContext context,
  AdminBatchCodesNotifier notifier,
  String batchId,
  AdminBatchCodesState state,
) async {
  final rows = state.codes.valueOrNull ?? const <QrStandeeCode>[];
  final anyHeld = rows.any((row) => row.assignedTo != null);

  final choice = await showAssignStandeeSheet(
    context,
    title: 'Assign the whole batch',
    subject: '${rows.length} standees on screen',
    subjectIsCode: false,
    canReturnToStock: anyHeld,
    returnLabel: 'Return all to stock',
  );
  if (choice == null) return;

  switch (choice) {
    case AssignToRep(:final rep):
      await notifier.assignAll(repUserId: rep.id);
    case UnassignStandee():
      await notifier.unassignAll();
  }
}

/// Opens the picker and performs whatever the admin chose.
///
/// The AWAIT AND THE ACTION ARE SPLIT ACROSS THE SHEET BOUNDARY on purpose: the
/// sheet only decides, and the notifier call happens here, so the row spins and
/// any failure lands on the list the admin is still looking at.
Future<void> _assign(
  BuildContext context,
  AdminBatchCodesNotifier notifier,
  QrStandeeCode code,
) async {
  final choice = await showAssignStandeeSheet(
    context,
    subject: code.code,
    currentHolder: code.assignedTo,
  );
  if (choice == null) return;

  switch (choice) {
    case AssignToRep(:final rep):
      // Re-picking the rep who already holds it is treated as a no-op rather
      // than a redundant round trip that reports "assigned" for a change that
      // did not happen.
      if (rep.id == code.assignedTo?.id) return;
      await notifier.assign(code.code, repUserId: rep.id);
    case UnassignStandee():
      await notifier.unassign(code.code);
  }
}

class _CodeTile extends StatelessWidget {
  const _CodeTile({
    required this.code,
    required this.busy,
    required this.onSend,
    required this.onAssign,
  });

  final QrStandeeCode code;
  final bool busy;

  /// Null for a code that must not be printed — the button is ABSENT rather
  /// than disabled, matching the rep surface's rule: an affordance you do not
  /// have should be invisible, not greyed.
  final VoidCallback? onSend;

  /// Null for a code that cannot be handed to anyone. Same absent-not-greyed
  /// rule as [onSend].
  final VoidCallback? onAssign;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  code.code,
                  style: const TextStyle(
                    fontSize: AppTypography.sizeHeadline,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    // The characters a rep types off a printed standee. A
                    // monospace face is what makes 0/O and 1/I distinguishable
                    // on screen — the alphabet already excludes the ambiguous
                    // glyphs, so this is belt and braces for the person reading
                    // the code aloud over a phone.
                    fontFamily: 'monospace',
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  code.state.label,
                  style: TextStyle(
                    fontSize: AppTypography.sizeLabel,
                    color: switch (code.state) {
                      QrCodeState.unassigned => AppColors.royalGold,
                      QrCodeState.active => AppColors.textSecondary,
                      QrCodeState.retired ||
                      QrCodeState.unknown =>
                        AppColors.textMuted,
                    },
                  ),
                ),

                // WHO HAS IT — the answer this screen could not give before.
                // Present only when somebody holds it, so untouched stock stays
                // a two-line row and a handed-out one is visibly different at a
                // glance down the list.
                if (code.assignedTo != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      const Icon(
                        Icons.person_outline,
                        size: 14,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Flexible(
                        child: Text(
                          code.assignedTo!.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: AppTypography.sizeLabel,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else ...[
            if (onAssign != null)
              IconButton(
                key: ValueKey('assign_${code.code}'),
                // The verb changes with the state, because "Assign" on a row
                // that already names a holder reads as though it is unassigned.
                tooltip: code.isAssigned
                    ? 'Reassign this standee'
                    : 'Assign this standee to a rep',
                onPressed: onAssign,
                icon: Icon(
                  code.isAssigned
                      ? Icons.person
                      : Icons.person_add_alt_1_outlined,
                ),
                // Gold ONLY when assigned, and it is the single accent on this
                // row — the screen's 2–3% budget, spent on the one bit of state
                // an admin scans the list for.
                color: code.isAssigned
                    ? AppColors.royalGold
                    : AppColors.textSecondary,
              ),
            if (onSend != null)
              IconButton(
                tooltip: 'Save a printable standee',
                onPressed: onSend,
                // NEUTRAL BY TARGET, like the word "Save" the catalog QR screen
                // uses. On a phone this opens a share sheet; in a browser it is
                // a plain download. An iOS share glyph would be a lie in Chrome,
                // and the seam already hides which one is happening.
                icon: const Icon(Icons.save_alt),
                color: AppColors.textSecondary,
              ),
          ],
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body, this.onRetry});

  final String title;
  final String body;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        children: [
          const SizedBox(height: AppSpacing.huge),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: AppTypography.sizeHeadline,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: AppTypography.sizeBody,
              color: AppColors.textSecondary,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.lg),
            AppButton.secondary(label: 'Try again', onPressed: onRetry),
          ],
        ],
      );
}
