// lib/presentation/screens/capture/pre_capture_screen.dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/capture_flow_variant_provider.dart';
import '../../../application/capture/capture_mode_provider.dart';
import '../../../application/capture/ledger/level_capture_ledger_registry_provider.dart';
import '../../../application/capture/progression/level_progression_provider.dart';
import '../../../application/capture/session/capture_session_store.dart';
import '../../../application/config/config_notifier.dart';
import '../../../data/local/active_session_box.dart';
import '../../../domain/capture/capture_flow_variant.dart';
import '../../../domain/capture/capture_mode.dart';
import '../../../domain/entities/capture_config.dart';
import '../../../domain/entities/checklist_item.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/checklist_item_tile.dart';
import '../../widgets/selectable_option_card.dart';
import '../../../utils/platform_name.dart';

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
    // Bind the in-memory capture ledgers to THIS run's project. They are
    // app-scoped and nothing else bounds their lifetime, so a second capture
    // would otherwise review the previous object's frames alongside its own —
    // and inherit its variant lock below. Re-binding the same project is a
    // no-op, so a resume keeps the pass it is resuming.
    ref.read(levelCaptureLedgerRegistryProvider).bindProject(projectId);
    // Restore the project's CAPTURE MODE before anything reads a segment count.
    // This is the resume path's only chance to learn it: a user reopening a
    // project from the list never passes through the creation sheet, and every
    // expected count downstream (gates, ring sizes, the upload's file count)
    // depends on getting it right. Absent → full, the pre-Meshy behaviour.
    try {
      await ref.read(captureModeProvider.notifier).loadFor(projectId);
    } catch (_) {
      // Unreadable store → the provider keeps its default (full).
    }
    if (!mounted) return;
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
      'device_type': appPlatformName,
    });
    ref
        .read(captureFlowVariantProvider.notifier)
        .select(variant, projectId: _projectId);
  }

  @override
  Widget build(BuildContext context) {
    final variant = ref.watch(captureFlowVariantProvider);
    // Meshy is variant-independent (ONE ring of 6, no underside) — the bottom
    // question is meaningless there, so it is replaced with a single explainer.
    final mode = ref.watch(captureModeProvider);
    return Scaffold(
      backgroundColor: AppColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              color: AppColors.textPrimary),
          onPressed: () => navigateBack(context),
        ),
        title: Text('Before you start',
            style: Theme.of(context).textTheme.titleLarge),
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
                  // Honest, visible notice rather than a mode that quietly
                  // produces unusable models: browser capture is a degraded
                  // tier for photogrammetry (see the README web section).
                  if (kIsWeb) ...[
                    _WebCaptureQualityNotice(mode: mode),
                    const SizedBox(height: AppSpacing.md),
                  ],
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
                  if (mode == CaptureMode.meshy)
                    const _MeshyCaptureNote()
                  else
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
    // config × mode × variant resolver the flow itself uses.
    //
    // These are read PER RING and rendered per ring. They used to be read once
    // from 'mid' and described as "N photos each", on the stated grounds that
    // variant counts are uniform across rings — true of full mode, and FALSE in
    // Meshy mode (6 eye / 2 top / 2 bottom). A single representative number
    // there would have understated the eye ring or trebled the other two.
    final config = ref.watch(captureConfigProvider);
    final mode = ref.watch(captureModeProvider);
    String ringCopy(CaptureFlowVariant variant) {
      const labelForBand = {'mid': 'eye', 'high': 'top', 'low': 'bottom'};
      final parts = [
        for (final bandId in variant.bandIds)
          '${effectiveSegmentsFor(config, variant, bandId, mode: mode)} '
              '${labelForBand[bandId] ?? bandId}',
      ];
      return parts.join(' + ');
    }

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
        SelectableOptionCard<CaptureFlowVariant>(
          title: 'No — bottom stays hidden',
          subtitle: "You'll capture 2 rings — "
              '${ringCopy(CaptureFlowVariant.withoutBottom)} photos.',
          value: CaptureFlowVariant.withoutBottom,
          selected: selected,
          locked: locked,
          onSelect: onSelect,
        ),
        const SizedBox(height: AppSpacing.sm),
        SelectableOptionCard<CaptureFlowVariant>(
          title: 'Yes — capture the bottom',
          subtitle: "You'll capture 3 rings — "
              '${ringCopy(CaptureFlowVariant.withBottom)} photos.',
          value: CaptureFlowVariant.withBottom,
          selected: selected,
          locked: locked,
          onSelect: onSelect,
        ),
      ],
    );
  }
}

/// The Meshy-mode explainer that REPLACES the bottom question: Meshy is one ring
/// of 6, variant-independent, with no underside — so there is no Yes/No choice to
/// make, only a description of the single sweep.
class _MeshyCaptureNote extends StatelessWidget {
  const _MeshyCaptureNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'One ring — 6 photos.',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Circle the object once, keeping the camera between eye level and '
          'looking down at its top. No underside needed.',
          style:
              theme.textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// Web-only advisory shown before capture starts.
///
/// A browser gives `getUserMedia` frames with no exposure lock, no focus lock,
/// no RAW and a lower negotiated resolution than the native ImageCapture
/// pipeline, and it cannot upload in the background. For Maya Capture (6 manual
/// shots) that is a fair trade. For Full Capture — 48 photos feeding
/// photogrammetry — it is a real quality reduction, and saying so here is the
/// alternative to a user discovering it from a bad model.
class _WebCaptureQualityNotice extends StatelessWidget {
  const _WebCaptureQualityNotice({required this.mode});

  final CaptureMode mode;

  @override
  Widget build(BuildContext context) {
    final full = mode == CaptureMode.full;
    return Container(
      key: const Key('web_capture_quality_notice'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              full
                  ? 'You’re capturing in a browser. Photo quality is lower than '
                      'the app (no exposure or focus lock, reduced resolution), '
                      'so models built from a browser capture may be less '
                      'detailed. Keep this tab open — uploads stop if you '
                      'close it.'
                  : 'You’re capturing in a browser. Keep this tab open — '
                      'uploads stop if you close it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
