// lib/presentation/screens/catalog/publish_screen.dart
//
// `/catalog/publish` — the OWNER's publish screen (features 36-39, 52, 53, 68,
// 69).
//
// The body — the cards, the checklist, the progress line, the actions — is
// [PublishBody], shared with the rep's `/rep/catalogs/:id/publish`. What is
// the owner's here: where a gate's "Fix" goes (their own product, settings and
// category screens), the confirmation before taking the page offline, and the
// words for a run that was theirs.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../application/catalog/publish_notifier.dart';
import '../../../application/connectivity/connectivity_providers.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/publish_gate.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/publish_body.dart';

export '../../widgets/catalog/publish_body.dart' show kPublishContentMaxWidth;

class PublishScreen extends ConsumerStatefulWidget {
  const PublishScreen({super.key, this.startPublish = false});

  /// Opened by a button that SAID Publish: start the run as soon as the
  /// status says it can. See [kPublishStartQuery].
  final bool startPublish;

  @override
  ConsumerState<PublishScreen> createState() => _PublishScreenState();
}

class _PublishScreenState extends ConsumerState<PublishScreen> {
  /// The auto-start is one attempt per open, decided on the first status
  /// that arrives — a second look would republish after the user cancelled
  /// or after a run they watched finish.
  bool _autoStartDecided = false;

  /// Fires the publish the opening button asked for, once, when the screen
  /// can. Called from build, so the request itself is deferred a frame: a
  /// notifier must not be written while the tree that watches it is building.
  void _maybeAutoStart(PublishScreenState state, bool isOnline) {
    if (!widget.startPublish || _autoStartDecided) return;
    if (!state.status.hasValue) return; // still loading — ask next build
    _autoStartDecided = true;
    if (!publishAutoStartReady(state: state, isOnline: isOnline)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(publishProvider.notifier).publish();
    });
  }

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
      // The product's own screen is where its category is picked, so a product
      // pointing at a category the catalog no longer has is fixed there too.
      case PublishGateCode.productCategoryUnknown:
        if (productId == null) return;
        await context.pushNamed(
          AppRouteNames.productDetail,
          pathParameters: {'productId': productId},
        );
      case PublishGateCode.categoryNameInvalid:
        await context.pushNamed(AppRouteNames.catalogCategories);
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
    _maybeAutoStart(state, isOnline);

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

      final toast = publishTransitionToast(
        before: before,
        after: after,
        liveLine: 'Your catalog is live.',
        offlineLine: 'Your catalog is offline.',
      );
      if (toast != null) {
        CatalogFeedback.confirm(CatalogFeedback.of(context), toast);
      }
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
          data: (status) => PublishBody(
            state: state,
            status: status,
            isOnline: isOnline,
            voice: PublishVoice.owner,
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
