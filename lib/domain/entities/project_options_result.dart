// lib/domain/entities/project_options_result.dart
import 'project.dart';

/// What the user did in the Project Options sheet.
enum ProjectOptionsAction { renamed, deleted, none }

/// Typed result returned by `showProjectOptionsSheet`.
///
/// The sheet always resolves to one of these (never null) so the Projects List
/// can branch deterministically and update its state in place — no full
/// refetch after a rename or delete.
class ProjectOptionsResult {
  final ProjectOptionsAction action;

  /// Set only when [action] is [ProjectOptionsAction.renamed].
  final Project? updatedProject;

  /// Set only when [action] is [ProjectOptionsAction.deleted].
  final String? deletedProjectId;

  const ProjectOptionsResult.renamed(Project project)
      : action = ProjectOptionsAction.renamed,
        updatedProject = project,
        deletedProjectId = null;

  const ProjectOptionsResult.deleted(String id)
      : action = ProjectOptionsAction.deleted,
        updatedProject = null,
        deletedProjectId = id;

  const ProjectOptionsResult.none()
      : action = ProjectOptionsAction.none,
        updatedProject = null,
        deletedProjectId = null;
}
