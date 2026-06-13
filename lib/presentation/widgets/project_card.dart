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
    this.isActionInFlight = false,
  });

  final Project project;
  final ValueChanged<Project> onResume;
  final ValueChanged<Project> onView;
  final ValueChanged<Project> onRetry;

  /// Opens the project options sheet (Rename / Delete). The card stays free of
  /// sheet logic — it only signals intent.
  final ValueChanged<Project> onMore;

  /// When true the action button shows a loading state and is disabled
  /// (per-project in-flight guard owned by the screen).
  final bool isActionInFlight;

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
                      'Updated ${project.updatedAt.timeAgo}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppStatusPill(status: project.status),
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
    final action = project.status.cardAction;
    if (action == ProjectCardAction.none) return const [];

    return [
      const SizedBox(height: AppSpacing.md),
      const Divider(color: AppColors.disabled, thickness: 0.5, height: 1),
      const SizedBox(height: AppSpacing.md),
      Align(
        alignment: Alignment.centerRight,
        child: _buildAction(context, action),
      ),
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
