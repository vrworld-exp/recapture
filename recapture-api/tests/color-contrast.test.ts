// tests/color-contrast.test.ts
//
// The Appearance contrast rules (more-customization Stage 2).
//
// These vectors deliberately repeat mirage-fe's src/theme/applyTheme.test.ts:
// Mirage-fe re-checks every colour and silently falls back to the preset when a
// check fails, so the one thing that must never happen is ReCapture saving a
// colour Mirage-fe then refuses — the owner would see it in the app and never on
// the menu. If a vector here changes, change it there too.
import { describe, it, expect } from 'vitest';

import { THEME_PRESETS, findThemePreset } from '@/config/themePresets';
import {
  accentPasses,
  appearanceContrastProblem,
  contrastRatio,
  deriveFromPrimary,
  MIN_LARGE_CONTRAST,
  MIN_TEXT_CONTRAST,
  presetDerivatives,
  primaryPasses,
} from '@/utils/colorContrast';
import { THEME_PRESETS_WIRE } from '@/validation/remoteConfigSchema';

describe('contrastRatio', () => {
  it('matches the WCAG reference points', () => {
    expect(contrastRatio('#000000', '#FFFFFF')).toBeCloseTo(21, 5);
    expect(contrastRatio('#FFFFFF', '#FFFFFF')).toBeCloseTo(1, 5);
    // Basalt's own red on its own background — the reason primary-on-bg is 3.0.
    expect(contrastRatio('#E10600', '#0B0B0E')).toBeCloseTo(3.96, 2);
  });
});

describe('presets (mirror of mirage-fe presets.ts)', () => {
  it('keeps Basalt byte-identical to the live menu', () => {
    const basalt = findThemePreset('basalt')!;
    expect(basalt.tokens.bg).toBe('#0B0B0E');
    expect(basalt.tokens.primary).toBe('#E10600');
    expect(presetDerivatives(basalt)).toEqual({
      onPrimary: '#F5F5F7',
      ctaFrom: '#8B1A1A',
      ctaTo: '#A52422',
      primaryGlow: '#FF2A1F',
    });
  });

  for (const preset of THEME_PRESETS) {
    it(`${preset.id} passes its own rules`, () => {
      const t = preset.tokens;
      expect(primaryPasses(t.primary, t.bg, presetDerivatives(preset))).toBe(true);
      expect(accentPasses(t.accent, t.bg)).toBe(true);
      for (const ground of [t.bg, t.surface, t.surface2]) {
        expect(contrastRatio(t.text, ground)).toBeGreaterThanOrEqual(MIN_TEXT_CONTRAST);
        expect(contrastRatio(t.text2, ground)).toBeGreaterThanOrEqual(MIN_TEXT_CONTRAST);
      }
      expect(contrastRatio(t.accent, t.surface)).toBeGreaterThanOrEqual(MIN_LARGE_CONTRAST);
      // And the preset itself is a valid appearance.
      expect(appearanceContrastProblem({ presetId: preset.id })).toBeNull();
    });
  }

  it('serves every preset with its resolved button colours', () => {
    expect(THEME_PRESETS_WIRE.map((p) => p.id)).toEqual(THEME_PRESETS.map((p) => p.id));
    const basalt = THEME_PRESETS_WIRE.find((p) => p.id === 'basalt')!;
    expect(basalt.colors.ctaFrom).toBe('#8B1A1A');
    expect(basalt.colors.onPrimary).toBe('#F5F5F7');
  });
});

describe('appearanceContrastProblem', () => {
  it('refuses a pale primary on a light preset, naming the pair', () => {
    const problem = appearanceContrastProblem({ presetId: 'garden', primary: '#FFF59D' });
    expect(problem?.field).toBe('primary');
    expect(problem?.pair).toContain('#FFF59D');
    expect(problem!.ratio).toBeLessThan(problem!.required);
  });

  it('refuses an accent that disappears into the page', () => {
    expect(appearanceContrastProblem({ presetId: 'garden', accent: '#EEEEEE' })?.field).toBe(
      'accent'
    );
  });

  it('accepts a readable override and derives light button text for it', () => {
    expect(appearanceContrastProblem({ presetId: 'basalt', primary: '#1565C0' })).toBeNull();
    expect(deriveFromPrimary('#0D47A1', findThemePreset('garden')!).onPrimary).toBe('#FFFFFF');
  });

  it('judges against Basalt when no preset is named, as Mirage-fe does', () => {
    // Near-black primary on Basalt's near-black page.
    expect(appearanceContrastProblem({ primary: '#111111' })?.field).toBe('primary');
  });
});
