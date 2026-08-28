// lib/presentation/screens/capture/level_intro_scaffold.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes/flow_back.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../data/local/level_intro_box.dart';
import '../../../data/local/storage_providers.dart';
import '../../../utils/analytics.dart';
import '../../widgets/app_button.dart';
import 'level_intro_content.dart';

/// The SHARED guided-capture intro (Screens 5B & 5C). One widget, parameterized
/// by [LevelIntroContent]: it plays the per-level illustration, lists the rules,
/// shows the A→B→C progress, and hands off to capture via a "Begin" CTA (route
/// replacement so Back doesn't return here mid-capture). Levels B and C are the
/// SAME widget with different [content] — there is no per-level layout.
///
/// It only introduces the level — it does not own the camera/sensors and never
/// creates a capture session (the active session persists across the flow).
/// Structurally mirrors the Level A intro.
class LevelIntroScaffold extends ConsumerStatefulWidget {
  const LevelIntroScaffold({
    super.key,
    required this.content,
    this.nextRoute,
    this.store,
    this.autoSkipEnabled = true,
    this.onProceed,
  });

  /// All per-level display copy + illustration + analytics names.
  final LevelIntroContent content;

  /// Capture route the CTA replaces into. Defaults to
  /// [LevelIntroContent.defaultNextRoute]. Overridable for tests.
  final String? nextRoute;

  /// Persistence for the "seen"/"don't show again" flags. Defaults to the Hive
  /// store via [levelIntroStoreProvider]; injectable for tests.
  final LevelIntroStore? store;

  /// Gate for auto-skipping opted-out users.
  final bool autoSkipEnabled;

  /// Navigation override for tests. When null, uses `context.go(nextRoute)`.
  final VoidCallback? onProceed;

  @override
  ConsumerState<LevelIntroScaffold> createState() => _LevelIntroScaffoldState();
}

class _LevelIntroScaffoldState extends ConsumerState<LevelIntroScaffold> {
  /// Resolved once the auto-skip decision is made — gates the first paint to
  /// avoid flashing the intro before an auto-skip navigates away.
  bool _decided = false;
  bool _dontShowAgain = false;
  bool _navigating = false;
  bool _viewedLogged = false;
  String? _projectId;
  late final DateTime _enteredAt;

  LevelIntroContent get _content => widget.content;
  String get _nextRoute => widget.nextRoute ?? _content.defaultNextRoute;

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

    final prefs = await _store.get(_content.introId);
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
    Analytics.logEvent(_content.viewedEvent, {
      'project_id': _projectId,
      'reduce_motion': MediaQuery.maybeOf(context)?.disableAnimations ?? false,
      'device_type': _deviceType,
    });
  }

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// Persists the seen/opt-out flags, emits the dismissed event, then navigates.
  /// Guarded so a rapid double-tap on Begin/Skip fires navigation only once.
  Future<void> _dismiss(String method) async {
    if (_navigating) return;
    _navigating = true;

    try {
      await _store.markSeen(_content.introId, dontShowAgain: _dontShowAgain);
    } catch (_) {
      // Persistence is best-effort — never block the hand-off to capture.
    }

    Analytics.logEvent(_content.dismissedEvent, {
      'method': method,
      'dont_show_again': _dontShowAgain,
      'seconds_on_screen': DateTime.now().difference(_enteredAt).inSeconds,
    });

    if (!mounted) return;
    if (widget.onProceed != null) {
      widget.onProceed!();
    } else {
      context.go(_nextRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hold a plain Deep Black screen until the auto-skip decision resolves — no
    // content flash before a potential auto-skip.
    if (!_decided) {
      return const Scaffold(backgroundColor: AppColors.bgPrimary);
    }

    final theme = Theme.of(context);
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
        title: Text(_content.appBarTitle, style: theme.textTheme.titleLarge),
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
                    // Guided-sequence progress — current level highlighted.
                    _LevelProgressIndicator(activeLevel: _content.activeLevel),
                    const SizedBox(height: AppSpacing.lg),
                    // Focal (placeholder) illustration of the phone position.
                    Center(
                      child: _LevelIllustration(
                        icon: _content.illustrationIcon,
                        semanticLabel: _content.illustrationSemanticLabel,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    // Primary instruction.
                    Text(_content.headline, style: theme.textTheme.titleLarge),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _content.supportingLine,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    ..._content.rules.map(_buildRule),
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

/// Compact guided-sequence progress: the A → B → C levels with [activeLevel]
/// highlighted (and earlier levels marked done). Display-only; built from theme
/// tokens. There is no shared level-sequence indicator widget to reuse, so this
/// stays private to the intro.
class _LevelProgressIndicator extends StatelessWidget {
  const _LevelProgressIndicator({required this.activeLevel});

  final String activeLevel;

  static const List<String> _levels = ['A', 'B', 'C'];

  @override
  Widget build(BuildContext context) {
    final activeIndex = _levels.indexOf(activeLevel);
    return Semantics(
      label: 'Level $activeLevel of ${_levels.length}',
      child: Row(
        children: [
          for (var i = 0; i < _levels.length; i++) ...[
            _dot(context, label: _levels[i], index: i, activeIndex: activeIndex),
            if (i < _levels.length - 1)
              Expanded(
                child: Container(
                  height: 2,
                  margin:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                  color: i < activeIndex
                      ? AppColors.royalGold
                      : AppColors.disabled,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _dot(
    BuildContext context, {
    required String label,
    required int index,
    required int activeIndex,
  }) {
    final isActive = index == activeIndex;
    final isDone = index < activeIndex;
    final Color fill = isActive
        ? AppColors.mirageRed
        : (isDone ? AppColors.royalGold : Colors.transparent);
    final Color border =
        isActive || isDone ? Colors.transparent : AppColors.disabled;
    final Color text = isActive || isDone
        ? AppColors.textPrimary
        : AppColors.textSecondary;
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: text, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// Placeholder illustration of the phone position for this level. Rendered with a
/// framework [Icon] inside a styled container — there is NO external/Lottie
/// asset, so it cannot reach a broken-asset state or throw at runtime (the
/// missing-asset edge degrades to this neutral glyph, never a red error screen).
/// The glyph + label come from the level config, so it is never the wrong level's
/// illustration.
class _LevelIllustration extends StatelessWidget {
  const _LevelIllustration({required this.icon, required this.semanticLabel});

  final IconData icon;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Container(
        width: double.infinity,
        height: 200,
        decoration: BoxDecoration(
          color: AppColors.surface1,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: AppColors.royalGold.withValues(alpha: 0.4),
          ),
        ),
        child: Center(
          child: Icon(
            icon,
            size: 80,
            color: AppColors.royalGold,
            semanticLabel: semanticLabel,
          ),
        ),
      ),
    );
  }
}
