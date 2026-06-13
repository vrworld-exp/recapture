// lib/domain/entities/permission_item.dart
import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';

/// The permissions ReCapture requests before a capture session.
enum AppPermissionType { camera, motion, photos }

/// How strongly a permission gates progress.
///
/// - [required] — blocks the Continue CTA until granted (Camera).
/// - [recommended] — warns when missing but never blocks (Motion).
/// - [optional] — never blocks, never warns (Photos).
enum PermissionRequirement { required, recommended, optional }

/// Display metadata for a single permission. Illustrations use Material
/// [IconData] to match the rest of the app — the project ships no assets.
@immutable
class PermissionItem {
  const PermissionItem({
    required this.type,
    required this.title,
    required this.rationale,
    required this.icon,
    required this.requirement,
  });

  final AppPermissionType type;
  final String title;
  final String rationale;
  final IconData icon;
  final PermissionRequirement requirement;
}

/// Display properties for each requirement level (badge label + color).
extension PermissionRequirementDisplay on PermissionRequirement {
  String get label => switch (this) {
        PermissionRequirement.required => '(required)',
        PermissionRequirement.recommended => '(recommended)',
        PermissionRequirement.optional => '(optional)',
      };

  Color get color => switch (this) {
        PermissionRequirement.required => AppColors.mirageRed,
        PermissionRequirement.recommended => AppColors.textSecondary,
        PermissionRequirement.optional => AppColors.textMuted,
      };

  /// Lowercase token used for analytics properties.
  String get analyticsValue => switch (this) {
        PermissionRequirement.required => 'required',
        PermissionRequirement.recommended => 'recommended',
        PermissionRequirement.optional => 'optional',
      };
}

/// Lowercase token used for analytics properties.
extension AppPermissionTypeAnalytics on AppPermissionType {
  String get analyticsValue => switch (this) {
        AppPermissionType.camera => 'camera',
        AppPermissionType.motion => 'motion',
        AppPermissionType.photos => 'photos',
      };
}

/// The three permissions shown on the gate, in display order.
const List<PermissionItem> defaultPermissionItems = [
  PermissionItem(
    type: AppPermissionType.camera,
    title: 'Camera',
    rationale: 'To capture photos of your object.',
    icon: Icons.camera_alt_outlined,
    requirement: PermissionRequirement.required,
  ),
  PermissionItem(
    type: AppPermissionType.motion,
    title: 'Motion',
    rationale: 'Improves tilt and stability guidance during capture.',
    icon: Icons.sensors,
    requirement: PermissionRequirement.recommended,
  ),
  PermissionItem(
    type: AppPermissionType.photos,
    title: 'Photos',
    rationale: 'To save captured results to your gallery.',
    icon: Icons.photo_library_outlined,
    requirement: PermissionRequirement.optional,
  ),
];
