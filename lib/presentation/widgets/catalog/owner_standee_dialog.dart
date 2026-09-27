// lib/presentation/widgets/catalog/owner_standee_dialog.dart
//
// The owner's "Download standee": how many, out of what the plan has left.
//
// IT RETURNS A NUMBER, NOT A FILE — the same split as `standee_copies_dialog`.
// The caller runs the download through [ownerStandeeProvider], so the spinner
// and any failure land on the screen that was pressed rather than inside a
// dialog that is already gone.
//
// The ceiling is the plan's REMAINING allowance, read fresh as the dialog
// opens. It is what the user is told and what the field accepts; the server
// checks it again in the write that spends it.
//
// Two helpers sit beside the dialog so the catalog header and the QR screen
// start the download and report on it identically:
// [startOwnerStandeeDownload] and [listenOwnerStandee].
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/catalog/owner_standee_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../app_button.dart';
import '../app_loading_indicator.dart';
import 'catalog_feedback.dart';

/// Asks how many, then downloads them. Does nothing if the user backs out.
Future<void> startOwnerStandeeDownload(
  BuildContext context,
  WidgetRef ref,
) async {
  if (ref.read(ownerStandeeProvider).busy) return;
  // Read fresh: the header may have been built before the last download.
  ref.invalidate(standeeQuotaProvider);
  final copies = await showDialog<int>(
    context: context,
    builder: (_) => const OwnerStandeeDialog(),
  );
  if (copies == null) return;
  await ref.read(ownerStandeeProvider.notifier).download(copies);
}

/// Shows the download's outcome on [context]'s messenger. Call from `build`.
void listenOwnerStandee(BuildContext context, WidgetRef ref) {
  ref.listen<OwnerStandeeState>(ownerStandeeProvider, (previous, next) {
    if (next.busy) return;
    // The catalog screen stays mounted under the QR screen and listens too;
    // only the one on top reports, or the owner reads every toast twice.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final messenger = CatalogFeedback.of(context);
    final failure = next.failure;
    if (failure != null && failure != previous?.failure) {
      CatalogFeedback.failure(
        messenger,
        failure,
        subject: 'Your standees could not be downloaded',
        // Only a counted-but-unsaved file gets a retry: it spends nothing.
        // A refusal from the server gets the same answer on every press.
        onRetry: next.unsaved == null
            ? null
            : () => ref.read(ownerStandeeProvider.notifier).saveAgain(),
        retryLabel: 'Save again',
      );
    } else if (next.notice != null && next.notice != previous?.notice) {
      CatalogFeedback.confirm(messenger, next.notice!);
    }
  });
}

class OwnerStandeeDialog extends ConsumerStatefulWidget {
  const OwnerStandeeDialog({super.key});

  @override
  ConsumerState<OwnerStandeeDialog> createState() => _OwnerStandeeDialogState();
}

class _OwnerStandeeDialogState extends ConsumerState<OwnerStandeeDialog> {
  final _controller = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? _copiesFor(StandeeQuota quota) {
    final n = int.tryParse(_controller.text.trim());
    if (n == null || n < 1 || n > quota.remaining) return null;
    return n;
  }

  void _step(StandeeQuota quota, int delta) {
    final current = int.tryParse(_controller.text.trim()) ?? 1;
    _controller.text = '${(current + delta).clamp(1, quota.remaining)}';
  }

  @override
  Widget build(BuildContext context) {
    final quota = ref.watch(standeeQuotaProvider);
    final ready = quota.valueOrNull;
    final printable = ready != null && ready.isLive && ready.canDownload;
    final copies = printable ? _copiesFor(ready) : null;

    return AlertDialog(
      backgroundColor: AppColors.surface1,
      title: const Text('Download standee'),
      content: SingleChildScrollView(
        child: quota.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Center(child: AppLoadingIndicator()),
          ),
          error: (error, _) => _QuotaFailed(
            failure: error is CatalogFailure ? error : null,
            onRetry: () => ref.invalidate(standeeQuotaProvider),
          ),
          data: (quota) => printable
              ? _Picker(
                  quota: quota,
                  copies: copies,
                  controller: _controller,
                  onStep: (delta) => _step(quota, delta),
                )
              : _Unavailable(quota: quota),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('owner_standee_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(printable ? 'Cancel' : 'Close'),
        ),
        if (printable)
          TextButton(
            key: const ValueKey('owner_standee_download'),
            onPressed:
                copies == null ? null : () => Navigator.of(context).pop(copies),
            child: const Text('Download'),
          ),
      ],
    );
  }
}

class _Picker extends StatelessWidget {
  const _Picker({
    required this.quota,
    required this.copies,
    required this.controller,
    required this.onStep,
  });

  final StandeeQuota quota;
  final int? copies;
  final TextEditingController controller;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    final left = quota.remaining;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$left of ${quota.included} standees left on your plan.',
          key: const ValueKey('owner_standee_left'),
          style: const TextStyle(
            fontSize: AppTypography.sizeBody,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            IconButton(
              key: const ValueKey('owner_standee_minus'),
              tooltip: 'One fewer',
              onPressed: () => onStep(-1),
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: TextField(
                key: const ValueKey('owner_standee_field'),
                controller: controller,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'How many standees',
                  errorText: copies == null
                      ? (left == 1
                          ? 'You have 1 standee left.'
                          : 'Enter a number from 1 to $left.')
                      : null,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('owner_standee_plus'),
              tooltip: 'One more',
              onPressed: () => onStep(1),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        // Said BEFORE the press: the count is spent on download, and there is
        // no way to hand one back from the app.
        const Text(
          'Each standee is one A4 page with your QR code. Downloading uses '
          'them from your plan, even if you download the same QR again.',
          style: TextStyle(
            fontSize: AppTypography.sizeLabel,
            color: AppColors.textMuted,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// Why there is nothing to download — each reason says what would change it.
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.quota});

  final StandeeQuota quota;

  String get _sentence {
    if (!quota.isLive) {
      return 'Standees can be downloaded while your catalog is live. '
          'Publish it first.';
    }
    if (quota.included == 0) {
      return "Your plan doesn't include standees. Choose a plan to get them.";
    }
    if (quota.remaining == 0) {
      return "You've downloaded all ${quota.included} standees on your plan. "
          'Upgrade your plan for more.';
    }
    return "Your plan isn't active right now, so standees can't be "
        'downloaded. Renew it to download the '
        '${quota.remaining} you have left.';
  }

  @override
  Widget build(BuildContext context) => Text(
        _sentence,
        key: const ValueKey('owner_standee_unavailable'),
        style: const TextStyle(
          fontSize: AppTypography.sizeBody,
          color: AppColors.textSecondary,
        ),
      );
}

class _QuotaFailed extends StatelessWidget {
  const _QuotaFailed({required this.failure, required this.onRetry});

  final CatalogFailure? failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            CatalogFeedback.textForCode(
              failure?.code,
              subject: "Your standees couldn't be checked",
            ),
            style: const TextStyle(
              fontSize: AppTypography.sizeBody,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppButton.secondary(
            key: const ValueKey('owner_standee_retry'),
            label: 'Try again',
            onPressed: onRetry,
          ),
        ],
      );
}
