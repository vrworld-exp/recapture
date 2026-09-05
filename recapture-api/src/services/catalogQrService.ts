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
//   • the PDF is written BY HAND below. A single page holding one image is a
//     few hundred bytes of syntax, and a PDF library would be a second
//     dependency for it — plus every one worth using stamps a CreationDate,
//     which would break byte-identity on its own.
import QRCode from 'qrcode';
import sharp from 'sharp';

/** Fixed rendering parameters. Changing any of these changes every issued code. */
export const QR_ERROR_CORRECTION = 'M' as const;
/** Modules of white margin. Four is the spec's minimum for reliable scanning. */
export const QR_QUIET_ZONE = 4;
export const QR_DEFAULT_SIZE = 1024;
export const QR_MIN_SIZE = 256;
export const QR_MAX_SIZE = 2048;

/** Clamps rather than errors — a size out of range is a preference, not a fault. */
export function clampQrSize(requested: number | undefined): number {
  if (requested === undefined || !Number.isFinite(requested)) return QR_DEFAULT_SIZE;
  return Math.min(QR_MAX_SIZE, Math.max(QR_MIN_SIZE, Math.round(requested)));
}

/**
 * The QR module matrix for [text], quiet zone included.
 *
 * `QRCode.create` is the encoder and nothing more: it returns the bit matrix and
 * leaves rendering to us. That separation is what lets the PNG be produced by
 * sharp — one image library in the tree — and what makes the output a pure
 * function of the text.
 */
function matrixFor(text: string): { size: number; isDark: (x: number, y: number) => boolean } {
  const qr = QRCode.create(text, { errorCorrectionLevel: QR_ERROR_CORRECTION });
  const inner = qr.modules.size;
  const size = inner + QR_QUIET_ZONE * 2;

  return {
    size,
    isDark(x, y) {
      const mx = x - QR_QUIET_ZONE;
      const my = y - QR_QUIET_ZONE;
      if (mx < 0 || my < 0 || mx >= inner || my >= inner) return false;
      return Boolean(qr.modules.get(mx, my));
    },
  };
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

const A4_WIDTH_PT = 595.28;
const A4_HEIGHT_PT = 841.89;

/** PDF strings escape exactly three characters. */
function pdfText(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
}

/**
 * A one-page A4 PDF: the code centred, the catalog name beneath it, the URL
 * beneath that.
 *
 * THE URL IS PRINTED AS TEXT ON PURPOSE. A smudged, creased or badly-photocopied
 * QR is unreadable and gives a customer nothing to do about it; the same sheet
 * with the link written out is still usable. It costs one line of content stream.
 *
 * Written by hand — see the file header. The structure is the minimum a
 * conforming reader needs: catalog, pages, one page, one content stream, one
 * embedded image XObject, one Type1 base font (Helvetica is one of the fourteen
 * every reader must provide, so nothing is embedded and nothing is licensed).
 * The xref offsets are computed from the actual byte lengths as the file is
 * assembled, which is the only part that is fiddly and the part the test pins.
 */
function buildPdf(png: Buffer, pngSize: number, title: string, url: string): Buffer {
  const qrSide = 360;
  const qrX = (A4_WIDTH_PT - qrSide) / 2;
  const qrY = A4_HEIGHT_PT - 200 - qrSide;

  const content = [
    'q',
    `${qrSide} 0 0 ${qrSide} ${qrX.toFixed(2)} ${qrY.toFixed(2)} cm`,
    '/Im0 Do',
    'Q',
    'BT /F1 20 Tf',
    `1 0 0 1 ${(A4_WIDTH_PT / 2 - Math.min(title.length * 5.6, 240)).toFixed(2)} ${(qrY - 48).toFixed(2)} Tm`,
    `(${pdfText(title)}) Tj`,
    'ET',
    'BT /F1 11 Tf',
    `1 0 0 1 ${(A4_WIDTH_PT / 2 - Math.min(url.length * 3.05, 260)).toFixed(2)} ${(qrY - 76).toFixed(2)} Tm`,
    `(${pdfText(url)}) Tj`,
    'ET',
  ].join('\n');

  const objects: Buffer[] = [
    Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'),
    Buffer.from('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    Buffer.from(
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${A4_WIDTH_PT} ${A4_HEIGHT_PT}] ` +
        '/Resources << /XObject << /Im0 5 0 R >> /Font << /F1 6 0 R >> >> /Contents 4 0 R >>'
    ),
    Buffer.concat([
      Buffer.from(`<< /Length ${Buffer.byteLength(content)} >>\nstream\n`),
      Buffer.from(content),
      Buffer.from('\nendstream'),
    ]),
    Buffer.concat([
      Buffer.from(
        `<< /Type /XObject /Subtype /Image /Width ${pngSize} /Height ${pngSize} ` +
          `/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Length ${png.byteLength} >>\nstream\n`
      ),
      png,
      Buffer.from('\nendstream'),
    ]),
    Buffer.from('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
  ];

  const header = Buffer.from('%PDF-1.4\n');
  const chunks: Buffer[] = [header];
  const offsets: number[] = [];
  let cursor = header.byteLength;

  objects.forEach((body, index) => {
    const chunk = Buffer.concat([
      Buffer.from(`${index + 1} 0 obj\n`),
      body,
      Buffer.from('\nendobj\n'),
    ]);
    offsets.push(cursor);
    chunks.push(chunk);
    cursor += chunk.byteLength;
  });

  const xref = [
    'xref',
    `0 ${objects.length + 1}`,
    '0000000000 65535 f ',
    ...offsets.map((offset) => `${String(offset).padStart(10, '0')} 00000 n `),
    'trailer',
    `<< /Size ${objects.length + 1} /Root 1 0 R >>`,
    'startxref',
    String(cursor),
    '%%EOF',
    // No /Info dictionary, and therefore no CreationDate — the one thing a PDF
    // library would add that would break byte-identity between two renders.
  ].join('\n');

  chunks.push(Buffer.from(xref));
  return Buffer.concat(chunks);
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
}): Promise<RenderedQr> {
  const size = clampQrSize(params.size);
  const png = await renderPng(params.publicUrl, size);
  const slug = filenameSlug(params.catalogName);

  if (params.format === 'png') {
    return { body: png, contentType: 'image/png', filename: `${slug}-qr.png` };
  }

  // The PDF embeds a JPEG rather than the PNG: /DCTDecode is the only lossless-
  // enough image filter every reader supports without also supporting
  // /FlateDecode-with-predictor, and re-encoding here keeps the writer above
  // small. Quality 100 on a pure black-and-white image is visually exact.
  const matrix = matrixFor(params.publicUrl);
  const scale = Math.max(1, Math.floor(size / matrix.size));
  const jpegSize = matrix.size * scale;
  const jpeg = await sharp(png).jpeg({ quality: 100, chromaSubsampling: '4:4:4' }).toBuffer();

  return {
    body: buildPdf(jpeg, jpegSize, params.catalogName, params.publicUrl),
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
