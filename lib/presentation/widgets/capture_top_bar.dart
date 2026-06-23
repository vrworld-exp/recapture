// lib/presentation/widgets/capture_top_bar.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../domain/entities/capture_top_bar_state.dart';

/// The capture-screen top bar: a compact, safe-area-aware bar over the camera
/// preview with a back/close control (leading), the level indicator (centre),
/// and Help + Settings controls (trailing).
///
/// Intent-only: it renders a supplied [CaptureTopBarState] and invokes
/// [onBack] / [onHelp] / [onSettings]. It builds NO Help/Settings content and
/// manages NO capture/auto-capture state — the parent decides what each opens
/// and whether to pause auto-capture while a sheet is up.
///
/// Self-positions at the top (returns a [Positioned]) so it drops straight into
/// the [CaptureOverlayLayer] overlay list. A thin Deep-Black→transparent scrim
/// keeps white icons/text legible over bright scenes. Rapid taps are debounced
/// (leading-edge) so the parent only ever gets a single open intent.
class CaptureTopBar extends StatefulWidget {
  const CaptureTopBar({
    super.key,
    required this.state,
    required this.onBack,
    required this.onHelp,
    required this.onSettings,
  });

  final CaptureTopBarState state;

  /// Back / close intent. The parent decides whether to confirm (e.g. a capture
  /// in progress) — the bar just emits.
  final VoidCallback onBack;

  /// Help intent (parent re-surfaces rules / pauses auto-capture).
  final VoidCallback onHelp;

  /// Settings intent (parent opens capture settings / pauses auto-capture).
  final VoidCallback onSettings;

  @override
  State<CaptureTopBar> createState() => _CaptureTopBarState();
}

class _CaptureTopBarState extends State<CaptureTopBar> {
  /// Leading-edge debounce window: the first tap on a control fires immediately,
  /// further taps on the SAME control within this window are swallowed so a
  /// single open intent reaches the parent. Per-control (keyed) so tapping a
  /// different control is never blocked by a recent tap on another.
  static const Duration _tapCooldown = Duration(milliseconds: 500);
  final Map<String, Timer> _cooldowns = {};

  @override
  void dispose() {
    for (final t in _cooldowns.values) {
      t.cancel();
    }
    super.dispose();
  }

  /// Fires [action] only if [key]'s cooldown is idle, then starts its window.
  void _guarded(String key, VoidCallback action) {
    if (_cooldowns[key]?.isActive ?? false) return;
    _cooldowns[key] = Timer(_tapCooldown, () {});
    action();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final theme = Theme.of(context);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: DecoratedBox(
        // Thin top scrim (covers the status bar too) so white chrome reads over
        // any preview background.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.bgPrimary.withValues(alpha: 0.6),
              AppColors.bgPrimary.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                _ScrimIconButton(
                  icon: Icons.close,
                  label: 'Back',
                  reduceMotion: reduceMotion,
                  onTap: () => _guarded('back', widget.onBack),
                ),
                Expanded(child: _LevelIndicator(state: state, theme: theme)),
                _ScrimIconButton(
                  icon: Icons.help_outline,
                  label: 'Help',
                  reduceMotion: reduceMotion,
                  onTap: state.helpEnabled
                      ? () => _guarded('help', widget.onHelp)
                      : null,
                ),
                const SizedBox(width: AppSpacing.xs),
                _ScrimIconButton(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  reduceMotion: reduceMotion,
                  onTap: state.settingsEnabled
                      ? () => _guarded('settings', widget.onSettings)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Centre level indicator: label (prominent) over an optional subtitle (grey),
/// announced as a single header to screen readers. Both lines truncate so a long
/// subtitle never breaks the bar layout.
class _LevelIndicator extends StatelessWidget {
  const _LevelIndicator({required this.state, required this.theme});

  final CaptureTopBarState state;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final subtitle = state.levelSubtitle;
    return Semantics(
      header: true,
      label: subtitle == null || subtitle.isEmpty
          ? state.levelLabel
          : '${state.levelLabel}, $subtitle',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            state.levelLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (subtitle != null && subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }
}

/// A 48×48 circular-scrim icon control with a tooltip + button semantics.
/// [onTap] == null greys the icon and disables it (no ripple, no callback).
/// Under reduce-motion the splash is suppressed.
class _ScrimIconButton extends StatelessWidget {
  const _ScrimIconButton({
    required this.icon,
    required this.label,
    required this.reduceMotion,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool reduceMotion;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Tooltip(
        message: label,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Material(
            type: MaterialType.circle,
            color: AppColors.bgPrimary.withValues(alpha: 0.4),
            child: InkResponse(
              onTap: onTap,
              radius: 24,
              splashFactory: reduceMotion ? NoSplash.splashFactory : null,
              child: Icon(
                icon,
                size: 22,
                color: enabled ? AppColors.textPrimary : AppColors.disabled,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
