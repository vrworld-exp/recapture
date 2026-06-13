// lib/domain/entities/project_status.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';

/// The lifecycle state of a ReCapture capture project.
///
/// State machine:
///   draft → capturing → uploading → processing → completed
///                                              ↘ failed
///
/// [completed] is the viewer-facing "model is viewable" status (the legacy
/// backend value `ready` maps to it for backward-compat). [unknown] is a
/// defensive fallback for any unmapped backend status string.
///
/// This enum is the single source of truth for project status across:
///   - Domain entities (Project)
///   - Remote API responses (jobs collection `status` field)
///   - Local Hive storage (serialised as string)
///   - Presentation layer (AppStatusPill widget, ProjectCard actions)
enum ProjectStatus {
  draft,
  capturing,
  uploading,
  processing,
  completed,
  failed,
  unknown,
}

/// The single contextual action a project card offers for a given status.
enum ProjectCardAction { resume, view, retry, uploading, processing, none }

/// Display properties for each ProjectStatus.
/// Import this extension wherever a status needs a label, color, or action.
extension ProjectStatusDisplay on ProjectStatus {
  /// Human-readable label shown in UI (e.g. status pills, project cards).
  String get label => switch (this) {
        ProjectStatus.draft => 'Draft',
        ProjectStatus.capturing => 'Capturing',
        ProjectStatus.uploading => 'Uploading',
        ProjectStatus.processing => 'Processing',
        ProjectStatus.completed => 'Completed',
        ProjectStatus.failed => 'Failed',
        ProjectStatus.unknown => 'Unknown',
      };

  /// Semantic color for this status (theme tokens only — never hardcoded hex).
  /// Used by AppStatusPill and any other status-aware UI.
  Color get color => switch (this) {
        ProjectStatus.draft => AppColors.disabled,
        ProjectStatus.capturing => AppColors.mirageRed,
        ProjectStatus.uploading => AppColors.royalGold,
        ProjectStatus.processing => AppColors.warning,
        ProjectStatus.completed => AppColors.success,
        ProjectStatus.failed => AppColors.error,
        ProjectStatus.unknown => AppColors.textMuted,
      };

  /// Transient, server-or-device-driven states that show a live progress
  /// affordance. Single source of truth for "is this state in motion".
  bool get isInProgress =>
      this == ProjectStatus.capturing ||
      this == ProjectStatus.uploading ||
      this == ProjectStatus.processing;

  /// Settled end states. Single source of truth for "is this state finished".
  bool get isTerminal =>
      this == ProjectStatus.completed || this == ProjectStatus.failed;

  /// The contextual card action for this status. Mapping lives here in the
  /// model — card widgets consume this, never raw status logic.
  ///
  /// `capturing` is resumable (the user can return to the in-progress capture);
  /// `uploading` and `processing` are non-interactive progress states.
  ProjectCardAction get cardAction => switch (this) {
        ProjectStatus.draft => ProjectCardAction.resume,
        ProjectStatus.capturing => ProjectCardAction.resume,
        ProjectStatus.uploading => ProjectCardAction.uploading,
        ProjectStatus.processing => ProjectCardAction.processing,
        ProjectStatus.completed => ProjectCardAction.view,
        ProjectStatus.failed => ProjectCardAction.retry,
        ProjectStatus.unknown => ProjectCardAction.none,
      };

  /// API string value matching the backend `status` field. Must match exactly.
  String get apiValue => switch (this) {
        ProjectStatus.draft => 'DRAFT',
        ProjectStatus.capturing => 'CAPTURING',
        ProjectStatus.uploading => 'UPLOADING',
        ProjectStatus.processing => 'PROCESSING',
        ProjectStatus.completed => 'COMPLETED',
        ProjectStatus.failed => 'FAILED',
        ProjectStatus.unknown => 'UNKNOWN',
      };

  /// Parse an API string back to a ProjectStatus. Case-insensitive.
  ///
  /// Legacy `READY` maps to [ProjectStatus.completed]. Returns
  /// [ProjectStatus.unknown] for any unrecognised value so the UI can render
  /// defensively instead of crashing or mislabelling.
  static ProjectStatus fromApiValue(String value) {
    return switch (value.toUpperCase()) {
      'DRAFT' => ProjectStatus.draft,
      'CAPTURING' => ProjectStatus.capturing,
      'UPLOADING' => ProjectStatus.uploading,
      'PROCESSING' => ProjectStatus.processing,
      'COMPLETED' => ProjectStatus.completed,
      'READY' => ProjectStatus.completed, // backward-compat: legacy value
      'FAILED' => ProjectStatus.failed,
      _ => ProjectStatus.unknown,
    };
  }
}
