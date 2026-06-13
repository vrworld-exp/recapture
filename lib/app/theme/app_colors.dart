// lib/app/theme/app_colors.dart
import 'package:flutter/material.dart';

/// MayasabhaXR — "Illusion on Obsidian" Design Token System
/// Theme concept: Ancient Mystique × Futuristic XR
///
/// USAGE RULES (enforced across entire codebase):
/// - bgPrimary covers 70–80% of any screen
/// - mirageRed is used sparingly for CTAs and active states only
/// - royalGold is used at max 2–3% per screen (borders, dividers, premium highlights)
/// - Never reference a Color hex value outside this file — always use AppColors.*
abstract final class AppColors {
  // ── Core Backgrounds ───────────────────────────────────────────────────────

  /// Primary background — deepest black. 70–80% of every screen.
  static const Color bgPrimary = Color(0xFF0B0B0E);

  /// Slightly elevated surface — cards, modals, bento tiles, feature blocks.
  static const Color surface1 = Color(0xFF151518);

  /// Higher elevated surface — nested cards, inner containers.
  static const Color surface2 = Color(0xFF16161C);

  // ── Brand Accent Colors ────────────────────────────────────────────────────

  /// Primary CTA color — buttons, active states, headline highlights.
  /// Use decisively but sparingly. If everything is red, nothing is important.
  static const Color mirageRed = Color(0xFFE10600);

  /// Red hover / active glow — use with opacity 30–60% for glow effects.
  static const Color redGlow = Color(0xFFFF2A1F);

  /// Premium gold accent — borders, dividers, icon outlines, thin lines.
  /// Max 2–3% usage per screen. Never use for body text.
  static const Color royalGold = Color(0xFFC9A24D);

  /// Gold hover / interactive state — premium section highlights.
  static const Color goldGlow = Color(0xFFE6C36A);

  // ── Text Colors ────────────────────────────────────────────────────────────

  /// Primary text — main headings, body paragraphs. Use instead of pure white.
  static const Color textPrimary = Color(0xFFF5F5F7);

  /// Secondary text — sub-headlines, descriptions, captions, footer text.
  static const Color textSecondary = Color(0xFFB3B3B8);

  /// Muted text — placeholders, hints, disabled labels.
  static const Color textMuted = Color(0xFF8A8A96);

  // ── Semantic State Colors ──────────────────────────────────────────────────

  /// Success — accepted photos, completed levels, model ready.
  static const Color success = Color(0xFF2BD576);

  /// Warning — blur warnings, exposure warnings, low coverage alerts.
  static const Color warning = Color(0xFFFFB020);

  /// Error — rejected photos, upload failures, processing failures.
  static const Color error = Color(0xFFFF4D4D);

  /// Focus ring — accessibility keyboard/D-pad focus outline.
  static const Color focusRing = Color(0xFF78A6FF);

  /// Disabled — inactive buttons, muted icons, inactive stepper steps.
  static const Color disabled = Color(0xFF5C5C61);

  // ── Overlay ────────────────────────────────────────────────────────────────

  /// Modal / bottom sheet scrim. rgba(0, 0, 0, 0.55).
  static const Color scrim = Color(0x8C000000);

  // ── Gradient Definitions ───────────────────────────────────────────────────

  /// Primary CTA gradient (Red Energy) — use for primary buttons and key banners.
  /// Direction: 135° (top-left → bottom-right).
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [mirageRed, redGlow],
  );

  /// Background depth gradient — hero sections, cover slides, section transitions.
  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [bgPrimary, surface1],
  );

  /// Gold accent gradient — section separators, premium frames, thin divider lines.
  /// Use very sparingly — max once per screen.
  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [royalGold, goldGlow],
  );
}
