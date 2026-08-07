// lib/presentation/screens/projects/capture_mode_sheet.dart
//
// The capture-mode chooser behind the Projects `+` button: Full Capture vs
// Meshy Capture, asked ONCE at project creation because the answer changes how
// many photos the whole session will take.
//
// ── WHY A MODAL SHEET AND NOT A ROUTE ───────────────────────────────────────
// A sheet adds no entry to the router, so `lib/app/routes/flow_back.dart` needs
// no new back mapping and hardware back simply dismisses it. Made a route, this
// would need a mapping there or back would escape the creation flow entirely.
//
// The chosen mode is returned to the caller AND pushed into
// [captureModeProvider] — the provider because the pre-capture and capture
// screens read it from there, the return value because the caller must not
// navigate on a dismissal.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/capture_mode_provider.dart';
import '../../../application/config/config_notifier.dart';
import '../../../domain/capture/capture_mode.dart';
import '../../../domain/capture/capture_flow_variant.dart';
import '../../../domain/entities/capture_config.dart';
import '../../widgets/selectable_option_card.dart';

/// Asks which capture mode to use. Resolves to the chosen mode, or null when
/// the user dismissed the sheet without choosing (scrim tap / back / drag) —
/// callers MUST treat null as "do nothing", never as the default.
Future<CaptureMode?> showCaptureModeSheet(BuildContext context) {
  return showModalBottomSheet<CaptureMode>(
    context: context,
    backgroundColor: AppColors.bgPrimary,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (_) => const _CaptureModeSheet(),
  );
}

class _CaptureModeSheet extends ConsumerStatefulWidget {
  const _CaptureModeSheet();

  @override
  ConsumerState<_CaptureModeSheet> createState() => _CaptureModeSheetState();
}

class _CaptureModeSheetState extends ConsumerState<_CaptureModeSheet> {
  // Full Capture leads and is preselected: it is the default and the behaviour
  // that already exists, so the common path needs no interaction.
  CaptureMode _selected = CaptureMode.full;

  Future<void> _confirm() async {
    // Persisting has to wait for a project id, which does not exist yet — the
    // provider holds the choice in memory and CreateProjectScreen writes it
    // through the moment the id arrives.
    await ref.read(captureModeProvider.notifier).select(_selected);
    if (mounted) Navigator.of(context).pop(_selected);
  }

  /// The photo total for [mode], summed over the default variant's rings — a
  /// SUM, because Meshy's rings hold different counts and `rings × perRing`
  /// would be wrong for it.
  int _totalFor(CaptureMode mode) => expectedPhotoTotalFor(
        ref.read(captureConfigProvider),
        CaptureFlowVariant.withBottom,
        mode: mode,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.disabled,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('How do you want to capture?',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              "This sets how many photos you'll take. You can't change it once "
              'you start capturing.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            SelectableOptionCard<CaptureMode>(
              key: const Key('capture_mode_full'),
              title: 'Full Capture',
              subtitle: 'Highest quality. ~${_totalFor(CaptureMode.full)} '
                  'photos, guided auto-capture.',
              value: CaptureMode.full,
              selected: _selected,
              onSelect: (m) => setState(() => _selected = m),
            ),
            const SizedBox(height: AppSpacing.sm),
            SelectableOptionCard<CaptureMode>(
              key: const Key('capture_mode_meshy'),
              title: 'Maya AI Capture',
              subtitle: 'Faster. ${_totalFor(CaptureMode.meshy)} photos, you '
                  'tap to shoot.',
              value: CaptureMode.meshy,
              selected: _selected,
              onSelect: (m) => setState(() => _selected = m),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              key: const Key('capture_mode_continue'),
              onPressed: _confirm,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.mirageRed,
                minimumSize: const Size.fromHeight(52),
              ),
              child: const Text('Continue'),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}
