// lib/presentation/screens/projects/model_building_screen.dart
//
// The OWNER's view of a model being built for them — the state that only exists
// because generation now starts on its own when a capture finishes.
//
// The whole job of this screen is to make an unrequested, minutes-long wait feel
// intentional rather than broken. Three things carry that:
//   • it names what is happening ("Creating your 3D model") — the user never
//     asked for this, so it must explain itself;
//   • it gives a duration ("usually takes a few minutes") — an unbounded
//     spinner reads as a hang;
//   • it says leaving is safe — generation continues server-side, and a user
//     who feels trapped will kill the app and assume it failed.
//
// Pure observer: polling, backoff and the stop condition all live in
// [OwnerModelStateNotifier]. Failures render mapped copy only — never a code,
// a URL, or anything about Meshy.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/projects/owner_model_state_notifier.dart';
import '../../../data/repositories/projects_repository.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';
import 'model_viewer_screen.dart';

class ModelBuildingScreen extends ConsumerWidget {
  const ModelBuildingScreen({
    super.key,
    required this.projectId,
    required this.projectName,
    this.onRegenerate,
  });

  final String projectId;
  final String projectName;

  /// Opens the manual Prepare-Images path. Null when this build has no such
  /// entry point for this user — the CTA is then simply absent rather than
  /// present-and-dead.
  final VoidCallback? onRegenerate;

  Future<void> _openViewer(BuildContext context, ProjectModelView model) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelViewerScreen(model: model, title: projectName),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(ownerModelStateProvider(projectId));

    return Scaffold(
      appBar: AppBar(title: Text(projectName)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(ownerModelStateProvider(projectId).notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SizedBox(height: AppSpacing.xl),
              async.when(
                loading: () => const _Waiting(percent: null),
                // A load error is not a generation failure: the model may be
                // fine and the network may not. Say so, and let pull-to-refresh
                // resolve it rather than claiming the model failed.
                error: (_, __) => const _Message(
                  icon: Icons.cloud_off_outlined,
                  title: "Can't check right now",
                  body: 'Pull down to try again.',
                ),
                data: (state) => _Body(
                  state: state,
                  onView: (model) => _openViewer(context, model),
                  onRegenerate: onRegenerate,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.onView, this.onRegenerate});

  final OwnerModelState state;
  final void Function(ProjectModelView model) onView;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    final model = state.model;
    final generation = state.generation;

    // Order matters. A finished model wins over an in-flight run: if a
    // regenerate is going, the user should still be able to open the model they
    // already have rather than being made to wait again for one they own.
    if (model != null && model.isViewable) {
      return _Ready(
        model: model,
        isRegenerating: state.isGenerating,
        onView: () => onView(model),
        onRegenerate: onRegenerate,
      );
    }

    if (state.isGenerating) {
      return _Waiting(percent: generation?.progressPercent);
    }

    if (generation != null && generation.hasFailed) {
      return _Message(
        icon: Icons.error_outline,
        title: "We couldn't build your model",
        // Deliberately no code, no upstream text. The one useful thing an owner
        // can do is try again with photos they choose.
        body: 'Something went wrong while creating the 3D model from your photos.',
        action: onRegenerate == null
            ? null
            : AppButton(label: 'Try again', onPressed: onRegenerate),
      );
    }

    return _Message(
      icon: Icons.view_in_ar_outlined,
      title: 'No 3D model yet',
      body: 'Capture this object to have a model created for you.',
    );
  }
}

/// The waiting state — the one this screen exists for.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.percent});

  /// Coarse 0–100 when the server has reported any; null shows an
  /// indeterminate bar rather than a fake number.
  final int? percent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(Icons.auto_awesome_outlined, size: 56, color: AppColors.royalGold),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Creating your 3D model',
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'This usually takes a few minutes.',
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xl),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            // A null value renders indeterminate — honest about not knowing,
            // instead of inventing progress.
            value: percent == null ? null : percent! / 100,
            minHeight: 8,
          ),
        ),
        if (percent != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text('$percent%', style: theme.textTheme.labelMedium),
        ],
        const SizedBox(height: AppSpacing.xl),
        Text(
          "You can leave this screen — we'll keep going and it'll be waiting in "
          'your project when it\'s done.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// The finished state, reachable while a NEWER generation is still running.
class _Ready extends StatelessWidget {
  const _Ready({
    required this.model,
    required this.isRegenerating,
    required this.onView,
    this.onRegenerate,
  });

  final ProjectModelView model;
  final bool isRegenerating;
  final VoidCallback onView;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(Icons.check_circle_outline, size: 56, color: AppColors.success),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Your 3D model is ready',
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        if (model.isAutoGenerated) ...[
          const SizedBox(height: AppSpacing.sm),
          // Sets expectations BEFORE the model opens. A four-photo generation
          // shown as a finished product disappoints; the same model shown as an
          // AI preview reads as a bonus.
          Text(
            kAutoGeneratedBadgeLabel,
            style: theme.textTheme.labelMedium,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        AppButton(label: 'View 3D model', onPressed: onView),
        if (isRegenerating) ...[
          const SizedBox(height: AppSpacing.lg),
          Text(
            "We're building an updated version — this one stays available until "
            "it's ready.",
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ] else if (onRegenerate != null) ...[
          const SizedBox(height: AppSpacing.md),
          TextButton(
            onPressed: onRegenerate,
            child: const Text('Not happy with it? Try different photos'),
          ),
        ],
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(icon, size: 56, color: theme.colorScheme.outline),
        const SizedBox(height: AppSpacing.lg),
        Text(title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.sm),
        Text(body, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
        if (action != null) ...[
          const SizedBox(height: AppSpacing.xl),
          action!,
        ],
      ],
    );
  }
}
