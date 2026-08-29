// lib/presentation/screens/capture/level_a_intro_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/app_router.dart';
import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/capture/capture_flow_variant_provider.dart';
import '../../../application/config/config_notifier.dart';
import '../../../data/local/level_intro_box.dart';
import '../../../data/local/storage_providers.dart';
import '../../../domain/entities/capture_config.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import '../../widgets/capture_tip.dart';
import '../../widgets/eye_ring_intro_animation.dart';
import '../../../utils/platform_name.dart';

/// Stable persistence/analytics key for this intro.
const String _kIntroId = 'level_a';

/// Whether a user who checked "Don't show again" is auto-skipped straight to
/// capture on the next entry. The flag exists because some teams prefer the
/// safety rules to ALWAYS show; auto-skip only ever applies to users who
/// explicitly opted out (it never skips a first-time or returning user who did
/// not check the box). Flip to `false` to always show the intro.
const bool kLevelAIntroAutoSkipEnabled = true;

/// Screen 5A — Level A (Eye Ring) intro. Plays a looping instructional animation
/// of the eye-level ring motion, lists the capture rules, and hands off to the
/// Level A capture screen via a "Begin" CTA (route replacement so Back doesn't
/// return here mid-capture).
///
/// This screen only introduces the level — it does not own the camera/sensors.
class LevelAIntroScreen extends ConsumerStatefulWidget {
  const LevelAIntroScreen({
    super.key,
    this.nextRoute = AppRoutes.levelACapture,
    this.store,
    this.autoSkipEnabled = kLevelAIntroAutoSkipEnabled,
    this.onProceed,
  });

  /// Capture route the CTA replaces into. Overridable for tests.
  final String nextRoute;

  /// Persistence for the "seen"/"don't show again" flags. Defaults to the Hive
  /// store via [levelIntroStoreProvider]; injectable for tests.
  final LevelIntroStore? store;

  /// Gate for auto-skipping opted-out users (see [kLevelAIntroAutoSkipEnabled]).
  final bool autoSkipEnabled;

  /// Navigation override for tests. When null, uses `context.go(nextRoute)`.
  final VoidCallback? onProceed;

  @override
  ConsumerState<LevelAIntroScreen> createState() => _LevelAIntroScreenState();
}

class _LevelAIntroScreenState extends ConsumerState<LevelAIntroScreen> {
  /// Resolved once the auto-skip decision is made — gates the first paint to
  /// avoid flashing the intro before an auto-skip navigates away.
  bool _decided = false;
  bool _dontShowAgain = false;
  bool _navigating = false;
  bool _viewedLogged = false;
  String? _projectId;
  late final DateTime _enteredAt;

  LevelIntroStore get _store =>
      widget.store ?? ref.read(levelIntroStoreProvider);

  @override
  void initState() {
    super.initState();
    _enteredAt = DateTime.now();
    _init();
  }

  Future<void> _init() async {
    // Read the project context (active session) for analytics; absence is fine.
    try {
      final session = await ref.read(activeSessionBoxProvider).read();
      _projectId = session?.projectId;
    } catch (_) {
      _projectId = null;
    }

    final prefs = await _store.get(_kIntroId);
    if (!mounted) return;

    if (widget.autoSkipEnabled && prefs.dontShowAgain) {
      // Returning opted-out user: skip straight to capture without painting.
      _dontShowAgain = true;
      _dismiss('auto_skip');
      return;
    }

    setState(() => _decided = true);
    _logViewed();
  }

  /// Fires the "viewed" reach metric exactly once, after the auto-skip decision.
  /// Safe to read MediaQuery here: the widget is mounted and in the tree.
  void _logViewed() {
    if (_viewedLogged || !mounted) return;
    _viewedLogged = true;
    Analytics.logEvent(AnalyticsEvents.levelAIntroViewed, {
      'project_id': _projectId,
      'reduce_motion': MediaQuery.maybeOf(context)?.disableAnimations ?? false,
      'device_type': _deviceType,
    });
  }

  String get _deviceType => appPlatformName;

  /// Persists the seen/opt-out flags, emits the dismissed event, then navigates.
  /// Guarded so a rapid double-tap on Begin/Skip fires navigation only once.
  Future<void> _dismiss(String method) async {
    if (_navigating) return;
    _navigating = true;

    try {
      await _store.markSeen(_kIntroId, dontShowAgain: _dontShowAgain);
    } catch (_) {
      // Persistence is best-effort — never block the hand-off to capture.
    }

    Analytics.logEvent(AnalyticsEvents.levelAIntroDismissed, {
      'method': method,
      'dont_show_again': _dontShowAgain,
      'seconds_on_screen': DateTime.now().difference(_enteredAt).inSeconds,
    });

    if (!mounted) return;
    if (widget.onProceed != null) {
      widget.onProceed!();
    } else {
      context.go(widget.nextRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hold a plain Deep Black screen until the auto-skip decision resolves — no
    // content flash before a potential auto-skip.
    if (!_decided) {
      return const Scaffold(backgroundColor: AppColors.bgPrimary);
    }

    // The Eye Ring's effective count (config × flow variant) — the same
    // resolver the flow uses, so the rules copy names the real target.
    final segments = effectiveSegmentsFor(
      ref.watch(captureConfigProvider),
      ref.watch(captureFlowVariantProvider),
      'mid',
    );
    // Rules are sourced from the SHARED tip list (also used by the Help sheet),
    // so the copy never drifts between the intro and Help.
    final rules = levelACaptureTips
        .map((t) => t.formattedBody(segments))
        .toList(growable: false);

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
        title: Text('Level A: Eye Ring',
            style: Theme.of(context).textTheme.titleLarge),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  AppSpacing.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Focal animation.
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: EyeRingIntroAnimation(segments: segments),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Text(
                      'Walk a steady circle around the object at eye level. '
                      'Keep it centered and let each position settle.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    ...rules.map(_buildRule),
                  ],
                ),
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildRule(String rule) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.check_circle_outline,
                  color: AppColors.mirageRed, size: 20),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(rule, style: Theme.of(context).textTheme.bodyLarge),
            ),
          ],
        ),
      );

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // "Don't show again" — tappable row wrapping the checkbox.
          InkWell(
            onTap: () => setState(() => _dontShowAgain = !_dontShowAgain),
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Row(
                children: [
                  Checkbox(
                    value: _dontShowAgain,
                    onChanged: (v) =>
                        setState(() => _dontShowAgain = v ?? false),
                    activeColor: AppColors.mirageRed,
                  ),
                  Expanded(
                    child: Text(
                      "Don't show this again",
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Begin',
            onPressed: () => _dismiss('begin'),
          ),
          const SizedBox(height: AppSpacing.xs),
          TextButton(
            onPressed: () => _dismiss('skip'),
            child: Text(
              'Skip',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
