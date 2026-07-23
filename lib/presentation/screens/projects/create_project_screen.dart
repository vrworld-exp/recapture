// lib/presentation/screens/projects/create_project_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/capture_shape_mode_provider.dart';
import '../../../application/projects/projects_notifier.dart';
import '../../../domain/capture/capture_shape_mode.dart';
import '../../../domain/entities/create_project_options.dart';
import '../../../domain/entities/project.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/offline_retry_modal.dart';

/// Create Project form. The user names the project, picks an object size and a
/// capture mode, then submits to create the project and route into the
/// pre-capture checklist.
///
/// Creation goes through [projectsProvider] so the new project lands in the
/// shared list state (it appears on return to the Projects Hub without a
/// refetch). Form input is local; creation happens only on an explicit CTA tap.
class CreateProjectScreen extends ConsumerStatefulWidget {
  const CreateProjectScreen({super.key});

  @override
  ConsumerState<CreateProjectScreen> createState() =>
      _CreateProjectScreenState();
}

class _CreateProjectScreenState extends ConsumerState<CreateProjectScreen> {
  final TextEditingController _nameController = TextEditingController();

  ObjectSize? _selectedSize;
  CaptureMode? _selectedMode;

  /// The capture SHAPE (full photogrammetry vs the short Meshy single-ring). This
  /// is the PROVISIONAL Meshy entry point: a real Meshy project would get its own
  /// creation flow, but this toggle is enough to drive the whole capture + upload
  /// path end-to-end. Defaults to full (the common path). Distinct from
  /// [_selectedMode], which is the auto-capture DRIVE (guided/manual).
  CaptureShapeMode _selectedShape = CaptureShapeMode.full;

  bool _creating = false;
  String? _nameError;

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// CTA enables only when the name is non-blank, a size and a mode are both
  /// chosen, and no create request is in flight.
  bool get _canSubmit =>
      _nameController.text.trim().isNotEmpty &&
      _selectedSize != null &&
      _selectedMode != null &&
      !_creating;

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
      'capture_shape': _selectedShape.id,
      'name_length': name.length,
      'device_type': _deviceType,
    });

    if (created != null) {
      // Carry the capture SHAPE into the flow: set the live provider + persist it
      // per project so the whole capture + upload path runs in the chosen shape
      // (best-effort — an unavailable store never blocks entry).
      await ref
          .read(captureShapeModeProvider.notifier)
          .select(_selectedShape, projectId: created!.id);
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

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
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
                    const SizedBox(height: AppSpacing.xxl),
                    const _SectionLabel('CAPTURE TYPE'),
                    const SizedBox(height: AppSpacing.md),
                    _ShapeCard(
                      title: 'Full detail',
                      subtitle:
                          'Walk all rings for a photogrammetry-grade model (48 photos).',
                      value: CaptureShapeMode.full,
                      selected: _selectedShape,
                      enabled: !_creating,
                      onSelect: (v) => setState(() => _selectedShape = v),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _ShapeCard(
                      title: 'Quick scan (Meshy AI)',
                      subtitle:
                          'One circle, 6 photos — fastest path to an AI 3D model.',
                      value: CaptureShapeMode.meshy,
                      selected: _selectedShape,
                      enabled: !_creating,
                      onSelect: (v) => setState(() => _selectedShape = v),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: AppButton(
                label: 'Create & Continue',
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

/// Single-select capture-SHAPE card (Full detail / Quick scan). Selection shows
/// via the accent border + radio glyph; mirrors the pre-capture variant cards.
class _ShapeCard extends StatelessWidget {
  const _ShapeCard({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  final String title;
  final String subtitle;
  final CaptureShapeMode value;
  final CaptureShapeMode selected;
  final bool enabled;
  final ValueChanged<CaptureShapeMode> onSelect;

  bool get _isSelected => value == selected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: _isSelected,
      enabled: enabled,
      label: title,
      hint: subtitle,
      child: AppCard(
        onTap: enabled ? () => onSelect(value) : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        padding: const EdgeInsets.all(AppSpacing.lg),
        border: _isSelected
            ? const BorderSide(color: AppColors.mirageRed, width: 1.5)
            : null,
        child: Row(
          children: [
            Icon(
              _isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: _isSelected ? AppColors.mirageRed : AppColors.textMuted,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
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
