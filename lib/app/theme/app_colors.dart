import 'package:flutter/material.dart';

/// MayasabhaXR — "Illusion on Obsidian" Design Token System
/// Theme: Ancient Mystique × Futuristic XR
abstract final class AppColors {
  // ── Core Brand Palette ───────────────────────────────────────────────────
  /// Primary background — 70–80% of any screen
  static const Color bgPrimary = Color(0xFF0B0B0E);

  /// Elevated surface — cards, modals, feature blocks
  static const Color surface1 = Color(0xFF151518);

  /// Slightly more elevated surface
  static const Color surface2 = Color(0xFF16161C);

  // ── Accent Colors ────────────────────────────────────────────────────────
  /// Primary CTA / highlights / active states
  static const Color mirageRed = Color(0xFFE10600);

  /// Hover / active state (use with glow/blur)
  static const Color redGlow = Color(0xFFFF2A1F);

  /// Premium accent — borders, dividers, thin lines (max 2–3% usage)
  static const Color royalGold = Color(0xFFC9A24D);

  /// Gold hover state
  static const Color goldGlow = Color(0xFFE6C36A);

  // ── Text Colors ──────────────────────────────────────────────────────────
  /// Primary text — headings, body copy
  static const Color textPrimary = Color(0xFFF5F5F7);

  /// Secondary text — sub-headlines, captions, descriptions
  static const Color textSecondary = Color(0xFFB3B3B8);

  /// Muted text — placeholders, disabled labels
  static const Color textMuted = Color(0xFF8A8A96);

  // ── State Colors ─────────────────────────────────────────────────────────
  /// Success states
  static const Color success = Color(0xFF2BD576);

  /// Warning states
  static const Color warning = Color(0xFFFFB020);

  /// Error states
  static const Color error = Color(0xFFFF4D4D);

  /// Focus ring (accessibility)
  static const Color focusRing = Color(0xFF78A6FF);

  /// Disabled / inactive elements
  static const Color disabled = Color(0xFF5C5C61);

  // ── Overlay ──────────────────────────────────────────────────────────────
  /// Modal / sheet scrim
  static const Color scrim = Color(0x8C000000); // rgba(0,0,0,0.55)

  // ── Gradient Definitions ─────────────────────────────────────────────────
  /// Primary CTA gradient (Red Energy) — 135°
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [mirageRed, redGlow],
  );

  /// Background depth gradient
  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [bgPrimary, surface1],
  );

  /// Gold accent gradient (use sparingly — section separators only)
  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [royalGold, goldGlow],
  );
}
