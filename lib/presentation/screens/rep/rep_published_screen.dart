// lib/presentation/screens/rep/rep_published_screen.dart
//
// "Published standees" — the restaurants that have actually been put online:
// this rep's, or EVERY rep's when an admin is reading.
//
// THE COUNT AT THE TOP IS THE POINT. A rep wants to know how many menus they
// have taken live, and that number comes from the server ignoring the filter, so
// narrowing to "Last 7 days" changes the list underneath it and not the total.
//
// AN ADMIN GETS THE SAME COUNT AS A FRACTION — "2 of 115 menus live" — because
// their question is not how many but how MUCH: standees are printed in runs and
// handed out, and the gap between what was minted and what is working is the
// only number that says whether the stock in the field is doing anything. The
// denominator is every standee ever minted, and like the numerator it ignores
// the window: a fraction that shrank when somebody tapped "Last 7 days" would
// be answering a question nobody asked.
//
// WHOSE LIST IT IS, IS SAID OUT LOUD. An admin reading rows they did not create
// must not have to guess, so the subtitle names the scope and each row carries
// who put that menu live. Without that, a cross-rep list reads as a personal one
// with impossible entries in it.
//
// TAPPING A ROW OPENS THE MENU — the real one, in a browser, on both targets.
// That is what made url_launcher worth adding (see
// catalog_link_delivery_io.dart for the justification): "share it to another
// app and open it from there" is a workaround, not a preview, and looking at
// the menu you just put live is the whole reason to tap a row here.
//
// THE DOWNLOAD IS ITS OWN CONTROL on the row, not buried a tap deeper. Saving
// the sheet and looking at the menu are two different errands, and a rep
// reprinting a standee should not have to open a restaurant page to do it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/rep/rep_published_notifier.dart';
import '../../../application/standee_sheet_plan.dart';
import '../../../domain/entities/qr_standee.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
import '../../widgets/standee_copies_dialog.dart';
import '../../../application/catalog/catalog_link_service.dart';

class RepPublishedScreen extends ConsumerWidget {
  const RepPublishedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(repPublishedProvider);
    final notifier = ref.read(repPublishedProvider.notifier);

    ref.listen<RepPublishedState>(repPublishedProvider, (previous, next) {
      final failure = next.failure;
      final changed = failure?.code != previous?.failure?.code ||
          next.notice != previous?.notice;
      if (!changed) return;

      final messenger = CatalogFeedback.of(context);
      if (failure != null) {
        CatalogFeedback.failure(
          messenger,
          failure,
          subject: 'That standee could not be saved',
        );
      } else if (next.notice != null) {
        CatalogFeedback.confirm(messenger, next.notice!);
      }
    });

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(title: const Text('Published standees')),
      body: SafeArea(
        child: Column(
          children: [
            _Header(state: state),
            _WindowChips(
              selected: state.window,
              onSelect: notifier.setWindow,
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: RefreshIndicator(
                onRefresh: notifier.load,
                child: state.page.when(
                  loading: () => const Center(child: AppLoadingIndicator()),
                  error: (_, __) => _Message(
                    title: state.everyone
                        ? "Couldn't load published standees."
                        : "Couldn't load your published standees.",
                    body: 'Check your connection and pull down to try again.',
                    onRetry: notifier.load,
                  ),
                  data: (_) => state.standees.isEmpty
                      ? _Message(
                          title: state.window == PublishedWindow.all
                              ? 'Nothing published yet.'
                              : 'Nothing in this period.',
                          body: state.window == PublishedWindow.all
                              ? state.everyone
                                  // An admin has not failed to do anything —
                                  // the reps have not been out yet.
                                  ? 'When a standee is activated and its menu '
                                      'published, it appears here.'
                                  : 'Activate a standee and publish the menu — '
                                      'it will appear here.'
                              : 'Try a longer period.',
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          itemCount: state.standees.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: AppSpacing.sm),
                          itemBuilder: (_, i) {
                            final row = state.standees[i];
                            return _PublishedTile(
                              standee: row,
                              busy: state.isBusy(row.code),
                              onOpen: () => _openMenu(context, ref, row),
                              onDownload: () =>
                                  _downloadStandee(context, notifier, row.code),
                            );
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the live menu in a browser.
  ///
  /// Through the SAME seam the owner publish screen uses, so there is one
  /// definition of what opening a catalog link means and one place it can
  /// break. A platform that still cannot open one (the stub target) falls back
  /// to copying, which is the honest remaining action rather than a dead tap.
  Future<void> _openMenu(
    BuildContext context,
    WidgetRef ref,
    RepPublishedStandee standee,
  ) async {
    final actions = ref.read(catalogLinkActionsProvider);
    final messenger = CatalogFeedback.of(context);
    try {
      if (actions.canOpen) {
        await actions.open(standee.url);
        return;
      }
      await actions.copy(standee.url);
      CatalogFeedback.confirm(messenger, "Menu link copied.");
    } catch (_) {
      // Mapped copy only: a refused launch arrives as a platform exception
      // carrying no envelope code and no sentence fit for a user.
      CatalogFeedback.confirm(
        messenger,
        "That menu could not be opened. The link is ${standee.url}",
      );
    }
  }
}

/// The number the screen exists to show: a count for a rep, a fraction of the
/// printed stock for an admin.
class _Header extends StatelessWidget {
  const _Header({required this.state});

  final RepPublishedState state;

  @override
  Widget build(BuildContext context) {
    final total = state.total;
    final generated = state.generated;
    final fraction = state.hasFraction;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$total',
                key: const ValueKey('published_total'),
                style: const TextStyle(
                  fontSize: AppTypography.sizeDisplay,
                  fontWeight: FontWeight.w700,
                  color: AppColors.royalGold,
                ),
              ),
              if (fraction) ...[
                const SizedBox(width: AppSpacing.xs),
                Text(
                  // The denominator is deliberately quieter than the
                  // numerator: how many are LIVE is the finding, how many were
                  // printed is the context it is read against.
                  'of $generated',
                  key: const ValueKey('published_generated'),
                  style: const TextStyle(
                    fontSize: AppTypography.sizeTitle,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  _caption(total, fraction: fraction),
                  style: const TextStyle(
                    fontSize: AppTypography.sizeBody,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          if (fraction) ...[
            const SizedBox(height: AppSpacing.md),
            _StockBar(live: total, generated: generated!),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              // Says whose work is on screen. An admin reading rows they did
              // not create should never have to infer the scope.
              'Across every staff member, out of all standees minted.',
              style: TextStyle(
                fontSize: AppTypography.sizeLabel,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Singular matters on a screen whose whole job is a count — and the
  /// possessive has to go when the list is not the reader's own work.
  static String _caption(int total, {required bool fraction}) {
    if (fraction) return total == 1 ? 'menu live' : 'menus live';
    return total == 1 ? 'menu you put live' : 'menus you put live';
  }
}

/// How much of the printed stock is working, as a bar.
///
/// A bar and not a percentage: the useful reading is "most of it" or "hardly
/// any", and a figure like 1.7% invites precision the number does not have —
/// standees are minted in runs long before anyone goes out with them.
class _StockBar extends StatelessWidget {
  const _StockBar({required this.live, required this.generated});

  final int live;
  final int generated;

  @override
  Widget build(BuildContext context) {
    // Nothing minted is not zero progress, it is NO fraction; an empty track
    // says that without dividing by zero.
    final value = generated <= 0 ? 0.0 : (live / generated).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: LinearProgressIndicator(
        key: const ValueKey('published_stock_bar'),
        value: value,
        minHeight: 6,
        color: AppColors.royalGold,
        backgroundColor: AppColors.surface2,
      ),
    );
  }
}

class _WindowChips extends StatelessWidget {
  const _WindowChips({required this.selected, required this.onSelect});

  final PublishedWindow selected;
  final ValueChanged<PublishedWindow> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 40,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          itemCount: PublishedWindow.values.length,
          separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
          itemBuilder: (_, i) {
            final window = PublishedWindow.values[i];
            return ChoiceChip(
              key: ValueKey('published_window_${window.name}'),
              label: Text(window.label),
              selected: window == selected,
              onSelected: (_) => onSelect(window),
              backgroundColor: AppColors.surface1,
              selectedColor: AppColors.surface2,
              labelStyle: TextStyle(
                fontSize: AppTypography.sizeCaption,
                color: window == selected
                    ? AppColors.textPrimary
                    : AppColors.textMuted,
              ),
            );
          },
        ),
      );
}

/// Ask how many and which layout, THEN download one row's sheet.
///
/// Same split as the rep's standee list: the dialog owns the question, the
/// notifier owns the download, so a failure lands on the row.
Future<void> _downloadStandee(
  BuildContext context,
  RepPublishedNotifier notifier,
  String code,
) async {
  final choice = await showStandeeCopiesDialog(
    context,
    code: code,
    plan: repStandeeSheetPlanProvider(code),
  );
  if (choice == null || !context.mounted) return;
  await notifier.deliverStandeeSheet(
    code,
    copies: choice.copies,
    layout: choice.layout,
  );
}

class _PublishedTile extends StatelessWidget {
  const _PublishedTile({
    required this.standee,
    required this.busy,
    required this.onOpen,
    required this.onDownload,
  });

  final RepPublishedStandee standee;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      standee.displayName,
                      style: const TextStyle(
                        fontSize: AppTypography.sizeHeadline,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      standee.code,
                      style: const TextStyle(
                        fontSize: AppTypography.sizeLabel,
                        color: AppColors.textMuted,
                        fontFamily: 'monospace',
                        letterSpacing: 1.2,
                      ),
                    ),
                    // Only ever present on the admin read. A rep does not need
                    // telling that they are the one who did this.
                    if (standee.activatedBy case final person?) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(Icons.person_outline,
                              size: 12, color: AppColors.textMuted),
                          const SizedBox(width: AppSpacing.xs),
                          Flexible(
                            child: Text(
                              'Put live by ${person.displayLabel}',
                              key: ValueKey(
                                  'published_activator_${standee.code}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: AppTypography.sizeLabel,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  key: ValueKey('published_download_${standee.code}'),
                  tooltip: 'Save the standee sheet',
                  onPressed: onDownload,
                  icon: const Icon(Icons.save_alt),
                  color: AppColors.textSecondary,
                ),
              const Icon(Icons.open_in_new,
                  size: 16, color: AppColors.textMuted),
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
          const SizedBox(height: AppSpacing.xxxl),
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
