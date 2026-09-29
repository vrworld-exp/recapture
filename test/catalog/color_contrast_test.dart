// test/catalog/color_contrast_test.dart
//
// The Appearance contrast rules and preset catalog (more-customization
// Stage 2). The vectors repeat recapture-api tests/color-contrast.test.ts on
// purpose: the app, the API and Mirage-fe must agree on what is readable, or an
// owner saves a colour here that never reaches the menu.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/appearance.dart';
import 'package:recapture/domain/catalog/color_contrast.dart';
import 'package:recapture/domain/catalog/menu_theme_fonts.dart';
import 'package:recapture/domain/catalog/menu_theme_presets.dart';
import 'package:recapture/domain/entities/capture_config.dart';

const presets = MenuThemePreset.bundled;

MenuThemePreset preset(String id) => presets.firstWhere((p) => p.id == id);

void main() {
  group('contrastRatio', () {
    test('matches the WCAG reference points', () {
      expect(contrastRatio('#000000', '#FFFFFF'), closeTo(21, 1e-6));
      expect(contrastRatio('#FFFFFF', '#FFFFFF'), closeTo(1, 1e-6));
      // Basalt's own red on its page — why primary-on-bg is 3.0, not 4.5.
      expect(contrastRatio('#E10600', '#0B0B0E'), closeTo(3.96, 0.01));
    });
  });

  group('bundled presets', () {
    test('Basalt is first and byte-identical to the live menu', () {
      final basalt = presets.first;
      expect(basalt.id, 'basalt');
      expect(basalt.colors.bg, '#0B0B0E');
      expect(basalt.colors.primary, '#E10600');
      expect(basalt.colors.ctaFrom, '#8B1A1A');
      expect(basalt.colors.ctaTo, '#A52422');
    });

    for (final p in presets) {
      test('${p.id} is a valid, readable look', () {
        expect(appearanceContrastProblem(CatalogAppearance(presetId: p.id), presets), isNull);
        final c = p.colors;
        for (final ground in [c.bg, c.surface, c.surface2]) {
          expect(contrastRatio(c.text, ground), greaterThanOrEqualTo(kMinTextContrast));
          expect(contrastRatio(c.text2, ground), greaterThanOrEqualTo(kMinTextContrast));
        }
        for (final stop in [c.primary, c.ctaFrom, c.ctaTo]) {
          expect(contrastRatio(stop, c.onPrimary), greaterThanOrEqualTo(kMinTextContrast));
        }
      });
    }

    // The presets without hand-tuned button colours carry DERIVED ones; the
    // Dart derivation must reproduce what the API served, or an override's
    // preview would drift from the menu.
    test('derived button colours match the API derivation', () {
      for (final id in ['espresso', 'street', 'garden', 'bakery', 'ocean', 'royal']) {
        final p = preset(id);
        final d = deriveFromPrimary(p.colors.primary, p);
        expect(d.ctaFrom, p.colors.ctaFrom, reason: '$id ctaFrom');
        expect(d.ctaTo, p.colors.ctaTo, reason: '$id ctaTo');
      }
    });
  });

  group('appearanceContrastProblem', () {
    test('refuses a pale primary on a light preset', () {
      final problem = appearanceContrastProblem(
        const CatalogAppearance(presetId: 'garden', primary: '#FFF59D'),
        presets,
      );
      expect(problem?.field, 'primary');
    });

    test('refuses an accent that disappears into the page', () {
      final problem = appearanceContrastProblem(
        const CatalogAppearance(presetId: 'garden', accent: '#EEEEEE'),
        presets,
      );
      expect(problem?.field, 'accent');
    });

    test('accepts a readable override', () {
      expect(
        appearanceContrastProblem(
          const CatalogAppearance(presetId: 'basalt', primary: '#1565C0'),
          presets,
        ),
        isNull,
      );
      expect(deriveFromPrimary('#0D47A1', preset('garden')).onPrimary, '#FFFFFF');
    });

    test('judges against Basalt when no preset is named', () {
      expect(
        appearanceContrastProblem(const CatalogAppearance(primary: '#111111'), presets)?.field,
        'primary',
      );
    });
  });

  group('resolveMenuColors', () {
    test('applies a readable override with its derived button colours', () {
      final c = resolveMenuColors(
        const CatalogAppearance(presetId: 'basalt', primary: '#1565C0'),
        presets,
      );
      expect(c.primary, '#1565C0');
      expect(c.ctaFrom, isNot('#8B1A1A'));
    });

    test('drops an unreadable override, as Mirage-fe does', () {
      final c = resolveMenuColors(
        const CatalogAppearance(presetId: 'garden', primary: '#FFF59D'),
        presets,
      );
      expect(c.primary, preset('garden').colors.primary);
    });
  });

  group('served presets', () {
    test('parses the served list and falls back whole on anything malformed', () {
      final served = [for (final p in presets) p.toMap()];
      expect(MenuThemePreset.listFromOrDefault(served).length, presets.length);

      expect(MenuThemePreset.listFromOrDefault(null), same(MenuThemePreset.bundled));
      expect(MenuThemePreset.listFromOrDefault([
        {'id': 'x', 'label': 'X', 'mode': 'dark', 'colors': {'bg': 'red'}},
      ]), same(MenuThemePreset.bundled));
      // A list without Basalt has no fallback look — rejected.
      expect(
        MenuThemePreset.listFromOrDefault([preset('garden').toMap()]),
        same(MenuThemePreset.bundled),
      );
    });

    test('font pairings parse, fall back whole, and ride on the config', () {
      expect(MenuThemeFont.listFromOrDefault(null), same(MenuThemeFont.bundled));
      expect(
        MenuThemeFont.listFromOrDefault([
          {'id': 'classic', 'label': 'Classic', 'sample': 'x'},
        ]),
        same(MenuThemeFont.bundled),
        reason: 'no default pairing',
      );
      final config = CaptureConfig.fromMap({
        'themeFonts': [for (final f in MenuThemeFont.bundled.take(2)) f.toMap()],
      });
      expect(config.themeFonts.map((f) => f.id), ['default', 'classic']);
    });

    test('an appearance round-trips layout and font', () {
      final a = CatalogAppearance.fromMap(const {
        'presetId': 'royal',
        'layout': 'large',
        'fontId': 'hindi',
      });
      expect(a.layout, MenuLayout.large);
      expect(a.toMap(), {'presetId': 'royal', 'layout': 'large', 'fontId': 'hindi'});
      // An unknown layout from a newer server is dropped, not sent back.
      expect(CatalogAppearance.fromMap(const {'layout': 'carousel'}).layout, isNull);
    });

    test('rides on the remote config, bundled when absent', () {
      expect(CaptureConfig.fromMap(const {}).themePresets, same(MenuThemePreset.bundled));
      final config = CaptureConfig.fromMap({
        'themePresets': [preset('basalt').toMap(), preset('royal').toMap()],
      });
      expect(config.themePresets.map((p) => p.id), ['basalt', 'royal']);
    });
  });
}
