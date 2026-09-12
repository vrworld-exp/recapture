// lib/presentation/screens/rep/rep_publish_screen.dart
//
// `/rep/catalogs/:id/publish` — the REP's publish screen, for a restaurant
// they are standing in.
//
// THE OWNER'S SCREEN, DELEGATED. The body is [PublishBody], the flow is
// [PublishFlow]; both are the ones behind `/catalog/publish`. A rep and the
// restaurant's owner watching the same run must see the same progress line,
// the same failure list and the same next action, and the way to make that
// true is for there to be one of each. What is the rep's here is only where a
// gate's "Fix" goes — the rep's own dish editor, add-dish and restaurant
// details screens, resolved from the catalog id in the path rather than from
// a token — and the words for a restaurant that is not theirs.
//
// NO "TAKE OFFLINE". A customer page going dark is the owner's decision; the
// rep's router has no unpublish route and the gateway says so, so the body
// hides the control rather than offering one that would answer 404.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../application/catalog/publish_flow.dart';
import '../../../application/connectivity/connectivity_providers.dart';
import '../../../application/rep/rep_publish_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/catalog/publish_gate.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/catalog_message.dart';
import '../../widgets/catalog/publish_body.dart';

class RepPublishScreen extends ConsumerStatefulWidget {
  const RepPublishScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  ConsumerState<RepPublishScreen> createState() => _RepPublishScreenState();
}

class _RepPublishScreenState extends ConsumerState<RepPublishScreen> {
  String get _catalogId => widget.catalogId;
  String get _base => '${AppRoutes.repCatalogs}/$_catalogId';

  /// Whether the rep has a screen that fixes [gate].
  ///
  /// Every gate with a fix label has one now. "Rename category" used to be the
  /// exception — the rep's section picker could create a section but not
  /// rename one — and the rep's category manager
  /// (`/rep/catalogs/:id/categories`) closed that. The body still asks, so a
  /// gate that grows a label before it grows a screen can be turned off here
  /// rather than offering a button that opens nothing.
  bool _canFix(PublishGate gate) => true;

  /// Sends the rep to whatever fixes [gate], then re-reads.
  ///
  /// The gates come back from the server on every status read, so returning
  /// from a fix and finding the row gone is the whole feedback loop — no local
  /// bookkeeping decides when a blocker is cleared.
  Future<void> _fix(PublishGate gate) async {
    final productId = gate.productId;
    switch (gate.code) {
      case PublishGateCode.catalogEmpty:
        await context.push('$_base/dishes/new');
      case PublishGateCode.catalogNameMissing:
        await context.push('$_base/details');
      case PublishGateCode.productAssetMissing:
      case PublishGateCode.productNameDuplicate:
      // The dish editor is where its section is picked, so a dish pointing at
      // a section the menu no longer has is fixed there too.
      case PublishGateCode.productCategoryUnknown:
        if (productId == null) return;
        await context.push('$_base/dishes/$productId');
      case PublishGateCode.categoryNameInvalid:
        await context.push('$_base/categories');
      // Nothing the rep can open would help: the preview image is generating,
      // the model is not finished, or publishing is off on this deployment.
      case PublishGateCode.productThumbnailMissing:
      case PublishGateCode.productModelNotReady:
      case PublishGateCode.publishingUnavailable:
      case PublishGateCode.unknown:
        return;
    }
    if (!mounted) return;
    await ref.read(repPublishProvider(_catalogId).notifier).refresh();
  }

  /// Opens the preview, which shows the SAME warnings against the dishes they
  /// are about — the checklist says what is wrong, the preview shows where.
  Future<void> _openPreview() async {
    await context.push('$_base/preview');
    if (!mounted) return;
    await ref.read(repPublishProvider(_catalogId).notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final provider = repPublishProvider(_catalogId);
    final state = ref.watch(provider);
    final isOnline = ref.watch(isOnlineProvider);

    // A notice or a failure is a RESULT, and a result the rep does not see is
    // the same as no result at all.
    ref.listen<PublishScreenState>(provider, (previous, next) {
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
          subject: 'The menu could not be published',
        );
      } else if (next.notice != null) {
        CatalogFeedback.confirm(messenger, next.notice!);
      }
    });

    // Started and finished, said out loud — only on a transition this screen
    // actually WATCHED, for the reasons the owner's screen gives.
    ref.listen<PublishScreenState>(provider, (previous, next) {
      final before = previous?.status.valueOrNull;
      final after = next.status.valueOrNull;
      if (before == null || after == null) return;

      final toast = publishTransitionToast(
        before: before,
        after: after,
        liveLine: 'The menu is live. Scan the standee to see it.',
        offlineLine: 'The menu is offline.',
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
        title: Text(
          'Publish the menu',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      body: RefreshIndicator(
        color: AppColors.mirageRed,
        backgroundColor: AppColors.surface1,
        onRefresh: () => ref.read(provider.notifier).refresh(),
        child: state.status.when(
          loading: () => const Center(child: AppLoadingIndicator()),
          error: (error, _) => CatalogMessage(
            icon: Icons.cloud_off_outlined,
            title: "We couldn't check this menu",
            body: error is CatalogFailure
                ? CatalogFeedback.failureText(error)
                : CatalogFeedback.textForCode(null),
            actionLabel: 'Try again',
            onAction: () => ref.read(provider.notifier).reload(),
          ),
          data: (status) => PublishBody(
            state: state,
            status: status,
            isOnline: isOnline,
            voice: PublishVoice.rep,
            onPublish: () => ref.read(provider.notifier).publish(),
            onRetryFailed: () => ref.read(provider.notifier).retryFailed(),
            // No onUnpublish: see the file header.
            onFixGate: _fix,
            canFix: _canFix,
            onOpenPreview: _openPreview,
            onRename: (name) =>
                ref.read(provider.notifier).renameAndPublish(name),
            onOpenQr: () => context.push('$_base/qr'),
          ),
        ),
      ),
    );
  }
}
