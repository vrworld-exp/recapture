// lib/presentation/screens/projects/owner_model_history_screen.dart
//
// The OWNER's per-project 3D-model list — what a normal user gets when they tap
// "Models" on their own project.
//
// Replaces the old behaviour of opening the newest model straight in the
// viewer. That shortcut hid everything else the project had: an earlier
// generation, a regenerate that is still running, and the optimized copy the
// Optimize action produces. A list makes all of them addressable.
//
// Owner-safe by CONSTRUCTION, in three independent ways — none of which relies
// on this screen remembering to hide anything:
//   1. It reads [ownerModelHistoryProvider], which polls the owner route and
//      parses the owner DTO. The staff-only fields are not merely unrendered,
//      they are never received.
//   2. Its only actions are Optimize (through the owner-scoped, rate-limited
//      endpoint) and "open this model". There is no Approve and no Export here.
//   3. It pushes [ModelViewerScreen] DIRECTLY rather than through the
//      `modelViewer` named route: that route resolves the record out of the
//      STAFF provider, which an owner would only ever 403 on. Approve is left
//      null, and the viewer's Export button gates itself on `isStaffProvider`.
//
// Pure observer, like the staff screen: polling, backoff and the stop condition
// all live in the notifier, so this adds no second loop.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/projects/owner_model_history_notifier.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';
import '../../widgets/model_row.dart';
import 'model_viewer_screen.dart';
import 'preview_gallery_screen.dart' show failureCopy;

class OwnerModelHistoryScreen extends ConsumerWidget {
  const OwnerModelHistoryScreen({
    super.key,
    required this.projectId,
    this.projectName,
    this.onRegenerate,
    this.renderBuilder,
  });

  final String projectId;

  /// Titles the pushed viewer, so the user still knows which project they are
  /// in one screen deeper. Falls back to the viewer's own default.
  final String? projectName;

  /// Owner "make a new version" action, forwarded to the viewer. Optional
  /// because the list itself never regenerates — that stays the viewer's call,
  /// exactly as it was before this screen existed.
  final VoidCallback? onRegenerate;

  /// Injectable for tests — the real viewer drives a WebView, which has no
  /// platform implementation in a widget test.
  final ModelRenderBuilder? renderBuilder;

  /// Fires the Optimize request and reports the outcome.
  ///
  /// Deliberately quiet on success: the notifier's refresh puts a pending `OPT`
  /// row at the head of the list, which says more than a snackbar could. Only a
  /// FAILURE needs words, and they are mapped copy — never a raw code, since
  /// the server's 409 reasons are internal rule ids.
  Future<void> _optimize(
    BuildContext context,
    WidgetRef ref,
    ProjectModelView model,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(ownerModelHistoryProvider(projectId).notifier)
          .optimize(model.id);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(failureCopy(error))));
    }
  }

  void _openViewer(BuildContext context, WidgetRef ref, ProjectModelView model) {
    // Guarded here as well as on the row's onTap: a pending or failed record
    // has nothing to render.
    if (!model.isViewable) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelViewerScreen(
          model: model,
          title: projectName ?? '3D Model',
          onRegenerate: onRegenerate,
          // The SAME owner-scoped call the row uses. No staff route, no
          // bypass — and no onApprove, which is what keeps the staff-only
          // action off an owner's viewer.
          onOptimize: () => _optimize(context, ref, model),
          renderBuilder:
              renderBuilder ?? ModelViewerScreen.defaultRenderBuilder,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(ownerModelHistoryProvider(projectId));
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
        error: (error, __) => _OwnerHistoryErrorView(
          message: failureCopy(error),
          onRetry: () => ref.invalidate(ownerModelHistoryProvider(projectId)),
        ),
        data: (models) => models.isEmpty
            ? const _OwnerEmptyView()
            : RefreshIndicator(
                color: AppColors.mirageRed,
                backgroundColor: AppColors.surface1,
                onRefresh: () => ref
                    .read(ownerModelHistoryProvider(projectId).notifier)
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
                      key: ValueKey('owner_model_row_${model.id}'),
                      model: model,
                      // Owners are shown WHERE the model came from; staff are
                      // looking at the pipeline that made it and don't need it.
                      showSourceBadge: true,
                      onTap: model.isViewable
                          ? () => _openViewer(context, ref, model)
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

/// No models yet. Unlike the staff empty state this points at nothing: an owner
/// creates models from the project card ("Generate 3D model"), not from here,
/// and a dead link into the staff Preview gallery would only 403.
class _OwnerEmptyView extends StatelessWidget {
  const _OwnerEmptyView();

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
              'Create a 3D model from this project to see it here.',
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

class _OwnerHistoryErrorView extends StatelessWidget {
  const _OwnerHistoryErrorView({required this.message, required this.onRetry});

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
