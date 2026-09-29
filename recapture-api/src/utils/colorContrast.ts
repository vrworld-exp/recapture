// src/utils/colorContrast.ts
//
// WCAG contrast maths for the catalog Appearance (more-customization Stage 2).
//
// A 1:1 PORT of mirage-fe `src/theme/applyTheme.ts` (`contrastRatio`, `mix`,
// `deriveFromPrimary`, `primaryPasses`, `accentPasses`). Mirage-fe re-runs the
// same check and silently falls back to the preset colour when it fails, so if
// the two ever disagree an owner saves a colour here that never shows up on the
// menu. Change both together; the test vectors in tests/color-contrast.test.ts
// are shared with mirage-fe's applyTheme.test.ts on purpose.
import { findThemePreset, DEFAULT_THEME_PRESET_ID, type ThemePreset } from '@/config/themePresets';
import type { CatalogAppearance } from '@/models/types/catalog.types';

export const HEX_COLOR_RE = /^#[0-9a-fA-F]{6}$/;

export const MIN_TEXT_CONTRAST = 4.5;
export const MIN_LARGE_CONTRAST = 3;

function toRgb(hex: string): [number, number, number] {
  return [
    parseInt(hex.slice(1, 3), 16),
    parseInt(hex.slice(3, 5), 16),
    parseInt(hex.slice(5, 7), 16),
  ];
}

function toHex(rgb: number[]): string {
  return `#${rgb
    .map((c) =>
      Math.round(Math.min(255, Math.max(0, c)))
        .toString(16)
        .padStart(2, '0')
    )
    .join('')
    .toUpperCase()}`;
}

function luminance(hex: string): number {
  const [r, g, b] = toRgb(hex).map((c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrastRatio(a: string, b: string): number {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

function mix(hex: string, target: string, amount: number): string {
  const from = toRgb(hex);
  const to = toRgb(target);
  return toHex(from.map((c, i) => c + (to[i]! - c) * amount));
}

export interface PrimaryDerivatives {
  onPrimary: string;
  ctaFrom: string;
  ctaTo: string;
  primaryGlow: string;
}

/** onPrimary / CTA gradient / glow for a primary colour on a preset. */
export function deriveFromPrimary(primary: string, preset: ThemePreset): PrimaryDerivatives {
  const { mode, tokens } = preset;
  const lightInk = mode === 'dark' ? tokens.text : '#FFFFFF';
  const darkInk = mode === 'dark' ? tokens.bg : tokens.text;
  const onPrimary =
    contrastRatio(primary, lightInk) >= contrastRatio(primary, darkInk) ? lightInk : darkInk;
  const lightText = onPrimary === lightInk;
  return {
    onPrimary,
    ctaFrom: lightText ? mix(primary, '#000000', 0.38) : mix(primary, '#000000', 0.08),
    ctaTo: lightText ? mix(primary, '#000000', 0.27) : mix(primary, '#FFFFFF', 0.12),
    primaryGlow: mix(primary, '#FFFFFF', 0.15),
  };
}

/** The preset's own derivatives — hand-tuned values win over derived ones. */
export function presetDerivatives(preset: ThemePreset): PrimaryDerivatives {
  const derived = deriveFromPrimary(preset.tokens.primary, preset);
  return {
    onPrimary: preset.onPrimary ?? derived.onPrimary,
    ctaFrom: preset.ctaFrom ?? derived.ctaFrom,
    ctaTo: preset.ctaTo ?? derived.ctaTo,
    primaryGlow: preset.primaryGlow ?? derived.primaryGlow,
  };
}

export function primaryPasses(primary: string, bg: string, derived: PrimaryDerivatives): boolean {
  return (
    contrastRatio(primary, derived.onPrimary) >= MIN_TEXT_CONTRAST &&
    contrastRatio(derived.ctaFrom, derived.onPrimary) >= MIN_TEXT_CONTRAST &&
    contrastRatio(derived.ctaTo, derived.onPrimary) >= MIN_TEXT_CONTRAST &&
    contrastRatio(primary, bg) >= MIN_LARGE_CONTRAST
  );
}

export function accentPasses(accent: string, bg: string): boolean {
  return (
    contrastRatio(accent, bg) >= MIN_TEXT_CONTRAST &&
    contrastRatio(accent, '#000000') >= MIN_LARGE_CONTRAST
  );
}

/** Why an appearance would be refused, in words an owner can act on. */
export interface AppearanceContrastProblem {
  field: 'primary' | 'accent';
  /** The colour pair that failed, e.g. `primary #FFF59D on bg #F7F9F4`. */
  pair: string;
  ratio: number;
  required: number;
}

const round2 = (n: number) => Math.round(n * 100) / 100;

/**
 * The first contrast rule the appearance breaks, or null when it is readable.
 * Colour FORMAT and preset-id membership are the Zod schema's job; this only
 * judges readability, against the preset the appearance names (Basalt when it
 * names none — the same fallback Mirage-fe applies).
 */
export function appearanceContrastProblem(
  appearance: CatalogAppearance
): AppearanceContrastProblem | null {
  const preset =
    findThemePreset(appearance.presetId) ?? findThemePreset(DEFAULT_THEME_PRESET_ID)!;
  const bg = preset.tokens.bg;

  if (appearance.primary && HEX_COLOR_RE.test(appearance.primary)) {
    const primary = appearance.primary.toUpperCase();
    const d = deriveFromPrimary(primary, preset);
    const checks: [string, string, string, number][] = [
      [`primary ${primary}`, `its button text ${d.onPrimary}`, primary, MIN_TEXT_CONTRAST],
      [`button ${d.ctaFrom}`, `its text ${d.onPrimary}`, d.ctaFrom, MIN_TEXT_CONTRAST],
      [`button ${d.ctaTo}`, `its text ${d.onPrimary}`, d.ctaTo, MIN_TEXT_CONTRAST],
    ];
    for (const [a, b, colour, required] of checks) {
      const ratio = contrastRatio(colour, d.onPrimary);
      if (ratio < required) {
        return { field: 'primary', pair: `${a} vs ${b}`, ratio: round2(ratio), required };
      }
    }
    const onBg = contrastRatio(primary, bg);
    if (onBg < MIN_LARGE_CONTRAST) {
      return {
        field: 'primary',
        pair: `primary ${primary} on background ${bg}`,
        ratio: round2(onBg),
        required: MIN_LARGE_CONTRAST,
      };
    }
  }

  if (appearance.accent && HEX_COLOR_RE.test(appearance.accent)) {
    const accent = appearance.accent.toUpperCase();
    const onBg = contrastRatio(accent, bg);
    if (onBg < MIN_TEXT_CONTRAST) {
      return {
        field: 'accent',
        pair: `accent ${accent} on background ${bg}`,
        ratio: round2(onBg),
        required: MIN_TEXT_CONTRAST,
      };
    }
    const onScrim = contrastRatio(accent, '#000000');
    if (onScrim < MIN_LARGE_CONTRAST) {
      return {
        field: 'accent',
        pair: `accent ${accent} on the dark photo badge`,
        ratio: round2(onScrim),
        required: MIN_LARGE_CONTRAST,
      };
    }
  }

  return null;
}

/**
 * The 400 body for a refused appearance — ONE shape for the owner and rep
 * routes. Same envelope as a validation 400 (`fields` keyed by dotted path) so
 * the app can point at the offending picker, with its own code so it can tell
 * "unreadable" apart from "malformed".
 */
export function lowContrastBody(problem: AppearanceContrastProblem) {
  const message =
    `That ${problem.field} colour is hard to read: ${problem.pair} is ` +
    `${problem.ratio}:1, it needs at least ${problem.required}:1.`;
  return {
    status: 'error' as const,
    code: 'APPEARANCE_LOW_CONTRAST',
    message,
    fields: { [`appearance.${problem.field}`]: message },
  };
}
