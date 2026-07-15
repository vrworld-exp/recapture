// lib/presentation/screens/projects/live_projects_view.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/projects/live_projects_notifier.dart';
import '../../../application/projects/project_export_service.dart';
import '../../../data/repositories/live_projects_repository.dart';
import '../../../domain/entities/live_project.dart';
import '../../../domain/entities/project_status.dart';
import '../../../utils/analytics.dart';
import '../../../utils/extensions.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_status_pill.dart';

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

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // REACH metric: once per tab entry (a fresh State per entry), not per
    // rebuild. Non-PII: no ids ride along.
    Analytics.logEvent('live_projects_viewed');
    _scroll.addListener(_maybeLoadMore);
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
      final result =
          await ref.read(projectExportServiceProvider).exportProject(project.id);
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

  /// Friendly, mapped-only failure copy (no raw codes/URLs — same rule as 9F).
  void _showFailure(Object error) {
    if (!mounted) return;
    final message = switch (error) {
      LiveProjectsException(failure: LiveProjectsFailure.notExportable) =>
        'This project has no finished upload to export yet.',
      LiveProjectsException(
        failure: LiveProjectsFailure.rateLimited,
        retryAfterSeconds: final retry
      ) =>
        retry == null
            ? 'Export limit reached — try again later.'
            : 'Export limit reached — try again in ${_friendlyWait(retry)}.',
      LiveProjectsException(failure: LiveProjectsFailure.forbidden) =>
        'Your account no longer has staff access.',
      LiveProjectsException(failure: LiveProjectsFailure.network) =>
        'You’re offline — check your connection and try again.',
      _ => 'Something went wrong. Please try again.',
    };
    _snack(message);
  }

  static String _friendlyWait(int seconds) {
    if (seconds < 90) return '$seconds seconds';
    return '${(seconds / 60).ceil()} minutes';
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(liveProjectsProvider);
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
  });

  final LiveProject project;
  final bool isExporting;
  final VoidCallback onExport;
  final VoidCallback onPreview;

  bool get _exportable =>
      project.status == ProjectStatus.processing ||
      project.status == ProjectStatus.completed;

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
                    Text('Owner ${project.ownerIdShort}', style: muted),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppStatusPill(status: project.status),
            ],
          ),
          if (_exportable) ...[
            const SizedBox(height: AppSpacing.md),
            const Divider(
                color: AppColors.disabled, thickness: 0.5, height: 1),
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
          ],
        ],
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
