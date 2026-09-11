// src/services/qrLogo.ts
//
// THE MARK IN THE MIDDLE OF A STANDEE QR, prepared for the two things that draw
// it.
//
// A sheet is drawn two ways — sharp composites the PNG, and the PDFs are
// written by hand out of `pdfPrimitives` — and each wants the artwork in a
// different shape: the PNG wants an overlay it can drop onto the raster at
// whatever size that render is, the PDF wants raw RGB pixels to deflate into an
// XObject once. Both start from the same bytes (`assets/mayasabhaLogo`) and
// this is the only module that touches them, so the mark cannot drift between
// the square a rep downloads and the square a print shop gets.
//
// WHERE the mark goes and HOW BIG is not decided here. The well is carved into
// the matrix by `matrixFor`, and the box the artwork fills is `logoBox` — in
// modules, so every renderer scales it by its own module size. This module
// only answers "give me the pixels".
//
// Deterministic, like everything else on the sheet: sharp's resampling and
// rsvg's rasterising of the corner mask are pure functions of their inputs,
// which is what keeps two renders of one code byte-identical and the ETags
// honest.
import sharp from 'sharp';

import { MAYASABHA_LOGO } from '@/assets/mayasabhaLogo';
import { QR_LOGO_CORNER_RADIUS, type RgbBitmap } from '@/services/pdfPrimitives';

/**
 * Pixels a side the mark is rastered at for the PDFs.
 *
 * On the one-up sheet the mark is about an inch across, so this is ~320dpi;
 * on the batch sheet it is a third of that and the same pixels are simply
 * finer. It is the ONE copy in the file however many cards there are (every
 * card names the same XObject), so the cost is paid once, and it is capped
 * here rather than following the QR's DPI setting because a 600dpi run should
 * make the modules crisper, not double the size of a picture that was already
 * finer than the printer.
 */
export const QR_LOGO_PDF_PX = 320;

let pdfLogo: Promise<RgbBitmap> | undefined;

/**
 * The mark as packed 8-bit RGB at [QR_LOGO_PDF_PX], for `rgbImageXObject`.
 *
 * Decoded once per process and shared — a batch sheet of five hundred cards
 * must not decode the JPEG five hundred times, and neither should five hundred
 * one-up downloads. A failed decode is NOT cached: the next caller retries
 * rather than every sheet for the life of the process failing the same way.
 *
 * Flattened onto white so a future replacement with transparency lands on the
 * well's colour rather than on black.
 */
export function qrLogoForPdf(): Promise<RgbBitmap> {
  pdfLogo ??= sharp(MAYASABHA_LOGO)
    .resize(QR_LOGO_PDF_PX, QR_LOGO_PDF_PX, { kernel: 'lanczos3', fit: 'fill' })
    .flatten({ background: '#ffffff' })
    .toColourspace('srgb')
    .raw()
    .toBuffer()
    .then((data) => ({ data, side: QR_LOGO_PDF_PX }))
    .catch((err: unknown) => {
      pdfLogo = undefined;
      throw err;
    });
  return pdfLogo;
}

/**
 * The mark as a PNG overlay `sidePx` square with rounded corners cut into its
 * alpha, for sharp to composite onto the rendered code.
 *
 * Per render rather than cached, because the size follows the render: a
 * 256px square and a 2048px square want different overlays, and resizing a
 * 27KB JPEG is cheaper than reasoning about a cache keyed by size.
 *
 * The corners come from an SVG mask applied with `dest-in` — keep the artwork
 * where the mask is opaque — which is the standard rounded-corner recipe and
 * the reason the overlay carries alpha at all.
 */
export async function qrLogoOverlay(sidePx: number): Promise<Buffer> {
  const radius = Math.round(sidePx * QR_LOGO_CORNER_RADIUS);
  const mask = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${sidePx}" height="${sidePx}">` +
      `<rect width="${sidePx}" height="${sidePx}" rx="${radius}" ry="${radius}" fill="#fff"/>` +
      '</svg>'
  );

  return sharp(MAYASABHA_LOGO)
    .resize(sidePx, sidePx, { kernel: 'lanczos3', fit: 'fill' })
    .ensureAlpha()
    .composite([{ input: mask, blend: 'dest-in' }])
    .png()
    .toBuffer();
}
