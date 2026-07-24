// lib/presentation/screens/projects/projects_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/user_role_notifier.dart';
import '../../../application/projects/model_generation_request_notifier.dart';
import '../../../application/projects/owner_generation_request_notifier.dart';
import '../../../application/projects/projects_notifier.dart';
import '../../../data/repositories/projects_repository.dart';
import '../../../domain/entities/project.dart';
import '../../../domain/entities/project_status.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/offline_retry_modal.dart';
import '../../widgets/project_card.dart';
import '../../widgets/project_options_sheet.dart';
import '../../widgets/projects_empty_state.dart';
import 'live_projects_view.dart';
import 'capture_mode_sheet.dart';
import 'model_building_screen.dart';
import 'model_viewer_screen.dart';

/// Which list the (staff-only) segmented control shows. Non-staff users never
/// see the control and always get [mine].
enum _ProjectsTab { mine, live }

/// Projects Hub. The list state lives entirely in [projectsProvider] (single
/// source of truth) — this screen renders loading/empty/loaded/error straight
/// from that `AsyncValue` and drives mutations through the notifier. Only
/// ephemeral UI guards (per-action in-flight, sheet/refresh dedupe) are local.
class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> with RouteAware {
  /// Per-project in-flight guard so a double-tap can't fire two requests/navs.
  final Set<String> _actionInFlight = <String>{};

  /// Guards against stacking a second options sheet on a rapid double-tap of
  /// the overflow trigger.
  bool _sheetOpen = false;

  /// Guards against a second pull-to-refresh firing while one is already in
  /// flight (e.g. a programmatic post-action refresh racing a manual pull).
  bool _refreshInFlight = false;

  /// Dedupe guard so the auto offline modal isn't stacked on repeated error
  /// emissions for the same failed load.
  bool _loadErrorModalOpen = false;

  /// Active tab. Only meaningful for staff (the control is hidden otherwise,
  /// and non-staff can never leave [_ProjectsTab.mine]).
  _ProjectsTab _tab = _ProjectsTab.mine;

  ProjectsNotifier get _notifier => ref.read(projectsProvider.notifier);

  @override
  void initState() {
    super.initState();
    // A fresh mount (e.g. `context.go(/projects)` after the capture → generate
    // flow) shows the CACHED list first — re-pull once so a model finished while
    // away is picked up without a manual swipe.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshSilently());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to the root-navigator observer so [didPopNext] fires when a
    // pushed screen (model viewer, build, capture flow) pops back to here.
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      projectsRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    projectsRouteObserver.unsubscribe(this);
    super.dispose();
  }

  /// Returned to this tab after a pushed screen popped — re-pull so a model
  /// generated while away shows its Models button. See [projectsRouteObserver].
  @override
  void didPopNext() => _refreshSilently();

  /// A focus-driven re-fetch. Unlike [_refresh] it NEVER surfaces the offline
  /// modal: a background refresh that nags on every network blip would be worse
  /// than a slightly stale list. The notifier keeps the visible list on failure.
  Future<void> _refreshSilently() async {
    if (!mounted || _refreshInFlight) return;
    _refreshInFlight = true;
    try {
      await _notifier.refresh();
    } catch (_) {
      // Keep the visible list; the next focus/pull reconciles.
    } finally {
      _refreshInFlight = false;
    }
  }

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  // ── Data ─────────────────────────────────────────────────────────────────────

  /// Pull-to-refresh / post-action re-fetch — no full skeleton. The returned
  /// Future is what the [RefreshIndicator] awaits. On failure the visible list
  /// is preserved (the notifier never blanks it) and the offline modal is shown.
  Future<void> _refresh() async {
    if (_refreshInFlight) return; // single in-flight fetch — dedupe rapid pulls
    _refreshInFlight = true;
    try {
      await _notifier.refresh();
      _logRefresh('success');
    } catch (_) {
      _logRefresh('network_error');
      if (!mounted) return;
      await showOfflineRetryModal(
        context,
        source: OfflineSource.projectsHub,
        onRetry: _notifier.refresh,
      );
    } finally {
      _refreshInFlight = false;
    }
  }

  void _logRefresh(String result) {
    Analytics.logEvent('projects_list_refreshed', {
      'result': result,
      'project_count':
          result == 'success' ? (_projectsOrEmpty().length) : 0,
      'device_type': _deviceType,
    });
  }

  List<Project> _projectsOrEmpty() =>
      ref.read(projectsProvider).valueOrNull ?? const <Project>[];

  void _logViewed(List<Project> projects) {
    Analytics.logEvent('projects_list_viewed', {
      'project_count': projects.length,
      'has_failed_projects':
          projects.any((p) => p.status.cardAction == ProjectCardAction.retry),
      'device_type': _deviceType,
    });
  }

  /// Auto-surfaces the offline modal when a full load/reload fails, parking the
  /// `_ErrorView` behind it so the screen is never blank if the modal is closed.
  Future<void> _showLoadErrorModal() async {
    if (_loadErrorModalOpen) return;
    _loadErrorModalOpen = true;
    try {
      await showOfflineRetryModal(
        context,
        source: OfflineSource.projectsHub,
        // Reload via the provider; rethrows on failure so the modal stays open.
        onRetry: () => ref.refresh(projectsProvider.future),
      );
    } finally {
      _loadErrorModalOpen = false;
    }
  }

  // ── Actions ──────────────────────────────────────────────────────────────────

  bool _claim(Project p) {
    if (_actionInFlight.contains(p.id)) return false;
    setState(() => _actionInFlight.add(p.id));
    return true;
  }

  void _release(Project p) {
    if (mounted) setState(() => _actionInFlight.remove(p.id));
  }

  void _logAction(String action, Project p) {
    Analytics.logEvent('project_action_tapped', {
      'action': action,
      'project_status': p.status.apiValue.toLowerCase(),
      'project_id': p.id,
    });
  }

  void _onResume(Project p) {
    if (!_claim(p)) return;
    _logAction('resume', p);
    // TODO(capture): pass p.id into the pre-capture/capture flow.
    context.goNamed(AppRouteNames.preCapture, extra: p.id);
  }

  /// Opens the project's finished 3D model when it has one.
  ///
  /// The model is fetched HERE, on tap, rather than watched per card: the
  /// projects list DTO doesn't carry it (see ProjectsRepository.fetchModel), and
  /// one request per completed card would be an N+1 across the whole list.
  /// Projects without a generated model keep the previous behaviour exactly.
  Future<void> _onView(Project p) async {
    if (!_claim(p)) return;
    _logAction('view', p);
    try {
      final state = await ref.read(projectsRepositoryProvider).fetchModelState(p.id);
      if (!mounted) return;
      if (state.hasViewableModel) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ModelViewerScreen(
              model: state.model!,
              title: p.name,
              // Owners can spin a fresh version straight from the viewer; staff
              // regenerate through Prepare-Images (see _regenerateHandlerFor).
              onRegenerate: _regenerateHandlerFor(p),
            ),
          ),
        );
        return;
      }
      // A model is being built for this project that the user never asked for.
      // Sending them to the generic "model ready" placeholder here would be a
      // lie; the building screen explains the wait and watches it finish.
      if (state.generation != null) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ModelBuildingScreen(
              projectId: p.id,
              projectName: p.name,
              onRegenerate: _regenerateHandlerFor(p),
            ),
          ),
        );
        return;
      }
    } catch (_) {
      // Offline / server hiccup: fall through to the existing destination
      // rather than dead-ending the tap on an error.
    }
    if (!mounted) return;
    context.goNamed(AppRouteNames.modelReady);
  }

  /// The "make a new version" action for the model viewer / building screen.
  ///
  /// Two different paths by role. STAFF regenerate through the Preview gallery →
  /// Prepare-Images, where they hand-pick and clean up the photos. OWNERS get
  /// the server-selected path — the same POST the post-capture button uses, with
  /// `regenerate: true` so it makes a genuinely new version rather than replaying
  /// the existing one. The owner spend is bounded server-side by the per-user
  /// daily cap; here it is just a button.
  VoidCallback _regenerateHandlerFor(Project p) {
    if (ref.read(isStaffProvider)) {
      return () => context.pushNamed(
            AppRouteNames.previewGallery,
            pathParameters: {'id': p.id},
          );
    }
    return () => _onRegenerate(p);
  }

  /// Owner "Create a new version": forces a fresh (capped) generation and opens
  /// the build screen to watch it. Mirrors [_onGenerate] but through the owner
  /// notifier's [OwnerGenerationRequestNotifier.regenerate], and it deliberately
  /// does NOT gate on `_claim`: it is launched from a pushed screen (the viewer /
  /// build screen), not the card, so the per-card in-flight guard doesn't apply —
  /// the notifier's own in-flight guard is what stops a double-fire.
  Future<void> _onRegenerate(Project p) async {
    _logAction('regenerate', p);
    // Fire the request; the build screen we push renders its progress/outcome.
    final pending =
        ref.read(ownerGenerationRequestProvider(p.id).notifier).regenerate();
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ModelBuildingScreen(
            projectId: p.id,
            projectName: p.name,
            watchOwnerRequest: true,
            onRegenerate: _regenerateHandlerFor(p),
          ),
        ),
      );
    } finally {
      // Let the POST settle before returning so a fast re-tap finds it in flight.
      await pending;
    }
  }

  /// "Generate 3D model": the SERVER picks the photos and starts a generation,
  /// then this pushes the screen that explains what it decided and watches the
  /// build.
  ///
  /// Role-split, because the two audiences talk to different routes with
  /// different payloads: an OWNER goes through [_onGenerateOwner]
  /// (`POST /projects/:id/model`, one owner-safe sentence), while STAFF use the
  /// `/admin` auto route below, which additionally returns the selector trace
  /// the staff building screen renders. An owner hitting the admin route would
  /// only ever 403, so they never reach it.
  ///
  /// The screen is pushed FIRST and the request is awaited there rather than
  /// here, because the most valuable outcome is a REFUSAL: a snackbar can say
  /// "couldn't build a model" but it cannot show which rule refused and with
  /// what numbers. Every outcome — enqueued, replayed, declined, failed — gets
  /// the same full screen.
  Future<void> _onGenerate(Project p) async {
    if (!ref.read(isStaffProvider)) {
      await _onGenerateOwner(p);
      return;
    }
    if (!_claim(p)) return;
    _logAction('generate', p);
    // Fire-and-render: the notifier holds the result, so the screen shows the
    // in-flight state and then the trace without this having to await.
    final pending =
        ref.read(modelGenerationRequestProvider(p.id).notifier).request();
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ModelBuildingScreen(
            projectId: p.id,
            projectName: p.name,
            onRegenerate: _regenerateHandlerFor(p),
          ),
        ),
      );
    } finally {
      // Let the request settle before releasing the per-project claim, so a
      // second press cannot start a second (paid) generation while the first
      // is still in flight.
      await pending;
      _release(p);
    }
  }

  /// Owner "Generate 3D model": the non-staff counterpart to [_onGenerate].
  ///
  /// Fires the owner request (`POST /projects/:id/model` via
  /// [OwnerGenerationRequestNotifier.request] — no body, so a repeat replays
  /// instead of paying twice) and pushes the owner-safe build screen with
  /// [ModelBuildingScreen.watchOwnerRequest] set, so it watches the OWNER
  /// notifier rather than the staff one. Same double-spend discipline as
  /// [_onGenerate]: claim first, await the POST before releasing.
  Future<void> _onGenerateOwner(Project p) async {
    if (!_claim(p)) return;
    _logAction('generate', p);
    final pending =
        ref.read(ownerGenerationRequestProvider(p.id).notifier).request();
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ModelBuildingScreen(
            projectId: p.id,
            projectName: p.name,
            watchOwnerRequest: true,
            onRegenerate: _regenerateHandlerFor(p),
          ),
        ),
      );
    } finally {
      await pending;
      _release(p);
    }
  }

  /// The `+` action: ask which capture mode, then open Create Project.
  ///
  /// The chooser is unconditional — choosing a capture mode is now part of
  /// creating a project, so there is no path to Create Project that leaves the
  /// mode unstated. A dismissed sheet navigates NOWHERE: the user backed out of
  /// creating a project, and pushing the form anyway would ignore that.
  ///
  /// REQUIRES a server that understands `captureMode`. A Meshy project created
  /// against an older deployment reaches create-job with a mode and a 10-file
  /// count that server knows nothing about, and 422s there — after the user has
  /// already shot everything.
  Future<void> _onCreateProject() async {
    final mode = await showCaptureModeSheet(context);
    if (mode == null || !mounted) return;
    context.pushNamed(AppRouteNames.createProject, extra: mode);
  }

  /// Staff-only per-project Preview (My-projects surface). Pushed so hardware
  /// back returns here. No in-flight claim: it's a pure navigation, not a
  /// mutation, and the Preview screen owns its own load/guards.
  void _onPreview(Project p) {
    _logAction('preview', p);
    context.pushNamed(
      AppRouteNames.previewGallery,
      pathParameters: {'id': p.id},
    );
  }

  /// Staff-only per-project model history — the persistent way back to a
  /// generated model once you've left the screen that created it. Pushed, like
  /// Preview, and likewise unclaimed: pure navigation, and the history screen
  /// owns its own load/empty/error states.
  ///
  /// Shown only for a project with a VIEWABLE model (`modelCount > 0` on the
  /// Project DTO — one aggregation per list page server-side, never a request
  /// per card). The count is SUCCEEDED-only by backend contract, so a project
  /// whose generations all FAILED shows no button; its failures stay visible on
  /// the generation screen, not here.
  ///
  /// The button carries no NUMBER on purpose — the count exists to decide
  /// whether to render it, and the very next tap shows the full history anyway.
  void _onModels(Project p) {
    // Role-split by what each audience can reach. STAFF open the full
    // generation HISTORY (the `/admin/projects/:id/models` endpoint the history
    // screen polls). An OWNER has no history endpoint — that route would 403 —
    // so their "Models" opens the newest finished model directly through the
    // owner path, identical to [_onView].
    if (!ref.read(isStaffProvider)) {
      _onView(p);
      return;
    }
    _logAction('models', p);
    context.pushNamed(
      AppRouteNames.modelHistory,
      pathParameters: {'id': p.id},
    );
  }

  /// A project has a finalized upload worth previewing (mirrors the backend's
  /// exportable set: PROCESSING/COMPLETED).
  static bool _isExportable(Project p) =>
      p.status == ProjectStatus.processing ||
      p.status == ProjectStatus.completed;

  Future<void> _onRetry(Project p) async {
    if (!_claim(p)) return;
    _logAction('retry', p);
    try {
      // Notifier optimistically flips the card to processing and rolls back on
      // failure — no refetch needed.
      await _notifier.retry(p.id);
    } catch (_) {
      if (!mounted) return;
      await showOfflineRetryModal(
        context,
        source: OfflineSource.projectsHub,
        onRetry: () => _notifier.retry(p.id),
      );
    } finally {
      _release(p);
    }
  }

  /// Opens the Rename / Delete options sheet. Mutations run through the notifier
  /// (optimistic + rollback); the list state lives in the provider, so the
  /// sheet's typed result is no longer applied locally.
  Future<void> _onMore(Project p) async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    try {
      await showProjectOptionsSheet(
        context,
        project: p,
        onRename: (id, newName) async {
          await _notifier.rename(id, newName);
          // The sheet wants the updated entity for its result; the notifier has
          // already committed this optimistic value to shared state.
          return p.copyWith(name: newName, updatedAt: DateTime.now());
        },
        onDelete: (id) => _notifier.delete(id),
      );
    } finally {
      _sheetOpen = false;
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // React to load outcomes: log 'viewed' on a settled load/reload, and
    // auto-surface the offline modal on a load error. Refresh/mutation failures
    // keep the list as AsyncData, so they never reach these branches.
    ref.listen<AsyncValue<List<Project>>>(projectsProvider, (prev, next) {
      if (prev is AsyncLoading && next is AsyncData<List<Project>>) {
        _logViewed(next.value);
      }
      if (next is AsyncError) {
        _showLoadErrorModal();
      }
    });

    final projectsAsync = ref.watch(projectsProvider);
    // Staff gating: the Live tab exists ONLY for MODEL_ARTIST/ADMIN accounts
    // (server-verified via /auth/me; every /admin call is re-checked
    // server-side). Non-staff users get the exact pre-existing screen.
    final isStaff = ref.watch(isStaffProvider);
    final showLive = isStaff && _tab == _ProjectsTab.live;

    final listBody = showLive
        ? const LiveProjectsView()
        : _buildBody(projectsAsync);
    final tabbedBody = isStaff
        ? Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
                child: SegmentedButton<_ProjectsTab>(
                  segments: const [
                    ButtonSegment(
                      value: _ProjectsTab.mine,
                      label: Text('My projects'),
                    ),
                    ButtonSegment(
                      value: _ProjectsTab.live,
                      label: Text('Live projects'),
                    ),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (selection) =>
                      setState(() => _tab = selection.first),
                ),
              ),
              Expanded(child: listBody),
            ],
          )
        : listBody;

    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text('Projects', style: Theme.of(context).textTheme.titleLarge),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle_outlined,
                color: AppColors.textSecondary),
            onPressed: () {},
          ),
        ],
      ),
      // Creating a project belongs to My projects; the Live tab is read-only.
      floatingActionButton: showLive
          ? null
          : FloatingActionButton(
              onPressed: _onCreateProject,
              backgroundColor: AppColors.mirageRed,
              child: const Icon(Icons.add, color: Colors.white),
            ),
      body: tabbedBody,
    );
  }

  Widget _buildBody(AsyncValue<List<Project>> projectsAsync) {
    return projectsAsync.when(
      // A refresh/mutation keeps the previous data visible via `skipLoadingOn*`
      // defaults; a true first load / reload has no data yet → skeleton.
      loading: () => const _SkeletonList(),
      error: (_, __) => _ErrorView(
        onRetry: () => ref.invalidate(projectsProvider),
      ),
      data: (projects) {
        // Staff get a Preview action on their OWN exportable projects too; the
        // callback is null for everyone else, so the shared card is unchanged.
        final isStaff = ref.watch(isStaffProvider);
        if (projects.isEmpty) {
          // Empty state is pull-to-refreshable too — a user with no projects can
          // swipe to re-check. The scroll view fills the viewport so the gesture
          // is available even though the content is short.
          return _refreshable(
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: ProjectsEmptyState(
                    // Go through the same capture-mode sheet the FAB uses — a
                    // direct push here would skip the Full/Meshy chooser, so a
                    // first-time user (whose list is empty) could never start a
                    // Meshy capture and would silently get a Full one.
                    onStartCapture: _onCreateProject,
                  ),
                ),
              ),
            ),
          );
        }
        return _refreshable(
          ListView.separated(
            // Always scrollable so even a 1–2 item list can be pulled down.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: projects.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, index) {
              final project = projects[index];
              return ProjectCard(
                project: project,
                isActionInFlight: _actionInFlight.contains(project.id),
                onResume: _onResume,
                onView: _onView,
                onRetry: _onRetry,
                onMore: _onMore,
                onPreview:
                    isStaff && _isExportable(project) ? _onPreview : null,
                // Any owner can open their own generated models — _onModels
                // routes to ModelViewerScreen for every user. Still requires a
                // VIEWABLE model: the history has nothing to show otherwise, and
                // a button that opens an empty screen is worse than no button.
                // Failed-only projects therefore show no Models button (see
                // ProjectListItem.modelCount).
                onModels: project.hasViewableModels ? _onModels : null,
                // Any owner can generate a model for their own capturable
                // project. Requires a FINALIZED capture (without one the server
                // always answers NOT_EXPORTABLE) AND no model yet: once this
                // capture already has one, Generate gives way to the Models
                // button — a viewable model is the successful end state, so
                // re-offering Generate there is redundant noise. Regenerating
                // stays reachable from inside the viewer.
                onGenerate: _isExportable(project) && !project.hasViewableModels
                    ? _onGenerate
                    : null,
              );
            },
          ),
        );
      },
    );
  }

  /// Wraps a scrollable child in the shared pull-to-refresh indicator.
  Widget _refreshable(Widget child) {
    return RefreshIndicator(
      color: AppColors.mirageRed,
      backgroundColor: AppColors.surface1,
      onRefresh: _refresh,
      child: child,
    );
  }
}

/// Lightweight skeleton placeholder shown while the list loads.
class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: 4,
      physics: const NeverScrollableScrollPhysics(),
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (_, __) => const AppCard(
        child: Row(
          children: [
            _SkeletonBox(width: 48, height: 48),
            SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonBox(width: 140, height: 14),
                  SizedBox(height: AppSpacing.sm),
                  _SkeletonBox(width: 80, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
    );
  }
}

/// Minimal retry surface rendered behind the offline modal so the screen is
/// never blank if the modal is dismissed.
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry});

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
              "Couldn't load your projects.",
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
