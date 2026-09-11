// src/services/pdfPrimitives.ts
//
// The parts of "draw a QR code into a PDF by hand" that TWO sheet layouts now
// need, in one place.
//
// It exists because a second layout appeared. `catalogQrService` has written its
// own PDF since the beginning — see that file's header for why a library was
// refused (a second image dependency, plus a `CreationDate` stamp that would
// break byte-identity between two renders of the same code). That argument still
// holds; what stopped holding is that one file could own the whole job.
// `standeeSheetPdf` lays a GRID of fixed-size codes across as many A4 pages as a
// batch needs, and it shares every low-level concern with the one-code sheet:
// the QR matrix, the 1-bit packing, string escaping, the font metrics used to
// centre a line, and the xref arithmetic.
//
// THE XREF ARITHMETIC IS THE REASON THIS IS SHARED AND NOT COPIED. Every offset
// in the table must be the exact byte position of its object, computed from the
// lengths of everything written before it. It is the one part of a hand-written
// PDF that is genuinely easy to get wrong, and a second hand-maintained copy is
// a second chance to get it wrong in a file nobody opens until it is at a print
// shop. `assemblePdf` is the only place that counts bytes.
//
// Nothing here knows what a standee, a catalog or a batch is. It takes text and
// numbers and returns bytes.
import QRCode from 'qrcode';
import zlib from 'zlib';

// ── Page geometry ───────────────────────────────────────────────────────────

export const A4_WIDTH_PT = 595.28;
export const A4_HEIGHT_PT = 841.89;

/** PDF's user-space unit is 1/72 inch, which is the whole of the DPI story. */
export const PT_PER_INCH = 72;

// ── The QR matrix ───────────────────────────────────────────────────────────

/** Fixed rendering parameters. Changing any of these changes every issued code. */
export const QR_ERROR_CORRECTION = 'M' as const;
/**
 * The level a code carries when the MARK is punched into its middle.
 *
 * ⚠ 'H' IS NOT A PREFERENCE, IT IS THE PRICE OF THE HOLE. Level H can rebuild
 * up to 30% of its codewords; the well below takes out under a tenth, and the
 * rest is the margin a printed square needs for a thumb, a coffee ring and a
 * phone camera at an angle. Punching the same hole in a level-M code (15%)
 * scans on the developer's phone and fails on a customer's, which is the worst
 * kind of bug to have in something already glued to a table.
 */
export const QR_LOGO_ERROR_CORRECTION = 'H' as const;
/** Modules of white margin. Four is the spec's minimum for reliable scanning. */
export const QR_QUIET_ZONE = 4;

/**
 * The white well the mark sits in, as a fraction of the CODE'S OWN side (quiet
 * zone excluded), before it is snapped to a whole odd number of modules.
 *
 * Three-tenths puts the drawn tile at about a fifth of the printed square,
 * which is the proportion the payment apps settled on — the square reads as a
 * QR with a badge in it, not as a logo with some dots around it — and it costs
 * under 9% of the modules at every version a URL produces (a quarter looked
 * timid next to a Google Pay code on the same table; it was tried). Odd, so
 * the well is centred on the grid: the code's side is always odd (21 + 4n),
 * and an odd well leaves the same whole number of modules on each side of it.
 */
export const QR_LOGO_WELL_FRACTION = 0.3;

/**
 * Modules of white between the well's edge and the artwork.
 *
 * The same unit as the quiet zone and for the same reason: a scanner locating
 * modules wants the dark artwork separated from the dark modules by a stripe
 * of clean white, and one module is the stripe it already knows how to read
 * past. It is also what makes the mark look badged rather than pasted on.
 */
export const QR_LOGO_WELL_PADDING = 1;

/** A square of modules, top-left origin, quiet zone included in the coordinates. */
export interface ModuleSquare {
  x: number;
  y: number;
  side: number;
}

export interface QrMatrix {
  /** Side in MODULES, quiet zone included. */
  size: number;
  isDark(x: number, y: number): boolean;
  /**
   * The white well carved for the mark, when the matrix was built with one.
   * Modules inside it always read light; the artwork is drawn over it later.
   */
  well?: ModuleSquare;
}

/**
 * The QR module matrix for [text], quiet zone included.
 *
 * `QRCode.create` is the encoder and nothing more: it returns the bit matrix and
 * leaves rendering to us. That separation is what lets the PNG be produced by
 * sharp — one image library in the tree — and what makes the output a pure
 * function of the text.
 *
 * With `logoWell` the code is encoded at [QR_LOGO_ERROR_CORRECTION] and a
 * centred square of modules is CLEARED in the matrix itself, not merely painted
 * over downstream. That is what makes the hole part of every rendering — the
 * PNG, the one-up PDF and the batch sheet all raster the same matrix — and it
 * is what lets a test decode the embedded bitmap and prove the holed code still
 * reads, rather than proving that a bitmap nobody prints reads.
 */
export function matrixFor(text: string, options: { logoWell?: boolean } = {}): QrMatrix {
  const qr = QRCode.create(text, {
    errorCorrectionLevel: options.logoWell ? QR_LOGO_ERROR_CORRECTION : QR_ERROR_CORRECTION,
  });
  const inner = qr.modules.size;
  const size = inner + QR_QUIET_ZONE * 2;

  const well = options.logoWell ? wellFor(inner) : undefined;

  return {
    size,
    well,
    isDark(x, y) {
      if (
        well &&
        x >= well.x &&
        y >= well.y &&
        x < well.x + well.side &&
        y < well.y + well.side
      ) {
        return false;
      }
      const mx = x - QR_QUIET_ZONE;
      const my = y - QR_QUIET_ZONE;
      if (mx < 0 || my < 0 || mx >= inner || my >= inner) return false;
      return Boolean(qr.modules.get(mx, my));
    },
  };
}

/** The well for a code of `inner` modules a side: the nearest odd size, centred. */
function wellFor(inner: number): ModuleSquare {
  const wanted = inner * QR_LOGO_WELL_FRACTION;
  // Nearest ODD integer to `wanted`. `inner` is odd by the QR spec, so an odd
  // well leaves equal whole-module margins on both sides and lands on the grid.
  const side = 2 * Math.round((wanted - 1) / 2) + 1;
  const offset = QR_QUIET_ZONE + (inner - side) / 2;
  return { x: offset, y: offset, side };
}

/**
 * Where the ARTWORK goes: the well, inset by [QR_LOGO_WELL_PADDING] on each side.
 *
 * Throws on a matrix built without a well rather than inventing a place — a
 * mark drawn over live modules is exactly what the well exists to prevent.
 */
export function logoBox(matrix: QrMatrix): ModuleSquare {
  if (!matrix.well) {
    throw new Error('logoBox: matrix was built without a logo well');
  }
  const { x, y, side } = matrix.well;
  const pad = QR_LOGO_WELL_PADDING;
  return { x: x + pad, y: y + pad, side: side - pad * 2 };
}

export interface QrBitmap {
  data: Buffer;
  /** Side in PIXELS. */
  side: number;
}

/**
 * Packs the matrix as a 1-BIT bitmap, `scale` device pixels per module.
 *
 * ⚠ ONE BIT, NOT EIGHT, AND FLATE, NOT JPEG. The PDF used to embed the greyscale
 * PNG re-encoded as a JPEG (`/DCTDecode`), on the reasoning that every reader
 * supports it. Every reader does — and JPEG is a frequency-domain codec applied
 * to the worst possible input: an image made entirely of hard black/white edges.
 * Even at quality 100 it rings, so each module got a grey halo and the printed
 * sheet looked washed out and fuzzy rather than like a QR code.
 *
 * A 1-bit image cannot be anything but pure black and pure white — there is no
 * value between 0 and 1 to be wrong — and Flate is lossless, so what is printed
 * is exactly the matrix. It is also far smaller: this whole image compresses to
 * a few hundred bytes, against tens of kilobytes of JPEG.
 *
 * The upscale is here rather than left to the viewer because `/Interpolate` is
 * only a HINT — a reader is free to smooth anyway, and a smoothed QR is one a
 * phone has to work harder to read. Blowing each module up to a block of
 * identical pixels means there is nothing left to smooth.
 */
export function qrBitmap1Bit(matrix: QrMatrix, scale: number): QrBitmap {
  const side = matrix.size * scale;
  const rowBytes = Math.ceil(side / 8);
  // 0xff = every bit set = every pixel WHITE. DeviceGray 1-bit reads 0 as black
  // and 1 as white, so dark modules clear their bit below.
  const data = Buffer.alloc(rowBytes * side, 0xff);

  for (let y = 0; y < side; y++) {
    const my = (y / scale) | 0;
    for (let x = 0; x < side; x++) {
      if (matrix.isDark((x / scale) | 0, my)) {
        data[y * rowBytes + (x >> 3)]! &= ~(0x80 >> (x & 7));
      }
    }
  }

  return { data, side };
}

// ── Text ────────────────────────────────────────────────────────────────────

/** PDF strings escape exactly three characters. */
export function pdfText(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
}

/**
 * Typographic characters a person actually types, and their ASCII stand-ins.
 *
 * The non-breaking space is written as an escape rather than pasted in: a
 * literal one is invisible in review and in a diff, and it is the one character
 * here that a linter (rightly) refuses to let through as itself.
 */
const ASCII_SUBSTITUTES: Readonly<Record<string, string>> = {
  '—': '-', // em dash
  '–': '-', // en dash
  '−': '-', // minus sign
  '‘': "'", // left single quote
  '’': "'", // right single quote / apostrophe
  '“': '"', // left double quote
  '”': '"', // right double quote
  '·': '-', // middle dot
  '•': '-', // bullet
  '…': '...', // ellipsis
  '\u00a0': ' ', // non-breaking space
};

/**
 * Folds a caption to ASCII, because THE BASE-14 FONTS ARE SINGLE-BYTE.
 *
 * ⚠ THIS IS NOT COSMETIC. Nothing here embeds a font or declares an /Encoding,
 * so a reader interprets a string one byte per glyph. Writing a JavaScript
 * string into a content stream encodes it as UTF-8, so the moment a caption
 * contains anything above U+007F the reader draws one glyph per BYTE — an em
 * dash comes out as three characters of mojibake.
 *
 * It is not a hypothetical: the batch label is free text, and the house shape
 * the mint dialog suggests — "Vendor A — Oct 2026, run 3" — contains an em dash.
 * The first real batch would have printed mojibake across the footer of every
 * page.
 *
 * Substitution walks the string against [ASCII_SUBSTITUTES] rather than driving
 * a regex character class. The class version worked and was a standing trap:
 * every new entry in the map had to be added to the class by hand, and a key
 * that was in one and not the other silently stopped being folded. There is now
 * one list.
 *
 * Whatever survives that is put through NFKD and stripped of combining marks, so
 * `Café` reads `Cafe`; anything still unmappable becomes `?` rather than being
 * dropped. Dropping would let two differently-named batches print identical
 * footers, which defeats the only thing the footer is for.
 *
 * Codes never need this — the QR alphabet is uppercase ASCII and digits — but
 * they are folded anyway rather than the caller having to know which strings are
 * safe.
 */
export function asciiFold(value: string): string {
  return [...value]
    .map((ch) => ASCII_SUBSTITUTES[ch] ?? ch)
    .join('')
    .normalize('NFKD')
    .replace(/\p{Diacritic}/gu, '')
    .replace(/[^\x20-\x7e]/g, '?');
}

/**
 * Helvetica-Bold advance widths, in 1/1000 em, for exactly the glyphs a code can
 * contain — the QR alphabet is uppercase and digits only.
 *
 * From the Adobe AFM metrics for one of the base-14 fonts, so these are the real
 * numbers the reader will use, not estimates. A table rather than an average
 * because the range here is wide (a `W` is 944 against a `J` at 556): averaging
 * puts an eight-character code visibly off-centre.
 */
export const HELVETICA_BOLD_WIDTHS: Readonly<Record<string, number>> = {
  '0': 556, '1': 556, '2': 556, '3': 556, '4': 556,
  '5': 556, '6': 556, '7': 556, '8': 556, '9': 556,
  A: 722, B: 722, C: 722, D: 722, E: 667, F: 611, G: 778, H: 722,
  J: 556, K: 722, M: 833, N: 722, P: 667, Q: 778, R: 722, S: 667,
  T: 611, V: 667, W: 944, X: 667, Y: 667, Z: 611,
};

/**
 * The exact ink width of a printed code, for centring it by hand.
 *
 * Exact, because every glyph a code can contain is in the table above and the
 * letter spacing is passed in. `n - 1` gaps, not `n`: PDF's `Tc` adds space
 * after every glyph including the last, but that trailing gap is not ink and
 * counting it would shift the code left by half a space.
 */
export function codeInkWidth(code: string, fontSize: number, letterSpacing: number): number {
  const glyphs = [...code].reduce(
    (total, ch) => total + (HELVETICA_BOLD_WIDTHS[ch] ?? 600),
    0
  );
  return (glyphs / 1000) * fontSize + Math.max(0, code.length - 1) * letterSpacing;
}

/**
 * Approximate ink width of a proportional line, for centring prose.
 *
 * An average is fine here and not for a code: this is a line a reader glances
 * at, where a few points either way is invisible.
 */
export function proportionalInkWidth(text: string, fontSize: number): number {
  return text.length * fontSize * 0.52;
}

// ── Objects ─────────────────────────────────────────────────────────────────

/** `<< /Length n >> stream … endstream` for a page's drawing operators. */
export function contentStreamObject(content: string): Buffer {
  return Buffer.concat([
    Buffer.from(`<< /Length ${Buffer.byteLength(content)} >>\nstream\n`),
    Buffer.from(content),
    Buffer.from('\nendstream'),
  ]);
}

/**
 * One 1-bit image XObject, Flate-compressed.
 *
 * Deterministic: zlib.deflateSync with fixed settings gives the same bytes for
 * the same input, which is what keeps two renders of one code byte-identical.
 */
export function imageXObject(image: QrBitmap): Buffer {
  const compressed = zlib.deflateSync(image.data, { level: 9 });
  return Buffer.concat([
    Buffer.from(
      `<< /Type /XObject /Subtype /Image /Width ${image.side} /Height ${image.side} ` +
        '/ColorSpace /DeviceGray /BitsPerComponent 1 /Interpolate false ' +
        `/Filter /FlateDecode /Length ${compressed.byteLength} >>\nstream\n`
    ),
    compressed,
    Buffer.from('\nendstream'),
  ]);
}

export interface RgbBitmap {
  /** Packed 8-bit RGB, three bytes a pixel, no alpha. */
  data: Buffer;
  /** Side in PIXELS. */
  side: number;
}

/**
 * One 8-bit RGB image XObject, Flate-compressed — the container for the MARK.
 *
 * Flate and not DCT for the same reason the code itself is: the mark is flat
 * colour with hard edges, and a JPEG would put a halo round every one of them.
 * It is heavier than a JPEG — tens of kilobytes rather than a few — but there
 * is exactly ONE of these per file however many cards are on it, because every
 * card's content stream names the same object.
 *
 * `/Interpolate true`, the opposite of the QR's setting and on purpose: the
 * artwork is drawn at a fraction of an inch from a few hundred pixels, and a
 * reader that smooths it is doing the right thing, where a reader that smooths
 * a module edge is not.
 */
export function rgbImageXObject(image: RgbBitmap): Buffer {
  const compressed = zlib.deflateSync(image.data, { level: 9 });
  return Buffer.concat([
    Buffer.from(
      `<< /Type /XObject /Subtype /Image /Width ${image.side} /Height ${image.side} ` +
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Interpolate true ' +
        `/Filter /FlateDecode /Length ${compressed.byteLength} >>\nstream\n`
    ),
    compressed,
    Buffer.from('\nendstream'),
  ]);
}

/**
 * Corner radius of the drawn mark, as a fraction of its side.
 *
 * A fifth is roughly what a launcher icon gets, which is what this artwork is;
 * square corners read as a sticker, a circle would crop the wordmark.
 */
export const QR_LOGO_CORNER_RADIUS = 0.2;

/** Bézier control-point distance for a quarter circle, as a fraction of the radius. */
const KAPPA = 0.5523;

/**
 * A rounded square as PDF path operators, bottom-left at (x, y).
 *
 * Four lines and four quarter-circle Béziers, closed. Emitted without a
 * painting operator so the caller decides whether it is stroked, filled or —
 * the use here — made the clip path.
 */
export function roundedSquarePath(x: number, y: number, side: number, radius: number): string {
  const r = Math.min(radius, side / 2);
  const k = r * KAPPA;
  const x1 = x + side;
  const y1 = y + side;
  const f = (n: number): string => n.toFixed(2);
  return [
    `${f(x + r)} ${f(y)} m`,
    `${f(x1 - r)} ${f(y)} l`,
    `${f(x1 - r + k)} ${f(y)} ${f(x1)} ${f(y + r - k)} ${f(x1)} ${f(y + r)} c`,
    `${f(x1)} ${f(y1 - r)} l`,
    `${f(x1)} ${f(y1 - r + k)} ${f(x1 - r + k)} ${f(y1)} ${f(x1 - r)} ${f(y1)} c`,
    `${f(x + r)} ${f(y1)} l`,
    `${f(x + r - k)} ${f(y1)} ${f(x)} ${f(y1 - r + k)} ${f(x)} ${f(y1 - r)} c`,
    `${f(x)} ${f(y + r)} l`,
    `${f(x)} ${f(y + r - k)} ${f(x + r - k)} ${f(y)} ${f(x + r)} ${f(y)} c`,
    'h',
  ].join('\n');
}

/**
 * The operators that draw the MARK into a code's well, for a code placed with
 * its bottom-left at (qrX, qrY) and `qrSidePt` points a side.
 *
 * ONE function for both layouts, so a standee cut off a batch sheet carries the
 * mark at exactly the proportion a one-up sheet does. The well is in module
 * units on the matrix; this is where they become points, and the ONLY place
 * the y axis is flipped — the matrix counts rows from the top, PDF user space
 * counts from the bottom.
 *
 * Drawn after the code so it sits over the (already white) well, clipped to a
 * rounded square, and scaled with an equal-axis `cm` like the code itself so
 * nothing downstream can stretch it. `imageName` is the page-local resource
 * the caller registered the RGB XObject under.
 */
export function logoOperators(
  matrix: QrMatrix,
  qrX: number,
  qrY: number,
  qrSidePt: number,
  imageName: string
): string {
  const box = logoBox(matrix);
  const modulePt = qrSidePt / matrix.size;
  const side = box.side * modulePt;
  const x = qrX + box.x * modulePt;
  const y = qrY + qrSidePt - (box.y + box.side) * modulePt;

  return [
    'q',
    roundedSquarePath(x, y, side, side * QR_LOGO_CORNER_RADIUS),
    'W n',
    `${side.toFixed(2)} 0 0 ${side.toFixed(2)} ${x.toFixed(2)} ${y.toFixed(2)} cm`,
    `${imageName} Do`,
    'Q',
  ].join('\n');
}

/**
 * Helvetica and Helvetica-Bold are two of the fourteen fonts every conforming
 * reader must provide, so nothing is embedded and nothing is licensed.
 */
export const HELVETICA_OBJECT = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>';
export const HELVETICA_BOLD_OBJECT =
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>';

/**
 * Wraps `objects` (1-indexed, in order) in a PDF file with a correct xref table.
 *
 * The offsets are computed from the ACTUAL byte lengths as the file is
 * assembled, which is the only fiddly part of writing a PDF by hand and the part
 * `tests/catalog-qr.test.ts` pins by walking the table back to its objects.
 *
 * No /Info dictionary, and therefore no CreationDate — the one thing a PDF
 * library would add that would break byte-identity between two renders.
 */
export function assemblePdf(objects: readonly Buffer[]): Buffer {
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
  ].join('\n');

  chunks.push(Buffer.from(xref));
  return Buffer.concat(chunks);
}
