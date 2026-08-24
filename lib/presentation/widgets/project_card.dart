// lib/presentation/widgets/project_card.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_status.dart';
import '../../utils/extensions.dart';
import 'app_button.dart';
import 'app_card.dart';
import 'app_status_pill.dart';

/// A single project row. Pure presentation — every action is an injected
/// callback, so the card holds no business logic.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    super.key,
    required this.project,
    required this.onResume,
    required this.onView,
    required this.onRetry,
    required this.onMore,
    this.onPreview,
    this.onModels,
    this.onGenerate,
    this.isActionInFlight = false,
  });

  final Project project;

  /// The card's primary "continue this project" action. It backs BOTH the
  /// capture card's "Resume" and the upload card's "Select photos" — one
  /// callback because it means one thing to the screen ("open where this
  /// project left off"), and the screen already routes the two sources to
  /// their own destinations.
  final ValueChanged<Project> onResume;
  final ValueChanged<Project> onView;
  final ValueChanged<Project> onRetry;

  /// Opens the project options sheet (Rename / Delete). The card stays free of
  /// sheet logic — it only signals intent.
  final ValueChanged<Project> onMore;

  /// OPTIONAL staff-only "Preview" action. Null for every non-staff caller
  /// (default) — the button renders ONLY when this is non-null, so the shared
  /// My-projects card is byte-for-byte unchanged for regular users. The screen
  /// passes it only for staff on an exportable project.
  final ValueChanged<Project>? onPreview;

  /// OPTIONAL staff-only "Models" action, opening the project's 3D-model
  /// generation history. Null for every non-staff caller (default) — same
  /// null-means-hidden rule as [onPreview], so the shared card is unchanged for
  /// regular users.
  ///
  /// Deliberately ONE button rather than one per model: the history grows
  /// without bound (a project regenerated eight times would crowd this
  /// fixed-height card with eight buttons), and a list has room to show the
  /// timestamp, status, photo count and approval that a button cannot.
  final ValueChanged<Project>? onModels;

  /// OPTIONAL staff-only "Generate" action: ask the server to pick photos
  /// itself and build a 3D model. Same null-means-hidden rule as [onPreview].
  ///
  /// The caller passes it only for a project with a FINALIZED capture — a
  /// project without one would always be refused, and a button that always
  /// errors is worse than no button.
  final ValueChanged<Project>? onGenerate;

  /// When true the action button shows a loading state and is disabled
  /// (per-project in-flight guard owned by the screen).
  final bool isActionInFlight;

  /// Whether to render the top-right status pill.
  ///
  /// Hidden once a viewable model exists AND the project is still flagged
  /// "Processing…": the model is the real deliverable and it's done, so a
  /// perpetually-pulsing amber "Processing" pill is stale noise. Every other
  /// status keeps its pill. Mirrors the action-area suppression in
  /// [_buildActionArea].
  bool get _showStatusPill =>
      !(project.status == ProjectStatus.processing &&
          project.hasViewableModels);

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Thumbnail(url: project.thumbnailUrl),
              const SizedBox(width: AppSpacing.md),
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
                      // Photo count comes from the API's stats.totalPhotos —
                      // populated once an upload finalizes; hidden until then.
                      project.totalPhotos > 0
                          ? '${project.totalPhotos} photos · '
                              'Updated ${project.updatedAt.timeAgo}'
                          : 'Updated ${project.updatedAt.timeAgo}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              if (_showStatusPill) ...[
                const SizedBox(width: AppSpacing.sm),
                AppStatusPill(status: project.status),
              ],
              IconButton(
                icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                tooltip: 'Project options',
                onPressed: () => onMore(project),
              ),
            ],
          ),
          ..._buildActionArea(context),
        ],
      ),
    );
  }

  List<Widget> _buildActionArea(BuildContext context) {
    // Once a viewable model exists, the "Processing…" label is stale noise: the
    // model is done and the Models button is the real state. Suppress it so the
    // card doesn't spin forever. Uploading is untouched — that's a live upload,
    // not a finished model.
    // Project.cardAction, not status.cardAction: a DRAFT upload project has
    // nothing to resume, and the status alone cannot tell the two apart.
    final rawAction = project.cardAction;
    final action =
        rawAction == ProjectCardAction.processing && project.hasViewableModels
            ? ProjectCardAction.none
            : rawAction;
    final showPreview = onPreview != null;
    final showModels = onModels != null;
    final showGenerate = onGenerate != null;
    if (action == ProjectCardAction.none &&
        !showPreview &&
        !showModels &&
        !showGenerate) {
      return const [];
    }

    final trailing = <Widget>[
      if (showPreview)
        AppButton.secondary(
          label: 'Preview',
          icon: Icons.photo_library_outlined,
          isFullWidth: false,
          onPressed: () => onPreview!(project),
        ),
      if (showModels)
        AppButton.secondary(
          label: 'Models',
          icon: Icons.view_in_ar_outlined,
          isFullWidth: false,
          onPressed: () => onModels!(project),
        ),
      if (action != ProjectCardAction.none) _buildAction(context, action),
    ];

    return [
      const SizedBox(height: AppSpacing.md),
      const Divider(color: AppColors.disabled, thickness: 0.5, height: 1),
      const SizedBox(height: AppSpacing.md),
      // AppButton's theme sets an infinite minimumSize width, so each child
      // needs a bounded-width slot — Expanded gives that (a lone action fills
      // the row, matching the previous single-Align layout).
      Row(
        children: [
          for (var i = 0; i < trailing.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.sm),
            Expanded(child: trailing[i]),
          ],
        ],
      ),
      // Its OWN full-width row rather than a fourth slot above: three labelled
      // buttons across a phone-width card already ellipsize, and this one is a
      // deliberate, credit-spending action that should not be squeezed into an
      // abbreviation. Same treatment the Live card gives its Models button.
      if (showGenerate) ...[
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          width: double.infinity,
          child: AppButton.secondary(
            label: 'Generate 3D model',
            icon: Icons.auto_awesome_outlined,
            onPressed: () => onGenerate!(project),
          ),
        ),
      ],
    ];
  }

  Widget _buildAction(BuildContext context, ProjectCardAction action) {
    switch (action) {
      case ProjectCardAction.uploading:
        return _ProgressLabel(
          label: 'Uploading…',
          color: project.status.color,
        );
      case ProjectCardAction.processing:
        return _ProgressLabel(
          label: 'Processing…',
          color: project.status.color,
        );
      case ProjectCardAction.resume:
        return AppButton(
          label: 'Resume',
          isFullWidth: false,
          isLoading: isActionInFlight,
          onPressed: () => onResume(project),
        );
      case ProjectCardAction.selectPhotos:
        // Same callback as Resume — the screen routes an upload project to its
        // photo grid — but never the same WORD: the photos are already in, so
        // "Resume" would promise an unfinished job that does not exist.
        return AppButton(
          label: 'Select photos',
          isFullWidth: false,
          isLoading: isActionInFlight,
          onPressed: () => onResume(project),
        );
      case ProjectCardAction.view:
        return AppButton.secondary(
          label: 'View',
          isFullWidth: false,
          isLoading: isActionInFlight,
          onPressed: () => onView(project),
        );
      case ProjectCardAction.retry:
        return AppButton(
          label: 'Retry',
          icon: Icons.refresh,
          isFullWidth: false,
          isLoading: isActionInFlight,
          onPressed: () => onRetry(project),
        );
      case ProjectCardAction.none:
        return const SizedBox.shrink();
    }
  }
}

/// Non-interactive progress row for in-progress states (uploading/processing).
/// A small spinner plus a label, tinted with the status's semantic color.
class _ProgressLabel extends StatelessWidget {
  const _ProgressLabel({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          label,
          style:
              Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// Square thumbnail with a graceful placeholder for null/broken URLs.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: SizedBox(
        width: 48,
        height: 48,
        child: url == null
            ? const _ThumbnailPlaceholder()
            : Image.network(
                url!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const _ThumbnailPlaceholder(),
              ),
      ),
    );
  }
}

class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface2,
      alignment: Alignment.center,
      child: const Icon(
        Icons.view_in_ar_outlined,
        color: AppColors.textMuted,
        size: 22,
      ),
    );
  }
}
