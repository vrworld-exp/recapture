// lib/presentation/screens/capture/processing_screen.dart
//
// The post-upload screen: the capture's photos are in S3, and the owner is
// offered the one thing that can happen next — "Generate 3D model".
//
// ── WHAT THIS REPLACED, AND WHY ─────────────────────────────────────────────
// This screen used to show a five-stage pipeline stepper with a hardcoded
// "Texturing" state, a 4-second timer that force-navigated to a "model ready"
// placeholder, and a "Notify me when done" switch that was wired to nothing. All
// three were claims the app could not back: no generation had been requested, no
// stage was running, no model was coming, and no notification would arrive. They
// are gone.
//
//   • The stepper is gone because the honest one already exists — the timeline
//     in [ModelBuildingScreen] renders the server's real progress, and only
//     after a generation has actually been asked for.
//   • The notify toggle is REMOVED rather than made real: this app has no push
//     infrastructure at all (no messaging package, no token registration, no
//     server-side send), so making it real is a feature, not a wiring change. A
//     dead toggle is a promise we break silently; no toggle promises nothing,
//     and the build screen already says leaving is safe.
//
// ── THE BUTTON SPENDS MONEY ─────────────────────────────────────────────────
// Every press can start a paid generation. Two things stop it becoming two: the
// per-press guard here, and the state-layer guard in
// [OwnerGenerationRequestNotifier] (which outlives this screen, so a re-entry
// finds the request already made). The server's `manual:{jobId}` idempotency key
// is the third and final backstop — this screen deliberately sends no `force`
// and no cache-buster that could defeat it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/capture_mode_provider.dart';
import '../../../application/projects/generation_tracker_notifier.dart';
import '../../../application/projects/owner_generation_request_notifier.dart';
import '../../../data/repositories/projects_repository.dart';
import '../../../utils/feature_flags.dart';
import '../../widgets/app_button.dart';
import '../projects/model_building_screen.dart';

class ProcessingScreen extends ConsumerStatefulWidget {
  const ProcessingScreen({super.key, this.projectId});

  /// The REMOTE project the photos were uploaded into, carried from the upload
  /// flow (see UploadingScreen). Null when it could not be resolved — the
  /// screen then offers no generate button at all, because a button that names
  /// the wrong project would 404 a paid request.
  final String? projectId;

  @override
  ConsumerState<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends ConsumerState<ProcessingScreen> {
  /// A press is in flight (the POST, and the screen it pushed). Blocks the
  /// fast double tap; the notifier blocks everything slower.
  bool _pressing = false;

  /// One-shot latch for the automatic Meshy path, so a rebuild cannot fire a
  /// second (paid) generation.
  bool _autoStarted = false;

  /// Meshy mode generates its model without being asked — that is the point of
  /// the mode. Behind its OWN flag so the capture flow can be dogfooded before
  /// any credits are spent; with the flag off a Meshy capture lands on the same
  /// manual button a full capture does.
  bool get _autoGenerates =>
      kMeshyAutoGenerateEnabled &&
      ref.read(captureModeProvider).generatesModelAutomatically;

  @override
  void initState() {
    super.initState();
    // Fire after the first frame so the push has a mounted Navigator, and only
    // when there is a project to spend on.
    if (widget.projectId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_autoGenerates) {
        // A capture can start a generation with NO press at all (server-side
        // auto-generation), and the upload result says nothing about it. So ask
        // once, rather than guessing, and hand anything already running to the
        // app-wide tracker. Skipped when this screen is about to fire the
        // request itself — that path tracks on its own `started` outcome, and a
        // second GET would only race it.
        unawaited(_trackExistingGeneration(widget.projectId!));
        return;
      }
      if (_autoStarted) return;
      _autoStarted = true;
      // The SAME request the button makes — deliberately not a second path.
      // It carries no body, no `force` and no cache-buster, so the server's
      // `manual:{jobId}` idempotency key still collapses a repeat into a
      // replay, the per-user rate window still applies, and the run still
      // counts against the shared 24h ceiling. An automatic trigger that
      // bypassed any of those would be the one place a bill could run away.
      unawaited(_onGenerate(widget.projectId!));
    });
  }

  /// One read of `GET /projects/:id` to find out whether the server already
  /// started a generation for this capture. Purely observational — it never
  /// POSTs, so it can never spend.
  Future<void> _trackExistingGeneration(String projectId) async {
    try {
      final state =
          await ref.read(projectsRepositoryProvider).fetchModelState(projectId);
      if (!mounted || !state.isGenerating) return;
      ref.read(generationTrackerProvider.notifier).track(
            projectId,
            projectName: _buildScreenTitle,
            source: GenerationTrackingSource.postCapture,
          );
    } catch (_) {
      // Offline / server hiccup: nothing to track. The project itself still
      // shows the model whenever the user next opens it.
    }
  }

  Future<void> _onGenerate(String projectId) async {
    if (_pressing) return;
    setState(() => _pressing = true);
    // Fire, then render: the request is awaited on the screen we push, not
    // here. The most valuable outcome is a REFUSAL, and a refusal needs a
    // screen — a snackbar cannot carry "walk all the way around the object"
    // and still be readable.
    final pending = ref
        .read(ownerGenerationRequestProvider(projectId).notifier)
        .request(projectName: _buildScreenTitle);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ModelBuildingScreen(
            projectId: projectId,
            projectName: _buildScreenTitle,
            watchOwnerRequest: true,
          ),
        ),
      );
    } finally {
      // Let the request settle before releasing the guard, so backing out fast
      // cannot land a second press while the first POST is still open.
      await pending;
      if (mounted) setState(() => _pressing = false);
    }
  }

  /// The build screen names the project in its app bar; the post-capture flow
  /// has the id but not the name (the upload names the remote project itself),
  /// and a wrong name is worse than a neutral one.
  static const _buildScreenTitle = 'Your capture';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final projectId = widget.projectId;
    // Only meaningful once we have a project: the family key is the id.
    final hasRequested = projectId != null &&
        ref.watch(ownerGenerationRequestProvider(projectId)).hasStarted;

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text('Upload complete', style: theme.textTheme.titleLarge),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(
                key: Key('processing_uploaded_icon'),
                Icons.cloud_done_outlined,
                size: 64,
                color: AppColors.success,
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Photos uploaded',
                key: const Key('processing_uploaded_title'),
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                projectId == null
                    // Honest about the one thing that is missing, without
                    // naming ids or routes: the photos ARE safe, and the model
                    // can still be made from the project itself later.
                    ? 'Your photos are saved. Open this project from Projects '
                        'when you want to create a 3D model.'
                    : 'Your photos are safely stored. Create a 3D model from '
                        'them whenever you like — it takes a few minutes.',
                key: const Key('processing_uploaded_body'),
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              // SUPPRESSED, not de-emphasised, when the mode generates on its
              // own: the model is already being made, so a "Generate 3D model"
              // button would either be a no-op or a second charge. The user is
              // taken to the build screen instead.
              if (projectId != null && !_autoGenerates) ...[
                AppButton(
                  key: const Key('processing_generate_model'),
                  label: hasRequested
                      // A second press must not read as a second purchase.
                      ? 'View progress'
                      : 'Generate 3D model',
                  onPressed: _pressing ? null : () => _onGenerate(projectId),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              AppButton.secondary(
                key: const Key('processing_back_to_projects'),
                label: 'Back to Projects',
                // Leaving is safe and cancels nothing: the upload is finished
                // and a generation, once started, continues server-side.
                onPressed: () => context.go(AppRoutes.projects),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}
