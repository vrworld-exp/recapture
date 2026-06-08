// lib/domain/entities/project_status.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';

/// The lifecycle state of a ReCapture capture project.
///
/// State machine:
///   draft → capturing → uploading → processing → completed
///                                              ↘ failed
///
/// This enum is the single source of truth for project status across:
///   - Domain entities (Project)
///   - Remote API responses (jobs collection `status` field)
///   - Local Hive storage (serialised as string)
///   - Presentation layer (AppStatusPill widget)
enum ProjectStatus {
  draft,
  capturing,
  uploading,
  processing,
  completed,
  failed,
}

/// Display properties for each ProjectStatus.
/// Import this extension wherever a status needs a label or color.
extension ProjectStatusDisplay on ProjectStatus {
  /// Human-readable label shown in UI (e.g. status pills, project cards).
  String get label => switch (this) {
        ProjectStatus.draft => 'Draft',
        ProjectStatus.capturing => 'Capturing',
        ProjectStatus.uploading => 'Uploading',
        ProjectStatus.processing => 'Processing',
        ProjectStatus.completed => 'Completed',
        ProjectStatus.failed => 'Failed',
      };

  /// Semantic color for this status.
  /// Used by AppStatusPill and any other status-aware UI.
  Color get color => switch (this) {
        ProjectStatus.draft => AppColors.disabled,
        ProjectStatus.capturing => AppColors.mirageRed,
        ProjectStatus.uploading => AppColors.royalGold,
        ProjectStatus.processing => AppColors.royalGold,
        ProjectStatus.completed => AppColors.success,
        ProjectStatus.failed => AppColors.error,
      };

  /// Whether this status represents an in-progress state.
  /// Used to show resume/retry actions on project cards.
  bool get isActive => switch (this) {
        ProjectStatus.draft => true,
        ProjectStatus.capturing => true,
        ProjectStatus.uploading => true,
        ProjectStatus.processing => false,
        ProjectStatus.completed => false,
        ProjectStatus.failed => false,
      };

  /// Whether this status allows the user to resume capture.
  bool get canResume => switch (this) {
        ProjectStatus.draft => true,
        ProjectStatus.capturing => true,
        ProjectStatus.uploading => false,
        ProjectStatus.processing => false,
        ProjectStatus.completed => false,
        ProjectStatus.failed => false,
      };

  /// API string value matching the backend `status` field in the
  /// MongoDB `projects` collection. Must match exactly.
  String get apiValue => switch (this) {
        ProjectStatus.draft => 'DRAFT',
        ProjectStatus.capturing => 'CAPTURING',
        ProjectStatus.uploading => 'UPLOADING',
        ProjectStatus.processing => 'PROCESSING',
        ProjectStatus.completed => 'COMPLETED',
        ProjectStatus.failed => 'FAILED',
      };

  /// Parse an API string back to a ProjectStatus.
  /// Returns [ProjectStatus.draft] as a safe fallback for unknown values.
  static ProjectStatus fromApiValue(String value) {
    return switch (value.toUpperCase()) {
      'DRAFT' => ProjectStatus.draft,
      'CAPTURING' => ProjectStatus.capturing,
      'UPLOADING' => ProjectStatus.uploading,
      'PROCESSING' => ProjectStatus.processing,
      'COMPLETED' => ProjectStatus.completed,
      'FAILED' => ProjectStatus.failed,
      _ => ProjectStatus.draft, // safe fallback
    };
  }
}
