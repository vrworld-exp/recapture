// lib/presentation/screens/projects/model_building_screen.dart
//
// The view of a model being built — the state that exists because a generation
// can now be started by a button (or by a capture finishing) and then takes
// minutes.
//
// The whole job of this screen is to make a minutes-long wait feel intentional
// rather than broken. Four things carry that:
//   • it names what is happening ("Creating your 3D model") — the user may not
//     have asked for this, so it must explain itself;
//   • it gives a duration ("usually takes a few minutes") — an unbounded
//     spinner reads as a hang;
//   • it says leaving is safe — generation continues server-side, and a user
//     who feels trapped will kill the app and assume it failed;
//   • it shows the steps, so the wait has visible structure.
//
// ── TWO SOURCES, DELIBERATELY NOT MERGED ────────────────────────────────────
// The REQUEST steps come from [modelGenerationRequestProvider] and are ALREADY
// FINISHED when they arrive (the server does all six inside one sub-second
// POST). The WORKER half comes from [ownerModelStateProvider]'s polling. The
// screen composes them; it never pretends the first half is live.
//
// Owner-facing copy is mapped only — never a code, a key, a URL, or anything
// about Meshy. The raw trace is behind a staff + debug gate.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/user_role_notifier.dart';
import '../../../application/projects/model_generation_request_notifier.dart';
import '../../../application/projects/owner_model_state_notifier.dart';
import '../../../application/projects/projects_notifier.dart';
import '../../../data/repositories/projects_repository.dart';
import '../../../domain/entities/generation_trace.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';
import '../../widgets/step_checklist_row.dart';
import 'model_viewer_screen.dart';

class ModelBuildingScreen extends ConsumerStatefulWidget {
  const ModelBuildingScreen({
    super.key,
    required this.projectId,
    required this.projectName,
    this.onRegenerate,
    this.watchOwnerState = true,
    this.onOpenHistory,
  });

  final String projectId;
  final String projectName;

  /// Opens the manual Prepare-Images path. Null when this build has no such
  /// entry point for this user — the CTA is then simply absent rather than
  /// present-and-dead.
  final VoidCallback? onRegenerate;

  /// Whether to poll `GET /projects/:id` for the worker half.
  ///
  /// FALSE on the staff Live tab, where the project belongs to someone else and
  /// the owner endpoint would 404. The screen then shows the request trace and
  /// hands off to [onOpenHistory] instead of inventing progress it cannot see.
  final bool watchOwnerState;

  /// Opens the staff generation history — the destination when this screen
  /// cannot watch the run itself.
  final VoidCallback? onOpenHistory;

  @override
  ConsumerState<ModelBuildingScreen> createState() => _ModelBuildingScreenState();
}

class _ModelBuildingScreenState extends ConsumerState<ModelBuildingScreen> {
  /// The highest percent seen this session.
  ///
  /// Progress writes are best-effort and fenced, so a percent can arrive stale
  /// or out of order. A bar that jumps backwards reads as a bug, so the value
  /// only ever climbs — the number shown is the best the server has ever
  /// reported, not necessarily its latest word.
  int? _maxPercent;

  /// When the number last actually moved — the "still working…" affordance's
  /// input. A stalled generation otherwise looks like a frozen app.
  DateTime _lastMovement = DateTime.now();

  static const _stallThreshold = Duration(seconds: 45);

  int? _monotonic(int? reported) {
    if (reported == null) return _maxPercent;
    final current = _maxPercent;
    if (current == null || reported > current) {
      // setState is deliberately NOT called here — this runs during build, from
      // a state the provider just pushed. The rebuild is already happening.
      _maxPercent = reported;
      _lastMovement = DateTime.now();
      return reported;
    }
    return current;
  }

  bool get _looksStalled =>
      DateTime.now().difference(_lastMovement) > _stallThreshold;

  Future<void> _openViewer(ProjectModelView model) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelViewerScreen(model: model, title: widget.projectName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final request = ref.watch(modelGenerationRequestProvider(widget.projectId));

    // A finished generation changes the PROJECTS LIST, not just this screen:
    // `modelCount` is aggregated server-side into the list DTO, so the Models
    // button stays hidden until the list is re-fetched.
    if (widget.watchOwnerState) {
      ref.listen<AsyncValue<OwnerModelState>>(
        ownerModelStateProvider(widget.projectId),
        (previous, next) {
          final hadModel = previous?.valueOrNull?.hasViewableModel ?? false;
          final hasModel = next.valueOrNull?.hasViewableModel ?? false;
          if (!hadModel && hasModel) ref.invalidate(projectsProvider);
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.projectName)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            if (!widget.watchOwnerState) return;
            await ref
                .read(ownerModelStateProvider(widget.projectId).notifier)
                .refresh();
          },
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SizedBox(height: AppSpacing.lg),
              ..._content(request),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _content(ModelGenerationRequestState request) {
    // ── The request itself failed (offline, ceiling, switched off). Nothing was
    // started, so there is nothing to watch — say what happened and stop.
    if (request.failure case final failure?) {
      return [
        _Message(
          icon: Icons.error_outline,
          title: "Couldn't start",
          body: modelGenerationFailureMessage(failure),
        ),
      ];
    }

    // ── The server REFUSED to spend on these photos. The most valuable screen
    // here, not the least: the selector has never seen a real capture, so this
    // is a likely first-week outcome and it has to be explained well.
    if (request.wasDeclined) {
      final reason = request.request?.declineReason ?? GenerationDeclineReason.unknown;
      return [
        _Message(
          icon: Icons.photo_camera_back_outlined,
          title: "We couldn't build a model from this capture",
          body: reason.message,
          action: widget.onRegenerate == null
              ? null
              : AppButton(label: 'Choose photos yourself', onPressed: widget.onRegenerate),
        ),
        _StaffTrace(
          steps: request.request?.steps ?? const [],
          selection: request.request?.trace,
        ),
      ];
    }

    if (request.isRequesting) {
      return [
        const _Waiting(percent: null, isStalled: false),
        const _Timeline(requestDone: false, percent: null),
      ];
    }

    // ── The request enqueued, but this screen cannot watch the worker (a staff
    // user on someone else's project). Show what was decided and point at the
    // surface that CAN watch it, rather than faking progress.
    if (!widget.watchOwnerState) {
      return [
        const _Waiting(percent: null, isStalled: false),
        const _Timeline(requestDone: true, percent: null),
        if (widget.onOpenHistory != null) ...[
          const SizedBox(height: AppSpacing.xl),
          AppButton.secondary(
            label: 'View generation history',
            onPressed: widget.onOpenHistory,
          ),
        ],
        _StaffTrace(
          steps: request.request?.steps ?? const [],
          selection: request.request?.trace,
        ),
      ];
    }

    final async = ref.watch(ownerModelStateProvider(widget.projectId));
    return [
      async.when(
        loading: () => const _Waiting(percent: null, isStalled: false),
        // A load error is not a generation failure: the model may be fine and
        // the network may not. Say so, and let pull-to-refresh resolve it
        // rather than claiming the model failed.
        error: (_, __) => const _Message(
          icon: Icons.cloud_off_outlined,
          title: "Can't check right now",
          body: 'Pull down to try again.',
        ),
        data: (state) => _Body(
          state: state,
          percent: _monotonic(state.generation?.progressPercent),
          isStalled: _looksStalled,
          hasStoppedChecking:
              ref.read(ownerModelStateProvider(widget.projectId).notifier).pollsExhausted,
          requestDone: request.hasResult,
          onView: _openViewer,
          onRegenerate: widget.onRegenerate,
        ),
      ),
      _StaffTrace(
        steps: request.request?.steps ?? const [],
        selection: request.request?.trace,
      ),
    ];
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.state,
    required this.percent,
    required this.isStalled,
    required this.hasStoppedChecking,
    required this.requestDone,
    required this.onView,
    this.onRegenerate,
  });

  final OwnerModelState state;
  final int? percent;
  final bool isStalled;
  final bool hasStoppedChecking;
  final bool requestDone;
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
      // The poll cap ran out with the generation still pending. Saying nothing
      // would leave a spinner that never resolves — worse than admitting we
      // stopped looking.
      if (hasStoppedChecking) {
        return _Message(
          icon: Icons.hourglass_disabled_outlined,
          title: 'This is taking longer than usual',
          body: "We've stopped checking for now. Pull down to check again.",
        );
      }
      return Column(
        children: [
          _Waiting(percent: percent, isStalled: isStalled),
          _Timeline(requestDone: requestDone, percent: percent),
        ],
      );
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

    return const _Message(
      icon: Icons.view_in_ar_outlined,
      title: 'No 3D model yet',
      body: 'Capture this object to have a model created for you.',
    );
  }
}

/// The waiting state — the one this screen exists for.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.percent, required this.isStalled});

  /// Coarse 0–100 when the server has reported any; null shows an
  /// indeterminate bar rather than a fake number.
  final int? percent;

  /// The number has not moved for a while. Says so, instead of letting a
  /// stalled run read as a frozen app.
  final bool isStalled;

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
        if (isStalled) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Still working — some objects take longer.',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            textAlign: TextAlign.center,
          ),
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

/// The plain-language timeline. Five rows, no vocabulary from our pipeline.
///
/// HONESTY NOTE: the owner payload carries a single percent and deliberately no
/// phase name (those describe our internals). Rows 3–5 are therefore a
/// PRESENTATION of that one number across bands, not five separate facts
/// reported by the server. They exist so a multi-minute wait has visible
/// structure; they never claim more than the percent does.
///
/// Only ever rendered WHILE a generation is running — a finished one replaces
/// the whole body with [_Ready], so there is no "all five ticked" state to
/// build for.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.requestDone, required this.percent});

  /// The server has finished picking photos and queued the job.
  final bool requestDone;
  final int? percent;

  StepRowStatus _statusFor(int lowerBound, int upperBound) {
    final p = percent;
    if (p == null) return lowerBound == 0 ? StepRowStatus.running : StepRowStatus.pending;
    if (p >= upperBound) return StepRowStatus.done;
    if (p >= lowerBound) return StepRowStatus.running;
    return StepRowStatus.pending;
  }

  @override
  Widget build(BuildContext context) {
    final p = percent;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StepChecklistRow(
            status: requestDone ? StepRowStatus.done : StepRowStatus.running,
            label: 'Choosing your best photos',
          ),
          StepChecklistRow(
            status: requestDone ? StepRowStatus.done : StepRowStatus.pending,
            label: 'Sending them to the 3D engine',
          ),
          StepChecklistRow(
            status: _statusFor(0, 70),
            label: p == null ? 'Building the model' : 'Building the model — $p%',
          ),
          StepChecklistRow(
            status: _statusFor(70, 100),
            label: 'Adding textures',
          ),
          const StepChecklistRow(
            status: StepRowStatus.pending,
            label: 'Finishing up',
          ),
        ],
      ),
    );
  }
}

/// The raw trace, for the people who can act on it.
///
/// DOUBLE-GATED on staff AND debug, matching the upload tracker's devDetail
/// precedent: it names our S3 key layout and our selector's thresholds, and
/// neither belongs in a release build's widget tree even for staff.
class _StaffTrace extends ConsumerWidget {
  const _StaffTrace({required this.steps, this.selection});

  final List<GenerationStep> steps;
  final GenerationSelectionTrace? selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kDebugMode) return const SizedBox.shrink();
    if (!ref.watch(isStaffProvider)) return const SizedBox.shrink();
    if (steps.isEmpty && selection == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: AppColors.textSecondary,
    );
    final t = selection;

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('Selection trace (dev)', style: theme.textTheme.labelMedium),
        children: [
          for (final step in steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${_glyph(step.status)} ${step.rawName}'
                '${step.durationMs == null ? '' : ' (${step.durationMs}ms)'}'
                '${step.detail == null ? '' : '\n    ${step.detail}'}',
                style: mono,
              ),
            ),
          if (t != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'ring=${t.ringUsed} pool=${t.poolSize}/${t.photosInManifest} '
              'segments=${t.segmentCountUsed}\n'
              'dropped: noBlurScore=${t.droppedNoBlurScore} '
              'missingObject=${t.droppedMissingObject} '
              'unresolvableKey=${t.droppedUnresolvableKey}\n'
              'belowFloor(${t.minBlurScoreUsed})=${t.belowBlurFloor} '
              'warnedExcluded=${t.warnedExcluded} unplaced=${t.unplacedCount}\n'
              'quadrants=${t.quadrantHistogram}',
              style: mono,
            ),
            if (t.chosen.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              for (final photo in t.chosen)
                Text(
                  'q${photo.quadrant ?? '-'}  blur=${photo.blurScore}  ${photo.key}',
                  style: mono,
                ),
            ],
          ],
        ],
      ),
    );
  }

  static String _glyph(GenerationStepStatus status) => switch (status) {
        GenerationStepStatus.ok => '✓',
        GenerationStepStatus.skipped => '–',
        GenerationStepStatus.failed => '✗',
        GenerationStepStatus.unknown => '?',
      };
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
