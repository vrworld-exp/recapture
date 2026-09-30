// src/services/brandedQr.ts
//
// The owner's BRANDED QR (more-customization Stage 7.4): colours, the
// restaurant's own logo in the centre, a line of frame text ("Scan for our 3D
// menu"), and four printable templates.
//
// catalogQrService stays the one door: it calls in here only when the catalog
// has a non-default style, so every plain square — standees, reps, admin — is
// rendered exactly as before, byte for byte.
//
// SCANNABILITY IS CHECKED, NOT HOPED FOR. The style is gated at the API (dark
// on light, contrast ≥ MIN_QR_CONTRAST), the code is always encoded at level H
// with a cleared well, and every styled PNG is DECODED with jsQR before it is
// returned. A square that does not read back as its URL is replaced by the
// plain one and logged — a printed code that does not scan is the one failure
// this feature must never ship.
//
// The PDFs are hand-written from pdfPrimitives like the plain sheet. The code
// is a 1-bit IMAGE MASK painted in the chosen colour over a filled background
// square, so colour costs nothing in sharpness: the modules are still exactly
// the matrix, just not black.
import zlib from 'zlib';
import sharp from 'sharp';
import jsQR from 'jsqr';

import { findThemePreset, DEFAULT_THEME_PRESET_ID } from '@/config/themePresets';
import { BUCKET_ARTIFACTS } from '@/config/s3';
import type { CatalogAppearance, CatalogQrStyle } from '@/models/types/catalog.types';
import {
  A4_HEIGHT_PT,
  A4_WIDTH_PT,
  asciiFold,
  assemblePdf,
  contentStreamObject,
  HELVETICA_BOLD_OBJECT,
  HELVETICA_OBJECT,
  logoBox,
  logoOperators,
  matrixFor,
  pdfText,
  proportionalInkWidth,
  QR_LOGO_CORNER_RADIUS,
  qrBitmap1Bit,
  rgbImageXObject,
  type QrBitmap,
  type QrMatrix,
  type RgbBitmap,
} from '@/services/pdfPrimitives';
import { QR_LOGO_PDF_PX, qrLogoForPdf, qrLogoOverlay } from '@/services/qrLogo';
import { getObjectBytes } from '@/services/s3ObjectStore';
import { contrastRatio, hexToRgb } from '@/utils/colorContrast';
import { parseProductImageKey } from '@/utils/productImageKeys';

export const DEFAULT_QR_STYLE: CatalogQrStyle = {
  fg: '#000000',
  bg: '#FFFFFF',
  logoCenter: false,
  template: 'classic',
};

/** The stored style with defaults filled in. */
export function resolveQrStyle(stored: CatalogQrStyle | null | undefined): CatalogQrStyle {
  if (!stored) return { ...DEFAULT_QR_STYLE };
  return {
    fg: stored.fg ?? DEFAULT_QR_STYLE.fg,
    bg: stored.bg ?? DEFAULT_QR_STYLE.bg,
    logoCenter: stored.logoCenter === true,
    ...(stored.frameText ? { frameText: stored.frameText } : {}),
    template: stored.template ?? 'classic',
  };
}

/** Nothing chosen — render through the plain, byte-identical path. */
export function isDefaultQrStyle(style: CatalogQrStyle): boolean {
  return (
    style.fg.toUpperCase() === DEFAULT_QR_STYLE.fg &&
    style.bg.toUpperCase() === DEFAULT_QR_STYLE.bg &&
    !style.logoCenter &&
    !style.frameText &&
    style.template === 'classic'
  );
}

/** Everything a styled render may need beyond the URL. */
export interface BrandingSource {
  catalogName: string;
  appearance?: CatalogAppearance | null;
  logoKey?: string;
  coverImageKey?: string;
}

/** An image of ours from S3, or undefined — a missing picture never fails a render. */
async function ownImageBytes(key: string | undefined): Promise<Buffer | undefined> {
  if (!key || !parseProductImageKey(key).ok) return undefined;
  try {
    const fetched = await getObjectBytes(BUCKET_ARTIFACTS, key);
    return fetched.outcome === 'absent' ? undefined : fetched.body;
  } catch (err) {
    console.warn(`[qr] branded render: image unavailable (${(err as Error).message})`);
    return undefined;
  }
}

/** The menu's primary colour — the preset's, or the owner's override. */
function themePrimary(appearance: CatalogAppearance | null | undefined): string {
  const preset =
    findThemePreset(appearance?.presetId) ?? findThemePreset(DEFAULT_THEME_PRESET_ID);
  return appearance?.primary ?? preset?.tokens.primary ?? '#E10600';
}

/** "blue_cafe" → "Blue Cafe", ASCII-folded for the base-14 fonts. */
function displayName(name: string): string {
  return asciiFold(
    name
      .replace(/_/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .replace(/\b\w/g, (c) => c.toUpperCase())
  );
}

const escapeXml = (s: string): string =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

// ── Logo in the well ────────────────────────────────────────────────────────

/** The owner's logo (or the Mayasabha mark) as a rounded PNG overlay. */
async function wellOverlay(sidePx: number, logo: Buffer | undefined): Promise<Buffer> {
  if (!logo) return qrLogoOverlay(sidePx);
  const radius = Math.round(sidePx * QR_LOGO_CORNER_RADIUS);
  const mask = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${sidePx}" height="${sidePx}">` +
      `<rect width="${sidePx}" height="${sidePx}" rx="${radius}" ry="${radius}" fill="#fff"/></svg>`
  );
  return sharp(logo)
    .resize(sidePx, sidePx, { fit: 'contain', background: '#ffffff' })
    .flatten({ background: '#ffffff' })
    .ensureAlpha()
    .composite([{ input: mask, blend: 'dest-in' }])
    .png()
    .toBuffer();
}

/** The same, as packed RGB for the PDF. */
async function wellRgb(logo: Buffer | undefined): Promise<RgbBitmap> {
  if (!logo) return qrLogoForPdf();
  const data = await sharp(logo)
    .resize(QR_LOGO_PDF_PX, QR_LOGO_PDF_PX, { fit: 'contain', background: '#ffffff' })
    .flatten({ background: '#ffffff' })
    .toColourspace('srgb')
    .raw()
    .toBuffer();
  return { data, side: QR_LOGO_PDF_PX };
}

// ── PNG ─────────────────────────────────────────────────────────────────────

/**
 * The coloured square (plus the frame-text band when there is one). Modules
 * are painted at native resolution and upscaled with `nearest`, exactly like
 * the plain renderer, so no edge is ever smoothed.
 */
async function renderStyledPng(
  url: string,
  size: number,
  style: CatalogQrStyle,
  logo: Buffer | undefined
): Promise<Buffer> {
  const matrix = matrixFor(url, { logoWell: true });
  const [fr, fg, fb] = hexToRgb(style.fg);
  const [br, bgc, bb] = hexToRgb(style.bg);
  const raw = Buffer.alloc(matrix.size * matrix.size * 3);
  for (let y = 0; y < matrix.size; y++) {
    for (let x = 0; x < matrix.size; x++) {
      const i = (y * matrix.size + x) * 3;
      const dark = matrix.isDark(x, y);
      raw[i] = dark ? fr : br;
      raw[i + 1] = dark ? fg : bgc;
      raw[i + 2] = dark ? fb : bb;
    }
  }

  const scale = Math.max(1, Math.floor(size / matrix.size));
  const side = matrix.size * scale;
  const box = logoBox(matrix);
  const square = await sharp(raw, { raw: { width: matrix.size, height: matrix.size, channels: 3 } })
    .resize(side, side, { kernel: 'nearest' })
    .composite([
      { input: await wellOverlay(box.side * scale, logo), left: box.x * scale, top: box.y * scale },
    ])
    .png()
    .toBuffer();

  if (!style.frameText) return square;

  // The band sits BELOW the quiet zone, so it can never eat into the code.
  const band = Math.round(side * 0.16);
  const text = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${side}" height="${band}">` +
      `<text x="50%" y="58%" text-anchor="middle" dominant-baseline="middle" ` +
      `font-family="Helvetica, Arial, sans-serif" font-weight="700" ` +
      `font-size="${Math.round(band * 0.42)}" fill="${style.fg}">${escapeXml(style.frameText)}</text></svg>`
  );
  return sharp(square)
    .extend({ bottom: band, background: style.bg })
    .composite([{ input: text, left: 0, top: side }])
    .png({ compressionLevel: 9 })
    .toBuffer();
}

/**
 * Reads the PNG back with jsQR. Decoded at no more than 1024 px a side — the
 * decoder's cost grows with the pixel count, and a module at that size is
 * still several pixels wide.
 */
export async function decodesTo(png: Buffer, expected: string): Promise<boolean> {
  try {
    const { data, info } = await sharp(png)
      .resize({ width: 1024, height: 1024, fit: 'inside', withoutEnlargement: true })
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });
    const result = jsQR(new Uint8ClampedArray(data), info.width, info.height);
    return result?.data === expected;
  } catch (err) {
    console.warn(`[qr] decode check failed to run (${(err as Error).message})`);
    return false;
  }
}

export interface StyledPngResult {
  png: Buffer;
  /** True when the style did not scan and the plain square was returned instead. */
  fellBack: boolean;
}

/**
 * The branded PNG, or — when it does not decode back to [url] — the result of
 * [plain], flagged. [plain] is catalogQrService's own renderer.
 */
export async function brandedPng(params: {
  url: string;
  size: number;
  style: CatalogQrStyle;
  source: BrandingSource;
  plain: () => Promise<Buffer>;
}): Promise<StyledPngResult> {
  const logo = params.style.logoCenter ? await ownImageBytes(params.source.logoKey) : undefined;
  const png = await renderStyledPng(params.url, params.size, params.style, logo);
  if (await decodesTo(png, params.url)) return { png, fellBack: false };
  console.warn('[qr] branded square did not decode — falling back to the plain one');
  return { png: await params.plain(), fellBack: true };
}

// ── PDF ─────────────────────────────────────────────────────────────────────

/** The code as a 1-bit image MASK — painted in the current fill colour. */
function imageMaskXObject(image: QrBitmap): Buffer {
  const compressed = zlib.deflateSync(image.data, { level: 9 });
  return Buffer.concat([
    Buffer.from(
      `<< /Type /XObject /Subtype /Image /Width ${image.side} /Height ${image.side} ` +
        '/ImageMask true /BitsPerComponent 1 /Interpolate false ' +
        `/Filter /FlateDecode /Length ${compressed.byteLength} >>\nstream\n`
    ),
    compressed,
    Buffer.from('\nendstream'),
  ]);
}

/** A non-square RGB image (the cover). */
function rgbRectXObject(data: Buffer, width: number, height: number): Buffer {
  const compressed = zlib.deflateSync(data, { level: 9 });
  return Buffer.concat([
    Buffer.from(
      `<< /Type /XObject /Subtype /Image /Width ${width} /Height ${height} ` +
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Interpolate true ' +
        `/Filter /FlateDecode /Length ${compressed.byteLength} >>\nstream\n`
    ),
    compressed,
    Buffer.from('\nendstream'),
  ]);
}

const rgbOp = (hex: string, op: 'rg' | 'RG' = 'rg'): string =>
  hexToRgb(hex)
    .map((c) => (c / 255).toFixed(3))
    .join(' ') + ` ${op}`;

/** The code: background square, modules in `fg`, logo in the well. */
function qrOps(matrix: QrMatrix, x: number, y: number, side: number, style: CatalogQrStyle): string {
  return [
    `q ${rgbOp(style.bg)} ${x.toFixed(2)} ${y.toFixed(2)} ${side} ${side} re f Q`,
    `q ${rgbOp(style.fg)} ${side} 0 0 ${side} ${x.toFixed(2)} ${y.toFixed(2)} cm /Im0 Do Q`,
    logoOperators(matrix, x, y, side, '/Logo'),
  ].join('\n');
}

/** One centred line of text. */
function textOps(text: string, font: '/F1' | '/F2', size: number, y: number, colour: string): string {
  const folded = asciiFold(text);
  const x = A4_WIDTH_PT / 2 - proportionalInkWidth(folded, size) / 2;
  return [
    `${rgbOp(colour)}`,
    `BT ${font} ${size} Tf 0 Tc 1 0 0 1 ${x.toFixed(2)} ${y.toFixed(2)} Tm (${pdfText(folded)}) Tj ET`,
  ].join('\n');
}

const INK = '#1A1A1A';
const MUTED = '#6B6B6B';

/** The drawing operators for one page of [template]. */
function templateOps(params: {
  matrix: QrMatrix;
  style: CatalogQrStyle;
  name: string;
  url: string;
  primary: string;
  onPrimary: string;
  hasCover: boolean;
}): string {
  const { matrix, style, name, url, primary, onPrimary, hasCover } = params;
  const W = A4_WIDTH_PT;
  const H = A4_HEIGHT_PT;
  const frame = style.frameText ?? '';

  switch (style.template) {
    case 'minimal': {
      const side = 420;
      const x = (W - side) / 2;
      const y = (H - side) / 2 + 30;
      return [
        qrOps(matrix, x, y, side, style),
        ...(frame ? [textOps(frame, '/F2', 24, y - 48, style.fg)] : []),
      ].join('\n');
    }

    case 'bold': {
      const bandH = hasCover ? 300 : 200;
      const side = 330;
      const x = (W - side) / 2;
      const y = H - bandH - 60 - side;
      return [
        `q ${rgbOp(primary)} 0 ${H - bandH} ${W} ${bandH} re f Q`,
        // The cover fills the band's top, the name sits on the colour below it.
        ...(hasCover ? [`q ${W} 0 0 ${bandH - 90} 0 ${H - bandH + 90} cm /Cover Do Q`] : []),
        textOps(name, '/F2', 30, H - bandH + 36, onPrimary),
        qrOps(matrix, x, y, side, style),
        ...(frame ? [textOps(frame, '/F2', 22, y - 44, style.fg)] : []),
        textOps(url, '/F1', 10, y - (frame ? 72 : 44), MUTED),
      ].join('\n');
    }

    case 'tent': {
      // Folded across the middle: the bottom half faces the table, the top half
      // is the same face turned 180° so the tent reads from both sides.
      const half = (): string => {
        const side = 230;
        const x = (W - side) / 2;
        const y = 150;
        return [
          qrOps(matrix, x, y, side, style),
          textOps(name, '/F2', 20, y + side + 24, INK),
          ...(frame ? [textOps(frame, '/F2', 16, y - 32, style.fg)] : []),
        ].join('\n');
      };
      return [
        half(),
        `q 1 0 0 1 0 0 cm ${rgbOp(MUTED, 'RG')} 0.5 w [4 4] 0 d 20 ${(H / 2).toFixed(2)} m ${W - 20} ${(H / 2).toFixed(2)} l S Q`,
        `q -1 0 0 -1 ${W} ${H} cm`,
        half(),
        'Q',
      ].join('\n');
    }

    case 'classic':
    default: {
      const side = 360;
      const x = (W - side) / 2;
      const y = H - 200 - side;
      return [
        ...(frame ? [textOps(frame, '/F2', 24, y + side + 40, style.fg)] : []),
        qrOps(matrix, x, y, side, style),
        textOps(name, '/F2', 20, y - 52, INK),
        textOps(url, '/F1', 11, y - 84, MUTED),
      ].join('\n');
    }
  }
}

/**
 * A branded A4 sheet, [pages] identical pages sharing one content stream —
 * the same shape as the plain sheet, so the counted standee download is
 * unchanged: only the artwork differs.
 */
export async function brandedPdf(params: {
  url: string;
  style: CatalogQrStyle;
  source: BrandingSource;
  pages?: number;
}): Promise<Buffer> {
  const { url, style, source } = params;
  const matrix = matrixFor(url, { logoWell: true });
  const mask = qrBitmap1Bit(matrix, 8);
  const logo = style.logoCenter ? await ownImageBytes(source.logoKey) : undefined;
  const artwork = await wellRgb(logo);

  const primary = themePrimary(source.appearance);
  const onPrimary = contrastRatio(primary, '#FFFFFF') >= 3 ? '#FFFFFF' : '#111111';

  let cover: { data: Buffer; width: number; height: number } | undefined;
  if (style.template === 'bold') {
    const bytes = await ownImageBytes(source.coverImageKey);
    if (bytes) {
      const width = 900;
      const height = 314; // the band's aspect: 595.28 × 210
      const data = await sharp(bytes)
        .resize(width, height, { fit: 'cover' })
        .flatten({ background: '#ffffff' })
        .toColourspace('srgb')
        .raw()
        .toBuffer();
      cover = { data, width, height };
    }
  }

  const content = templateOps({
    matrix,
    style,
    name: displayName(source.catalogName),
    url,
    primary,
    onPrimary,
    hasCover: Boolean(cover),
  });

  const count = Math.max(1, Math.floor(params.pages ?? 1));
  const CONTENTS = 3 + count;
  const IMAGE = CONTENTS + 1;
  const F1 = IMAGE + 1;
  const F2 = F1 + 1;
  const LOGO = F2 + 1;
  const COVER = LOGO + 1;
  const xobjects = `/Im0 ${IMAGE} 0 R /Logo ${LOGO} 0 R${cover ? ` /Cover ${COVER} 0 R` : ''}`;

  const kids = Array.from({ length: count }, (_, i) => `${3 + i} 0 R`).join(' ');
  const pageObjects = Array.from({ length: count }, () =>
    Buffer.from(
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${A4_WIDTH_PT} ${A4_HEIGHT_PT}] ` +
        `/Resources << /XObject << ${xobjects} >> /Font << /F1 ${F1} 0 R /F2 ${F2} 0 R >> >> ` +
        `/Contents ${CONTENTS} 0 R >>`
    )
  );

  return assemblePdf([
    Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'),
    Buffer.from(`<< /Type /Pages /Kids [${kids}] /Count ${count} >>`),
    ...pageObjects,
    contentStreamObject(content),
    imageMaskXObject(mask),
    Buffer.from(HELVETICA_OBJECT),
    Buffer.from(HELVETICA_BOLD_OBJECT),
    rgbImageXObject(artwork),
    ...(cover ? [rgbRectXObject(cover.data, cover.width, cover.height)] : []),
  ]);
}
