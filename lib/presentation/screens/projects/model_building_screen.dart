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
import '../../../application/projects/owner_generation_request_notifier.dart';
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
    this.watchOwnerRequest = false,
    @visibleForTesting this.onOpenViewer,
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

  /// Read the request half from [ownerGenerationRequestProvider] instead of the
  /// staff [modelGenerationRequestProvider].
  ///
  /// TRUE on the owner's post-capture path: the two providers post to different
  /// routes (owner vs `/admin`) and carry different payloads (one sentence vs
  /// steps + selector trace), so which one is in play is a property of who
  /// pressed the button, not of this screen. The worker half below is identical
  /// either way.
  final bool watchOwnerRequest;

  /// Test seam for the auto-open-on-ready path. The real viewer drives a
  /// WebView that has no widget-test platform, so tests inject this to observe
  /// that the finished model opens exactly once, without rendering it. Null in
  /// production, where [_openViewer] pushes the real [ModelViewerScreen].
  final void Function(ProjectModelView model)? onOpenViewer;

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

  /// One-shot latch for the post-request re-read (see the owner branch below).
  bool _refreshedAfterRequest = false;

  /// True once a settled poll showed NO viewable model yet — i.e. the user is
  /// actually watching this build, not arriving on an already-finished one.
  /// Gates the auto-open below so a re-entry onto a done model never bounces
  /// straight back out.
  bool _sawWaitingState = false;

  /// One-shot latch so the finished model opens the viewer exactly once. Kept
  /// even after the viewer is popped, so returning here lands on the "ready"
  /// state with its View button rather than auto-opening again.
  bool _autoOpenedViewer = false;

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
    if (widget.onOpenViewer case final override?) {
      override(model);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelViewerScreen(model: model, title: widget.projectName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Only ONE of the two request providers is ever read: watching the staff one
    // on an owner's screen would spin up a notifier for a route they cannot call.
    final request = widget.watchOwnerRequest
        ? const ModelGenerationRequestState()
        : ref.watch(modelGenerationRequestProvider(widget.projectId));

    // A finished generation changes the PROJECTS LIST, not just this screen:
    // `modelCount` is aggregated server-side into the list DTO, so the Models
    // button stays hidden until the list is re-fetched.
    if (widget.watchOwnerState) {
      ref.listen<AsyncValue<OwnerModelState>>(
        ownerModelStateProvider(widget.projectId),
        (previous, next) {
          final data = next.valueOrNull;
          if (data == null) return;
          // Remember that we've seen a settled "still building" poll — that's
          // what tells a genuine finish apart from opening onto a done model.
          if (!data.hasViewableModel) {
            _sawWaitingState = true;
            return;
          }
          final hadModel = previous?.valueOrNull?.hasViewableModel ?? false;
          // A finished generation changes the PROJECTS LIST, not just this
          // screen: `modelCount` is aggregated server-side into the list DTO,
          // so the Models button stays hidden until the list is re-fetched.
          if (!hadModel) ref.invalidate(projectsProvider);
          // Take the owner straight to the finished model — pressing Generate
          // was a request to SEE a model, so land them on it rather than on a
          // "done, tap to view" screen. One-shot, and only when we actually
          // watched it finish here (never on a re-entry onto an already-done
          // model, which would bounce the user straight back out).
          final model = data.model;
          if (_sawWaitingState && !_autoOpenedViewer && model != null) {
            _autoOpenedViewer = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _openViewer(model);
            });
          }
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
    // ── The OWNER's press. One value, one sentence, no trace — see
    // `watchOwnerRequest`. Every non-started outcome (declined, ceiling, rate
    // limit, 404, offline) renders through the same plain message: an owner can
    // act on the sentence and on nothing else we know.
    if (widget.watchOwnerRequest) {
      final owner = ref.watch(ownerGenerationRequestProvider(widget.projectId));
      if (owner.isRequesting) {
        return const [
          _Waiting(percent: null, isStalled: false),
          _Timeline(requestDone: false, percent: null),
        ];
      }
      if (owner.refusalMessage case final message?) {
        return [
          _Message(
            icon: Icons.photo_camera_back_outlined,
            title: "We couldn't start this",
            body: message,
          ),
        ];
      }
      // The poll and the POST start together, so the FIRST poll can land before
      // the record the POST creates exists. Left alone that reads as "No 3D
      // model yet" — and the notifier, seeing nothing pending, stops polling and
      // never corrects itself. One re-read once the request confirms fixes both.
      if (owner.isBuilding && !_refreshedAfterRequest) {
        _refreshedAfterRequest = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !widget.watchOwnerState) return;
          ref.read(ownerModelStateProvider(widget.projectId).notifier).refresh();
        });
      }
      // Started (or entered without a press) → fall through to the worker half,
      // which is the same for everyone.
      return _ownerWorkerContent(
        requestDone: owner.isBuilding,
        expectGeneration: owner.isBuilding,
      );
    }

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

    return [
      ..._ownerWorkerContent(requestDone: request.hasResult),
      _StaffTrace(
        steps: request.request?.steps ?? const [],
        selection: request.request?.trace,
      ),
    ];
  }

  /// The WORKER half — identical for staff and owner, because it is the same
  /// poll of the same owner endpoint. [requestDone] is the only thing the two
  /// callers disagree about: it comes from whichever request half is in play.
  List<Widget> _ownerWorkerContent({
    required bool requestDone,
    bool expectGeneration = false,
  }) {
    if (!widget.watchOwnerState) {
      return const [_Waiting(percent: null, isStalled: false)];
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
          // The optimization tail gave up. The model is finished and openable —
          // show it, un-optimized, rather than waiting on a job that is not
          // reporting.
          showUnoptimized: ref
              .read(ownerModelStateProvider(widget.projectId).notifier)
              .optimizationWaitExhausted,
          requestDone: requestDone,
          expectGeneration: expectGeneration,
          onView: _openViewer,
          onRegenerate: widget.onRegenerate,
        ),
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
    this.expectGeneration = false,
    this.showUnoptimized = false,
  });

  final OwnerModelState state;
  final int? percent;
  final bool isStalled;
  final bool hasStoppedChecking;
  final bool requestDone;

  /// Show a model whose optimization never reported, rather than keep waiting.
  /// The fail-open half of the optimization wait — see
  /// [OwnerModelStateNotifier.optimizationWaitExhausted].
  final bool showUnoptimized;
  final void Function(ProjectModelView model) onView;
  final VoidCallback? onRegenerate;

  /// The server has just accepted a generation, so a record exists even if this
  /// poll has not seen it yet. Turns the "nothing here" state into the waiting
  /// state — the accurate one — instead of "No 3D model yet".
  final bool expectGeneration;

  @override
  Widget build(BuildContext context) {
    final model = state.model;
    final generation = state.generation;

    // Order matters. A finished model wins over an in-flight run: if a
    // regenerate is going, the user should still be able to open the model they
    // already have rather than being made to wait again for one they own.
    //
    // `isSettled`, not `isViewable`: a model whose web build is still running is
    // openable but not FINISHED — its URL still resolves to the untouched
    // original, which is the heavy build the viewer struggles with. Waiting out
    // that last step is the difference between the user getting the optimized
    // model and never getting it. [showUnoptimized] is the escape hatch when the
    // optimization job stops reporting.
    if (model != null && (model.isSettled || (model.isViewable && showUnoptimized))) {
      return _Ready(
        model: model,
        isRegenerating: state.generation?.isPending ?? false,
        onView: () => onView(model),
        onRegenerate: onRegenerate,
      );
    }

    if (state.isGenerating || (expectGeneration && state.isEmpty)) {
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
          _Timeline(
            requestDone: requestDone,
            percent: percent,
            // The model exists and only the web build is left — the one moment
            // "Finishing up" is a fact rather than a placeholder.
            finishingUp: model?.optimizationPending ?? false,
          ),
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
  const _Timeline({
    required this.requestDone,
    required this.percent,
    this.finishingUp = false,
  });

  /// The server has finished picking photos and queued the job.
  final bool requestDone;
  final int? percent;

  /// The 3D engine is done and the web build is running. Unlike rows 3–4, this
  /// one IS a distinct server-reported fact (`optimizationPending`), so the
  /// last row stops being a permanent placeholder and the rows above it are
  /// genuinely complete.
  final bool finishingUp;

  StepRowStatus _statusFor(int lowerBound, int upperBound) {
    if (finishingUp) return StepRowStatus.done;
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
            label: p == null || finishingUp
                ? 'Building the model'
                : 'Building the model — $p%',
          ),
          StepChecklistRow(
            status: _statusFor(70, 100),
            label: 'Adding textures',
          ),
          StepChecklistRow(
            status: finishingUp ? StepRowStatus.running : StepRowStatus.pending,
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
            // Neutral copy: an owner's regenerate re-selects server-side (they
            // don't pick photos), while staff's opens Prepare-Images. Both make
            // a new version, so the CTA names that outcome, not the mechanism.
            child: const Text('Not happy with it? Create a new version'),
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
