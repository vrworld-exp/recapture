// lib/presentation/screens/rep/rep_catalog_detail_screen.dart
//
// One delegated restaurant's dishes, while the rep is still at the table.
//
// THE SCREEN'S REASON TO EXIST IS THE BADGE. A rep adds a dish, captures it,
// comes back here, and watches it flip from "3D generating…" to "AR ready"
// without pulling to refresh — that flip is the whole promise of the visit, and
// a rep who cannot see it happen leaves not knowing whether it worked. The poll
// loop behind it is the app's shared cadence (see PendingPollLoop), stops the
// moment nothing is pending, and dies with this screen.
//
// ADD-DISH DEEP-LINKS INTO THE EXISTING CAPTURE FLOW, UNMODIFIED. There is no
// rep-specific capture path and there must not be one: a forked flow is a
// second implementation of the hardest screen in the app, and it is the one
// nobody would keep in step.
//
// THREE WAYS OUT OF THIS SCREEN, AND EACH ANSWERS A DIFFERENT QUESTION:
//   • a dish row  → 'is this one right?'          → the dish editor
//   • Preview     → 'is the PAGE right?'          → the customer-eye preview
//   • Details     → 'is the RESTAURANT right?'    → name, contact, branding
// Until they existed a rep could add dishes and publish, and could not fix a
// single thing they had got wrong — the owner had to sign in later and do it,
// which on a pilot visit means the page goes live wrong or does not go live.
//
// AND EVERY ONE OF THOSE EDITS LANDS IN A DRAFT, WHICH THE BOTTOM BAR NOW SAYS.
// Renaming a dish, replacing its photo or model, changing the restaurant's own
// name or branding — none of it reaches a customer until a publish. The bar
// used to be a single button reading "Publish the menu" whether there were
// twenty unsent edits behind it or none, so a rep who corrected a price and
// walked out had nothing on screen telling them the correction was still in
// the draft. See [_PublishBar].
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/rep/rep_catalogs_notifier.dart';
import '../../../application/rep/rep_publish_notifier.dart';
import '../../../application/rep/rep_restaurant_notifier.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../../domain/entities/catalog.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/catalog_status.dart';
import '../../../domain/entities/product_model_status.dart';
import '../../../utils/extensions.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';

class RepCatalogDetailScreen extends ConsumerWidget {
  const RepCatalogDetailScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(repCatalogProductsProvider(catalogId));

    ref.listen<RepPublishState>(repPublishProvider(catalogId), (prev, next) {
      final failure = next.failure;
      final changed = failure?.code != prev?.failure?.code ||
          next.notice != prev?.notice;
      if (!changed) return;

      final messenger = CatalogFeedback.of(context);
      if (next.isBlocked) {
        // The gate list, not a generic sentence: these are the things the rep
        // can still fix while standing in the restaurant.
        CatalogFeedback.confirm(
          messenger,
          next.gates.length == 1
              ? next.gates.first.message
              : '${next.gates.length} things to fix: ${next.gates.first.message}',
        );
      } else if (failure != null) {
        CatalogFeedback.failure(
          messenger,
          failure,
          subject: 'The menu could not be published',
        );
      } else if (next.notice != null) {
        CatalogFeedback.confirm(messenger, next.notice!);
      }
    });

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        title: const Text('Dishes'),
        actions: [
          IconButton(
            key: const ValueKey('rep_preview_menu'),
            icon: const Icon(Icons.visibility_outlined),
            tooltip: 'Preview the menu',
            onPressed: () =>
                context.push('${AppRoutes.repCatalogs}/$catalogId/preview'),
          ),
          IconButton(
            key: const ValueKey('rep_restaurant_details'),
            icon: const Icon(Icons.storefront_outlined),
            tooltip: 'Restaurant details',
            onPressed: () async {
              await context.push('${AppRoutes.repCatalogs}/$catalogId/details');
              if (!context.mounted) return;
              // The details screen can change the NAME the preview and the
              // catalog list render, and the draft state the publish button
              // acts on. Re-read rather than leave a stale header behind.
              ref.invalidate(repCatalogDocumentProvider(catalogId));
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('rep_add_dish_fab'),
        onPressed: () async {
          // The SOURCE PICKER, not the camera. Going straight to capture was
          // the mobile-only assumption stage 10 removed: a rep on a laptop has
          // no capture pipeline at all, and even on a phone "from a finished
          // capture" and "photo" are ordinary ways to add a dish.
          //
          // The refresh is what makes a new "3D generating…" row appear
          // immediately rather than up to one poll interval later.
          await context.push('/rep/catalogs/$catalogId/dishes/new');
          if (!context.mounted) return;
          // A NEW DISH IS A DRAFT CHANGE. The list re-reads itself below; the
          // publish bar reads the catalog document, which carries the
          // server-derived draft flag, so that has to be re-read too or the
          // bar goes on claiming everything is live.
          ref.invalidate(repCatalogDocumentProvider(catalogId));
          await ref
              .read(repCatalogProductsProvider(catalogId).notifier)
              .refresh();
        },
        icon: const Icon(Icons.add),
        label: const Text('Add a dish'),
      ),
      // The publish bar, and the line above it saying what is still a draft.
      // See [_PublishBar].
      bottomNavigationBar: _PublishBar(catalogId: catalogId),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () {
            ref.invalidate(repCatalogDocumentProvider(catalogId));
            return ref
                .read(repCatalogProductsProvider(catalogId).notifier)
                .refresh();
          },
          child: products.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (_, __) => _Message(
              title: "Couldn't load the dishes.",
              body: 'Check your connection and pull down to try again.',
              onRetry: () => ref
                  .read(repCatalogProductsProvider(catalogId).notifier)
                  .refresh(),
            ),
            data: (items) => items.isEmpty
                ? const _Message(
                    title: 'No dishes yet.',
                    body: 'Add the first one — capture it and the 3D model '
                        'starts generating on its own.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.huge * 2,
                    ),
                    itemCount: items.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (_, i) => _DishRow(
                      product: items[i],
                      // The refresh is what makes an edited name, price or
                      // photo appear on the row the rep came back to, rather
                      // than up to one poll interval later — or never, for a
                      // dish with no 3D model to poll for.
                      onTap: () async {
                        await context.push(
                          '${AppRoutes.repCatalogs}/$catalogId/dishes/'
                          '${items[i].id}',
                        );
                        if (!context.mounted) return;
                        // An edited name, price, photo or model is a draft
                        // change — same reason as the add-dish FAB above.
                        ref.invalidate(repCatalogDocumentProvider(catalogId));
                        await ref
                            .read(
                                repCatalogProductsProvider(catalogId).notifier)
                            .refresh();
                      },
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// The bottom bar: what is waiting to go live, and the one button that sends it.
///
/// A BOTTOM BAR, NOT A SECOND FAB. "Add a dish" is the repeated action and keeps
/// the FAB; publishing happens once, at the end of the visit. Two floating
/// buttons would also put the rarer, irreversible-feeling one under the thumb
/// that has been tapping the other all visit.
///
/// THE LINE ABOVE THE BUTTON IS THE POINT. A rep edits a draft all visit — dish
/// names, photos, models, the restaurant's own name and branding — and none of
/// it reaches a customer until a publish. With a fixed "Publish the menu" label
/// and nothing else, the screen looked identical with twenty unsent edits and
/// with none, so the one question a rep has on the way out the door ("did that
/// price fix actually go up?") had no answer on the screen that owed it one.
///
/// SERVER-DERIVED, NEVER DIFFED. [Catalog.hasUnpublishedChanges] comes off the
/// draft/published revision counters; the client must not try to recompute it
/// by comparing anything locally, because a badge that disagrees with the
/// publish it describes is worse than no badge at all. The detail screen
/// re-reads the document after every edit that can move the flag.
///
/// WHILE THE DOCUMENT IS UNREAD, THE BAR CLAIMS NOTHING AND THE BUTTON STILL
/// WORKS. Loading, or a failed read, shows no state line and leaves a live
/// "Publish now" — the same "we cannot tell → assume there are drafts" rule
/// [Catalog.fromMap] applies to the flag itself. Wrongly hiding the state tells
/// a rep their edits are live when they are not; wrongly showing it costs one
/// redundant publish, and a disabled button would cost them the visit.
class _PublishBar extends ConsumerWidget {
  const _PublishBar({required this.catalogId});

  final String catalogId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(repCatalogDocumentProvider(catalogId)).valueOrNull;
    final publish = ref.watch(repPublishProvider(catalogId));

    // KEEPING THE RUN WATCH ALIVE FROM HERE, not from the notifier's build.
    // A run can start without this device asking — a 3D model finishing
    // generation publishes on its own, and so does the owner on their phone —
    // so "something is publishing" arrives as a document change, and this is
    // where document changes land. The notifier makes the call idempotent.
    ref.listen(repCatalogDocumentProvider(catalogId), (_, next) {
      final loaded = next.valueOrNull;
      if (loaded == null) return;
      ref
          .read(repPublishProvider(catalogId).notifier)
          .watchRunIfPublishing(isPublishing: loaded.isPublishing);
    });

    // A run THIS device started, or one the server says already holds the
    // catalog: a rep who backed out and came straight back must meet the same
    // "Publishing…" rather than a button offering to start a second run.
    final running = publish.publishing || (catalog?.isPublishing ?? false);
    final pending = catalog?.hasUnpublishedChanges ?? true;
    final isLive = catalog?.status.isLive ?? false;

    // THE CASE THIS BAR WAS REBUILT FOR. A run is going, and edits landed after
    // it planned — so the menu about to go live is not the one on this screen.
    // Publish is re-offered, mid-run, because pressing it is the only thing
    // that gets those edits live and the rep has no other way to know.
    final staleRun = catalog?.hasChangesSincePublishStarted ?? false;

    // Nothing drafted AND already live is the one state with nothing to send.
    // Nothing drafted and NOT live still publishes — that is a page which was
    // taken offline, and putting it back is exactly this button's job.
    final canPublish = running
        ? staleRun && !publish.queuedBehindRun && !publish.publishing
        : pending || !isLive;

    final label = !canPublish && running
        ? 'Publishing…'
        : canPublish
            ? 'Publish now'
            : 'Published (live)';

    // The spinner belongs to OUR request, not to any run. A rep looking at a
    // stale run needs to read "Publish now" on a button they can press, and a
    // spinner over it would say the opposite.
    final showsSpinner = publish.publishing || (running && !canPublish);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (catalog != null) ...[
              _PublishStateLine(
                catalog: catalog,
                running: running,
                staleRun: staleRun,
                queuedBehindRun: publish.queuedBehindRun,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            if (publish.queuedBehindRun) ...[
              // An escape from a republish the rep did not mean to queue. It
              // shows only while one is queued, so the ordinary visit never
              // meets it.
              TextButton(
                key: const ValueKey('rep_cancel_queued_republish'),
                onPressed: () => ref
                    .read(repPublishProvider(catalogId).notifier)
                    .cancelQueuedRepublish(),
                child: const Text("Don't republish — leave them in the draft"),
              ),
              const SizedBox(height: AppSpacing.xs),
            ],
            AppButton(
              key: const ValueKey('rep_publish_button'),
              label: label,
              isLoading: showsSpinner,
              onPressed: !canPublish
                  ? null
                  : () async {
                      await ref
                          .read(repPublishProvider(catalogId).notifier)
                          .publish();
                      // Both halves of this screen move on a publish: the
                      // status the dish rows render, and the draft flag this
                      // bar reads — which is the whole reason the button was
                      // pressed, so it must not be the stale one.
                      ref.invalidate(repCatalogDocumentProvider(catalogId));
                      await ref
                          .read(repCatalogProductsProvider(catalogId).notifier)
                          .refresh();
                    },
            ),
          ],
        ),
      ),
    );
  }
}

/// One line saying what is not live yet, and since when.
///
/// "Draft changes not yet live" is the OWNER's wording, from the catalog header
/// (feature 38), reused here on purpose: a rep and an owner on the phone about
/// the same restaurant should be reading the same words for the same state.
class _PublishStateLine extends StatelessWidget {
  const _PublishStateLine({
    required this.catalog,
    required this.running,
    required this.staleRun,
    required this.queuedBehindRun,
  });

  final Catalog catalog;

  /// A publish run holds the catalog — from this device or any other.
  final bool running;

  /// That run planned before the rep's latest edits, so it will not carry them.
  final bool staleRun;

  /// We have taken responsibility for republishing when the run clears.
  final bool queuedBehindRun;

  @override
  Widget build(BuildContext context) {
    final (icon, color, title, detail) = _describe();
    final textTheme = Theme.of(context).textTheme;

    return Container(
      key: const ValueKey('rep_publish_state'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface1,
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
                Text(
                  title,
                  style: textTheme.bodyMedium
                      ?.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
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

  /// Every state this bar can be in, most urgent first.
  (IconData, Color, String, String) _describe() {
    final published = catalog.lastPublishedAt;

    if (running) {
      // ── The three mid-run states ────────────────────────────────────────
      if (queuedBehindRun) {
        return (
          Icons.pending_actions,
          AppColors.royalGold,
          'Your changes are queued.',
          'The publish already running does not include them. Yours starts '
              'the moment it finishes — keep this screen open.',
        );
      }
      if (staleRun) {
        // NOT reassurance. A rep reading "Publishing…" here would leave
        // believing the edit they just made is on its way, and it is not.
        return (
          Icons.warning_amber_rounded,
          AppColors.warning,
          'Your latest changes are NOT in this publish.',
          'A publish started before you made them and cannot pick them up. '
              'Press Publish now and they go up right after it.',
        );
      }
      return (
        Icons.sync,
        AppColors.royalGold,
        'Publishing…',
        'The customer page updates in about a minute.',
      );
    }

    if (catalog.hasUnpublishedChanges) {
      // NOT the same sentence twice. A restaurant that has never been live and
      // one that is live with edits behind it both have drafts, but only the
      // second one has something a customer can already see — and a rep who
      // reads "not yet live" on a page that IS live goes looking for a bug.
      return published == null
          ? (
              Icons.schedule,
              AppColors.warning,
              'Nothing is live yet.',
              'Your dishes and the restaurant details go live the first time '
                  'you publish.',
            )
          : (
              Icons.schedule,
              AppColors.warning,
              'Draft changes not yet live.',
              'Dish names, photos, 3D models and the restaurant details stay '
                  'in the draft until you publish. Last published '
                  '${published.timeAgo}.',
            );
    }

    // Nothing drafted. Live and offline are different answers, and the button
    // beside this line differs with them too.
    return catalog.status.isLive
        ? (
            Icons.check_circle_outline,
            AppColors.success,
            'Everything is live.',
            published == null
                ? 'Nothing is waiting to be published.'
                : 'Published ${published.timeAgo}. Nothing is waiting to go up.',
          )
        : (
            Icons.visibility_off_outlined,
            AppColors.textMuted,
            'This page is offline.',
            'Nothing is drafted. Publish to put it back in front of customers.',
          );
  }
}

class _DishRow extends StatelessWidget {
  const _DishRow({required this.product, this.onTap});

  final CatalogProduct product;

  /// Opens the dish. Null renders the row as plain text — there is no state
  /// where that is wanted today, and the parameter is optional only so the row
  /// stays usable in a test that is not about navigation.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Same four states, same words as the product card's badge. Two surfaces
    // that disagree about what "3D unavailable" looks like is how a rep learns
    // to distrust both.
    final (label, color) = switch (product.modelStatus) {
      ProductModelStatus.queued || ProductModelStatus.processing => (
          '3D generating…',
          AppColors.textSecondary
        ),
      ProductModelStatus.ready => ('AR ready', AppColors.royalGold),
      // NOT an error. The dish is on the menu; only AR is missing. A rep who
      // reads this as a rejection re-shoots the dish and spends generation
      // credits twice on a capture that was never the problem.
      ProductModelStatus.failed => ('3D unavailable', AppColors.textMuted),
      ProductModelStatus.none => ('Photo only', AppColors.textMuted),
    };

    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        key: ValueKey('rep_dish_row_${product.id}'),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.displayName,
                      style: const TextStyle(
                        fontSize: AppTypography.sizeHeadline,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (product.isModelPending) ...[
                          SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: color,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xs),
                        ],
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: AppTypography.sizeLabel,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (product.isArReady) ...[
                const Icon(Icons.view_in_ar,
                    color: AppColors.royalGold, size: 18),
                const SizedBox(width: AppSpacing.sm),
              ],
              // The affordance, not decoration: without it the row reads as a
              // status line and a rep never discovers the editor behind it.
              const Icon(Icons.chevron_right,
                  color: AppColors.textMuted, size: 18),
            ],
          ),
        ),
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
