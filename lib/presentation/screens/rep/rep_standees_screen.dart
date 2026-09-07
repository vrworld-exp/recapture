// lib/presentation/screens/rep/rep_standees_screen.dart
//
// The stock a rep is carrying: every standee an admin handed them, with its
// code and a printable sheet.
//
// THE ADMIN'S BATCH SCREEN SEEN FROM THE OTHER SIDE, minus one control. There
// is NO assign button here, and that is a rule rather than an omission:
// assignment is an ADMIN action, `/admin/qr-codes/:code/assignment` is
// ADMIN-gated, and a rep who tapped one would get a 403 for a button they
// should never have been shown. Same reasoning as everywhere else in this app —
// an affordance you do not have should be invisible, not greyed.
//
// TAPPING A ROW STARTS AN ACTIVATION, which is the whole point of the feature:
// before it, a rep read eight characters off a PDF and typed them at a table.
// Only a free standee is tappable; an ACTIVE one is already on somebody's
// table, and a RETIRED one is out of service.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../application/rep/rep_standees_notifier.dart';
import '../../../data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import '../../../domain/entities/qr_standee.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_loading_indicator.dart';
import '../../widgets/catalog/catalog_feedback.dart';

class RepStandeesScreen extends ConsumerWidget {
  const RepStandeesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(repStandeesProvider);
    final notifier = ref.read(repStandeesProvider.notifier);

    ref.listen<RepStandeesState>(repStandeesProvider, (previous, next) {
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
      appBar: AppBar(title: const Text('My standees')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: notifier.load,
          child: state.standees.when(
            loading: () => const Center(child: AppLoadingIndicator()),
            error: (_, __) => _Message(
              title: "Couldn't load your standees.",
              body: 'Check your connection and pull down to try again.',
              onRetry: notifier.load,
            ),
            data: (standees) => standees.isEmpty
                ? const _Message(
                    title: 'No standees yet.',
                    body: 'When an admin assigns you one it appears here, '
                        'ready to activate.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    itemCount: standees.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (_, i) {
                      final standee = standees[i];
                      return _StandeeTile(
                        standee: standee,
                        busy: state.isBusy(standee.code),
                        // Carries the code into the activation flow as a
                        // PREFILL — the same contract the `?code=` deep link
                        // has. The rep still taps Continue and the preflight
                        // still runs; nothing here activates on a tap.
                        onActivate: standee.canActivate
                            ? () => context.push(
                                  '${AppRoutes.repActivate}?code=${standee.code}',
                                )
                            : null,
                        onSave: standee.isPrintable
                            ? () => notifier.deliverStandee(
                                  standee.code,
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

class _StandeeTile extends StatelessWidget {
  const _StandeeTile({
    required this.standee,
    required this.busy,
    required this.onActivate,
    required this.onSave,
  });

  final RepStandee standee;
  final bool busy;

  /// Null for a standee that cannot be put on a table right now.
  final VoidCallback? onActivate;

  /// Null for a standee that must not be printed.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        onTap: onActivate,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      standee.code,
                      style: const TextStyle(
                        fontSize: AppTypography.sizeHeadline,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        // The characters printed on the sheet. Monospace so the
                        // rep reading one aloud can tell the glyphs apart.
                        fontFamily: 'monospace',
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // "Ready to activate" rather than the admin's "Available":
                      // the admin is looking at stock, the rep is looking at
                      // their next move.
                      standee.canActivate
                          ? 'Ready to activate'
                          : standee.state.label,
                      style: TextStyle(
                        fontSize: AppTypography.sizeLabel,
                        color: standee.canActivate
                            ? AppColors.royalGold
                            : AppColors.textMuted,
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
              else if (onSave != null)
                IconButton(
                  key: ValueKey('rep_standee_save_${standee.code}'),
                  tooltip: 'Save a printable standee',
                  onPressed: onSave,
                  // The SAME neutral glyph the admin screen uses, for the same
                  // reason: on a phone this opens a share sheet, in a browser it
                  // is a download, and the icon must not claim either.
                  icon: const Icon(Icons.save_alt),
                  color: AppColors.textSecondary,
                ),
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
