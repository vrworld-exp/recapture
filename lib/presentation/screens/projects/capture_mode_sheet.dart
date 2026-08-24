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
//
// ── THE THIRD OPTION IS NOT A CaptureMode ───────────────────────────────────
// "Upload photos" resolves to [UploadChoice], NOT to a new [CaptureMode] value.
// CaptureMode is the CAPTURE vocabulary: it is persisted via
// `captureModeProvider.persistFor`, read by the pre-capture and capture
// screens, and sent to the server as a capture mode. Adding `upload` to it
// would put a fake value into every one of those. The sheet therefore resolves
// to a [ProjectCreationChoice], and only a [CaptureChoice] touches the provider.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/auth/user_role_notifier.dart';
import '../../../application/capture/capture_mode_provider.dart';
import '../../../application/config/config_notifier.dart';
import '../../../data/datasources/project_photo_picker.dart';
import '../../../domain/capture/capture_mode.dart';
import '../../../domain/capture/capture_flow_variant.dart';
import '../../../domain/entities/capture_config.dart';
import '../../widgets/selectable_option_card.dart';

/// Whether the browser can upload a photo set yet.
///
/// The presigned part PUTs go DIRECT to S3, and the raw-captures bucket
/// deliberately serves no CORS policy (docs/aws-storage-and-cdn.md) — so on web
/// every PUT fails preflight until that policy is applied. Native is unaffected
/// and ships now; flipping this ONE constant is what switches web on, and the
/// policy must be recorded in AGENTS.md and docs/aws-storage-and-cdn.md when it
/// lands (it reverses a documented decision).
///
/// Until then the card renders DISABLED WITH A VISIBLE REASON — never
/// enabled-and-broken.
const bool kPhotoUploadEnabledOnWeb = false;

/// What the user chose in the sheet. A sealed result rather than a widened
/// [CaptureMode] — see the file header.
sealed class ProjectCreationChoice {
  const ProjectCreationChoice();
}

/// Run the guided capture flow in [mode].
class CaptureChoice extends ProjectCreationChoice {
  const CaptureChoice(this.mode);
  final CaptureMode mode;
}

/// Upload a hand-picked photo set instead of capturing. Staff-only.
class UploadChoice extends ProjectCreationChoice {
  const UploadChoice();
}

/// Asks how the project photos will be produced. Resolves to the choice, or
/// null when the user dismissed the sheet without choosing (scrim tap / back /
/// drag) — callers MUST treat null as "do nothing", never as the default.
Future<ProjectCreationChoice?> showCaptureModeSheet(BuildContext context) {
  return showModalBottomSheet<ProjectCreationChoice>(
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

/// The sheet internal selection vocabulary: the two capture modes plus the
/// upload option. Local to this file so [CaptureMode] stays uncontaminated.
enum _Option { full, meshy, upload }

class _CaptureModeSheetState extends ConsumerState<_CaptureModeSheet> {
  // Full Capture leads and is preselected: it is the default and the behaviour
  // that already exists, so the common path needs no interaction.
  _Option _selected = _Option.full;

  /// The upload card is offered only to staff, and on web only once the
  /// raw-bucket CORS policy is applied. `isStaffProvider` is fail-closed on any
  /// role-fetch failure, and the backend re-checks the role on EVERY request —
  /// this gate is UX, never the security boundary.
  bool get _uploadVisible => ref.watch(isStaffProvider);

  bool get _uploadEnabled => !kIsWeb || kPhotoUploadEnabledOnWeb;

  Future<void> _confirm() async {
    if (_selected == _Option.upload) {
      // Deliberately does NOT touch captureModeProvider: an upload project
      // never enters the capture flow, and a persisted mode would be read back
      // by screens this project never visits.
      Navigator.of(context).pop(const UploadChoice());
      return;
    }
    final mode = _selected == _Option.meshy ? CaptureMode.meshy : CaptureMode.full;
    // Persisting has to wait for a project id, which does not exist yet — the
    // provider holds the choice in memory and CreateProjectScreen writes it
    // through the moment the id arrives.
    await ref.read(captureModeProvider.notifier).select(mode);
    if (mounted) Navigator.of(context).pop(CaptureChoice(mode));
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
            Text(
              _uploadVisible
                  ? 'How do you want to add photos?'
                  : 'How do you want to capture?',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              "This sets how many photos you'll take. You can't change it once "
              'you start capturing.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            SelectableOptionCard<_Option>(
              key: const Key('capture_mode_full'),
              title: 'Full Capture',
              subtitle: 'Highest quality. ~${_totalFor(CaptureMode.full)} '
                  'photos, guided auto-capture.',
              value: _Option.full,
              selected: _selected,
              onSelect: (o) => setState(() => _selected = o),
            ),
            const SizedBox(height: AppSpacing.sm),
            SelectableOptionCard<_Option>(
              key: const Key('capture_mode_meshy'),
              title: 'Maya AI Capture',
              subtitle: 'Faster. ${_totalFor(CaptureMode.meshy)} photos, you '
                  'tap to shoot.',
              value: _Option.meshy,
              selected: _selected,
              onSelect: (o) => setState(() => _selected = o),
            ),
            if (_uploadVisible) ...[
              const SizedBox(height: AppSpacing.sm),
              SelectableOptionCard<_Option>(
                key: const Key('capture_mode_upload'),
                title: 'Upload photos',
                subtitle: _uploadEnabled
                    ? 'Up to $kProjectPhotoMaxCount photos from your gallery.'
                    : "Uploading from a browser isn't available yet.",
                value: _Option.upload,
                selected: _selected,
                // `locked` mutes the card and makes taps a no-op, which is
                // exactly "disabled with a visible reason" — the subtitle above
                // says WHY rather than leaving a dead card.
                locked: !_uploadEnabled,
                onSelect: (o) => setState(() => _selected = o),
              ),
            ],
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
