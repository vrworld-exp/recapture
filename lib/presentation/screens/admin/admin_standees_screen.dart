// lib/presentation/screens/admin/admin_standees_screen.dart
//
// Standee inventory: every mint run, and how much of each is still in the box.
//
// The list answers ONE question — "have we got codes left to hand out" — so the
// row leads with what is available rather than with the run's size. An admin
// opens this because a rep is about to go out, not to audit a print order.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/admin/admin_standees_notifier.dart';
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
          subject: 'The batch could not be minted',
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
                    itemBuilder: (_, i) => _BatchTile(batch: batches[i]),
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
        );
    if (batchId == null || !context.mounted) return;
    context.push('${AppRoutes.adminStandees}/$batchId');
  }
}

class _BatchTile extends StatelessWidget {
  const _BatchTile({required this.batch});

  final QrBatchSummary batch;

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
  const _MintRequest({required this.count, required this.label});

  final int count;
  final String label;
}

/// Count and label for a new run.
///
/// The label is REQUIRED, matching the backend schema, and the hint shows the
/// house shape ("Vendor A — Oct 2026, run 3"). A batch is a physical print run
/// somebody will have to identify months later out of a list of others.
class _MintDialog extends StatefulWidget {
  const _MintDialog();

  @override
  State<_MintDialog> createState() => _MintDialogState();
}

class _MintDialogState extends State<_MintDialog> {
  final _formKey = GlobalKey<FormState>();
  final _countController = TextEditingController(text: '25');
  final _labelController = TextEditingController();

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
