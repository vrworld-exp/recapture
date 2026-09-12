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
import '../../../application/common/pending_poll_loop.dart';
import '../../../application/rep/rep_catalogs_notifier.dart';
import '../../../application/rep/rep_restaurant_notifier.dart';
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

/// The bottom bar: what is waiting to go live, and the door to publishing it.
///
/// A BOTTOM BAR, NOT A SECOND FAB. "Add a dish" is the repeated action and keeps
/// the FAB; publishing happens once, at the end of the visit. Two floating
/// buttons would also put the rarer, irreversible-feeling one under the thumb
/// that has been tapping the other all visit.
///
/// THE BUTTON OPENS THE PUBLISH SCREEN; IT DOES NOT PUBLISH. This mirrors the
/// owner's catalog header, whose Publish button opens `/catalog/publish`. The
/// bar used to fire the request itself and report the result as a toast —
/// no progress, no per-dish failure, no retry — so a rep saw "Publishing…"
/// for a minute and then either a green line or, for a run that failed,
/// exactly the line they had read before pressing. The publish screen is
/// where the run is watched, and there is one of it for both doors.
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
/// re-reads the document after every edit that can move the flag, and — while
/// a run holds the catalog — keeps re-reading it on the shared cadence so a
/// finished run does not leave "Publishing…" on a screen nobody refreshed.
///
/// WHILE THE DOCUMENT IS UNREAD, THE BAR CLAIMS NOTHING AND THE BUTTON STILL
/// WORKS. Loading, or a failed read, shows no state line and leaves a live
/// button — the same "we cannot tell → assume there are drafts" rule
/// [Catalog.fromMap] applies to the flag itself.
class _PublishBar extends ConsumerStatefulWidget {
  const _PublishBar({required this.catalogId});

  final String catalogId;

  @override
  ConsumerState<_PublishBar> createState() => _PublishBarState();
}

class _PublishBarState extends ConsumerState<_PublishBar> {
  /// Re-reads the document while a run holds the catalog. The SHARED cadence
  /// (see [PendingPollLoop]) and lazily created: a screen opened on a catalog
  /// nobody is publishing never starts a timer.
  PendingPollLoop? _runWatch;

  @override
  void dispose() {
    _runWatch?.stop();
    super.dispose();
  }

  /// One tick. MUST NOT THROW — the loop has no error path, and a rep on
  /// restaurant wifi drops requests. A failed read reschedules against the
  /// state already on screen rather than blanking it.
  Future<bool> _tick() async {
    ref.invalidate(repCatalogDocumentProvider(widget.catalogId));
    try {
      final catalog =
          await ref.read(repCatalogDocumentProvider(widget.catalogId).future);
      return mounted && catalog.isPublishing;
    } catch (_) {
      return mounted;
    }
  }

  void _watchRunIfPublishing(bool isPublishing) {
    if (!isPublishing) {
      _runWatch?.stop();
      return;
    }
    if (_runWatch?.isRunning ?? false) return;
    (_runWatch ??= PendingPollLoop(poll: _tick))
      ..reset()
      ..scheduleIfPending(isPending: true);
  }

  Future<void> _openPublish() async {
    await context.push('${AppRoutes.repCatalogs}/${widget.catalogId}/publish');
    if (!mounted) return;
    // Both halves of this screen move on a publish: the status the dish rows
    // render, and the draft flag this bar reads. The publish screen refreshes
    // the document as it polls; this is the belt to those braces.
    ref.invalidate(repCatalogDocumentProvider(widget.catalogId));
    await ref
        .read(repCatalogProductsProvider(widget.catalogId).notifier)
        .refresh();
  }

  @override
  Widget build(BuildContext context) {
    final catalogId = widget.catalogId;
    final catalog = ref.watch(repCatalogDocumentProvider(catalogId)).valueOrNull;

    // A run can start without this device asking — a 3D model finishing
    // generation publishes on its own, and so does the owner on their phone —
    // so "something is publishing" arrives as a document change, and this is
    // where document changes land.
    ref.listen(repCatalogDocumentProvider(catalogId), (_, next) {
      final loaded = next.valueOrNull;
      if (loaded == null) return;
      _watchRunIfPublishing(loaded.isPublishing);
    });

    final running = catalog?.isPublishing ?? false;
    final pending = catalog?.hasUnpublishedChanges ?? true;
    final staleRun = catalog?.hasChangesSincePublishStarted ?? false;

    // Always a door, never a request: the screen behind it is where the
    // checklist, the progress and the failures live, and it is worth opening
    // whatever state the menu is in — mid-run to watch it, live to see the
    // link and the QR. The label says which of those it will find.
    final label = running
        ? 'Publishing… see progress'
        : catalog == null || catalog.isNeverPublished
            ? 'Publish the menu'
            : pending
                ? 'Publish changes'
                : 'Publish';

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
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            AppButton(
              key: const ValueKey('rep_publish_button'),
              label: label,
              icon: running ? Icons.sync : Icons.cloud_upload_outlined,
              onPressed: _openPublish,
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
  });

  final Catalog catalog;

  /// A publish run holds the catalog — from this device or any other.
  final bool running;

  /// That run planned before the rep's latest edits, so it will not carry them.
  final bool staleRun;

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
      if (staleRun) {
        // NOT reassurance. A rep reading "Publishing…" here would leave
        // believing the edit they just made is on its way, and it is not.
        return (
          Icons.warning_amber_rounded,
          AppColors.warning,
          'Your latest changes are NOT in this publish.',
          'A publish started before you made them and cannot pick them up. '
              'Publish again once it finishes and they go up right after.',
        );
      }
      return (
        Icons.sync,
        AppColors.royalGold,
        'Publishing…',
        'Open the publish screen to watch it and see anything that fails.',
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
