// lib/presentation/screens/admin/admin_batch_detail_screen.dart
//
// One batch's codes, and the two ways a code leaves the building.
//
// PER CODE — a printable PDF sheet the admin sends to a rep, who prints it and
// puts it on a table. This is the PILOT path: it needs no print vendor, and the
// QR it renders is byte-identical to the one a vendor would print, because both
// come from the same server-side composer.
//
// PER BATCH — the vendor CSV, unchanged since stage 2.
//
// A retired code offers NEITHER. Reprinting one produces a sheet that resolves
// to the fallback page, and the whole cost of that lands after somebody has
// printed it and stood it on a table.
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
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

class _CodeTile extends StatelessWidget {
  const _CodeTile({
    required this.code,
    required this.busy,
    required this.onSend,
  });

  final QrStandeeCode code;
  final bool busy;

  /// Null for a code that must not be printed — the button is ABSENT rather
  /// than disabled, matching the rep surface's rule: an affordance you do not
  /// have should be invisible, not greyed.
  final VoidCallback? onSend;

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
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (onSend != null)
            IconButton(
              tooltip: 'Save a printable standee',
              onPressed: onSend,
              // NEUTRAL BY TARGET, like the word "Save" the catalog QR screen
              // uses. On a phone this opens a share sheet; in a browser it is a
              // plain download. An iOS share glyph would be a lie in Chrome,
              // and the seam already hides which one is happening.
              icon: const Icon(Icons.save_alt),
              color: AppColors.textSecondary,
            ),
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
