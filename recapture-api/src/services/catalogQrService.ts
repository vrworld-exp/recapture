// src/services/catalogQrService.ts
//
// The catalog QR code, rendered server-side from `catalog.publicUrl` VERBATIM.
//
// FROM THE BUSINESS OWNER'S POINT OF VIEW THE QR IS THE PRODUCT. It goes on a
// sticker, a menu, a shop window. Feature 32 is therefore a hard constraint:
// regenerating catalog contents must never change the code — and the way that
// is guaranteed is not by being careful here, it is by this module having
// nothing to be careful about. It reads a stored string and draws it. It does
// not compose a URL, does not normalise one, does not trim, lower-case or
// re-derive one. `MIRAGE_PUBLIC_BASE_URL` is not imported by this file, and it
// should stay that way: a grandfathered catalog on an old host must keep
// rendering the code that was printed.
//
// DETERMINISM IS ASSERTED, NOT ASSUMED. The same catalog must produce a
// byte-identical PNG on every call, or a caching layer (or a client comparing
// checksums) sees churn that is not there. That rules out anything timestamped
// or locale-dependent, which is why:
//
//   • the QR MATRIX comes from `qrcode`, used ONLY as an encoder — its own
//     renderers are not called;
//   • the PNG comes from `sharp`, which is already a dependency (AGENTS.md
//     requires exactly one libvips copy in the tree, so adding a second image
//     library would be a real hazard, not just extra weight);
//   • the PDF is written BY HAND, out of `pdfPrimitives`. A single page holding
//     one image is a few hundred bytes of syntax, and a PDF library would be a
//     second dependency for it — plus every one worth using stamps a
//     CreationDate, which would break byte-identity on its own.
//
// The low-level half of that last point moved to `services/pdfPrimitives.ts`
// when the batch standee sheet (`services/standeeSheetPdf.ts`) became a second
// hand-written layout. Nothing about the output changed: this file still decides
// what a catalog's sheet looks like, and the xref arithmetic is now counted in
// one place instead of two.
import sharp from 'sharp';

import {
  A4_HEIGHT_PT,
  A4_WIDTH_PT,
  assemblePdf,
  codeInkWidth,
  contentStreamObject,
  HELVETICA_BOLD_OBJECT,
  HELVETICA_OBJECT,
  imageXObject,
  matrixFor,
  pdfText,
  proportionalInkWidth,
  QR_ERROR_CORRECTION,
  QR_QUIET_ZONE,
  qrBitmap1Bit,
  type QrBitmap,
} from '@/services/pdfPrimitives';

// Re-exported because this module was their home before the split, and both are
// part of "what every issued code looks like" rather than of PDF plumbing.
export { QR_ERROR_CORRECTION, QR_QUIET_ZONE };

export const QR_DEFAULT_SIZE = 1024;
export const QR_MIN_SIZE = 256;
export const QR_MAX_SIZE = 2048;

/** Clamps rather than errors — a size out of range is a preference, not a fault. */
export function clampQrSize(requested: number | undefined): number {
  if (requested === undefined || !Number.isFinite(requested)) return QR_DEFAULT_SIZE;
  return Math.min(QR_MAX_SIZE, Math.max(QR_MIN_SIZE, Math.round(requested)));
}

/**
 * Renders the matrix as a 1-byte-per-pixel greyscale bitmap at NATIVE module
 * resolution, then lets sharp scale it up.
 *
 * ⚠ THE SCALE MUST BE `nearest`. Any smoothing kernel blurs module edges, and a
 * blurred QR is one a phone camera has to work harder to read — at small print
 * sizes, one it fails to read at all. sharp's default is a Lanczos-family
 * kernel, so this is a deliberate override, not a default being restated.
 */
async function renderPng(text: string, size: number): Promise<Buffer> {
  const matrix = matrixFor(text);
  const raw = Buffer.alloc(matrix.size * matrix.size, 0xff);
  for (let y = 0; y < matrix.size; y++) {
    for (let x = 0; x < matrix.size; x++) {
      if (matrix.isDark(x, y)) raw[y * matrix.size + x] = 0x00;
    }
  }

  // The final size is snapped to a whole multiple of the module count where it
  // can be, so every module is the same number of pixels wide. An uneven scale
  // makes some modules one pixel fatter than others, which is exactly the kind
  // of asymmetry a scanner's grid detection has to fight.
  const scale = Math.max(1, Math.floor(size / matrix.size));
  const rendered = matrix.size * scale;

  return sharp(raw, {
    raw: { width: matrix.size, height: matrix.size, channels: 1 },
  })
    .resize(rendered, rendered, { kernel: 'nearest' })
    .png({ compressionLevel: 9, palette: false })
    .toBuffer();
}

// ── PDF ─────────────────────────────────────────────────────────────────────

/** Point size of the printed code. Large enough to read across a table. */
const CODE_SIZE = 30;

/** Device pixels per QR module inside the PDF. See qrBitmap1Bit. */
const PDF_MODULE_SCALE = 8;

/** Extra space between the code's characters, in points at [CODE_SIZE]. */
const CODE_LETTER_SPACING = 4;

/** Half the ink width of the printed code, for centring it by hand. */
function halfCodeWidth(code: string, fontSize: number): number {
  return codeInkWidth(code, fontSize, CODE_LETTER_SPACING) / 2;
}

/** Half the width of a proportional line, for centring the tagline. */
function halfWidth(text: string, fontSize: number): number {
  return proportionalInkWidth(text, fontSize) / 2;
}

/**
 * A one-page A4 sheet: the QR square, and beneath it either the standee's
 * printed code and tagline, or the catalog's name and URL.
 *
 * TWO CALLERS, TWO CAPTIONS. A standee is a blank object that a rep claims, so
 * what belongs under it is the code they will type and a line saying what the
 * sheet is for. An owner's QR is already bound to their restaurant, so what
 * belongs under it is the restaurant's name and the URL a customer could type if
 * the square is smudged — that argument is in the original design and still
 * holds for that surface. The two are different sheets for different readers,
 * which is why this takes a caption rather than growing a boolean.
 *
 * Written by hand — see the file header. The structure is the minimum a
 * conforming reader needs: catalog, pages, one page, one content stream, one
 * embedded image XObject, two Type1 base fonts (Helvetica and Helvetica-Bold are
 * both among the fourteen every reader must provide, so nothing is embedded and
 * nothing is licensed). The xref offsets are computed from the actual byte
 * lengths as the file is assembled, which is the only fiddly part and the part
 * the test pins.
 */
function buildPdf(
  image: QrBitmap,
  caption: { primary: string; secondary: string; primaryCode: boolean }
): Buffer {
  const qrSide = 360;
  const qrX = (A4_WIDTH_PT - qrSide) / 2;
  const qrY = A4_HEIGHT_PT - 200 - qrSide;

  const isCode = caption.primaryCode;
  const primarySize = isCode ? CODE_SIZE : 20;
  const secondarySize = isCode ? 13 : 11;
  // HELVETICA-BOLD, NOT COURIER. The code was set in Courier-Bold on the
  // reasoning that a monospaced face keeps similar glyphs apart — but the QR
  // alphabet already excludes every pair that argument was about (I, L, O and U
  // are not in it), so the discrimination was buying nothing and the typewriter
  // face read as cramped and informal on a sheet that sits on a restaurant
  // table. A bold grotesque is cleaner at a glance and looks like signage.
  const primaryFont = isCode ? '/F2' : '/F1';

  const primaryX =
    A4_WIDTH_PT / 2 -
    (isCode
      ? halfCodeWidth(caption.primary, primarySize)
      : halfWidth(caption.primary, primarySize));
  const secondaryX = A4_WIDTH_PT / 2 - halfWidth(caption.secondary, secondarySize);

  const content = [
    'q',
    `${qrSide} 0 0 ${qrSide} ${qrX.toFixed(2)} ${qrY.toFixed(2)} cm`,
    '/Im0 Do',
    'Q',
    `BT ${primaryFont} ${primarySize} Tf`,
    // Tc opens the characters up so each is read on its own — the single
    // biggest legibility win on a string nobody can guess from context. Reset
    // to 0 before the tagline, or the spacing leaks into prose and looks broken.
    `${isCode ? CODE_LETTER_SPACING : 0} Tc`,
    `1 0 0 1 ${primaryX.toFixed(2)} ${(qrY - 52).toFixed(2)} Tm`,
    `(${pdfText(caption.primary)}) Tj`,
    'ET',
    '0 Tc',
    'BT /F1 ' + secondarySize + ' Tf',
    `1 0 0 1 ${secondaryX.toFixed(2)} ${(qrY - 84).toFixed(2)} Tm`,
    `(${pdfText(caption.secondary)}) Tj`,
    'ET',
  ].join('\n');

  return assemblePdf([
    Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'),
    Buffer.from('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    Buffer.from(
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${A4_WIDTH_PT} ${A4_HEIGHT_PT}] ` +
        '/Resources << /XObject << /Im0 5 0 R >> /Font << /F1 6 0 R /F2 7 0 R >> >> /Contents 4 0 R >>'
    ),
    contentStreamObject(content),
    imageXObject(image),
    Buffer.from(HELVETICA_OBJECT),
    Buffer.from(HELVETICA_BOLD_OBJECT),
  ]);
}

// ── The service ─────────────────────────────────────────────────────────────

export type QrFormat = 'png' | 'pdf';

export interface RenderedQr {
  body: Buffer;
  contentType: string;
  /** `<slug>-qr.png`. Derived from the catalog name, never from the URL. */
  filename: string;
}

/** ASCII-safe, filesystem-safe, and deterministic. */
function filenameSlug(name: string): string {
  const slug = name
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40);
  // A name that slugifies to nothing (all emoji is a real input) must not
  // produce a file called "-qr.png".
  return slug || 'catalog';
}

/**
 * Renders the QR for a stored public URL.
 *
 * `publicUrl` is passed in by the caller and used verbatim. There is no code
 * path in this module that could produce a different string.
 */
export async function renderCatalogQr(params: {
  publicUrl: string;
  catalogName: string;
  format: QrFormat;
  size?: number;
  /**
   * The printed code, when this sheet is a STANDEE rather than an owner's QR.
   *
   * Its presence is what switches the caption: a standee gets the code big and
   * monospaced with [standeeTagline] under it, because a rep reads those
   * characters aloud and types them. An owner's QR gets the restaurant name and
   * the URL instead — a customer cannot do anything with an 8-character code,
   * but can type a link when the square is smudged.
   */
  standeeCode?: string;
  standeeTagline?: string;
}): Promise<RenderedQr> {
  const size = clampQrSize(params.size);
  const png = await renderPng(params.publicUrl, size);
  const slug = filenameSlug(params.catalogName);

  if (params.format === 'png') {
    return { body: png, contentType: 'image/png', filename: `${slug}-qr.png` };
  }

  // Straight from the matrix — the PNG above is not re-encoded into the PDF at
  // all any more. See qrBitmap1Bit for why a JPEG was the wrong container for
  // an image made entirely of hard edges.
  const bitmap = qrBitmap1Bit(matrixFor(params.publicUrl), PDF_MODULE_SCALE);

  return {
    body: buildPdf(
      bitmap,
      params.standeeCode
        ? {
            primary: params.standeeCode,
            secondary: params.standeeTagline ?? '',
            primaryCode: true,
          }
        : {
            primary: params.catalogName,
            secondary: params.publicUrl,
            primaryCode: false,
          }
    ),
    contentType: 'application/pdf',
    filename: `${slug}-qr.pdf`,
  };
}

/**
 * A SEAM, not a feature: feature 34's "put the business logo in the middle" is
 * still an open question (Q12), and the answer changes the error-correction
 * level it needs. Documented here so the next person adds it in one place
 * instead of threading a flag through four.
 *
 * Whoever implements it: raise QR_ERROR_CORRECTION to 'H' FIRST. Punching a hole
 * in a level-M code destroys more codewords than it can recover, and the result
 * scans on the developer's phone and fails on a customer's.
 */
export const QR_LOGO_SUPPORTED = false;
