// lib/presentation/widgets/level_a_settings_sheet.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/capture_settings.dart';
import '../../utils/analytics.dart';

/// Opens the Level A Settings sheet: auto-capture, save-to-gallery, and quality
/// mode. Matches the existing sheet styling (rounded top, drag handle, dark
/// surface, scrim). Always dismissible (swipe / tap-outside / close); the future
/// completes on dismissal so the parent can resume auto-capture.
///
/// Driven by a parent-owned [settings] listenable (NOT a one-shot snapshot) so
/// that a parent-side revert — e.g. save-to-gallery permission denied — reflects
/// live in the open sheet. Each user change calls [onChanged]; the parent
/// persists, applies live, and handles permissions. The sheet itself owns no
/// capture/permission/persistence logic.
Future<void> showLevelASettingsSheet(
  BuildContext context, {
  required ValueListenable<CaptureSettings> settings,
  required void Function(CaptureSettings) onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface1,
    barrierColor: AppColors.scrim,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (_) => LevelASettingsSheet(settings: settings, onChanged: onChanged),
  );
}

class LevelASettingsSheet extends StatelessWidget {
  const LevelASettingsSheet({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final ValueListenable<CaptureSettings> settings;
  final void Function(CaptureSettings) onChanged;

  static String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  void _emit(String setting, String value) {
    Analytics.logEvent(AnalyticsEvents.captureSettingChanged, {
      'setting': setting,
      'value': value,
      'device_type': _deviceType,
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Capture settings',
                        style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ValueListenableBuilder<CaptureSettings>(
                valueListenable: settings,
                builder: (context, s, _) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SwitchRow(
                        title: 'Auto-capture',
                        subtitle:
                            'Capture automatically when steady and aligned.',
                        value: s.autoCapture,
                        onChanged: (v) {
                          _emit('auto_capture', v ? 'on' : 'off');
                          onChanged(s.copyWith(autoCapture: v));
                        },
                      ),
                      _SwitchRow(
                        title: 'Save to gallery',
                        subtitle:
                            'Also save photos to your device gallery. Needs photo permission.',
                        value: s.saveToGallery,
                        onChanged: (v) {
                          _emit('save_to_gallery', v ? 'on' : 'off');
                          onChanged(s.copyWith(saveToGallery: v));
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                      _QualityRow(
                        value: s.quality,
                        onChanged: (q) {
                          _emit('quality_mode', qualityModeToString(q));
                          onChanged(s.copyWith(quality: q));
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A labelled switch row (title + helper + adaptive switch).
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      activeThumbColor: AppColors.mirageRed,
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: AppColors.textSecondary, height: 1.3),
      ),
    );
  }
}

/// Quality mode selector (Standard / High) with a one-line trade-off note.
class _QualityRow extends StatelessWidget {
  const _QualityRow({required this.value, required this.onChanged});

  final QualityMode value;
  final ValueChanged<QualityMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quality',
          style: theme.textTheme.titleSmall?.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Higher quality uses more storage and processing.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.textSecondary, height: 1.3),
        ),
        const SizedBox(height: AppSpacing.sm),
        SegmentedButton<QualityMode>(
          segments: const [
            ButtonSegment(
              value: QualityMode.standard,
              label: Text('Standard'),
            ),
            ButtonSegment(
              value: QualityMode.high,
              label: Text('High'),
            ),
          ],
          selected: {value},
          showSelectedIcon: false,
          onSelectionChanged: (sel) => onChanged(sel.first),
        ),
      ],
    );
  }
}
