// lib/presentation/screens/admin/admin_standees_screen.dart
//
// Standee inventory: every mint run, and how much of each is still in the box.
//
// The list answers ONE question — "have we got codes left to hand out" — so the
// row leads with what is available rather than with the run's size. An admin
// opens this because a rep is about to go out, not to audit a print order.
//
// THE DOWNLOAD SITS ON THE ROW, not only inside the batch. Getting a run onto
// paper is the second thing an admin does with a batch — right after minting it
// — and it needs nothing from the code list, so making them open the batch to
// find the button would be a step for no one. One press produces one PDF: six
// standees to an A4 page, cut guides, as many pages as the run needs.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/admin/admin_standees_notifier.dart';
import '../../../application/admin/sales_reps_notifier.dart';
import '../../../domain/entities/qr_standee.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';

class AdminStandeesScreen extends ConsumerWidget {
  const AdminStandeesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(adminStandeesProvider);

    ref.listen<AdminStandeesState>(adminStandeesProvider, (previous, next) {
      final failure = next.failure;
      final changed = failure?.code != previous?.failure?.code ||
          next.notice != previous?.notice;
      if (!changed) return;

      final messenger = CatalogFeedback.of(context);
      if (failure != null) {
        CatalogFeedback.failure(
          messenger,
          failure,
          // WHICH action failed, read from the transition rather than from the
          // failure's code: a download and a mint can fail with the same code
          // (an offline device, a missing resolver origin), and telling an
          // admin their batch could not be minted when they pressed Download
          // sends them to re-mint a run that already exists.
          subject: previous?.downloadingSheetFor != null
              ? 'That sheet could not be saved'
              : 'The batch could not be minted',
        );
      } else if (next.notice != null) {
        CatalogFeedback.confirm(messenger, next.notice!);
      }
    });

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('Standee inventory')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('admin_mint_fab'),
        onPressed: state.minting ? null : () => _mint(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Mint a batch'),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(adminStandeesProvider.notifier).load(),
          child: state.batches.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (_, __) => _Message(
              title: "Couldn't load the inventory.",
              body: 'Check your connection and pull down to try again.',
              onRetry: () => ref.read(adminStandeesProvider.notifier).load(),
            ),
            data: (batches) => batches.isEmpty
                ? const _Message(
                    title: 'No batches yet.',
                    body: 'Mint one to get codes a rep can activate.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    itemCount: batches.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (_, i) => _BatchTile(
                      batch: batches[i],
                      downloading: state.isDownloadingSheet(batches[i].id),
                      // Blocked while ANY sheet is in flight, matching the
                      // notifier: two overlapping downloads would race to
                      // report which one the confirmation is about.
                      onDownload: state.downloadingSheetFor != null
                          ? null
                          : () => ref
                              .read(adminStandeesProvider.notifier)
                              .deliverSheet(batches[i].id),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// Mint, then go STRAIGHT into the new batch.
  ///
  /// The admin minted because they want a code now; making them find the run
  /// they just created in a list is a step that exists for no one.
  Future<void> _mint(BuildContext context, WidgetRef ref) async {
    final request = await showDialog<_MintRequest>(
      context: context,
      builder: (_) => const _MintDialog(),
    );
    if (request == null || !context.mounted) return;

    final batchId = await ref.read(adminStandeesProvider.notifier).mint(
          count: request.count,
          label: request.label,
          assignToUserId: request.assignToUserId,
        );
    if (batchId == null || !context.mounted) return;
    context.push('${AppRoutes.adminStandees}/$batchId');
  }
}

class _BatchTile extends StatelessWidget {
  const _BatchTile({
    required this.batch,
    required this.downloading,
    required this.onDownload,
  });

  final QrBatchSummary batch;

  /// This row's sheet is being fetched — one row spins, not the whole list.
  final bool downloading;

  /// Null while another row is downloading, so two cannot overlap.
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: () => context.push('${AppRoutes.adminStandees}/${batch.id}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      batch.label,
                      style: const TextStyle(
                        fontSize: AppTypography.sizeHeadline,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // Availability first. The run's size is context; what is
                      // left is the decision.
                      '${batch.unassigned} available of ${batch.count}',
                      style: TextStyle(
                        fontSize: AppTypography.sizeLabel,
                        color: batch.unassigned > 0
                            ? AppColors.royalGold
                            : AppColors.textMuted,
                      ),
                    ),
                    if (batch.active > 0 || batch.retired > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${batch.active} in use · ${batch.retired} retired',
                        style: const TextStyle(
                          fontSize: AppTypography.sizeLabel,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('admin_batch_sheet_${batch.id}'),
                tooltip: 'Download printable standee sheets',
                onPressed: downloading ? null : onDownload,
                icon: downloading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.picture_as_pdf_outlined),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the mint dialog collects.
class _MintRequest {
  const _MintRequest({
    required this.count,
    required this.label,
    this.assignToUserId,
  });

  final int count;
  final String label;

  /// Who the whole run goes to, or null to mint unassigned stock.
  final String? assignToUserId;
}

/// Count and label for a new run.
///
/// The label is REQUIRED, matching the backend schema, and the hint shows the
/// house shape ("Vendor A — Oct 2026, run 3"). A batch is a physical print run
/// somebody will have to identify months later out of a list of others.
class _MintDialog extends ConsumerStatefulWidget {
  const _MintDialog();

  @override
  ConsumerState<_MintDialog> createState() => _MintDialogState();
}

class _MintDialogState extends ConsumerState<_MintDialog> {
  final _formKey = GlobalKey<FormState>();
  final _countController = TextEditingController(text: '25');
  final _labelController = TextEditingController();

  /// Who the run goes to. Null is a real, ordinary choice — an admin who has
  /// not decided yet still needs the codes at the printer.
  String? _assignToUserId;

  @override
  void dispose() {
    _countController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_MintRequest(
      count: int.parse(_countController.text.trim()),
      label: _labelController.text.trim(),
      assignToUserId: _assignToUserId,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Mint a batch'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const ValueKey('admin_mint_label'),
              controller: _labelController,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Label',
                hintText: 'Vendor A — Oct 2026, run 3',
              ),
              validator: (value) => (value ?? '').trim().isEmpty
                  ? 'Give the run a name you will recognise later.'
                  : null,
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              key: const ValueKey('admin_mint_count'),
              controller: _countController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'How many codes'),
              validator: (value) {
                final n = int.tryParse((value ?? '').trim());
                if (n == null || n < 1) return 'Enter a whole number above 0.';
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.md),
            _AssigneeField(
              selectedId: _assignToUserId,
              onChanged: (id) => setState(() => _assignToUserId = id),
            ),
            const SizedBox(height: AppSpacing.md),
            const Text(
              // The one irreversible thing about this screen, said before the
              // button rather than after: the resolver origin is baked into
              // every URL these codes carry, and a wrong host is unrecoverable
              // once the codes are on paper.
              'Codes are permanent. Print a couple and scan them before '
              'ordering a full run.',
              style: TextStyle(
                fontSize: AppTypography.sizeLabel,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('admin_mint_submit'),
          onPressed: _submit,
          child: const Text('Mint'),
        ),
      ],
    );
  }
}

/// "Give the whole run to..." — the reason this dialog grew a third field.
///
/// BULK IS THE WHOLE POINT. Assigning standees one row at a time is fine for a
/// correction and absurd for a rep being sent out with twenty of them, and the
/// moment an admin actually knows who is carrying a batch is the moment they
/// are creating it.
///
/// A FAILED ROSTER MUST NOT BLOCK A MINT. The codes are going to a printer
/// whether or not we can name a holder today, and assignment is advisory — it
/// changes what each side SEES and gates nothing. So an error here degrades to
/// "assign them later" rather than taking the Mint button with it, which is
/// also why nobody-selected is the default rather than a validation failure.
class _AssigneeField extends ConsumerWidget {
  const _AssigneeField({required this.selectedId, required this.onChanged});

  final String? selectedId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reps = ref.watch(salesRepsProvider);

    return reps.when(
      loading: () => const _AssigneeNote('Loading staff...'),
      // No retry control: minting is the task, and the recovery for a roster
      // that would not load is to assign afterwards.
      error: (_, __) =>
          const _AssigneeNote('Staff list unavailable — you can assign later.'),
      data: (people) {
        if (people.isEmpty) {
          return const _AssigneeNote(
            'No staff accounts yet — you can assign later.',
          );
        }
        return DropdownButtonFormField<String?>(
          key: const ValueKey('admin_mint_assignee'),
          initialValue: selectedId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Give them all to'),
          dropdownColor: AppColors.surface2,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Nobody yet'),
            ),
            for (final person in people)
              DropdownMenuItem<String?>(
                value: person.id,
                child: Text(
                  person.person.label,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged,
        );
      },
    );
  }
}

/// Stands in for the picker when there is nobody to choose from, or not yet.
class _AssigneeNote extends StatelessWidget {
  const _AssigneeNote(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          message,
          style: const TextStyle(
            fontSize: AppTypography.sizeLabel,
            color: AppColors.textMuted,
          ),
        ),
      );
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
