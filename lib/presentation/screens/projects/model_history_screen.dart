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
import 'preview_gallery_screen.dart'
    show failureCopy, kMaxModelPhotos, kMinModelPhotos;

class ModelHistoryScreen extends ConsumerWidget {
  const ModelHistoryScreen({super.key, required this.projectId});

  final String projectId;

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
                    return _ModelRow(
                      key: ValueKey('model_row_${model.id}'),
                      model: model,
                      onTap: model.isViewable
                          ? () => _openViewer(context, model)
                          : null,
                    );
                  },
                ),
              ),
      ),
    );
  }
}

/// One generation attempt: when it ran, how it ended, what it was built from.
class _ModelRow extends StatelessWidget {
  const _ModelRow({super.key, required this.model, this.onTap});

  final ProjectModelView model;

  /// Null for a record with nothing to open — a FAILED one, a pending one, or a
  /// SUCCEEDED one whose GLB is somehow missing. A null onTap is what makes the
  /// row inert; the chevron follows it so the affordance can't lie.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: AppColors.textMuted);
    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              _RowThumbnail(model: model),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '${_stamp(model.createdAt)} · ${_statusLabel(model.status)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium,
                          ),
                        ),
                        if (model.approved) ...[
                          const SizedBox(width: AppSpacing.sm),
                          const _ApprovedBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      _detail(model),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (model.status.isPending)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.textMuted,
                  ),
                )
              else if (onTap != null)
                const Icon(Icons.chevron_right,
                    color: AppColors.textMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// The secondary line: why it failed, or what it was built from — the photo
  /// count is the main thing that differs between attempts, and usually the
  /// reason one succeeded where another didn't.
  static String _detail(ProjectModelView model) {
    if (model.error case final error?) return error.message;
    if (model.status.isPending) {
      // Surface the worker's live phase when the backend reports one, so the
      // history row tells staff what is actually happening right now.
      return switch (model.progress?.phase) {
        ModelProgressPhase.preparing => 'Preparing photos…',
        ModelProgressPhase.generating =>
          'Generating 3D model · ${model.progress!.percent}%',
        ModelProgressPhase.finalizing => 'Saving the model…',
        ModelProgressPhase.unknown ||
        null =>
          'Generating — this takes a few minutes.',
      };
    }
    final n = model.selectedKeys.length;
    if (n == 0) return '';
    return n == 1 ? '1 photo' : '$n photos';
  }

  static String _statusLabel(ModelStatus status) => switch (status) {
        ModelStatus.queued => 'Queued',
        ModelStatus.processing => 'Processing…',
        ModelStatus.succeeded => 'Succeeded',
        ModelStatus.failed => 'Failed',
        ModelStatus.unknown => 'Unknown',
      };

  /// Compact local "Jul 17, 11:42". Hand-rolled: the app has no `intl`
  /// dependency, and one date format does not justify adding it.
  static String _stamp(DateTime? at) {
    if (at == null) return 'Unknown date';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = at.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${months[local.month - 1]} ${local.day}, $hh:$mm';
  }
}

/// The Meshy preview image we re-hosted, when the attempt got far enough to
/// produce one; otherwise a neutral placeholder so every row is the same shape.
class _RowThumbnail extends StatelessWidget {
  const _RowThumbnail({required this.model});

  final ProjectModelView model;

  @override
  Widget build(BuildContext context) {
    final url = model.previewUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: SizedBox(
        width: 44,
        height: 44,
        child: url == null
            ? const _ThumbPlaceholder()
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const _ThumbPlaceholder(),
              ),
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface2,
      alignment: Alignment.center,
      child: const Icon(Icons.view_in_ar_outlined,
          color: AppColors.textMuted, size: 20),
    );
  }
}

class _ApprovedBadge extends StatelessWidget {
  const _ApprovedBadge();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, size: 13, color: AppColors.mirageRed),
        const SizedBox(width: AppSpacing.xs),
        Text(
          'Approved',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.mirageRed),
        ),
      ],
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
