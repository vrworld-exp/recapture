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
// FOUR WAYS OUT OF THIS SCREEN, AND EACH ANSWERS A DIFFERENT QUESTION:
//   • a dish row  → 'is this one right?'          → the dish editor
//   • Categories  → 'are the SECTIONS right?'     → the category manager
//   • Preview     → 'is the PAGE right?'          → the customer-eye preview
//   • Details     → 'is the RESTAURANT right?'    → name, contact, branding
// Until they existed a rep could add dishes and publish, and could not fix a
// single thing they had got wrong — the owner had to sign in later and do it,
// which on a pilot visit means the page goes live wrong or does not go live.
//
// AND THE ROWS DRAG. The owner's grid has reordered since feature 10; this list
// sat in creation order until the owner signed in and dragged, so a rep could
// build "Mains" and not put Butter Chicken above Dal inside it. Same handle,
// same keyboard shortcut, same undo as the category manager — one gesture
// vocabulary across the rep surface — writing through
// `RepCatalogProductsNotifier.reorder`, which is the single place that knows
// the ReorderableListView index convention.
//
// AND EVERY ONE OF THOSE EDITS LANDS IN A DRAFT, WHICH THE TOP OF THE SCREEN
// SAYS. Renaming a dish, replacing its photo or model, changing the
// restaurant's own name or branding — none of it reaches a customer until a
// publish. The bar used to be a single button reading "Publish the menu"
// whether there were twenty unsent edits behind it or none, so a rep who
// corrected a price and walked out had nothing on screen telling them the
// correction was still in the draft. The state line first lived in the bottom
// bar, directly above the button; it now sits under the app bar, where the
// owner's catalog header keeps the same badge. See [_PublishStateHeader] and
// [_PublishBar].
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/common/pending_poll_loop.dart';
import '../../../application/rep/rep_catalogs_notifier.dart';
import '../../../application/rep/rep_restaurant_notifier.dart';
import '../../../data/repositories/catalog_failure.dart';
import '../../../domain/entities/catalog.dart';
import '../../../domain/entities/catalog_product.dart';
import '../../../domain/entities/catalog_status.dart';
import '../../../domain/entities/product_food_type.dart';
import '../../../domain/entities/product_model_status.dart';
import '../../../utils/extensions.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/catalog/food_type_field.dart';
import '../../widgets/catalog/publish_body.dart' show kPublishStartQuery;
import '../catalog/category_manager_screen.dart' show kCategoryTouchWidth;

class RepCatalogDetailScreen extends ConsumerWidget {
  const RepCatalogDetailScreen({super.key, required this.catalogId});

  final String catalogId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        title: const Text('Dishes'),
        actions: [
          IconButton(
            key: const ValueKey('rep_categories'),
            icon: const Icon(Icons.category_outlined),
            tooltip: 'Categories',
            onPressed: () async {
              await context.push(
                '${AppRoutes.repCatalogs}/$catalogId/categories',
              );
              if (!context.mounted) return;
              // The manager moves dishes between sections and deletes
              // sections (which moves their dishes), and every one of those
              // is a draft change. The list and the bar both re-read.
              ref.invalidate(repCatalogDocumentProvider(catalogId));
              await ref
                  .read(repCatalogProductsProvider(catalogId).notifier)
                  .refresh();
            },
          ),
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
      // The door to publishing. What is still a draft is said at the TOP of
      // the screen, not here — see [_PublishStateHeader].
      bottomNavigationBar: _PublishBar(catalogId: catalogId),
      body: SafeArea(
        child: Column(
          children: [
            // Outside the RefreshIndicator on purpose: it is a status strip,
            // not a row of the list, and it must not scroll away under the
            // pull-to-refresh spinner or with the dishes.
            _PublishStateHeader(catalogId: catalogId),
            Expanded(child: _DishList(catalogId: catalogId)),
          ],
        ),
      ),
    );
  }
}

/// The dishes, under pull-to-refresh: the list itself, or why there is none.
class _DishList extends ConsumerWidget {
  const _DishList({required this.catalogId});

  final String catalogId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(repCatalogProductsProvider(catalogId));

    return RefreshIndicator(
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
            : LayoutBuilder(
                builder: (context, constraints) {
                  // Finger-sized handles below the same width the category
                  // manager uses. Measured, never `kIsWeb`: a narrow
                  // browser window is the phone shape.
                  final touch = constraints.maxWidth < kCategoryTouchWidth;
                  return ReorderableListView.builder(
                    key: const ValueKey('rep_dish_list'),
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.huge * 2,
                    ),
                    // Handles are drawn by the rows themselves, so ONE
                    // affordance serves touch drag, mouse drag and the
                    // keyboard hint.
                    buildDefaultDragHandles: false,
                    header: Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: Text(
                        'Customers see the dishes in this order. Drag '
                        'the handle to change it.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppColors.textMuted),
                      ),
                    ),
                    itemCount: items.length,
                    onReorder: (oldIndex, newIndex) => _reorderDish(
                      context,
                      catalogId,
                      oldIndex,
                      newIndex,
                    ),
                    itemBuilder: (_, i) => Padding(
                      key: ValueKey('rep_dish_slot_${items[i].id}'),
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _DishRow(
                        product: items[i],
                        touch: touch,
                        index: i,
                        count: items.length,
                        onMove: (from, to) =>
                            _reorderDish(context, catalogId, from, to),
                        // The refresh is what makes an edited name, price
                        // or photo appear on the row the rep came back
                        // to, rather than up to one poll interval later —
                        // or never, for a dish with no 3D model to poll
                        // for.
                        onTap: () async {
                          await context.push(
                            '${AppRoutes.repCatalogs}/$catalogId/dishes/'
                            '${items[i].id}',
                          );
                          if (!context.mounted) return;
                          // An edited name, price, photo or model is a
                          // draft change — same reason as the add-dish
                          // FAB above.
                          ref.invalidate(repCatalogDocumentProvider(catalogId));
                          await ref
                              .read(repCatalogProductsProvider(catalogId)
                                  .notifier)
                              .refresh();
                        },
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// One drag on the dish list, written, confirmed, and offered back.
///
/// The same shape as the category manager's `_reorder`: the messenger and the
/// container are captured while the context is certainly mounted, because the
/// undo fires seconds later from a snackbar the rep may have navigated away
/// from — a container survives that, a ref does not.
Future<void> _reorderDish(
  BuildContext context,
  String catalogId,
  int oldIndex,
  int newIndex,
) async {
  final messenger = CatalogFeedback.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final name = container
      .read(repCatalogProductsProvider(catalogId))
      .valueOrNull
      ?.elementAtOrNull(oldIndex)
      ?.displayName;
  await _writeDishOrder(
    messenger,
    container,
    catalogId,
    oldIndex,
    newIndex,
    name: name,
  );
}

/// [undoable] is false for the undo's OWN write, so pressing undo twice does
/// not become a way to walk the list back and forth forever.
Future<void> _writeDishOrder(
  ScaffoldMessengerState messenger,
  ProviderContainer container,
  String catalogId,
  int oldIndex,
  int newIndex, {
  String? name,
  bool undoable = true,
}) async {
  try {
    final landed = await container
        .read(repCatalogProductsProvider(catalogId).notifier)
        .reorder(oldIndex, newIndex);
    // Nothing moved — a drag that ended where it started. Confirming it would
    // be a message about an event that did not happen.
    if (landed == null) return;

    final subject = name == null ? 'Dish order saved.' : '$name moved.';
    if (!undoable) {
      CatalogFeedback.confirm(messenger, subject);
      return;
    }
    CatalogFeedback.undoable(
      messenger,
      '$subject Customers see the new order after you publish.',
      // The REAL inverse: the row is dragged back from where it LANDED to
      // where it came from, and that write goes to the server like any other.
      // `oldIndex + 1` when moving down is the ReorderableListView convention
      // — the target is counted before the row is lifted out.
      onUndo: () => _writeDishOrder(
        messenger,
        container,
        catalogId,
        landed,
        oldIndex > landed ? oldIndex + 1 : oldIndex,
        name: name,
        undoable: false,
      ),
    );
  } on CatalogFailure catch (failure) {
    // The list has already snapped back and re-read itself. Say why, or the
    // row looks as though it refused the drag for no reason.
    CatalogFeedback.failure(
      messenger,
      failure,
      subject: 'That order could not be saved',
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
/// THE STATE LINE IS NOT HERE ANY MORE. It used to sit directly above this
/// button, which put the one sentence a rep needs ("is that price fix live?")
/// at the bottom of the screen, under the FAB, where nobody looks until they
/// are about to press Publish. It now sits under the app bar — see
/// [_PublishStateHeader]. This bar keeps two things: the button's label, which
/// still tracks the same document, and the poll that keeps that document
/// fresh while a run holds the catalog, so a finished run does not leave
/// "Publishing…" on a screen nobody refreshed.
///
/// WHILE THE DOCUMENT IS UNREAD, THE BUTTON STILL WORKS. Loading, or a failed
/// read, leaves a live button — the same "we cannot tell → assume there are
/// drafts" rule [Catalog.fromMap] applies to the flag itself.
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
    // A button that SAYS Publish starts the run; the "see progress" door only
    // watches. The label above is what decides which one this press was.
    final running = ref
            .read(repCatalogDocumentProvider(widget.catalogId))
            .valueOrNull
            ?.isPublishing ??
        false;
    await context.push(
      '${AppRoutes.repCatalogs}/${widget.catalogId}/publish'
      '${running ? '' : '?$kPublishStartQuery=1'}',
    );
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
    final catalog =
        ref.watch(repCatalogDocumentProvider(catalogId)).valueOrNull;

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
        child: AppButton(
          key: const ValueKey('rep_publish_button'),
          label: label,
          icon: running ? Icons.sync : Icons.cloud_upload_outlined,
          onPressed: _openPublish,
        ),
      ),
    );
  }
}

/// The publish state, pinned under the app bar.
///
/// AT THE TOP, WHERE THE OWNER'S BADGE IS. The owner's catalog screen says
/// "Draft changes not yet live" in its header (feature 38); a rep looking at
/// the same restaurant reads the same sentence in the same place. It is the
/// first thing on the screen because it is the first question a rep has on
/// opening it — and the last one on the way out — not a footnote to the
/// button.
///
/// SERVER-DERIVED, NEVER DIFFED. [Catalog.hasUnpublishedChanges] comes off the
/// draft/published revision counters; the client must not try to recompute it
/// by comparing anything locally, because a badge that disagrees with the
/// publish it describes is worse than no badge at all. The detail screen
/// re-reads the document after every edit that can move the flag, and
/// [_PublishBar] keeps re-reading it while a run holds the catalog.
///
/// WHILE THE DOCUMENT IS UNREAD, THIS CLAIMS NOTHING. Loading, or a failed
/// read, renders no strip at all rather than a guess.
class _PublishStateHeader extends ConsumerWidget {
  const _PublishStateHeader({required this.catalogId});

  final String catalogId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog =
        ref.watch(repCatalogDocumentProvider(catalogId)).valueOrNull;
    if (catalog == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        0,
      ),
      child: _PublishStateLine(
        catalog: catalog,
        running: catalog.isPublishing,
        staleRun: catalog.hasChangesSincePublishStarted,
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

  /// Every state this line can be in, most urgent first.
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
  const _DishRow({
    required this.product,
    required this.touch,
    required this.index,
    required this.count,
    this.onMove,
    this.onTap,
  });

  final CatalogProduct product;

  /// Narrow layout — the handle grows to a finger-sized box. See
  /// [kCategoryTouchWidth].
  final bool touch;

  /// This row's slot in the list, and how many there are: what the drag
  /// handle and the keyboard shortcut hand to the reorder.
  final int index;
  final int count;

  /// Keyboard reorder (Alt + arrows), in the `ReorderableListView` index
  /// convention. Null disables the shortcut; the handle still needs a
  /// `ReorderableListView` ancestor to do anything.
  final void Function(int from, int to)? onMove;

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

    final move = onMove;
    return CallbackShortcuts(
      // Keyboard reorder (Alt + arrows). Drag-only is inaccessible on a
      // desktop — and the rep surface runs in a browser — and this is the same
      // call the drag makes: one code path, one set of rollbacks.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () {
          if (move != null && index > 0) move(index, index - 1);
        },
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () {
          if (move != null && index < count - 1) move(index, index + 2);
        },
      },
      child: Material(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InkWell(
          key: ValueKey('rep_dish_row_${product.id}'),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              touch ? AppSpacing.sm : AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: Row(
              children: [
                // ReorderableDragStartListener works for touch AND mouse, so the
                // web build's drag needs no second implementation. The box
                // around the icon is the hit target, so on a phone it is padded
                // to 40 — the icon alone is 18, which a finger misses.
                ReorderableDragStartListener(
                  index: index,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    // No Tooltip: on touch the tooltip's trigger IS a long-press,
                    // so pressing the handle to start a drag popped "Drag to
                    // reorder" over the list mid-gesture, and on the web it hung
                    // off every hover. The label survives for screen readers only;
                    // how to drag is taught by the line above the list.
                    child: Semantics(
                      label: 'Drag to reorder',
                      child: SizedBox(
                        key: ValueKey('rep_dish_handle_${product.id}'),
                        width: touch ? 40 : 18,
                        height: touch ? 40 : 18,
                        child: Center(
                          child: Icon(
                            Icons.drag_indicator,
                            size: touch ? 22 : 18,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: touch ? AppSpacing.sm : AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // The veg / non-veg square, before the name the way
                          // a printed menu does it. Draws nothing for "no
                          // label", so the row needs no condition here.
                          if (product.foodType.showsMarker) ...[
                            FoodTypeMarker(type: product.foodType, size: 12),
                            const SizedBox(width: AppSpacing.sm),
                          ],
                          Expanded(
                            child: Text(
                              product.displayName,
                              style: const TextStyle(
                                fontSize: AppTypography.sizeHeadline,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
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
