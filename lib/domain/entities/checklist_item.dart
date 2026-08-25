// lib/domain/entities/checklist_item.dart
import 'package:flutter/material.dart';

/// A single pre-capture checklist item the user reviews (and, when
/// [isRequired], must acknowledge) before starting a capture session.
///
/// Illustrations use Material [IconData] to match the rest of the app —
/// the project ships no raster/SVG assets, so there is no missing-asset
/// failure mode to guard against.
@immutable
class ChecklistItem {
  const ChecklistItem({
    required this.id,
    required this.icon,
    required this.title,
    required this.shortDescription,
    required this.tooltipContent,
    this.isRequired = true,
  });

  /// Stable identifier used to track acknowledgment state.
  final String id;

  /// Illustration shown in the circular badge on the tile.
  final IconData icon;

  /// One-line item heading.
  final String title;

  /// Short supporting line shown under the title.
  final String shortDescription;

  /// Extended explanation shown in the tooltip bottom sheet. May be long —
  /// the sheet scrolls internally when it exceeds the available height.
  final String tooltipContent;

  /// When true the user must check this item before the Start CTA enables.
  final bool isRequired;
}

/// Placeholder checklist content. Final copy/illustrations are expected to be
/// supplied later via a content/config update rather than hardcoded here.
const List<ChecklistItem> defaultChecklistItems = [
  ChecklistItem(
    id: 'lighting',
    icon: Icons.wb_sunny_outlined,
    title: 'Good lighting',
    shortDescription: 'Bright, even light — no harsh shadows.',
    tooltipContent:
        'Even, diffuse lighting gives the cleanest reconstruction. Capture '
        'near a large window or under soft room lighting. Avoid direct flash, '
        'strong single-point lamps, and deep shadows — these create dark '
        'patches and glare that confuse the photogrammetry pipeline and reduce '
        'the quality of your final model.',
  ),
  ChecklistItem(
    id: 'space',
    icon: Icons.open_in_full,
    title: 'Clear space (2m radius)',
    shortDescription: 'Room to walk a full circle around the object.',
    tooltipContent:
        'You will move around the object in a complete circle, so clear at '
        'least a 2-metre radius of obstacles. A clutter-free, plain background '
        'also helps the system separate the object from its surroundings and '
        'produces cleaner edges.',
  ),
  ChecklistItem(
    id: 'stable',
    icon: Icons.table_restaurant_outlined,
    title: 'Stable surface / hand',
    shortDescription: 'Object must not move while you capture.',
    tooltipContent:
        'The object has to stay perfectly still relative to its surroundings. '
        'Place it on a stable, non-wobbly surface. Do not pick it up or rotate '
        'the object itself — you move around it, not the other way around. Any '
        'movement of the object mid-capture breaks alignment between photos.',
  ),
  ChecklistItem(
    id: 'camera_permission',
    icon: Icons.camera_alt_outlined,
    title: 'Camera permission granted',
    shortDescription: 'ReCapture needs the camera to capture.',
    tooltipContent:
        'Capture is impossible without camera access. If you have not granted '
        'the camera permission yet, you will be prompted on the next screen. '
        'You can always change this later in your device Settings under the '
        'ReCapture app permissions.',
  ),
];
