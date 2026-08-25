// lib/presentation/screens/projects/model_history_screen.dart
//
// Staff-only per-project 3D-model generation HISTORY — the persistent door into
// models, which are otherwise unreachable the moment you leave the screen that
// created them.
//
// Every attempt is listed, not just the newest: the backend returns the full
// history so an artist can COMPARE generations from different photo selections
// and approve the best one. Rows are labelled by timestamp, never by index — an
// index renumbers itself as new generations land at the head of the list.
//
// Pure observer: the polling, backoff and stop condition all live in
// [ModelGenerationNotifier] (already watching this project) — this screen adds
// no second loop. Failures render the backend's mapped message only, never a
// raw code or URL.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/projects/model_generation_notifier.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';
// The row itself is shared with the OWNER history screen — see model_row.dart
// for why one widget serves both surfaces. `formatBytes` is re-exported so the
// binary-divisor helper keeps a single definition and a single import site.
import '../../widgets/model_row.dart';
export '../../widgets/model_row.dart' show formatBytes;
import 'preview_gallery_screen.dart'
    show failureCopy, kMaxModelPhotos, kMinModelPhotos;

class ModelHistoryScreen extends ConsumerWidget {
  const ModelHistoryScreen({super.key, required this.projectId});

  final String projectId;

  /// Fires the Optimize request and reports the outcome.
  ///
  /// Deliberately quiet on success: the refresh inside the notifier puts a
  /// pending `OPT` row at the head of the list, which says more than a snackbar
  /// could. Only a FAILURE needs words, and they are mapped copy — never a raw
  /// code (the server's 409 reasons are internal rule ids).
  Future<void> _optimize(
    BuildContext context,
    WidgetRef ref,
    ProjectModelView model,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(modelGenerationProvider(projectId).notifier)
          .optimize(model.id);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(failureCopy(error))));
    }
  }

  void _openViewer(BuildContext context, ProjectModelView model) {
    // Guarded here as well as on the row's onTap: a non-viewable record has
    // nothing to render, and the viewer resolves by id rather than trusting a
    // passed-in model.
    if (!model.isViewable) return;
    context.pushNamed(
      AppRouteNames.modelViewer,
      pathParameters: {'id': projectId, 'modelId': model.id},
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(modelGenerationProvider(projectId));
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textSecondary),
          tooltip: 'Back',
          // Funnel BACK through the shared handler so hardware back and this
          // arrow behave identically even on a go()-replaced entry.
          onPressed: () => navigateBack(context),
        ),
        title: Text('Models', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: async.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.mirageRed),
        ),
        error: (error, __) => _HistoryErrorView(
          message: failureCopy(error),
          onRetry: () => ref.invalidate(modelGenerationProvider(projectId)),
        ),
        data: (models) => models.isEmpty
            ? const _EmptyView()
            : RefreshIndicator(
                color: AppColors.mirageRed,
                backgroundColor: AppColors.surface1,
                onRefresh: () => ref
                    .read(modelGenerationProvider(projectId).notifier)
                    .refresh(),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  // The backend already sorts newest-first — re-sorting here
                  // would only risk disagreeing with it.
                  itemCount: models.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    final model = models[index];
                    return ModelRow(
                      key: ValueKey('model_row_${model.id}'),
                      model: model,
                      onTap: model.isViewable
                          ? () => _openViewer(context, model)
                          : null,
                      onOptimize: () => _optimize(context, ref, model),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

/// No generations yet. Points at the Preview gallery, since that is where one
/// is started — an empty list with no way forward would be a dead end.
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.view_in_ar_outlined,
                color: AppColors.textMuted, size: 40),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'No models yet.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Open Preview, pick $kMinModelPhotos–$kMaxModelPhotos photos from '
              'different angles, then tap Create Model.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryErrorView extends StatelessWidget {
  const _HistoryErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, color: AppColors.textMuted, size: 40),
            const SizedBox(height: AppSpacing.lg),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: 'Retry',
              icon: Icons.refresh,
              isFullWidth: false,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
