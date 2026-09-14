// lib/presentation/screens/projects/model_generation_screen.dart
//
// Watches ONE Meshy generation from QUEUED → SUCCEEDED/FAILED and takes the
// next step itself: the 3D viewer OPENS on success, or Retry returns to the
// photo selection on failure.
//
// THERE IS NO "View 3D Model" BUTTON, deliberately. Reaching 100% is the
// answer to the only question this screen asks, so a button in between is a
// second confirmation of something the user already asked for by pressing
// Create Model. The open is latched ([_opened]) and backing out of the viewer
// pops this screen too — otherwise a back gesture would be answered by
// immediately reopening the viewer, or by stranding the user on a finished
// progress screen with nothing left to do.
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

class ModelGenerationScreen extends ConsumerStatefulWidget {
  const ModelGenerationScreen({
    super.key,
    required this.projectId,
    required this.modelId,
    this.renderBuilder = ModelViewerScreen.defaultRenderBuilder,
  });

  final String projectId;

  /// The record this screen follows — NOT "the latest": an artist may kick off
  /// a regenerate, and this screen must keep showing the run it was opened for.
  final String modelId;

  /// Forwarded to the viewer this screen opens on success. Same seam, same
  /// reason as [ModelViewerScreen.renderBuilder]: the real renderer drives a
  /// WebView, which has no platform implementation in a widget test — and now
  /// that the viewer opens BY ITSELF, a test of this screen reaches it.
  final ModelRenderBuilder renderBuilder;

  @override
  ConsumerState<ModelGenerationScreen> createState() =>
      _ModelGenerationScreenState();
}

class _ModelGenerationScreenState extends ConsumerState<ModelGenerationScreen> {
  /// One-shot latch for the automatic open. Polling keeps rebuilding this
  /// screen while the viewer sits on top of it, and a user who backs out has
  /// said they want OUT — without this, either would reopen the viewer.
  bool _opened = false;

  ProjectModelView? _find(List<ProjectModelView>? models) {
    for (final m in models ?? const <ProjectModelView>[]) {
      if (m.id == widget.modelId) return m;
    }
    return null;
  }

  Future<void> _openViewer(ProjectModelView model) async {
    final canApprove = ref.read(isStaffProvider);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelViewerScreen(
          model: model,
          renderBuilder: widget.renderBuilder,
          onApprove: canApprove
              ? () => ref
                  .read(modelGenerationProvider(widget.projectId).notifier)
                  .approve(model.id)
              : null,
        ),
      ),
    );
    // Back from the viewer lands where the run started (the photo set), not on
    // a finished progress screen. This screen has nothing left to say.
    if (mounted) await Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(modelGenerationProvider(widget.projectId));
    final model = _find(async.valueOrNull);

    // 100% means done, so done is what happens. Deferred to after this frame
    // because a build must not navigate; latched because this build runs again
    // on every poll and again when the viewer is dismissed.
    if (model?.status == ModelStatus.succeeded && !_opened) {
      _opened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openViewer(model!);
      });
    }

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
            // One live timeline for both pending states: the step that is
            // active mirrors what the backend worker is doing right now.
            ModelStatus.queued ||
            ModelStatus.processing =>
              _LiveProgress(
                key: const ValueKey('model_gen_pending'),
                model: model!,
              ),
            // Not a dead end and not a decision: the viewer is already on
            // its way in, and this is the frame underneath it.
            ModelStatus.succeeded => const _Pending(
                key: ValueKey('model_gen_succeeded'),
                headline: 'Your model is ready',
                detail: 'Opening the 3D preview…',
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

/// The four backend steps of one generation, in order. The active one mirrors
/// the record's live [ModelProgress]; a record with none (QUEUED, or an older
/// backend that doesn't report progress) still renders — the timeline just
/// stays on its best-known step with an indeterminate bar.
enum _GenStep {
  queued('Queued', 'Waiting for the processing worker to pick this up.'),
  preparing('Preparing photos', 'Sending your selected photos to Maya AI.'),
  generating('Generating 3D model',
      'Maya AI is building the 3D model from your photos.'),
  finalizing('Saving model', 'Downloading the result into ReCapture storage.');

  const _GenStep(this.label, this.detail);

  final String label;
  final String detail;
}

/// Live "what is the backend doing" view for a QUEUED/PROCESSING record:
/// an overall progress bar plus a step timeline, driven by the `progress`
/// field the worker publishes while it runs.
class _LiveProgress extends StatelessWidget {
  const _LiveProgress({super.key, required this.model});

  final ProjectModelView model;

  _GenStep get _active {
    if (model.status == ModelStatus.queued) return _GenStep.queued;
    return switch (model.progress?.phase) {
      ModelProgressPhase.preparing => _GenStep.preparing,
      ModelProgressPhase.finalizing => _GenStep.finalizing,
      // GENERATING, an unknown phase, and no progress at all (older backend or
      // a just-claimed job) all land on the long middle step.
      _ => _GenStep.generating,
    };
  }

  /// Overall 0–1 across the whole run, so the bar only ever moves forward:
  /// queued/preparing are the thin head, Meshy's own 0–100 fills the long
  /// middle, finalizing is the tail. Null → indeterminate (we know the phase
  /// is underway but have no number for it yet).
  double? get _overall {
    final percent = model.progress?.percent;
    return switch (_active) {
      _GenStep.queued => 0.03,
      _GenStep.preparing => 0.08,
      _GenStep.generating =>
        percent == null ? null : 0.10 + 0.80 * (percent / 100),
      _GenStep.finalizing => 0.95,
    };
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final active = _active;
    final overall = _overall;
    final percent = model.progress?.percent;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                active == _GenStep.generating && percent != null
                    ? 'Generating your model…'
                    : '${active.label}…',
                style: text.titleMedium,
              ),
            ),
            if (active == _GenStep.generating && percent != null)
              Text(
                '$percent%',
                key: const ValueKey('model_gen_percent'),
                style: text.titleMedium?.copyWith(color: AppColors.mirageRed),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          // Animate toward each new overall value so poll updates glide instead
          // of jumping; an indeterminate bar keeps its own built-in motion.
          child: overall == null
              ? const LinearProgressIndicator(
                  minHeight: 6,
                  color: AppColors.mirageRed,
                  backgroundColor: AppColors.surface2,
                )
              : TweenAnimationBuilder<double>(
                  tween: Tween(end: overall),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOut,
                  builder: (_, value, __) => LinearProgressIndicator(
                    value: value,
                    minHeight: 6,
                    color: AppColors.mirageRed,
                    backgroundColor: AppColors.surface2,
                  ),
                ),
        ),
        const SizedBox(height: AppSpacing.xl),
        for (final step in _GenStep.values) ...[
          _StepRow(
            step: step,
            state: step.index < active.index
                ? _StepState.done
                : step == active
                    ? _StepState.active
                    : _StepState.upcoming,
          ),
          if (step != _GenStep.values.last)
            const SizedBox(height: AppSpacing.md),
        ],
        const SizedBox(height: AppSpacing.xl),
        Text(
          'This usually takes a few minutes — you can leave this screen and '
          'come back.',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

enum _StepState { done, active, upcoming }

/// One timeline row: a state icon, the step's name, and — for the step that is
/// running right now — one line of "what the backend is doing".
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.state});

  final _GenStep step;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: switch (state) {
            _StepState.done => const Icon(Icons.check_circle,
                size: 18, color: AppColors.mirageRed),
            _StepState.active => const Padding(
                padding: EdgeInsets.all(2),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.mirageRed,
                ),
              ),
            _StepState.upcoming => const Icon(Icons.circle_outlined,
                size: 18, color: AppColors.textMuted),
          },
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                step.label,
                style: state == _StepState.upcoming
                    ? text.bodyMedium?.copyWith(color: AppColors.textMuted)
                    : text.bodyMedium,
              ),
              if (state == _StepState.active) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  step.detail,
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ],
          ),
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
