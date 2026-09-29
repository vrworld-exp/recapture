// lib/domain/catalog/color_contrast.dart
//
// WCAG contrast maths for the Appearance screen (more-customization Stage 2).
//
// The SAME formula as recapture-api utils/colorContrast.ts and mirage-fe
// src/theme/applyTheme.ts. All three must agree: the API refuses what fails,
// and Mirage-fe silently drops what fails — so a colour this screen lets
// through but either of them refuses is a colour the owner sees here and
// never on the menu. The test vectors in test/catalog/color_contrast_test.dart
// repeat the API's.
import 'dart:math' as math;

import 'appearance.dart';
import 'menu_theme_presets.dart';

final RegExp kHexColor = RegExp(r'^#[0-9A-Fa-f]{6}$');

const double kMinTextContrast = 4.5;
const double kMinLargeContrast = 3;

List<int> _rgb(String hex) => [
      int.parse(hex.substring(1, 3), radix: 16),
      int.parse(hex.substring(3, 5), radix: 16),
      int.parse(hex.substring(5, 7), radix: 16),
    ];

String _hex(List<double> rgb) =>
    '#${rgb.map((c) => c.round().clamp(0, 255).toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';

double _channel(int c) {
  final s = c / 255;
  return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
}

double relativeLuminance(String hex) {
  final c = _rgb(hex);
  return 0.2126 * _channel(c[0]) + 0.7152 * _channel(c[1]) + 0.0722 * _channel(c[2]);
}

double contrastRatio(String a, String b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

String _mix(String hex, String target, double amount) {
  final from = _rgb(hex);
  final to = _rgb(target);
  return _hex([for (var i = 0; i < 3; i++) from[i] + (to[i] - from[i]) * amount]);
}

/// onPrimary + the CTA gradient for [primary] on [preset] — derived exactly as
/// the API and Mirage-fe derive them for an override.
({String onPrimary, String ctaFrom, String ctaTo}) deriveFromPrimary(
  String primary,
  MenuThemePreset preset,
) {
  final c = preset.colors;
  final lightInk = preset.isDark ? c.text : '#FFFFFF';
  final darkInk = preset.isDark ? c.bg : c.text;
  final onPrimary =
      contrastRatio(primary, lightInk) >= contrastRatio(primary, darkInk) ? lightInk : darkInk;
  final lightText = onPrimary == lightInk;
  return (
    onPrimary: onPrimary,
    ctaFrom: lightText ? _mix(primary, '#000000', 0.38) : _mix(primary, '#000000', 0.08),
    ctaTo: lightText ? _mix(primary, '#000000', 0.27) : _mix(primary, '#FFFFFF', 0.12),
  );
}

/// Why an appearance would be refused, in words an owner can act on.
class AppearanceContrastProblem {
  const AppearanceContrastProblem({
    required this.field,
    required this.ratio,
    required this.required,
    required this.explanation,
  });

  /// 'primary' or 'accent'.
  final String field;
  final double ratio;
  final double required;

  /// A plain sentence for the inline warning.
  final String explanation;
}

/// The first rule [appearance] breaks on its preset, or null when readable.
AppearanceContrastProblem? appearanceContrastProblem(
  CatalogAppearance appearance,
  List<MenuThemePreset> presets,
) {
  final preset = MenuThemePreset.resolve(appearance.presetId, presets);
  final bg = preset.colors.bg;

  final primary = appearance.primary;
  if (primary != null && kHexColor.hasMatch(primary)) {
    final p = primary.toUpperCase();
    final d = deriveFromPrimary(p, preset);
    for (final colour in [p, d.ctaFrom, d.ctaTo]) {
      final ratio = contrastRatio(colour, d.onPrimary);
      if (ratio < kMinTextContrast) {
        return AppearanceContrastProblem(
          field: 'primary',
          ratio: ratio,
          required: kMinTextContrast,
          explanation: 'Button text would be hard to read on this colour.',
        );
      }
    }
    final onBg = contrastRatio(p, bg);
    if (onBg < kMinLargeContrast) {
      return AppearanceContrastProblem(
        field: 'primary',
        ratio: onBg,
        required: kMinLargeContrast,
        explanation: 'Prices in this colour would be hard to see on the page.',
      );
    }
  }

  final accent = appearance.accent;
  if (accent != null && kHexColor.hasMatch(accent)) {
    final a = accent.toUpperCase();
    final onBg = contrastRatio(a, bg);
    if (onBg < kMinTextContrast) {
      return AppearanceContrastProblem(
        field: 'accent',
        ratio: onBg,
        required: kMinTextContrast,
        explanation: 'Text in this colour would be hard to read on the page.',
      );
    }
    final onScrim = contrastRatio(a, '#000000');
    if (onScrim < kMinLargeContrast) {
      return AppearanceContrastProblem(
        field: 'accent',
        ratio: onScrim,
        required: kMinLargeContrast,
        explanation: 'The "Featured" badge on dish photos would be hard to read.',
      );
    }
  }

  return null;
}

/// The colours the menu will actually paint for [appearance] — overrides
/// applied only when they pass, exactly like Mirage-fe. What the live preview
/// draws.
MenuThemeColors resolveMenuColors(
  CatalogAppearance appearance,
  List<MenuThemePreset> presets,
) {
  final preset = MenuThemePreset.resolve(appearance.presetId, presets);
  var colors = preset.colors;
  final checkedPrimary = CatalogAppearance(presetId: preset.id, primary: appearance.primary);
  final primary = appearance.primary;
  if (primary != null &&
      kHexColor.hasMatch(primary) &&
      primary.toUpperCase() != colors.primary &&
      appearanceContrastProblem(checkedPrimary, presets) == null) {
    final d = deriveFromPrimary(primary.toUpperCase(), preset);
    colors = colors.copyWith(
      primary: primary.toUpperCase(),
      onPrimary: d.onPrimary,
      ctaFrom: d.ctaFrom,
      ctaTo: d.ctaTo,
    );
  }
  final checkedAccent = CatalogAppearance(presetId: preset.id, accent: appearance.accent);
  final accent = appearance.accent;
  if (accent != null &&
      kHexColor.hasMatch(accent) &&
      appearanceContrastProblem(checkedAccent, presets) == null) {
    colors = colors.copyWith(accent: accent.toUpperCase());
  }
  return colors;
}
