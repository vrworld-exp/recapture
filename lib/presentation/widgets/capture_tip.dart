// lib/presentation/widgets/capture_tip.dart
import 'package:flutter/material.dart';

/// A single scannable capture tip (icon + short title + 1–2 line body). This is
/// the SHARED content model consumed by BOTH the Level A Help sheet
/// ([LevelAHelpSheet]) and the Screen 5A intro rules — the copy lives here once
/// so the two never drift.
///
/// Lives under presentation (not domain) because it carries an [IconData];
/// domain entities stay pure Dart.
class CaptureTip {
  const CaptureTip({
    required this.id,
    required this.title,
    required this.body,
    required this.icon,
  });

  final String id;

  /// Short label, e.g. "Good lighting".
  final String title;

  /// 1–2 line guidance. May contain the `{n}` token, replaced with the
  /// config-derived ring segment count via [formattedBody].
  final String body;

  final IconData icon;

  /// The body with the `{n}` count placeholder resolved (no-op when absent).
  String formattedBody(int segments) => body.replaceAll('{n}', '$segments');
}

/// Fallback eye-ring segment count, matching `CaptureConfig.bundledDefault`'s
/// `mid` band. Used only if a renderer has no live config to format `{n}`.
const int kFallbackRingSegments = 10;

/// The single shared Level A tip list (6 items). Both the Help sheet and the
/// Screen 5A intro read from this — edit copy here and both update. Higher
/// levels can define their own list and reuse the same sheet/rendering.
const List<CaptureTip> levelACaptureTips = [
  CaptureTip(
    id: 'lighting',
    title: 'Good lighting',
    body: 'Capture in good, even light — avoid harsh shadows and glare.',
    icon: Icons.wb_sunny_outlined,
  ),
  CaptureTip(
    id: 'framing',
    title: 'Frame the object',
    body: 'Keep the object centered and fully in frame.',
    icon: Icons.center_focus_strong,
  ),
  CaptureTip(
    id: 'eye_level',
    title: 'Stay at eye level',
    body: 'Keep the camera level with the object as you circle it.',
    icon: Icons.visibility_outlined,
  ),
  CaptureTip(
    id: 'coverage',
    title: 'Cover the full ring',
    body: 'Move slowly in a circle — cover all {n} positions.',
    icon: Icons.donut_large,
  ),
  CaptureTip(
    id: 'steady',
    title: 'Hold steady',
    body: 'Pause at each spot and let it settle before the shot.',
    icon: Icons.pan_tool_outlined,
  ),
  CaptureTip(
    id: 'slow',
    title: 'Move slowly',
    body: 'Avoid quick movements; smooth and steady wins.',
    icon: Icons.slow_motion_video,
  ),
];
