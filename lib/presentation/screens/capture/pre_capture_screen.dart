// lib/presentation/screens/capture/pre_capture_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/capture_flow_variant_provider.dart';
import '../../../application/capture/ledger/level_capture_ledger_registry_provider.dart';
import '../../../application/capture/progression/level_progression_provider.dart';
import '../../../application/capture/session/capture_session_store.dart';
import '../../../application/config/config_notifier.dart';
import '../../../data/local/active_session_box.dart';
import '../../../domain/capture/capture_flow_variant.dart';
import '../../../domain/entities/capture_config.dart';
import '../../../domain/entities/checklist_item.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_card.dart';
import '../../widgets/checklist_item_tile.dart';

/// Pre-capture checklist. The user acknowledges each required item — and
/// answers the "can you capture the bottom?" question that selects the capture
/// FLOW VARIANT (with_bottom 3-ring 16-16-16 vs without_bottom 2-ring 24-24) —
/// before the Start CTA navigates into the capture flow.
///
/// Item acknowledgment stays local widget state (transient); the flow-variant
/// answer is app state ([captureFlowVariantProvider]) persisted per project.
/// Once the project has ≥1 accepted photo the variant control LOCKS (changing
/// rings mid-capture would invalidate coverage) — Start Over unlocks it.
class PreCaptureScreen extends ConsumerStatefulWidget {
  const PreCaptureScreen({
    super.key,
    this.items = defaultChecklistItems,
    this.sessionBox,
    this.sessionStore,
  });

  /// The checklist content to render. Defaults to [defaultChecklistItems] so the
  /// router can build it `const`; injectable for tests / future remote content.
  final List<ChecklistItem> items;

  /// Active-session gateway (for the project id). Injectable for tests.
  final ActiveSessionBox? sessionBox;

  /// Saved-draft store backing the variant lock check. Injectable for tests.
  final CaptureSessionStore? sessionStore;

  @override
  ConsumerState<PreCaptureScreen> createState() => _PreCaptureScreenState();
}

class _PreCaptureScreenState extends ConsumerState<PreCaptureScreen> {
  final Set<String> _checkedIds = <String>{};

  /// Active project id, resolved best-effort on mount (null = unknown — the
  /// variant selection then stays in-memory only).
  String? _projectId;

  /// True once the project already has ≥1 accepted photo — the variant is then
  /// locked for this capture (see the lock rule in the class doc).
  bool _variantLocked = false;

  @override
  void initState() {
    super.initState();
    // Reach metric: fire exactly once per checklist screen entry. initState
    // runs once per State (not on rebuild/rotation), so re-entering the screen
    // (a fresh State) fires again — the intended per-entry semantics.
    // Fire-and-forget; a thrown analytics observer never reaches this call site.
    Analytics.logEvent(AnalyticsEvents.precaptureChecklistStarted);
    _resolveProjectContext();
  }

  /// Best-effort resolve of the project context: computes the lock, then
  /// presets the variant control — the project's PERSISTED choice when one
  /// exists, else the product default "No — bottom stays hidden" (persisted
  /// immediately, so capture entry / resume see the same answer even when the
  /// user never touches the control). Legacy exception: a project with
  /// accepted photos but NO stored variant predates the variant feature and
  /// stays on the 3-ring flow it was captured under. Never fatal — an
  /// unavailable store leaves the in-memory variant and the control unlocked.
  Future<void> _resolveProjectContext() async {
    String? projectId;
    try {
      final session = await (widget.sessionBox ?? ActiveSessionBox()).read();
      projectId = session?.projectId;
    } catch (_) {
      projectId = null;
    }
    if (!mounted) return;
    final notifier = ref.read(captureFlowVariantProvider.notifier);
    if (projectId == null) {
      // No project context: still preselect the product default (in memory
      // only — there is nowhere to persist it).
      notifier.restore(CaptureFlowVariant.withoutBottom);
      return;
    }
    _projectId = projectId;
    bool locked;
    try {
      locked = await projectHasAcceptedCaptures(
        projectId: projectId,
        registry: ref.read(levelCaptureLedgerRegistryProvider),
        sessionStore: widget.sessionStore,
      );
    } catch (_) {
      locked = false;
    }
    if (!mounted) return;
    CaptureFlowVariant? persisted;
    try {
      persisted = await ref
          .read(levelProgressionStoreProvider)
          .loadVariantOrNull(projectId);
    } catch (_) {
      persisted = null; // unreadable store → treat as "never chosen"
    }
    if (!mounted) return;
    if (persisted != null) {
      notifier.restore(persisted);
    } else if (locked) {
      notifier.restore(CaptureFlowVariant.withBottom);
    } else {
      await notifier.select(
        CaptureFlowVariant.withoutBottom,
        projectId: projectId,
      );
    }
    if (mounted && locked != _variantLocked) {
      setState(() => _variantLocked = locked);
    }
  }

  /// True once every required item has been acknowledged. With no required items
  /// (e.g. an all-optional or empty list) this is vacuously true, so the CTA is
  /// enabled rather than permanently stuck.
  bool get _allRequiredChecked => widget.items
      .where((item) => item.isRequired)
      .every((item) => _checkedIds.contains(item.id));

  void _setChecked(ChecklistItem item, bool checked) {
    setState(() {
      if (checked) {
        _checkedIds.add(item.id);
      } else {
        _checkedIds.remove(item.id);
      }
    });
  }

  /// Applies a variant selection: TRANSITION-ONLY analytics (a tap on the
  /// already-selected option changes nothing and logs nothing — mirrors the
  /// permission events' transition rule), live state update, and best-effort
  /// per-project persistence.
  void _selectVariant(CaptureFlowVariant variant) {
    if (_variantLocked) return;
    final current = ref.read(captureFlowVariantProvider);
    if (variant == current) return;
    Analytics.logEvent(AnalyticsEvents.bottomCaptureOptionSelected, {
      'flow_variant': variant.id,
      'device_type':
          defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    });
    ref
        .read(captureFlowVariantProvider.notifier)
        .select(variant, projectId: _projectId);
  }

  @override
  Widget build(BuildContext context) {
    final variant = ref.watch(captureFlowVariantProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: AppColors.textPrimary),
          onPressed: () => navigateBack(context),
        ),
        title: Text('Before you start', style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Text(
                'Confirm each item below for the best capture results.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            // Scrollable list keeps the CTA pinned and on-screen even on small
            // devices or in landscape.
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                children: [
                  for (var i = 0; i < widget.items.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.sm),
                    ChecklistItemTile(
                      item: widget.items[i],
                      isChecked: _checkedIds.contains(widget.items[i].id),
                      onToggle: (checked) =>
                          _setChecked(widget.items[i], checked),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  _BottomCaptureQuestion(
                    selected: variant,
                    locked: _variantLocked,
                    onSelect: _selectVariant,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: AppButton(
                label: 'Start Capture',
                // Null disables the button (greyed state) until every required
                // item is acknowledged.
                onPressed: _allRequiredChecked
                    ? () => context.goNamed(AppRouteNames.permissions)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "can you capture the bottom of the object?" question — a Yes/No pair of
/// selectable option cards whose answer selects the capture flow variant.
class _BottomCaptureQuestion extends ConsumerWidget {
  const _BottomCaptureQuestion({
    required this.selected,
    required this.locked,
    required this.onSelect,
  });

  final CaptureFlowVariant selected;
  final bool locked;
  final ValueChanged<CaptureFlowVariant> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Per-ring photo counts for the option copy, through the same
    // config × variant resolver the flow itself uses ('mid' is representative:
    // variant counts are uniform across rings).
    final config = ref.watch(captureConfigProvider);
    final withBottomN =
        effectiveSegmentsFor(config, CaptureFlowVariant.withBottom, 'mid');
    final withoutBottomN =
        effectiveSegmentsFor(config, CaptureFlowVariant.withoutBottom, 'mid');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Can you capture the bottom of the object?',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          locked
              ? 'Locked for this capture — start over to change it.'
              : 'Tilt or lift the object so its underside is photographable.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.sm),
        // "No" leads: it is the session default (preselected), so the common
        // path needs no interaction; "Yes" is the opt-in below it.
        _VariantOptionCard(
          title: 'No — bottom stays hidden',
          subtitle:
              "You'll capture 2 rings — eye and top level ($withoutBottomN photos each).",
          value: CaptureFlowVariant.withoutBottom,
          selected: selected,
          locked: locked,
          onSelect: onSelect,
        ),
        const SizedBox(height: AppSpacing.sm),
        _VariantOptionCard(
          title: 'Yes — capture the bottom',
          subtitle:
              "You'll capture 3 rings — eye, top and bottom level ($withBottomN photos each).",
          value: CaptureFlowVariant.withBottom,
          selected: selected,
          locked: locked,
          onSelect: onSelect,
        ),
      ],
    );
  }
}

/// One selectable Yes/No option card. Selection is shown by the accent border +
/// radio glyph; when [locked] the unselected option is muted and taps no-op.
class _VariantOptionCard extends StatelessWidget {
  const _VariantOptionCard({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.selected,
    required this.locked,
    required this.onSelect,
  });

  final String title;
  final String subtitle;
  final CaptureFlowVariant value;
  final CaptureFlowVariant selected;
  final bool locked;
  final ValueChanged<CaptureFlowVariant> onSelect;

  bool get _isSelected => value == selected;

  @override
  Widget build(BuildContext context) {
    final disabled = locked && !_isSelected;
    return Semantics(
      button: true,
      selected: _isSelected,
      enabled: !locked,
      label: title,
      hint: subtitle,
      child: ConstrainedBox(
        // Comfortable tap target (≥48dp) even with tight text scaling.
        constraints: const BoxConstraints(minHeight: 56),
        child: AppCard(
          onTap: locked ? null : () => onSelect(value),
          border: _isSelected
              ? const BorderSide(color: AppColors.mirageRed, width: 1.5)
              : null,
          child: Row(
            children: [
              Icon(
                _isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: _isSelected
                    ? AppColors.mirageRed
                    : (disabled ? AppColors.disabled : AppColors.textMuted),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: disabled ? AppColors.textMuted : null,
                          ),
                    ),
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
      ),
    );
  }
}
