// lib/presentation/screens/catalog/publish_screen.dart
//
// `/catalog/publish` — the screen the phase exists for (features 36-39, 52, 53,
// 68, 69).
//
// IT IS BUILT AROUND PARTIAL FAILURE. Publishing ten products is ten sequential
// unbatched uploads against a server that may be waking from a sleeping tier,
// so "seven of ten went live" is the ORDINARY outcome, not the exceptional one.
// A screen that only knows "publishing…" and "done" leaves the user with three
// products missing from their menu and no way to find out which, so the failure
// list, the per-product reasons and the one-tap retry are the main event here,
// not an error path bolted on the side.
//
// FOUR RULES THIS FILE DOES NOT BEND:
//   1. The client holds NO publish state. Every number comes from the status
//      endpoint (see publish_notifier.dart).
//   2. No raw upstream text. Failure sentences are looked up from the code by
//      `sync_error_copy.dart`; the payload's own message is never parsed.
//   3. `publicUrl` is displayed verbatim and never composed, normalised or
//      rebuilt — every printed QR resolves through it.
//   4. Never let the user press Publish into a guaranteed failure. The gate
//      checklist is the server's own, and each row goes to the fix.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/publish_notifier.dart';
import '../../../application/connectivity/connectivity_providers.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/publish_gate.dart';
import '../../../domain/catalog/publish_status.dart';
import '../../../domain/entities/catalog_status.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/app_status_pill.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/publish_link_actions.dart';

/// Above this width the screen keeps its content in one readable column rather
/// than stretching a checklist across a desktop monitor. Decided from
/// CONSTRAINTS, never from `kIsWeb`.
const double kPublishContentMaxWidth = 640;

class PublishScreen extends ConsumerStatefulWidget {
  const PublishScreen({super.key});

  @override
  ConsumerState<PublishScreen> createState() => _PublishScreenState();
}

class _PublishScreenState extends ConsumerState<PublishScreen> {
  /// Sends the user to whatever fixes [gate], then re-reads.
  ///
  /// The gates come back from the server on every status read, so returning
  /// from a fix and finding the row gone is the whole feedback loop — no local
  /// bookkeeping decides when a blocker is cleared.
  Future<void> _fix(PublishGate gate) async {
    final productId = gate.productId;
    switch (gate.code) {
      case PublishGateCode.catalogEmpty:
        await context.pushNamed(AppRouteNames.productNew);
      case PublishGateCode.catalogNameMissing:
        await context.pushNamed(AppRouteNames.catalogSettings);
      case PublishGateCode.productAssetMissing:
      case PublishGateCode.productNameDuplicate:
        if (productId == null) return;
        await context.pushNamed(
          AppRouteNames.productDetail,
          pathParameters: {'productId': productId},
        );
      // Nothing the user can open would help: the preview image is generating,
      // the model is not finished, or publishing is off on this deployment.
      case PublishGateCode.productThumbnailMissing:
      case PublishGateCode.productModelNotReady:
      case PublishGateCode.publishingUnavailable:
      case PublishGateCode.unknown:
        return;
    }
    if (!mounted) return;
    await ref.read(publishProvider.notifier).refresh();
  }

  /// Opens the preview, which shows the SAME warnings against the products they
  /// are about — the checklist says what is wrong, the preview shows where.
  Future<void> _openPreview() async {
    await context.pushNamed(AppRouteNames.catalogPreview);
    if (!mounted) return;
    await ref.read(publishProvider.notifier).refresh();
  }

  Future<void> _confirmUnpublish() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: const Text('Take your catalog offline?'),
        // THE SECOND SENTENCE IS THE POINT. A business that has printed
        // stickers, put them on tables and paid for the printing needs to know
        // this is reversible before they can press it — and it genuinely is:
        // the Mirage restaurant, its id and the public URL all survive an
        // unpublish, so republishing restores the same page at the same link.
        content: const Text(
          'Customers who scan your QR code will see that the catalog is not '
          'available.\n\n'
          'Your QR code and link keep working — they will show your catalog '
          'again as soon as you publish.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it live'),
          ),
          TextButton(
            key: const ValueKey('publish_unpublish_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Take offline'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await ref.read(publishProvider.notifier).unpublish();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(publishProvider);
    final isOnline = ref.watch(isOnlineProvider);

    // A notice or a failure is a RESULT, and a result the user does not see is
    // the same as no result at all.
    ref.listen<PublishScreenState>(publishProvider, (previous, next) {
      // Compared on the CODE, not on the rendered sentence: two different codes
      // can map to the same words, and the second one is still news.
      final failure = next.actionFailure;
      final changed = failure?.code != previous?.actionFailure?.code ||
          next.notice != previous?.notice;
      if (!changed) return;

      final messenger = CatalogFeedback.of(context);
      if (failure != null) {
        CatalogFeedback.failure(
          messenger,
          failure,
          subject: 'Your catalog could not be published',
        );
      } else if (next.notice != null) {
        // A notice is OURS — written here, in this build, for a non-failure
        // outcome the user still has to be told about.
        CatalogFeedback.confirm(messenger, next.notice!);
      }
    });

    // Started and finished, said out loud (features 68, 69).
    //
    // The progress card on this screen already SHOWS both, so why a toast: a
    // run outlives the screen. "Publishing started" is the sentence that tells
    // the user they may leave, and "finished" is the one they get if they came
    // back and the card has already settled into its resting state. Both fire
    // only on a transition this screen actually WATCHED — a screen opened onto
    // a run already in flight announces nothing, because nothing happened while
    // anyone was looking.
    ref.listen<PublishScreenState>(publishProvider, (previous, next) {
      final before = previous?.status.valueOrNull;
      final after = next.status.valueOrNull;
      if (before == null || after == null) return;

      final wasRunning = before.isPublishing;
      final isRunning = after.isPublishing;
      if (wasRunning == isRunning) return;

      final messenger = CatalogFeedback.of(context);
      if (isRunning) {
        CatalogFeedback.confirm(
          messenger,
          after.run?.mode.isUnpublish ?? false
              ? 'Taking your catalog offline. This keeps going if you leave.'
              : 'Publishing started. This keeps going if you leave this screen.',
        );
        return;
      }

      // Finished. WHICH ending it was, not just that it ended — "done" over a
      // run that failed half its products is the message that stops someone
      // ever looking at the list below.
      final counts = before.run?.counts ?? after.run?.counts;
      final failed = counts?.failed ?? 0;
      CatalogFeedback.confirm(
        messenger,
        switch ((after.isLive, failed)) {
          (_, > 0) =>
            '$failed of ${counts?.total ?? failed} could not be published. '
                'Retry them below.',
          (true, _) => 'Your catalog is live.',
          (false, _) => 'Your catalog is offline.',
        },
      );
    });

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => navigateBack(context),
        ),
        title: Text('Publish', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: RefreshIndicator(
        color: AppColors.mirageRed,
        backgroundColor: AppColors.surface1,
        onRefresh: () => ref.read(publishProvider.notifier).refresh(),
        child: state.status.when(
          loading: () => const Center(child: AppLoadingIndicator()),
          error: (error, _) => CatalogMessage(
            icon: Icons.cloud_off_outlined,
            title: "We couldn't check your catalog",
            body: error is CatalogFailure
                ? CatalogFeedback.failureText(error)
                : CatalogFeedback.textForCode(null),
            actionLabel: 'Try again',
            onAction: () => ref.read(publishProvider.notifier).reload(),
          ),
          data: (status) => _Body(
            state: state,
            status: status,
            isOnline: isOnline,
            onPublish: () => ref.read(publishProvider.notifier).publish(),
            onRetryFailed: () =>
                ref.read(publishProvider.notifier).retryFailed(),
            onUnpublish: _confirmUnpublish,
            onFixGate: _fix,
            onOpenPreview: _openPreview,
            onRename: (name) =>
                ref.read(publishProvider.notifier).renameAndPublish(name),
            onOpenQr: () => context.pushNamed(AppRouteNames.catalogQr),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.state,
    required this.status,
    required this.isOnline,
    required this.onPublish,
    required this.onRetryFailed,
    required this.onUnpublish,
    required this.onFixGate,
    required this.onOpenPreview,
    required this.onRename,
    required this.onOpenQr,
  });

  final PublishScreenState state;
  final PublishStatus status;
  final bool isOnline;
  final VoidCallback onPublish;
  final VoidCallback onRetryFailed;
  final VoidCallback onUnpublish;
  final ValueChanged<PublishGate> onFixGate;
  final VoidCallback onOpenPreview;
  final ValueChanged<String> onRename;
  final VoidCallback onOpenQr;

  @override
  Widget build(BuildContext context) {
    final run = status.run;
    final inFlight = status.isPublishing || (run?.state.isInFlight ?? false);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        0,
        AppSpacing.screenPadding,
        AppSpacing.xxxl,
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: kPublishContentMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusCard(status: status),

                if (!isOnline) ...[
                  const SizedBox(height: AppSpacing.md),
                  const _Banner(
                    key: ValueKey('publish_offline_banner'),
                    icon: Icons.wifi_off_outlined,
                    color: AppColors.textMuted,
                    // Disabled with a reason beats a button that fires a
                    // request guaranteed to fail and reports it as an error the
                    // user might think they caused.
                    title: "You're offline",
                    body: 'Publishing needs a connection. Reconnect and this '
                        'page will pick up where it left off.',
                  ),
                ],

                if (state.suggestedName case final suggested?) ...[
                  const SizedBox(height: AppSpacing.md),
                  _NameTakenCard(
                    suggested: suggested,
                    busy: state.isRequesting,
                    onRename: onRename,
                  ),
                ],

                if (inFlight) ...[
                  const SizedBox(height: AppSpacing.md),
                  _RunProgress(status: status, paused: state.isPollingPaused),
                ],

                if (!inFlight && status.failures.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  _FailureCard(
                    status: status,
                    busy: state.isRequesting,
                    onRetryFailed: isOnline ? onRetryFailed : null,
                  ),
                ],

                if (!inFlight && status.isLive && status.failures.isEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  _SuccessCard(status: status, onOpenQr: onOpenQr),
                ],

                if (status.gates.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  _GateChecklist(
                    gates: status.gates,
                    onFix: onFixGate,
                    onOpenPreview: onOpenPreview,
                  ),
                ],

                const SizedBox(height: AppSpacing.xl),
                _Actions(
                  state: state,
                  status: status,
                  isOnline: isOnline,
                  inFlight: inFlight,
                  onPublish: onPublish,
                  onUnpublish: onUnpublish,
                ),

                if (status.products.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xxl),
                  _ProductList(products: status.products),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Where the catalog stands: live or not, when it last went out, and whether
/// the draft has moved since.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final PublishStatus status;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _Chip(
                label: status.status.label,
                color:
                    status.isLive ? AppColors.success : AppColors.textMuted,
              ),
              // Feature 38. Server-DERIVED — never recomputed here, and true
              // after a partial run because some products genuinely are not
              // live.
              if (status.hasDraftChanges)
                const _Chip(
                  label: 'Draft changes not yet live',
                  color: AppColors.warning,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            status.lastPublishedAt == null
                ? 'This catalog has never been published.'
                : 'Last published ${_ago(status.lastPublishedAt!)}.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// A run in flight: the counts, the bar, and an honest word about staleness.
class _RunProgress extends StatelessWidget {
  const _RunProgress({required this.status, required this.paused});

  final PublishStatus status;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final run = status.run;
    final counts = run?.counts ?? const PublishRunCounts();
    final unpublishing = run?.mode.isUnpublish ?? false;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border:
            Border.all(color: AppColors.royalGold.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // Taking a catalog offline reads nothing like putting it online.
            unpublishing ? 'Taking your catalog offline…' : 'Publishing…',
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            counts.total > 0
                ? '${counts.synced} of ${counts.total} published'
                : 'Getting your catalog ready…',
            key: const ValueKey('publish_progress_counts'),
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: LinearProgressIndicator(
              // Null renders indeterminate: a determinate bar pinned at zero
              // while the planner works reads as "stuck", not as "starting".
              value: counts.progress,
              minHeight: 6,
              backgroundColor: AppColors.surface2,
              color: AppColors.mirageRed,
            ),
          ),
          if (counts.failed > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              '${counts.failed} failed so far — you can retry them when this '
              'run finishes.',
              style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
            ),
          ],
          if (paused) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              // Says the numbers are old rather than quietly showing old ones.
              'Paused while this tab is in the background. It will catch up '
              'the moment you come back.',
              key: const ValueKey('publish_paused_note'),
              style:
                  textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// A finished run that left work undone (features 53, 68).
class _FailureCard extends StatelessWidget {
  const _FailureCard({
    required this.status,
    required this.busy,
    required this.onRetryFailed,
  });

  final PublishStatus status;
  final bool busy;

  /// Null disables the retry — offline, with the reason already on screen.
  final VoidCallback? onRetryFailed;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final failures = status.failures;
    final published = status.published.length;
    final total = status.products.length;
    final everything = published == 0;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // The honest headline in both shapes. With nothing published the
            // catalog is NOT live, and saying "0 of 10 published" while a
            // success card sat above it would be the worst of both.
            everything
                ? "Nothing was published — none of your $total "
                    '${total == 1 ? 'product' : 'products'} went live'
                : '$published of $total published · '
                    '${failures.length} failed',
            key: const ValueKey('publish_failure_headline'),
            style: textTheme.titleMedium?.copyWith(color: AppColors.error),
          ),
          const SizedBox(height: AppSpacing.md),
          for (final failure in failures)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: _FailureRow(product: failure),
            ),
          AppButton(
            key: const ValueKey('publish_retry_failed'),
            label: 'Retry failed',
            icon: Icons.refresh,
            isLoading: busy,
            onPressed: onRetryFailed,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            // Retry is scoped server-side to the FAILED rows, which is why
            // pressing it after "8 of 10" is cheap.
            'Only the failed products are tried again.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// One failed product: its name, OUR sentence, and the next action.
class _FailureRow extends StatelessWidget {
  const _FailureRow({required this.product});

  final PublishProductStatus product;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Looked up from the CODE. The payload's own message is never parsed, so
    // upstream prose has no field it could have arrived in.
    final copy = product.failureCopy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(product.name, style: textTheme.bodyMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          copy.message,
          style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
        ),
        if (copy.action case final action?)
          Text(
            action,
            style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
          ),
      ],
    );
  }
}

/// Live on Mirage (feature 69).
class _SuccessCard extends ConsumerWidget {
  const _SuccessCard({required this.status, required this.onOpenQr});

  final PublishStatus status;
  final VoidCallback onOpenQr;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final url = status.publicUrl;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle,
                  size: 18, color: AppColors.success),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Live on Mirage',
                style: textTheme.titleMedium?.copyWith(
                  color: AppColors.success,
                ),
              ),
            ],
          ),
          if (url != null && url.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            SelectableText(
              // VERBATIM. Not shortened, not prettified, not re-cased: this is
              // what every printed QR resolves through.
              url,
              key: const ValueKey('publish_public_url'),
              style: textTheme.bodySmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            PublishLinkActions(url: url),
            const SizedBox(height: AppSpacing.sm),
            AppButton.secondary(
              key: const ValueKey('publish_open_qr'),
              label: 'View QR code',
              icon: Icons.qr_code_2,
              isFullWidth: false,
              onPressed: onOpenQr,
            ),
          ],
        ],
      ),
    );
  }
}

/// The pre-flight checklist — the server's own gates, each with the way to fix
/// it (feature 36).
class _GateChecklist extends StatelessWidget {
  const _GateChecklist({
    required this.gates,
    required this.onFix,
    required this.onOpenPreview,
  });

  final List<PublishGate> gates;
  final ValueChanged<PublishGate> onFix;
  final VoidCallback onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      key: const ValueKey('publish_gate_checklist'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Before you can publish',
            style: textTheme.titleMedium?.copyWith(color: AppColors.warning),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'This is the same check the server runs, so fixing everything here '
            'is enough.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          for (final gate in gates)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    gate.code.resolvesItself
                        ? Icons.hourglass_empty
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: gate.code.resolvesItself
                        ? AppColors.textMuted
                        : AppColors.warning,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    // The backend's own sentence. Gates are computed purely
                    // from ReCapture rows — Mirage is never consulted to build
                    // one — so there is no upstream prose to strip.
                    child: Text(gate.message, style: textTheme.bodySmall),
                  ),
                  if (gate.code.fixLabel case final label?) ...[
                    const SizedBox(width: AppSpacing.sm),
                    TextButton(
                      onPressed: () => onFix(gate),
                      child: Text(label),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          AppButton.secondary(
            key: const ValueKey('publish_open_preview'),
            label: 'See them in preview',
            icon: Icons.visibility_outlined,
            isFullWidth: false,
            onPressed: onOpenPreview,
          ),
        ],
      ),
    );
  }
}

/// A Mirage name collision, with the way out (edge case: unprovisioned catalog
/// whose name is taken).
class _NameTakenCard extends StatelessWidget {
  const _NameTakenCard({
    required this.suggested,
    required this.busy,
    required this.onRename,
  });

  final String suggested;
  final bool busy;
  final ValueChanged<String> onRename;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const ValueKey('publish_name_taken'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'That catalog name is already taken',
            style: textTheme.titleMedium?.copyWith(color: AppColors.warning),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Catalog names have to be unique. We can rename yours to '
            '"$suggested" and publish.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            key: const ValueKey('publish_accept_suggested_name'),
            label: 'Use "$suggested" and publish',
            isLoading: busy,
            onPressed: () => onRename(suggested),
          ),
        ],
      ),
    );
  }
}

/// Publish, and — once there is something live — the way to take it down.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.state,
    required this.status,
    required this.isOnline,
    required this.inFlight,
    required this.onPublish,
    required this.onUnpublish,
  });

  final PublishScreenState state;
  final PublishStatus status;
  final bool isOnline;
  final bool inFlight;
  final VoidCallback onPublish;
  final VoidCallback onUnpublish;

  @override
  Widget build(BuildContext context) {
    // Every reason the button is off, in the order the user would discover
    // them. `null` onPressed is the theme's disabled state — there is no path
    // here that fires a request we already know will be refused.
    final blocked = !isOnline || inFlight || !state.canPublish;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppButton(
          key: const ValueKey('publish_cta'),
          label: inFlight
              ? 'Publishing…'
              : status.lastPublishedAt == null
                  ? 'Publish catalog'
                  : 'Publish changes',
          icon: Icons.cloud_upload_outlined,
          isLoading: state.isRequesting || inFlight,
          onPressed: blocked ? null : onPublish,
        ),
        if (status.hasPublicUrl && status.isLive) ...[
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            key: const ValueKey('publish_unpublish'),
            onPressed: inFlight || state.isRequesting ? null : onUnpublish,
            child: const Text('Take catalog offline'),
          ),
        ],
      ],
    );
  }
}

/// Every product with where it stands (feature 52).
///
/// `showWhenNeverPublished` is on here and nowhere else: on a product card in
/// the grid, "Not published" on every row of a catalog nobody has published is
/// noise — on THIS screen the absence is exactly the information.
class _ProductList extends StatelessWidget {
  const _ProductList({required this.products});

  final List<PublishProductStatus> products;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Products', style: textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        for (final product in products)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    product.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      color: product.hasFailed
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                SyncStatusPill(
                  status: product.syncStatus,
                  showWhenNeverPublished: true,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: textTheme.bodyMedium?.copyWith(color: color)),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  body,
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      );
}

/// Coarse relative time. Deliberately coarse: the exact minute a catalog went
/// live is not a thing anyone needs, and this app carries no `intl` dependency
/// to format a real date with.
String _ago(DateTime when) {
  final delta = DateTime.now().toUtc().difference(when.toUtc());
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) {
    return '${delta.inHours} ${delta.inHours == 1 ? 'hour' : 'hours'} ago';
  }
  return '${delta.inDays} ${delta.inDays == 1 ? 'day' : 'days'} ago';
}
