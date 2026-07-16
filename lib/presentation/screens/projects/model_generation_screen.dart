// lib/presentation/screens/projects/model_generation_screen.dart
//
// Watches ONE Meshy generation from QUEUED → SUCCEEDED/FAILED and offers the
// next step: View 3D Model, or Retry (which returns to the photo selection).
//
// Pure observer: the polling, backoff and stop condition all live in
// [ModelGenerationNotifier] — this screen only renders whichever record it was
// opened for. Generation takes minutes, so the copy is explicit that leaving is
// safe.
//
// Failures render MAPPED copy only, never a raw code or URL.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/user_role_notifier.dart';
import '../../../application/projects/model_generation_notifier.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';
import 'model_viewer_screen.dart';

class ModelGenerationScreen extends ConsumerWidget {
  const ModelGenerationScreen({
    super.key,
    required this.projectId,
    required this.modelId,
  });

  final String projectId;

  /// The record this screen follows — NOT "the latest": an artist may kick off
  /// a regenerate, and this screen must keep showing the run it was opened for.
  final String modelId;

  ProjectModelView? _find(List<ProjectModelView>? models) {
    for (final m in models ?? const <ProjectModelView>[]) {
      if (m.id == modelId) return m;
    }
    return null;
  }

  Future<void> _openViewer(
    BuildContext context,
    WidgetRef ref,
    ProjectModelView model,
  ) async {
    final canApprove = ref.read(isStaffProvider);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelViewerScreen(
          model: model,
          onApprove: canApprove
              ? () => ref
                  .read(modelGenerationProvider(projectId).notifier)
                  .approve(model.id)
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(modelGenerationProvider(projectId));
    final model = _find(async.valueOrNull);

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textSecondary),
        title: Text('Create Model', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: switch (model?.status) {
            // The record is not in the list yet (first fetch in flight).
            null => const _Pending(
                key: ValueKey('model_gen_pending'),
                headline: 'Starting…',
                detail: 'Setting up your model generation.',
              ),
            ModelStatus.queued => const _Pending(
                key: ValueKey('model_gen_pending'),
                headline: 'Queued',
                detail:
                    'Your model is waiting to start. This usually takes a few '
                    'minutes — you can leave this screen and come back.',
              ),
            ModelStatus.processing => const _Pending(
                key: ValueKey('model_gen_pending'),
                headline: 'Generating your model…',
                detail:
                    'Meshy AI is building the 3D model from your photos. This '
                    'usually takes a few minutes — you can leave this screen '
                    'and come back.',
              ),
            ModelStatus.succeeded => _Succeeded(
                key: const ValueKey('model_gen_succeeded'),
                onView: () => _openViewer(context, ref, model!),
              ),
            // A status this build doesn't know is treated as terminal, so the
            // user gets a way forward instead of an endless spinner.
            ModelStatus.failed || ModelStatus.unknown => _Failed(
                key: const ValueKey('model_gen_failed'),
                onRetry: () => Navigator.of(context).maybePop(),
              ),
          },
        ),
      ),
    );
  }
}

class _Pending extends StatelessWidget {
  const _Pending({super.key, required this.headline, required this.detail});

  final String headline;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(color: AppColors.mirageRed),
        const SizedBox(height: AppSpacing.xl),
        Text(headline, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

class _Succeeded extends StatelessWidget {
  const _Succeeded({super.key, required this.onView});

  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.view_in_ar, color: AppColors.mirageRed, size: 44),
        const SizedBox(height: AppSpacing.xl),
        Text('Your model is ready',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xl),
        AppButton(
          key: const ValueKey('view_model_cta'),
          label: 'View 3D Model',
          icon: Icons.view_in_ar_outlined,
          isFullWidth: false,
          onPressed: onView,
        ),
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, color: AppColors.textMuted, size: 40),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'We couldn’t create a model from those photos.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Try again with a different selection — photos from clearly '
          'different angles work best.',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.xl),
        AppButton(
          label: 'Choose photos again',
          icon: Icons.refresh,
          isFullWidth: false,
          onPressed: onRetry,
        ),
      ],
    );
  }
}
