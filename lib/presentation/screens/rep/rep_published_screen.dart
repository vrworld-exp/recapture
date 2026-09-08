// lib/presentation/screens/rep/rep_published_screen.dart
//
// "Published standees" — the restaurants this rep has actually put online.
//
// THE COUNT AT THE TOP IS THE POINT. A rep wants to know how many menus they
// have taken live, and that number comes from the server ignoring the filter, so
// narrowing to "Last 7 days" changes the list underneath it and not the total.
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
import '../../../domain/entities/qr_standee.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';
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
            _Header(total: state.total),
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
                    title: "Couldn't load your published standees.",
                    body: 'Check your connection and pull down to try again.',
                    onRetry: notifier.load,
                  ),
                  data: (_) => state.standees.isEmpty
                      ? _Message(
                          title: state.window == PublishedWindow.all
                              ? 'Nothing published yet.'
                              : 'Nothing in this period.',
                          body: state.window == PublishedWindow.all
                              ? 'Activate a standee and publish the menu — it '
                                  'will appear here.'
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
                                  notifier.deliverSheet(row.code),
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

class _Header extends StatelessWidget {
  const _Header({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: Row(
          children: [
            Text(
              '$total',
              style: const TextStyle(
                fontSize: AppTypography.sizeDisplay,
                fontWeight: FontWeight.w700,
                color: AppColors.royalGold,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                // Singular matters on a screen whose whole job is a count.
                total == 1 ? 'menu you put live' : 'menus you put live',
                style: const TextStyle(
                  fontSize: AppTypography.sizeBody,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
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
              const Icon(Icons.open_in_new, size: 16, color: AppColors.textMuted),
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
