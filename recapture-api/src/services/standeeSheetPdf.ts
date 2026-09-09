// src/services/standeeSheetPdf.ts
//
// A WHOLE BATCH of standees on A4, several to a page, as many pages as it takes.
//
// The one-code sheet (`catalogQrService.buildPdf`) is the pilot path: an admin
// renders one, sends it to a rep, the rep prints one square. That does not
// survive contact with a real print run. An admin who has just minted fifty
// codes has to press Download fifty times, tell fifty near-identical files
// apart, and print fifty sheets of paper to get fifty squares. This is the same
// physical object, laid out for the printer instead of for the browser.
//
// ⚠ THE QR IS A FIXED PHYSICAL SIZE AND IS NEVER SCALED TO FIT. STANDEE_QR_INCHES
// (1.67in by default) is the edge the standee artwork was cut for, and a QR
// printed smaller than the distance it is meant to be scanned from is a standee
// that does not work — a failure discovered by a diner at a table, after the
// paper is cut and stood up. So the LAYOUT gives way, never the square: if the
// configured grid cannot hold that many cards, [computeSheetLayout] drops
// columns and rows until it fits. Fewer per page is a cost; a shrunken code is a
// defect.
//
// Everything about the geometry is a setting, for the same reason: this is the
// one part of the system whose correctness is judged by holding a printed sheet
// next to a standee, and that judgement has to be actionable without a code
// change. See `config/env.ts` (STANDEE_SHEET_*).
//
// Written by hand out of `pdfPrimitives`, like every other PDF here — see that
// module's header for why, and for why the xref arithmetic is not duplicated.
import { env } from '@/config/env';
import {
  A4_HEIGHT_PT,
  A4_WIDTH_PT,
  asciiFold,
  assemblePdf,
  codeInkWidth,
  contentStreamObject,
  HELVETICA_BOLD_OBJECT,
  HELVETICA_OBJECT,
  imageXObject,
  matrixFor,
  pdfText,
  proportionalInkWidth,
  PT_PER_INCH,
  qrBitmap1Bit,
} from '@/services/pdfPrimitives';

// ── Fixed geometry ──────────────────────────────────────────────────────────
// These are constants rather than settings because they are TYPOGRAPHY, not
// physical requirements: nobody decides them by measuring a printed sheet. The
// numbers that do get decided that way live in env.

/** Page margin, 0.5in — inside any consumer printer's unprintable edge. */
const PAGE_MARGIN_PT = 36;

/**
 * White space between the cut line and the QR square.
 *
 * The QUIET ZONE IS ALREADY IN THE SQUARE (four modules, see pdfPrimitives), so
 * this is not about scannability — it is the room a pair of scissors needs, and
 * the reason a slightly crooked cut does not take a corner off the code.
 */
const CARD_PADDING_PT = 18;

/** Space between cards, so two cut lines never share a stroke. */
const CARD_GUTTER_PT = 18;

/** The printed code. Smaller than the one-up sheet's 30pt — six to a page. */
const CODE_SIZE = 13;
/** Opens the characters up so each is read on its own. See buildSheetPdf. */
const CODE_LETTER_SPACING = 2.5;
const TAGLINE_SIZE = 8.5;

const GAP_QR_TO_CODE = 12;
const GAP_CODE_TO_TAGLINE = 9;

/** Baseline of the per-page footer, measured from the bottom of the sheet. */
const FOOTER_BASELINE_PT = 24;
const FOOTER_SIZE = 8;

/** Room the footer needs above the bottom margin, so the grid never sits on it. */
const FOOTER_BAND_PT = 12;

/** Hairline cut guides — visible to a person, near-invisible in a photocopy. */
const CUT_LINE_WIDTH = 0.75;
const CUT_LINE_GREY = 0.85;

/** Caption block under the square: the code, then the line saying what this is. */
const CAPTION_HEIGHT_PT =
  GAP_QR_TO_CODE + CODE_SIZE + GAP_CODE_TO_TAGLINE + TAGLINE_SIZE;

// ── Layout ──────────────────────────────────────────────────────────────────

export interface StandeeSheetLayout {
  /** Printed edge of the QR square, in points. Never negotiable. */
  qrSidePt: number;
  /** Device pixels the square is rastered at — `inches × dpi`, rounded up. */
  qrPixels: number;
  columns: number;
  rows: number;
  perPage: number;
  cardWidth: number;
  cardHeight: number;
  /** Bottom-left of the grid block, already centred on the page. */
  originX: number;
  originY: number;
}

/**
 * A card that will not fit on A4 at all — QR_INCHES set past the page.
 *
 * Typed rather than silently shrunk, because shrinking is the one thing this
 * module exists to refuse. The route maps it to the same 409 it uses for other
 * "this deployment is misconfigured" answers.
 */
export class StandeeSheetLayoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'StandeeSheetLayoutError';
  }
}

/**
 * The grid, with the configured columns and rows CLAMPED DOWN to what fits.
 *
 * Reads `env` at call time, not at module load: the same reason
 * `mintQrBatchSchema` checks QR_BATCH_MAX_SIZE in a refine. A value captured at
 * first import cannot be changed by a test or a config reload.
 */
export function computeSheetLayout(): StandeeSheetLayout {
  const qrSidePt = env.STANDEE_SHEET_QR_INCHES * PT_PER_INCH;
  const qrPixels = Math.ceil(env.STANDEE_SHEET_QR_INCHES * env.STANDEE_SHEET_QR_DPI);

  const cardWidth = qrSidePt + CARD_PADDING_PT * 2;
  const cardHeight = CARD_PADDING_PT * 2 + qrSidePt + CAPTION_HEIGHT_PT;

  const usableWidth = A4_WIDTH_PT - PAGE_MARGIN_PT * 2;
  const usableHeight = A4_HEIGHT_PT - PAGE_MARGIN_PT * 2 - FOOTER_BAND_PT;

  // `+ gutter` on both sides of the divide because n cards carry n-1 gutters:
  // pretending every card trails one makes the fit a plain division.
  const fitColumns = Math.floor(
    (usableWidth + CARD_GUTTER_PT) / (cardWidth + CARD_GUTTER_PT)
  );
  const fitRows = Math.floor(
    (usableHeight + CARD_GUTTER_PT) / (cardHeight + CARD_GUTTER_PT)
  );

  if (fitColumns < 1 || fitRows < 1) {
    throw new StandeeSheetLayoutError(
      `A ${env.STANDEE_SHEET_QR_INCHES}in standee does not fit on A4. ` +
        'Lower STANDEE_SHEET_QR_INCHES.'
    );
  }

  const columns = Math.min(env.STANDEE_SHEET_COLUMNS, fitColumns);
  const rows = Math.min(env.STANDEE_SHEET_ROWS, fitRows);

  const gridWidth = columns * cardWidth + (columns - 1) * CARD_GUTTER_PT;
  const gridHeight = rows * cardHeight + (rows - 1) * CARD_GUTTER_PT;

  // CENTRED, not flush to the margin. A part-full last page then looks like a
  // deliberately short sheet rather than a misprint, and the slack ends up
  // shared between both edges where the scissors want it.
  return {
    qrSidePt,
    qrPixels,
    columns,
    rows,
    perPage: columns * rows,
    cardWidth,
    cardHeight,
    originX: (A4_WIDTH_PT - gridWidth) / 2,
    originY:
      PAGE_MARGIN_PT + FOOTER_BAND_PT + (usableHeight - gridHeight) / 2,
  };
}

// ── The sheet ───────────────────────────────────────────────────────────────

export interface StandeeSheetItem {
  /** The eight printed characters. */
  code: string;
  /** EXACTLY what the square encodes — composed by `resolverUrlFor`, verbatim. */
  url: string;
}

/**
 * One card's drawing operators, positioned at its bottom-left corner.
 *
 * `imageName` is the page-local resource (`/Im0`, `/Im1`, …) — names are scoped
 * to the page's own resource dictionary, so card 0 of every page is `/Im0` and
 * only the OBJECT number behind it differs.
 */
function drawCard(
  item: StandeeSheetItem,
  tagline: string,
  layout: StandeeSheetLayout,
  imageName: string,
  x: number,
  y: number
): string {
  const qrX = x + CARD_PADDING_PT;
  const qrY = y + layout.cardHeight - CARD_PADDING_PT - layout.qrSidePt;

  const codeBaseline = qrY - GAP_QR_TO_CODE - CODE_SIZE;
  const taglineBaseline = codeBaseline - GAP_CODE_TO_TAGLINE - TAGLINE_SIZE;

  // Folded BEFORE it is measured, not just before it is written: a string that
  // changes width on the way to the page is one that comes out off-centre.
  const code = asciiFold(item.code);
  const line = asciiFold(tagline);

  const centre = x + layout.cardWidth / 2;
  const codeX = centre - codeInkWidth(code, CODE_SIZE, CODE_LETTER_SPACING) / 2;
  const taglineX = centre - proportionalInkWidth(line, TAGLINE_SIZE) / 2;

  return [
    // The cut guide. Drawn FIRST so the square and the text sit over it rather
    // than a stroke landing across a module.
    'q',
    `${CUT_LINE_WIDTH} w`,
    `${CUT_LINE_GREY} ${CUT_LINE_GREY} ${CUT_LINE_GREY} RG`,
    `${x.toFixed(2)} ${y.toFixed(2)} ${layout.cardWidth.toFixed(2)} ${layout.cardHeight.toFixed(2)} re`,
    'S',
    'Q',
    'q',
    // The `cm` matrix IS the physical size: a unit image scaled to qrSidePt
    // points on both axes. Nothing downstream can stretch it — the width and
    // the height are the same number by construction.
    `${layout.qrSidePt.toFixed(2)} 0 0 ${layout.qrSidePt.toFixed(2)} ${qrX.toFixed(2)} ${qrY.toFixed(2)} cm`,
    `${imageName} Do`,
    'Q',
    // Tc opens the characters up so each is read on its own — the single biggest
    // legibility win on a string nobody can guess from context. Reset to 0
    // before the tagline, or the spacing leaks into prose and looks broken.
    `BT /F2 ${CODE_SIZE} Tf`,
    `${CODE_LETTER_SPACING} Tc`,
    `1 0 0 1 ${codeX.toFixed(2)} ${codeBaseline.toFixed(2)} Tm`,
    `(${pdfText(code)}) Tj`,
    'ET',
    '0 Tc',
    `BT /F1 ${TAGLINE_SIZE} Tf`,
    '0.35 g',
    `1 0 0 1 ${taglineX.toFixed(2)} ${taglineBaseline.toFixed(2)} Tm`,
    `(${pdfText(line)}) Tj`,
    'ET',
    '0 g',
  ].join('\n');
}

/** The line along the bottom of every page, so a dropped sheet can be refiled. */
function drawFooter(text: string): string {
  const line = asciiFold(text);
  const x = A4_WIDTH_PT / 2 - proportionalInkWidth(line, FOOTER_SIZE) / 2;
  return [
    `BT /F1 ${FOOTER_SIZE} Tf`,
    '0.45 g',
    `1 0 0 1 ${x.toFixed(2)} ${FOOTER_BASELINE_PT} Tm`,
    `(${pdfText(line)}) Tj`,
    'ET',
    '0 g',
  ].join('\n');
}

/**
 * The whole batch as a multi-page A4 PDF.
 *
 * OBJECT NUMBERING, which is the only structurally fiddly part: 1 catalog,
 * 2 pages, 3 and 4 the two base fonts, then a page/contents PAIR per page, then
 * every image after that. Fonts come before the pages so their numbers are
 * fixed constants a page dictionary can name; images come last so the first
 * image's number is a function of the page count, which is known before any
 * bitmap is built. Nothing here has to be renumbered when a batch gets longer.
 *
 * Deterministic, like every other PDF in this codebase: the same batch renders
 * byte-identical bytes twice, because nothing timestamps and `imageXObject`
 * deflates with fixed settings.
 */
export function buildStandeeSheetPdf(params: {
  items: readonly StandeeSheetItem[];
  /** The line printed under every code. */
  tagline: string;
  /** The batch, named on every page's footer. */
  label: string;
}): Buffer {
  const { items, tagline, label } = params;
  const layout = computeSheetLayout();
  const pageCount = Math.max(1, Math.ceil(items.length / layout.perPage));

  // 1 catalog, 2 pages, 3 /F1, 4 /F2; then two objects per page; then images.
  const FIRST_PAGE_OBJ = 5;
  const firstImageObj = FIRST_PAGE_OBJ + pageCount * 2;

  const pageObjects: Buffer[] = [];
  const contentObjects: Buffer[] = [];

  for (let page = 0; page < pageCount; page++) {
    const start = page * layout.perPage;
    const onPage = items.slice(start, start + layout.perPage);

    const ops: string[] = [];
    const resources: string[] = [];

    onPage.forEach((item, slot) => {
      const column = slot % layout.columns;
      // Filled left to right, TOP row first — the order a person reads and the
      // order `listBatchCodes` and the vendor CSV emit, so row 3 of the sheet is
      // row 3 of the list.
      const row = Math.floor(slot / layout.columns);

      const x = layout.originX + column * (layout.cardWidth + CARD_GUTTER_PT);
      const y =
        layout.originY +
        (layout.rows - 1 - row) * (layout.cardHeight + CARD_GUTTER_PT);

      ops.push(drawCard(item, tagline, layout, `/Im${slot}`, x, y));
      resources.push(`/Im${slot} ${firstImageObj + start + slot} 0 R`);
    });

    // A pipe rather than a dash: labels carry dashes of their own (the house
    // shape is "Vendor A - Oct 2026, run 3"), and a separator that looks like
    // part of the name it separates is not one.
    ops.push(
      drawFooter(
        `${label}   |   Page ${page + 1} of ${pageCount}   |   ${items.length} standees`
      )
    );

    const contentsObj = FIRST_PAGE_OBJ + page * 2 + 1;
    pageObjects.push(
      Buffer.from(
        `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${A4_WIDTH_PT} ${A4_HEIGHT_PT}] ` +
          `/Resources << /XObject << ${resources.join(' ')} >> ` +
          `/Font << /F1 3 0 R /F2 4 0 R >> >> /Contents ${contentsObj} 0 R >>`
      )
    );
    contentObjects.push(contentStreamObject(ops.join('\n')));
  }

  const kids = Array.from(
    { length: pageCount },
    (_, page) => `${FIRST_PAGE_OBJ + page * 2} 0 R`
  ).join(' ');

  const objects: Buffer[] = [
    Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'),
    Buffer.from(`<< /Type /Pages /Kids [${kids}] /Count ${pageCount} >>`),
    Buffer.from(HELVETICA_OBJECT),
    Buffer.from(HELVETICA_BOLD_OBJECT),
  ];
  for (let page = 0; page < pageCount; page++) {
    objects.push(pageObjects[page]!, contentObjects[page]!);
  }

  // Built one at a time and immediately compressed, so only ONE raw bitmap is
  // resident at a time. At 300dpi a card's raw buffer is tens of kilobytes and
  // its Flate form is about one — holding five hundred of the former would be
  // the difference between a large response and an out-of-memory.
  for (const item of items) {
    const matrix = matrixFor(item.url);
    // The scale follows FROM the physical size and the DPI setting rather than
    // being a tuning constant: enough whole pixels per module to clear
    // `qrPixels` across the square. Whole, because a fractional scale makes some
    // modules a pixel fatter than others — exactly the asymmetry a scanner's
    // grid detection has to fight.
    const scale = Math.max(1, Math.ceil(layout.qrPixels / matrix.size));
    objects.push(imageXObject(qrBitmap1Bit(matrix, scale)));
  }

  return assemblePdf(objects);
}
