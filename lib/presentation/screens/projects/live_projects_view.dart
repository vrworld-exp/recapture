// lib/presentation/screens/projects/live_projects_view.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/user_role_notifier.dart';
import '../../../application/projects/live_projects_notifier.dart';
import '../../../application/projects/model_generation_request_notifier.dart';
import '../../../application/projects/project_export_service.dart';
import '../../../data/repositories/live_projects_repository.dart';
import '../../../domain/entities/live_project.dart';
import '../../../domain/entities/project_owner.dart';
import '../../../domain/entities/project_status.dart';
import '../../../utils/analytics.dart';
import '../../../utils/extensions.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_status_pill.dart';
import 'admin_delete_project_dialog.dart';
import 'model_building_screen.dart';
import 'preview_gallery_screen.dart' show friendlyWait;
import 'project_owner_sheet.dart';

/// Staff-only "Live projects" tab body: every user's captured
/// (upload-finalized) project, newest first, with a per-project Export action
/// that hands the presigned-URL manifest to the platform share sheet.
///
/// Rendering rules mirror the My-projects list (pull-to-refresh, list kept
/// visible on refresh failure); pagination is cursor-driven via the notifier.
/// Errors show MAPPED copy only — never raw codes or URLs.
class LiveProjectsView extends ConsumerStatefulWidget {
  const LiveProjectsView({super.key});

  @override
  ConsumerState<LiveProjectsView> createState() => _LiveProjectsViewState();
}

class _LiveProjectsViewState extends ConsumerState<LiveProjectsView> {
  /// Per-project in-flight guard so a double-tap can't fire two exports.
  final Set<String> _exportInFlight = <String>{};

  /// Same guard for the admin delete — one confirmation flow per project.
  final Set<String> _deleteInFlight = <String>{};

  /// And for the generation request, which SPENDS CREDITS — one press must
  /// never become two.
  final Set<String> _generateInFlight = <String>{};

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // REACH metric: once per tab entry (a fresh State per entry), not per
    // rebuild. Non-PII: no ids ride along.
    Analytics.logEvent('live_projects_viewed');
    _scroll.addListener(_maybeLoadMore);
    // Re-pull on every tab ENTRY. [liveProjectsProvider] is long-lived (not
    // autoDispose), so a second entry would otherwise render whatever the list
    // held when the artist last left it — most visibly missing the project they
    // just finished uploading, which is exactly what they switched over to
    // check. Post-frame and only when the provider ALREADY has data: on a first
    // entry `build()` is the fetch, and firing here too would double it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(liveProjectsProvider).hasValue) return;
      ref
          .read(liveProjectsProvider.notifier)
          .refresh()
          .catchError((Object e) => _showFailure(e));
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter > 240) return;
    // Errors surface via the snackbar; the loaded rows always stay visible.
    ref
        .read(liveProjectsProvider.notifier)
        .loadMore()
        .catchError((Object e) => _showFailure(e));
  }

  Future<void> _export(LiveProject project) async {
    if (_exportInFlight.contains(project.id)) return;
    setState(() => _exportInFlight.add(project.id));
    try {
      final result = await ref
          .read(projectExportServiceProvider)
          .exportProject(project.id);
      if (!mounted) return;
      final expiry = result.expiresAt;
      final expiryNote = expiry == null
          ? ''
          : ' · links expire ${TimeOfDay.fromDateTime(expiry.toLocal()).format(context)}';
      _snack('Export ready — ${result.fileCount} files$expiryNote');
    } catch (e) {
      _showFailure(e);
    } finally {
      if (mounted) setState(() => _exportInFlight.remove(project.id));
    }
  }

  /// The ADMIN delete flow: mode + typed-name confirmation, then the API call.
  /// Success removes the row (the notifier trims it locally) — soft or hard,
  /// the project is out of the live set either way.
  Future<void> _delete(LiveProject project) async {
    if (_deleteInFlight.contains(project.id)) return;
    final mode = await showAdminDeleteProjectDialog(
      context,
      projectName: project.name,
    );
    if (mode == null || !mounted) return;

    setState(() => _deleteInFlight.add(project.id));
    try {
      await ref.read(liveProjectsProvider.notifier).deleteProject(
            project.id,
            mode: mode,
            confirmName: project.name,
          );
      if (!mounted) return;
      _snack(mode == AdminDeleteMode.hard
          ? 'Project permanently deleted.'
          : 'Project deleted — the team can restore it if needed.');
    } catch (e) {
      _showFailure(e);
    } finally {
      if (mounted) setState(() => _deleteInFlight.remove(project.id));
    }
  }

  /// "Generate 3D model": the server picks the photos and starts a generation.
  ///
  /// The result screen cannot watch the run here — these are OTHER users'
  /// projects and `GET /projects/:id` is owner-only — so it renders the request
  /// trace and hands off to the staff generation history, which polls the admin
  /// endpoint. Pushing the screen regardless of outcome is deliberate: a
  /// refusal is the outcome most worth explaining, and a snackbar cannot show
  /// which rule refused with what numbers.
  Future<void> _generate(LiveProject project) async {
    if (_generateInFlight.contains(project.id)) return;
    setState(() => _generateInFlight.add(project.id));
    final pending =
        ref.read(modelGenerationRequestProvider(project.id).notifier).request();
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ModelBuildingScreen(
            projectId: project.id,
            projectName: project.name,
            watchOwnerState: false,
            onOpenHistory: () => context.pushNamed(
              AppRouteNames.modelHistory,
              pathParameters: {'id': project.id},
            ),
          ),
        ),
      );
      // A finished generation changes this list's own Models gating, which is
      // server-aggregated per page — so re-read rather than trusting the row.
      if (mounted) {
        await ref
            .read(liveProjectsProvider.notifier)
            .refresh()
            .catchError((Object e) => _showFailure(e));
      }
    } finally {
      await pending;
      if (mounted) setState(() => _generateInFlight.remove(project.id));
    }
  }

  /// Opens the "Submit model" screen for [project].
  ///
  /// The name rides on the query string so the screen can head itself with the
  /// project the artist actually tapped — see the route's own note on why not
  /// `extra`. A finished submission changes this list's Models gating, so the
  /// return is treated exactly like a finished generation: re-read the page
  /// rather than trusting the row we left behind.
  Future<void> _submitModel(LiveProject project) async {
    await context.pushNamed(
      AppRouteNames.submitModel,
      pathParameters: {'id': project.id},
      queryParameters: {'name': project.name},
    );
    if (!mounted) return;
    await ref
        .read(liveProjectsProvider.notifier)
        .refresh()
        .catchError((Object e) => _showFailure(e));
  }

  /// Friendly, mapped-only failure copy (no raw codes/URLs — same rule as 9F).
  void _showFailure(Object error) {
    if (!mounted) return;
    final message = switch (error) {
      LiveProjectsException(failure: LiveProjectsFailure.notExportable) =>
        'This project has no finished upload to export yet.',
      LiveProjectsException(
        failure: LiveProjectsFailure.confirmationMismatch
      ) =>
        'The name you typed doesn’t match this project.',
      LiveProjectsException(failure: LiveProjectsFailure.notFound) =>
        'This project no longer exists — pull to refresh.',
      LiveProjectsException(
        failure: LiveProjectsFailure.rateLimited,
        retryAfterSeconds: final retry
      ) =>
        retry == null
            ? 'Export limit reached — try again later.'
            : 'Export limit reached — try again in ${friendlyWait(retry)}.',
      LiveProjectsException(failure: LiveProjectsFailure.forbidden) =>
        'Your account no longer has staff access.',
      LiveProjectsException(failure: LiveProjectsFailure.network) =>
        'You’re offline — check your connection and try again.',
      _ => 'Something went wrong. Please try again.',
    };
    _snack(message);
  }

  /// A project with a finalized upload — the backend's exportable set. Mirrors
  /// `_LiveProjectCard._exportable` and `ProjectsScreen._isExportable`.
  static bool _isExportable(LiveProject project) =>
      project.status == ProjectStatus.processing ||
      project.status == ProjectStatus.completed;

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(liveProjectsProvider);
    // Delete is ADMIN-only, mirroring the backend's requireRole('ADMIN') on
    // DELETE /admin/projects/:id. MODEL_ARTIST sees no affordance at all.
    final isAdmin = ref.watch(isAdminProvider);
    return async.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: AppColors.mirageRed),
      ),
      error: (_, __) => _LiveErrorView(
        onRetry: () => ref.invalidate(liveProjectsProvider),
      ),
      data: (state) {
        if (state.items.isEmpty) {
          return _refreshable(
            ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.xxl),
              children: [
                const SizedBox(height: AppSpacing.xxl),
                const Icon(Icons.public_off,
                    color: AppColors.textMuted, size: 40),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'No live projects yet.\nFinished uploads from all users appear here.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          );
        }
        return _refreshable(
          ListView.separated(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: state.items.length + (state.hasMore ? 1 : 0),
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, index) {
              if (index >= state.items.length) {
                return const Padding(
                  padding: EdgeInsets.all(AppSpacing.md),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.textMuted),
                    ),
                  ),
                );
              }
              final project = state.items[index];
              return _LiveProjectCard(
                project: project,
                isExporting: _exportInFlight.contains(project.id),
                onExport: () => _export(project),
                onPreview: () => context.pushNamed(
                  AppRouteNames.previewGallery,
                  pathParameters: {'id': project.id},
                ),
                // Null (button hidden) unless the project has a viewable model.
                // No isStaff check needed: this whole view is already staff-only.
                onModels: project.hasViewableModels
                    ? () => context.pushNamed(
                          AppRouteNames.modelHistory,
                          pathParameters: {'id': project.id},
                        )
                    : null,
                // Only for a project with a finalized capture — the server
                // refuses anything else, and a button that always errors is
                // worse than no button. No isStaff check: this view is staff.
                onGenerate:
                    _isExportable(project) ? () => _generate(project) : null,
                // Same gate as Generate, and for the same reason: the submit
                // route needs the project's finalized job to attach a model to.
                // ADMIN and MODEL_ARTIST both get it — this whole view is
                // already staff-only, and the backend re-checks the role.
                onSubmitModel:
                    _isExportable(project) ? () => _submitModel(project) : null,
                isGenerating: _generateInFlight.contains(project.id),
                // Null (affordance hidden) for MODEL_ARTIST — delete is the
                // ADMIN curation tool for bad captures.
                onDelete: isAdmin ? () => _delete(project) : null,
                // The "Created by" label. Gated TWICE, and both gates are
                // real: the server omits `owner` for anyone below ADMIN, and
                // isAdmin fails CLOSED on a failed role fetch. A MODEL_ARTIST
                // — or an admin whose role could not be read — keeps the
                // opaque owner line the card has always shown.
                onOwner: isAdmin && project.owner != null
                    ? () =>
                        showProjectOwnerSheet(context, owner: project.owner!)
                    : null,
              );
            },
          ),
        );
      },
    );
  }

  Widget _refreshable(Widget child) {
    return RefreshIndicator(
      color: AppColors.mirageRed,
      backgroundColor: AppColors.surface1,
      onRefresh: () =>
          ref.read(liveProjectsProvider.notifier).refresh().catchError(
                (Object e) => _showFailure(e),
              ),
      child: child,
    );
  }
}

/// One live-project row: name, status, photo count, owner (opaque short id),
/// and the Export action for exportable statuses.
class _LiveProjectCard extends StatelessWidget {
  const _LiveProjectCard({
    required this.project,
    required this.isExporting,
    required this.onExport,
    required this.onPreview,
    this.onModels,
    this.onGenerate,
    this.isGenerating = false,
    this.onSubmitModel,
    this.onDelete,
    this.onOwner,
  });

  final LiveProject project;
  final bool isExporting;
  final VoidCallback onExport;
  final VoidCallback onPreview;

  /// OPTIONAL "Models" action — the button renders ONLY when this is non-null,
  /// mirroring ProjectCard.onPreview. The caller passes it only for a project
  /// with a VIEWABLE model, so the button can never open an empty history.
  final VoidCallback? onModels;

  /// OPTIONAL "Generate 3D model" action: the server picks the photos itself.
  /// Same null-hides-it rule as [onModels]; passed only for a project with a
  /// finalized capture, since anything else would always be refused.
  final VoidCallback? onGenerate;

  /// The generation request for this project is in flight (sub-second — this
  /// is the button's own spinner, NOT the minutes-long Meshy run).
  final bool isGenerating;

  /// OPTIONAL "Submit model" action — opens the screen where staff hand a
  /// finished `.glb` to this project. Same null-hides-it rule as [onModels].
  ///
  /// Deliberately NOT gated on whether the project already has models: a second,
  /// better model is a legitimate submission, and the list is a history.
  final VoidCallback? onSubmitModel;

  /// OPTIONAL delete action — non-null for ADMIN only (same null-hides-it
  /// pattern as [onModels]); opens the soft/hard confirmation dialog.
  final VoidCallback? onDelete;

  /// OPTIONAL "Created by" action — non-null only when the caller is ADMIN AND
  /// the row resolved an owner; opens the identity sheet.
  ///
  /// Null does NOT hide the line here, unlike every other optional above: it
  /// falls back to the opaque `Owner …a1b2c3` the card has always shown. The
  /// line is not an affordance, it is a fact about the row, and a MODEL_ARTIST
  /// must not lose it just because they cannot see the name behind it.
  final VoidCallback? onOwner;

  bool get _exportable =>
      project.status == ProjectStatus.processing ||
      project.status == ProjectStatus.completed;

  /// Whether to render the status pill at all.
  ///
  /// Hidden once the project HAS a viewable model AND is still flagged
  /// "Processing…": the model is the deliverable and it has landed, so a
  /// perpetually-pulsing amber pill claims work that is already done. Every
  /// other status keeps its pill. Same rule as `ProjectCard._showStatusPill`
  /// on the My-projects list — the two surfaces must not disagree about the
  /// same project.
  bool get _showStatusPill => !(project.status == ProjectStatus.processing &&
      project.hasViewableModels);

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: AppColors.textMuted);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${project.totalPhotos} photos · '
                      'Updated ${project.updatedAt.timeAgo}',
                      style: muted,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    if (onOwner != null && project.owner != null)
                      _CreatedByLabel(
                        owner: project.owner!,
                        onTap: onOwner!,
                      )
                    else
                      Text('Owner ${project.ownerIdShort}', style: muted),
                  ],
                ),
              ),
              if (_showStatusPill) ...[
                const SizedBox(width: AppSpacing.sm),
                AppStatusPill(status: project.status),
              ],
              if (onDelete != null) ...[
                // A tighter gap after the pill, a full one when the pill is
                // suppressed and the icon sits straight after the text column.
                SizedBox(
                    width: _showStatusPill ? AppSpacing.xs : AppSpacing.sm),
                IconButton(
                  key: ValueKey('live_delete_${project.id}'),
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: AppColors.textMuted,
                  tooltip: 'Delete project',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: onDelete,
                ),
              ],
            ],
          ),
          if (_exportable) ...[
            const SizedBox(height: AppSpacing.md),
            const Divider(color: AppColors.disabled, thickness: 0.5, height: 1),
            const SizedBox(height: AppSpacing.md),
            // Expanded slots bound each button's width (AppButton's theme has
            // an infinite minimumSize, so a bare Row child would overflow).
            Row(
              children: [
                Expanded(
                  child: AppButton.secondary(
                    label: 'Preview',
                    icon: Icons.photo_library_outlined,
                    onPressed: onPreview,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppButton.secondary(
                    label: 'Export',
                    icon: Icons.ios_share,
                    isLoading: isExporting,
                    onPressed: onExport,
                  ),
                ),
              ],
            ),
            // Own row rather than a third Expanded slot: three labelled+icon
            // buttons across a phone-width card ellipsize. Rendered only when
            // the project HAS a viewable model, so the row is rare and the
            // common card keeps its two-button shape.
            if (onModels != null) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: AppButton.secondary(
                  label: 'Models',
                  icon: Icons.view_in_ar_outlined,
                  onPressed: onModels,
                ),
              ),
            ],
            if (onGenerate != null) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: AppButton.secondary(
                  key: ValueKey('live_generate_${project.id}'),
                  label: 'Generate 3D model',
                  icon: Icons.auto_awesome_outlined,
                  isLoading: isGenerating,
                  onPressed: onGenerate,
                ),
              ),
            ],
            // Its own full-width row beneath Generate, and in that order on
            // purpose: generating is the common path, submitting a hand-made
            // model the deliberate one.
            if (onSubmitModel != null) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: AppButton.secondary(
                  key: ValueKey('live_submit_model_${project.id}'),
                  label: 'Submit model',
                  icon: Icons.cloud_upload_outlined,
                  onPressed: onSubmitModel,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// The ADMIN-only "Created by" chip: the capturer's picture, their name, and a
/// hint that there is more behind it.
///
/// It replaces the opaque `Owner …a1b2c3` line rather than sitting beside it —
/// an admin who can see the name has no use for the truncated id, and two owner
/// lines on one card is noise. The id is still one tap away, at the top of the
/// sheet, for the rare case of talking to the backend about a row.
///
/// A CHIP, not a button: it sits inside the card's text column, where a real
/// button would compete with Preview/Export/Generate for the eye. The tap
/// target is padded out to a comfortable size regardless.
class _CreatedByLabel extends StatelessWidget {
  const _CreatedByLabel({required this.owner, required this.onTap});

  final ProjectOwnerSummary owner;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: AppColors.textMuted);

    return InkWell(
      key: ValueKey('live_owner_${owner.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OwnerAvatar(owner: owner, size: 20),
            const SizedBox(width: AppSpacing.sm),
            // Flexible, not Expanded: the chip hugs a short name instead of
            // stretching a hairline of empty tap target across the card.
            Flexible(
              child: Text(
                'Created by ${owner.displayLabel}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            const Icon(Icons.info_outline,
                size: 13, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

class _LiveErrorView extends StatelessWidget {
  const _LiveErrorView({required this.onRetry});

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
              "Couldn't load live projects.",
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
