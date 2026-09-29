// src/config/themePresets.ts
//
// The Mirage menu theme presets — a MIRROR of mirage-fe `src/theme/presets.ts`
// (more-customization Stage 1/2). Mirage-fe owns the palettes and renders them;
// ReCapture needs them to (a) refuse an unknown preset id, (b) run the same
// contrast check Mirage-fe runs (utils/colorContrast.ts), and (c) serve the
// swatches to the app's Appearance screen through /remote-config.
//
// ⚠ Keep this file value-for-value identical to mirage-fe/src/theme/presets.ts.
// A preset id is a contract: an id ReCapture accepts but Mirage-fe does not know
// silently renders as Basalt on the customer's phone.

export const THEME_MODES = ['dark', 'light'] as const;
export type ThemeMode = (typeof THEME_MODES)[number];

export interface ThemePresetTokens {
  bg: string;
  surface: string;
  surface2: string;
  text: string;
  text2: string;
  primary: string;
  accent: string;
  overlay: string;
}

export interface ThemePreset {
  id: string;
  label: string;
  mode: ThemeMode;
  tokens: ThemePresetTokens;
  /** Hand-tuned derivatives of `primary`; derived when absent (colorContrast.ts). */
  onPrimary?: string;
  ctaFrom?: string;
  ctaTo?: string;
  primaryGlow?: string;
}

export const DEFAULT_THEME_PRESET_ID = 'basalt';

export const THEME_PRESETS: readonly ThemePreset[] = [
  {
    id: 'basalt',
    label: 'Basalt',
    mode: 'dark',
    tokens: {
      bg: '#0B0B0E',
      surface: '#151518',
      surface2: '#1A1A24',
      text: '#F5F5F7',
      text2: '#B3B3B8',
      primary: '#E10600',
      accent: '#C9A24D',
      overlay: '#000000',
    },
    onPrimary: '#F5F5F7',
    ctaFrom: '#8B1A1A',
    ctaTo: '#A52422',
    primaryGlow: '#FF2A1F',
  },
  {
    id: 'midnight-gold',
    label: 'Fine Dine',
    mode: 'dark',
    tokens: {
      bg: '#0B1220',
      surface: '#131C2E',
      surface2: '#1A2540',
      text: '#F3F4F8',
      text2: '#A9B1C6',
      primary: '#D4AF37',
      accent: '#E8D5A3',
      overlay: '#000000',
    },
    onPrimary: '#0B1220',
    ctaFrom: '#C29D2E',
    ctaTo: '#DDBB4E',
  },
  {
    id: 'espresso',
    label: 'Café',
    mode: 'dark',
    tokens: {
      bg: '#1B1411',
      surface: '#261C17',
      surface2: '#30241E',
      text: '#F5EBDD',
      text2: '#C9B8A6',
      primary: '#D08A4E',
      accent: '#E6C79C',
      overlay: '#000000',
    },
    onPrimary: '#1B1411',
  },
  {
    id: 'street',
    label: 'Street Food',
    mode: 'dark',
    tokens: {
      bg: '#121212',
      surface: '#1C1C1C',
      surface2: '#262626',
      text: '#F5F5F5',
      text2: '#B0B0B0',
      primary: '#FFC400',
      accent: '#FF7A45',
      overlay: '#000000',
    },
    onPrimary: '#121212',
  },
  {
    id: 'garden',
    label: 'Fresh & Green',
    mode: 'light',
    tokens: {
      bg: '#F7F9F4',
      surface: '#FFFFFF',
      surface2: '#EAF1E3',
      text: '#1C2A1C',
      text2: '#4F5F4F',
      primary: '#2E7D32',
      accent: '#8F5200',
      overlay: '#F7F9F4',
    },
    onPrimary: '#FFFFFF',
  },
  {
    id: 'bakery',
    label: 'Bakery',
    mode: 'light',
    tokens: {
      bg: '#FFF8F3',
      surface: '#FFFFFF',
      surface2: '#FBE9E7',
      text: '#3B2A2A',
      text2: '#6E5A58',
      primary: '#C2185B',
      accent: '#A0522D',
      overlay: '#FFF8F3',
    },
    onPrimary: '#FFFFFF',
  },
  {
    id: 'ocean',
    label: 'Seafood',
    mode: 'light',
    tokens: {
      bg: '#F5FAFB',
      surface: '#FFFFFF',
      surface2: '#E3F1F3',
      text: '#0F2A33',
      text2: '#47626B',
      primary: '#00695C',
      accent: '#B3541E',
      overlay: '#F5FAFB',
    },
    onPrimary: '#FFFFFF',
  },
  {
    id: 'royal',
    label: 'Royal Indian',
    mode: 'dark',
    tokens: {
      bg: '#2A0A12',
      surface: '#3A1019',
      surface2: '#4A1622',
      text: '#FFF4E6',
      text2: '#E0C3B0',
      primary: '#F29F05',
      accent: '#E8C468',
      overlay: '#000000',
    },
    onPrimary: '#2A0A12',
  },
];

export const THEME_PRESET_IDS: readonly string[] = THEME_PRESETS.map((p) => p.id);

/** Stage 3 card layouts. `grid` is today's card and the default. */
export const THEME_LAYOUTS = ['grid', 'list', 'large'] as const;
export type ThemeLayout = (typeof THEME_LAYOUTS)[number];

/**
 * Stage 3 font pairings — a MIRROR of the ids in mirage-fe src/theme/fonts.ts,
 * which owns the actual font stacks. An id Mirage-fe does not know renders the
 * default fonts, so keep these equal. `default` = today's Poppins.
 */
export const THEME_FONTS: readonly { id: string; label: string; sample: string }[] = [
  { id: 'default', label: 'Default', sample: 'Poppins' },
  { id: 'classic', label: 'Classic', sample: 'Playfair Display / Inter' },
  { id: 'modern', label: 'Modern', sample: 'Poppins' },
  { id: 'friendly', label: 'Friendly', sample: 'Baloo 2 / Nunito' },
  { id: 'bold', label: 'Bold', sample: 'Bebas Neue / Roboto' },
  { id: 'elegant', label: 'Elegant', sample: 'Cormorant Garamond / Lato' },
  { id: 'hindi', label: 'Hindi', sample: 'Tiro Devanagari Hindi / Mukta' },
];

export const THEME_FONT_IDS: readonly string[] = THEME_FONTS.map((f) => f.id);

export function findThemePreset(id: string | undefined): ThemePreset | undefined {
  return THEME_PRESETS.find((p) => p.id === id);
}
