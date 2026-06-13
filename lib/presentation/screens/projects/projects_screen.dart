// lib/presentation/screens/projects/projects_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../data/repositories/projects_repository.dart';
import '../../../domain/entities/project.dart';
import '../../../domain/entities/project_options_result.dart';
import '../../../domain/entities/project_status.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/offline_retry_modal.dart';
import '../../widgets/project_card.dart';
import '../../widgets/project_options_sheet.dart';
import '../../widgets/projects_empty_state.dart';

enum _ScreenState { loading, loaded, empty, error }

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  final ProjectsRepository _repository = const ProjectsRepository();

  _ScreenState _state = _ScreenState.loading;
  List<Project> _projects = const [];

  /// Per-project in-flight guard so a double-tap can't fire two requests/navs.
  final Set<String> _actionInFlight = <String>{};

  /// Guards against stacking a second options sheet on a rapid double-tap of
  /// the overflow trigger.
  bool _sheetOpen = false;

  /// Guards against a second pull-to-refresh firing while one is already in
  /// flight (e.g. a programmatic post-action refresh racing a manual pull).
  bool _refreshInFlight = false;

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  // ── Data ─────────────────────────────────────────────────────────────────────

  /// Full load with the skeleton state. On network failure shows the offline
  /// modal (its retry re-fetches) and parks the screen in [error] behind it so
  /// nothing is blank if the modal is dismissed.
  Future<void> _loadProjects() async {
    setState(() => _state = _ScreenState.loading);
    try {
      final projects = await _repository.fetchProjects();
      if (!mounted) return;
      _applyProjects(projects);
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _ScreenState.error);
      await showOfflineRetryModal(
        context,
        source: OfflineSource.projectsHub,
        onRetry: _fetchInto, // throws on failure → modal stays open
      );
    }
  }

  /// Re-fetch for pull-to-refresh / post-action — no full skeleton, just the
  /// refresh spinner (the [RefreshIndicator] shows its own). The returned Future
  /// is what the indicator awaits, so the spinner lasts exactly as long as the
  /// fetch. On failure the visible list is preserved and the offline modal is
  /// surfaced over it.
  Future<void> _refresh() async {
    if (_refreshInFlight) return; // single in-flight fetch — dedupe rapid pulls
    _refreshInFlight = true;
    try {
      await _fetchInto();
      _logRefresh('success');
    } catch (_) {
      _logRefresh('network_error');
      if (!mounted) return;
      // Do NOT clear the list — _fetchInto threw before applying, so the last
      // good data stays visible behind the modal.
      await showOfflineRetryModal(
        context,
        source: OfflineSource.projectsHub,
        onRetry: _fetchInto,
      );
    } finally {
      _refreshInFlight = false;
    }
  }

  void _logRefresh(String result) {
    Analytics.logEvent('projects_list_refreshed', {
      'result': result,
      'project_count': result == 'success' ? _projects.length : 0,
      'device_type': _deviceType,
    });
  }

  /// Fetches and applies projects. Lets network errors propagate so the offline
  /// modal's retry can stay open until it succeeds.
  Future<void> _fetchInto() async {
    final projects = await _repository.fetchProjects();
    if (!mounted) return;
    _applyProjects(projects);
  }

  void _applyProjects(List<Project> projects) {
    setState(() {
      _projects = projects;
      _state = projects.isEmpty ? _ScreenState.empty : _ScreenState.loaded;
    });
    Analytics.logEvent('projects_list_viewed', {
      'project_count': projects.length,
      'has_failed_projects':
          projects.any((p) => p.status.cardAction == ProjectCardAction.retry),
      'device_type': _deviceType,
    });
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

  void _onView(Project p) {
    if (!_claim(p)) return;
    _logAction('view', p);
    // TODO(viewer): route to the project detail/viewer for p.id once it exists.
    context.goNamed(AppRouteNames.modelReady);
  }

  Future<void> _onRetry(Project p) async {
    if (!_claim(p)) return;
    _logAction('retry', p);
    try {
      await _repository.retryProject(p.id);
      if (!mounted) return;
      await _refresh(); // reflect the new status (back to processing)
    } catch (_) {
      if (!mounted) return;
      await showOfflineRetryModal(
        context,
        source: OfflineSource.projectsHub,
        onRetry: () => _repository.retryProject(p.id),
      );
      if (!mounted) return;
      await _refresh();
    } finally {
      _release(p);
    }
  }

  /// Opens the Rename / Delete options sheet and applies its typed result to the
  /// list state in place — no full refetch.
  Future<void> _onMore(Project p) async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    try {
      final result = await showProjectOptionsSheet(
        context,
        project: p,
        onRename: (id, newName) async {
          await _repository.renameProject(id, newName);
          // Backend returns success only — build the updated entity locally.
          return p.copyWith(name: newName, updatedAt: DateTime.now());
        },
        onDelete: (id) => _repository.deleteProject(id),
      );
      if (!mounted) return;
      _applyOptionsResult(result);
    } finally {
      _sheetOpen = false;
    }
  }

  void _applyOptionsResult(ProjectOptionsResult result) {
    switch (result.action) {
      case ProjectOptionsAction.renamed:
        final updated = result.updatedProject!;
        setState(() {
          _projects = [
            for (final project in _projects)
              if (project.id == updated.id) updated else project,
          ];
        });
      case ProjectOptionsAction.deleted:
        final id = result.deletedProjectId!;
        setState(() {
          _projects =
              _projects.where((project) => project.id != id).toList();
          if (_projects.isEmpty) _state = _ScreenState.empty;
        });
      case ProjectOptionsAction.none:
        break;
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
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
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.pushNamed(AppRouteNames.createProject),
        backgroundColor: AppColors.mirageRed,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _ScreenState.loading:
        return const _SkeletonList();
      case _ScreenState.empty:
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
                  // "Start new capture" begins by creating/configuring the project.
                  onStartCapture: () =>
                      context.pushNamed(AppRouteNames.createProject),
                ),
              ),
            ),
          ),
        );
      case _ScreenState.error:
        return _ErrorView(onRetry: _loadProjects);
      case _ScreenState.loaded:
        return _refreshable(
          ListView.separated(
            // Always scrollable so even a 1–2 item list can be pulled down.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: _projects.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, index) {
              final project = _projects[index];
              return ProjectCard(
                project: project,
                isActionInFlight: _actionInFlight.contains(project.id),
                onResume: _onResume,
                onView: _onView,
                onRetry: _onRetry,
                onMore: _onMore,
              );
            },
          ),
        );
    }
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
