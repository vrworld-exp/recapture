// lib/presentation/screens/projects/create_project_screen.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/capture_mode_provider.dart';
import '../../../application/capture/progression/level_progression_provider.dart';
import '../../../application/projects/project_photos_notifier.dart';
import '../../../application/projects/projects_notifier.dart';
import '../../../data/datasources/project_photo_picker.dart';
import '../../../data/local/storage_providers.dart';
import '../../../domain/entities/active_session.dart';
import '../../../domain/capture/capture_mode.dart' as capture_flow;
import '../../../domain/entities/create_project_options.dart';
import '../../../domain/entities/project.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/offline_retry_modal.dart';
import 'capture_mode_sheet.dart';
import 'photo_upload_progress_screen.dart';

/// Create Project form, in one of TWO variants picked by the sheet that opened
/// it (see [ProjectCreationChoice]).
///
/// CAPTURE (the default, unchanged): name, object size, capture mode → create,
/// persist the capture context, route into the pre-capture checklist. Creation
/// goes through [projectsProvider] so the new project lands in the shared list
/// state (it appears on return to the Projects Hub without a refetch).
///
/// UPLOAD: name and a PHOTOS section. OBJECT SIZE and CAPTURE MODE are HIDDEN —
/// they are capture concepts (object size drives camera-distance guidance an
/// uploaded set never receives; capture mode drives a flow that never runs),
/// and writing a placeholder MEDIUM/GUIDED would be a lie that later reads act
/// on. The server refuses either field on an upload project for the same
/// reason. The CTA reads "Upload N photos" and PUSHES
/// [PhotoUploadProgressScreen], which is where the transfer actually runs.
///
/// This form does NOT await the upload. It used to, behind a spinner on its own
/// CTA — minutes of nothing to look at for a 48-photo set. The push happens
/// immediately and the wait gets a screen of its own, with a row per photo.
///
/// Form input is local; creation happens only on an explicit CTA tap.
class CreateProjectScreen extends ConsumerStatefulWidget {
  const CreateProjectScreen({
    super.key,
    this.choice = const CaptureChoice(capture_flow.CaptureMode.full),
  });

  /// How this project will get its photos. Defaults to a capture so a cold
  /// deep-link to `/projects/new` (which carries no `extra`) behaves exactly as
  /// it always has.
  final ProjectCreationChoice choice;

  @override
  ConsumerState<CreateProjectScreen> createState() =>
      _CreateProjectScreenState();
}

class _CreateProjectScreenState extends ConsumerState<CreateProjectScreen> {
  final TextEditingController _nameController = TextEditingController();

  ObjectSize? _selectedSize;
  CaptureMode? _selectedMode;
  bool _creating = false;
  String? _nameError;

  /// True when this form is the UPLOAD variant. Read once from the route
  /// argument — the two variants never swap at runtime.
  bool get _isUpload => widget.choice is UploadChoice;

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// CTA enables only when the name is non-blank and, per variant:
  ///  • capture — a size and a mode are both chosen;
  ///  • upload  — at least [kProjectPhotoMinCount] photos are picked.
  /// Always requires no request in flight.
  bool get _canSubmit {
    if (_creating || _nameController.text.trim().isEmpty) return false;
    if (_isUpload) {
      return ref.read(projectPhotosProvider).picked.length >= kProjectPhotoMinCount;
    }
    return _selectedSize != null && _selectedMode != null;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // ── Submit ───────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (_creating) return; // in-flight guard — double-tap fires once
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = "Project name can't be empty");
      return;
    }
    if (_isUpload) {
      setState(() {
        _creating = true;
        _nameError = null;
      });
      await _submitUpload(name);
      return;
    }
    final size = _selectedSize;
    final mode = _selectedMode;
    if (size == null || mode == null) return; // CTA already guards this

    setState(() {
      _creating = true;
      _nameError = null;
    });

    Project? created;
    var result = 'success';
    try {
      created = await ref.read(projectsProvider.notifier).create(
            name: name,
            size: size,
            mode: mode,
          );
    } catch (_) {
      result = 'network_error';
      if (!mounted) return;
      // Offline modal retries the create; it only returns once it succeeds, so
      // we capture the new project from inside the retry closure. Form input is
      // untouched, so it is fully preserved across the failure.
      await showOfflineRetryModal(
        context,
        source: OfflineSource.projectsHub,
        onRetry: () async {
          created = await ref.read(projectsProvider.notifier).create(
                name: name,
                size: size,
                mode: mode,
              );
        },
      );
    }

    if (!mounted) return;
    // Log the initial service-call resolution (success | network_error).
    Analytics.logEvent('create_project_submitted', {
      'result': result,
      'object_size': size.apiValue,
      'capture_mode': mode.apiValue,
      'name_length': name.length,
      'device_type': _deviceType,
    });

    if (created != null) {
      // Persist the capture mode NOW — this is the first moment a project id
      // exists to key it on. The sheet's selection was in-memory only until
      // here (there was nothing to attach it to), and the mode has to be a
      // property of the PROJECT: a user resuming from the list never passes
      // through the sheet again. Offline, the id is a temp one and the outbox
      // migrates the record when the server id arrives.
      await ref
          .read(captureModeProvider.notifier)
          .persistFor(created!.id);

      // Persist the object SIZE against the project for the same reason — a
      // resumed session never revisits this form, and the server Project DTO
      // does not carry the size back. The upload flow reads it so POST /jobs
      // declares the size the project was created with (a mismatch is a
      // SIZE_MISMATCH rejection). Best-effort; never blocks the flow.
      try {
        await ref
            .read(levelProgressionStoreProvider)
            .saveObjectSize(created!.id, size);
      } catch (_) {/* durability is best-effort; see saveObjectSize */}

      // Establish this project as the resumable ACTIVE SESSION. This is the ONE
      // place the server project id is handed to the capture→upload route: the
      // pre-capture, capture and upload screens all resolve the current project
      // from ActiveSessionBox (not the route arg), so without this the upload
      // flow could not tell which project the photos belong to and would create
      // a SECOND one. Offline this records the temp id; the capture runs under
      // it and the upload flow's fallback create path handles a non-server id.
      // Best-effort — a failed write degrades to the old behaviour, never a crash.
      try {
        await ref.read(activeSessionBoxProvider).save(
              ActiveSession(
                projectId: created!.id,
                updatedAt: DateTime.now(),
              ),
            );
      } catch (_) {/* best-effort; capture falls back to no active session */}
      if (!mounted) return;
      // Route replacement (goNamed): back must not return to this half-finished
      // form. TODO(precapture): PreCaptureScreen does not yet consume the
      // project id; pass-through via `extra` until its signature accepts it.
      context.goNamed(AppRouteNames.preCapture, extra: created!.id);
    } else {
      // Modal was a no-op (already showing) — re-enable the form.
      setState(() => _creating = false);
    }
  }

  /// The UPLOAD submit path: hand off to [PhotoUploadProgressScreen] and let
  /// the transfer be that screen's whole job.
  ///
  /// Deliberately does NOT run the three capture-context writes the capture
  /// branch does — `captureModeProvider.persistFor`, `saveObjectSize`, and the
  /// [ActiveSession] write. All three exist purely to hand the CAPTURE flow its
  /// context; an upload project never enters that flow, and a stale
  /// ActiveSession would send a later resume into a capture screen for a
  /// project that has no rings.
  ///
  /// The project itself is created INSIDE the flow (online-only, straight to
  /// the repository — never through the offline outbox, which would hand back a
  /// temporary local id the photo session cannot use).
  ///
  /// A PUSH, not a `go()` replacement: [projectPhotosProvider] is autoDispose
  /// and holds the picked set, so this form has to stay mounted underneath as
  /// its listener for the whole transfer. It is also what makes "Back to the
  /// photo list" work after a failure — the picked set is still right here.
  Future<void> _submitUpload(String name) async {
    final photoCount = ref.read(projectPhotosProvider).picked.length;
    Analytics.logEvent('create_project_submitted', {
      // The transfer's own outcome belongs to the progress screen; this event
      // records that the artist committed to it, and with how many photos.
      'result': 'started',
      'source': 'upload',
      'photo_count': photoCount,
      'name_length': name.length,
      'device_type': _deviceType,
    });

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoUploadProgressScreen(projectName: name),
      ),
    );
    // Reached only when the artist came BACK — a failure they chose not to
    // retry, or a stopped transfer. Success leaves via goNamed(projects) and
    // never returns here. The form is intact, so another attempt costs nothing.
    if (mounted) setState(() => _creating = false);
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  String get _uploadCtaLabel {
    final count = ref.watch(projectPhotosProvider).picked.length;
    if (count == 0) return 'Upload';
    return 'Upload $count photo${count == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild the CTA and the photo strip as the picked set changes.
    ref.watch(projectPhotosProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: AppColors.textPrimary),
          onPressed: () => navigateBack(context),
        ),
        title: Text('New Project', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionLabel('PROJECT NAME'),
                    const SizedBox(height: AppSpacing.sm),
                    AppTextField(
                      label: 'Project name',
                      hint: 'e.g. Wooden statue',
                      controller: _nameController,
                      errorText: _nameError,
                      enabled: !_creating,
                      maxLength: kMaxProjectNameLength,
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setState(() {
                        if (_nameError != null) _nameError = null;
                      }),
                    ),
                    if (_isUpload) ...[
                      const SizedBox(height: AppSpacing.xxl),
                      const _SectionLabel('PHOTOS'),
                      const SizedBox(height: AppSpacing.md),
                      _PhotoPickerSection(enabled: !_creating),
                    ] else ...[
                      // OBJECT SIZE and CAPTURE MODE are CAPTURE concepts —
                      // hidden on the upload variant, never written as a
                      // placeholder. See the class doc.
                      const SizedBox(height: AppSpacing.xxl),
                      const _SectionLabel('OBJECT SIZE'),
                      const SizedBox(height: AppSpacing.md),
                      _SizeChipRow(
                        selected: _selectedSize,
                        onSelected: _creating
                            ? null
                            : (size) => setState(() => _selectedSize = size),
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      const _SectionLabel('CAPTURE MODE'),
                      const SizedBox(height: AppSpacing.md),
                      for (final option in kModeOptions) ...[
                        _ModeCard(
                          option: option,
                          selected: _selectedMode == option.value,
                          onTap: _creating
                              ? null
                              : () =>
                                  setState(() => _selectedMode = option.value),
                        ),
                        if (option != kModeOptions.last)
                          const SizedBox(height: AppSpacing.sm),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: AppButton(
                key: const Key('create_project_cta'),
                // Naming the count is the point: the artist sees exactly what
                // is about to be sent before a minute of uploading starts.
                label: _isUpload ? _uploadCtaLabel : 'Create & Continue',
                isLoading: _creating,
                onPressed: _canSubmit ? _submit : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The upload variant PHOTOS section: an "Add photos" affordance, the picked
/// thumbnails, and a per-file explanation for anything that was skipped.
///
/// Every bound it enforces is enforced AGAIN by the server; checking here means
/// the artist finds out at pick time rather than after a minute of uploading.
class _PhotoPickerSection extends ConsumerWidget {
  const _PhotoPickerSection({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(projectPhotosProvider);
    final notifier = ref.read(projectPhotosProvider.notifier);
    final theme = Theme.of(context);
    final remaining = kProjectPhotoMaxCount - state.picked.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppButton.secondary(
          key: const Key('create_project_add_photos'),
          label: state.picked.isEmpty ? 'Add photos' : 'Add more photos',
          icon: Icons.add_photo_alternate_outlined,
          isFullWidth: false,
          isLoading: state.phase == PhotoUploadPhase.picking,
          onPressed:
              enabled && remaining > 0 ? () => notifier.pickPhotos() : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          state.picked.isEmpty
              ? 'Pick $kProjectPhotoMinCount to $kProjectPhotoMaxCount photos of the object, '
                  'all the way around it.'
              : '${state.picked.length} of $kProjectPhotoMaxCount selected.',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        if (state.picked.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: state.picked.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
              itemBuilder: (_, i) => _PickedThumb(
                index: i,
                onRemove: enabled ? () => notifier.removePicked(i) : null,
              ),
            ),
          ),
        ],
        // A skipped file is NEVER silent — each one says why.
        for (final rejected in state.rejected) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${rejected.name} — ${_reasonText(rejected.reason)}',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.mirageRed),
          ),
        ],
      ],
    );
  }

  static String _reasonText(PhotoRejectionReason reason) => switch (reason) {
        PhotoRejectionReason.unsupportedType => 'not a JPEG, PNG or WebP',
        PhotoRejectionReason.tooLarge => 'larger than 15 MB',
        PhotoRejectionReason.unreadable => 'could not be read',
        PhotoRejectionReason.overCount =>
          'over the $kProjectPhotoMaxCount photo limit',
      };
}

/// One picked photo in the strip. A numbered placeholder rather than a decoded
/// preview: decoding 48 full-resolution photos to paint 72px squares is how
/// this form would stutter, and the real thumbnails arrive from the server
/// (already presigned) on the photos screen.
class _PickedThumb extends StatelessWidget {
  const _PickedThumb({required this.index, required this.onRemove});

  final int index;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          alignment: Alignment.center,
          child: Text(
            '${index + 1}',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
        ),
        if (onRemove != null)
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: AppColors.scrim,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: AppColors.textSecondary,
            letterSpacing: 0.08,
          ),
    );
  }
}

/// Single-select object-size chips with the selected option's helper beneath.
class _SizeChipRow extends StatelessWidget {
  const _SizeChipRow({required this.selected, required this.onSelected});

  final ObjectSize? selected;

  /// Null disables selection (e.g. while a create is in flight).
  final ValueChanged<ObjectSize>? onSelected;

  @override
  Widget build(BuildContext context) {
    final selectedHelper = selected == null
        ? 'Size helps us guide camera distance.'
        : kSizeOptions.firstWhere((o) => o.value == selected).helper;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final option in kSizeOptions)
              _SizeChip(
                label: option.label,
                selected: selected == option.value,
                onTap: onSelected == null
                    ? null
                    : () => onSelected!(option.value),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          selectedHelper,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

class _SizeChip extends StatelessWidget {
  const _SizeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: selected ? AppColors.mirageRed : AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: selected
              ? null
              : Border.all(
                  color: AppColors.disabled.withValues(alpha: 0.5),
                  width: 0.5,
                ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: selected ? Colors.white : AppColors.textSecondary,
              ),
        ),
      ),
    );
  }
}

/// Single-select capture-mode card with helper copy and a recommended badge.
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final ModeOption option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(option.label,
                        style: Theme.of(context).textTheme.headlineMedium),
                    if (option.recommended) ...[
                      const SizedBox(width: AppSpacing.sm),
                      const _RecommendedBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(option.helper,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // Radio-style selection indicator.
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? AppColors.mirageRed : AppColors.disabled,
                width: 2,
              ),
            ),
            child: selected
                ? const Center(
                    child: CircleAvatar(
                      radius: 4,
                      backgroundColor: AppColors.mirageRed,
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

class _RecommendedBadge extends StatelessWidget {
  const _RecommendedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.royalGold.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(
          color: AppColors.royalGold.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: Text(
        'Recommended',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppColors.royalGold,
              height: 1.0,
            ),
      ),
    );
  }
}
