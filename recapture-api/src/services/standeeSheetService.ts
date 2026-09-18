// src/services/standeeSheetService.ts
//
// THE one composer for a printable standee sheet.
//
// It exists because there are now TWO callers. `GET /admin/qr-codes/:code/qr`
// was the pilot path — an admin renders a sheet and sends it to a rep — and
// `GET /rep/standees/:code/qr` is the same sheet fetched by the rep who was
// handed the code, without the admin in the middle. A rep printing a standee
// and an admin printing the same standee must produce the same physical object;
// the only way to guarantee that is for one function to decide what is on it.
//
// The tagline used to live as a `const` in routes/admin.ts with a comment
// saying it was there "so the sheet cannot start saying two different things if
// a second caller ever renders one". This IS that second caller, so the
// constant moved here rather than being copied.
//
// Knows nothing about WHO may render a sheet. Both routes authorize first and
// call this with a record they have already decided the caller is entitled to.
import type { IQrCode } from '@/models/QrCode';
import { clampQrSize, renderCatalogQr } from '@/services/catalogQrService';
import { resolverUrlFor, slugifyBatchLabel, type BatchSheetSource } from '@/services/qrCodeService';
import { qrLogoForPdf } from '@/services/qrLogo';
import {
  buildStandeeSheetPdf,
  clampCopies,
  computeSheetLayout,
  sheetPageCount,
  STANDEE_SHEET_MAX_COPIES,
} from '@/services/standeeSheetPdf';

/** The line printed under every standee code. */
export const STANDEE_TAGLINE = 'Created for mirage menu';

/**
 * WHAT A STANDEE LOOKS LIKE, as a version, for the ETags.
 *
 * Every standee endpoint keys its ETag on the INPUTS to the render — the URL,
 * the size, the layout settings — because that is cheaper than rendering to
 * find out. The cost of that shortcut is that a change to the rendering itself
 * changes none of the inputs, so a client holding last month's sheet keeps
 * being told 304 and never sees the new one. This token is the missing input:
 * bump it whenever the drawing changes for the same URL and settings (the mark
 * appearing in the middle was the first such change), and every cached copy
 * is stale at once. Bumping it for nothing costs one re-download per client.
 */
export const STANDEE_ARTWORK_VERSION = 'mark-1';

export type StandeeSheetFormat = 'png' | 'pdf';

/**
 * How ONE code's copies are laid out on paper.
 *
 * `single` is the one-up sheet — one big square per A4 page, the file this
 * endpoint always produced — repeated `copies` pages. `grid` is the batch
 * sheet's layout (nine 1.67in cards to a page by default, with cut guides)
 * with just this code on it, `copies` times. Two layouts because they are two
 * different physical objects: the one-up sheet is a table stand, the grid
 * card is a sticker-sized cutout. Both draw the same square.
 */
export type SingleStandeeLayout = 'single' | 'grid';

/** What one code's sheet would take, before it is rendered — for the dialog. */
export interface StandeeSheetPlan {
  /** The grid, for the `grid` layout: cards per page and its shape. */
  columns: number;
  rows: number;
  perPage: number;
  maxCopies: number;
}

/**
 * Pages one code takes at `copies` in `layout` — the one formula, shared with
 * the render below so the number the dialog shows is the number that prints.
 */
export function singleStandeePages(
  copies: number,
  layout: SingleStandeeLayout,
  perPage: number
): number {
  return layout === 'single' ? copies : Math.max(1, Math.ceil(copies / perPage));
}

export function planStandeeSheet(): StandeeSheetPlan {
  const layout = computeSheetLayout();
  return {
    columns: layout.columns,
    rows: layout.rows,
    perPage: layout.perPage,
    maxCopies: STANDEE_SHEET_MAX_COPIES,
  };
}

export type RenderStandeeSheetResult =
  /**
   * Retirement means a standee was replaced. Rendering one hands somebody a
   * sheet that resolves to the fallback page, and the whole cost of that lands
   * after it has been printed and stood on a table — so both routes refuse,
   * with the same code, rather than one of them being lenient.
   */
  | { outcome: 'CODE_RETIRED' }
  | {
      outcome: 'RENDERED';
      body: Buffer;
      contentType: string;
      filename: string;
      /** What the QR encodes — used for the caller's ETag, never logged. */
      url: string;
      size: number;
      /** PDF only: what is in the file. A PNG is one picture and has neither. */
      copies: number;
      pages: number;
    };

/**
 * Renders one code's sheet.
 *
 * THROWS `QrResolverNotConfiguredError` (from `resolverUrlFor`) when the
 * deployment has no public origin — both callers map that to the same 409 they
 * already return elsewhere, because a URL against a guessed host is the one
 * output here that gets printed onto something physical.
 */
export async function renderStandeeSheet(params: {
  record: Pick<IQrCode, 'code' | 'state'>;
  format: StandeeSheetFormat;
  size?: number;
  /** PDF only — see [SingleStandeeLayout]. Defaults to one copy, one-up. */
  copies?: number;
  layout?: SingleStandeeLayout;
}): Promise<RenderStandeeSheetResult> {
  const { record, format } = params;
  if (record.state === 'RETIRED') return { outcome: 'CODE_RETIRED' };

  const url = resolverUrlFor(record.code);
  const size = clampQrSize(params.size);
  const copies = format === 'pdf' ? clampCopies(params.copies) : 1;
  const layout = params.layout ?? 'single';

  if (format === 'pdf' && layout === 'grid') {
    // The batch sheet's builder with a one-item batch: the SAME card, the
    // same square, the same mark, `copies` of it side by side — so a card cut
    // off this sheet and one cut off a batch sheet are indistinguishable.
    const grid = computeSheetLayout();
    const suffix = copies === 1 ? '' : `-x${copies}`;
    return {
      outcome: 'RENDERED',
      body: buildStandeeSheetPdf({
        items: [{ code: record.code, url }],
        tagline: STANDEE_TAGLINE,
        // The footer names the batch on a batch sheet; here it names the code,
        // which is the only thing that tells two of these apart in a pile.
        label: `Standee ${record.code}`,
        logo: await qrLogoForPdf(),
        copies,
      }),
      contentType: 'application/pdf',
      filename: `standee-${record.code.toLowerCase()}-qr-grid${suffix}.pdf`,
      url,
      size,
      copies,
      pages: singleStandeePages(copies, 'grid', grid.perPage),
    };
  }

  const rendered = await renderCatalogQr({
    publicUrl: url,
    // The filename stem (`standee-abcd2345-qr.pdf`), so several of these in a
    // downloads folder can be told apart unopened.
    catalogName: `Standee ${record.code}`,
    format,
    size,
    // What is PRINTED under the square: the code, big and monospaced, because
    // somebody reads those eight characters off the sheet and types them; then
    // one line saying what the sheet is, for whoever finds it in a drawer.
    standeeCode: record.code,
    standeeTagline: STANDEE_TAGLINE,
    // The Mayasabha mark in the middle of the square — the thing that makes a
    // standee read as ours on a table full of other people's payment codes.
    logo: true,
    copies,
  });

  return {
    outcome: 'RENDERED',
    body: rendered.body,
    contentType: rendered.contentType,
    // `-x10` when there are copies, so the ten-page file and the one-page file
    // do not collide in a downloads folder. A PNG is never suffixed: copies do
    // not apply to it.
    filename:
      copies === 1 ? rendered.filename : rendered.filename.replace(/\.pdf$/, `-x${copies}.pdf`),
    url,
    size,
    copies,
    pages: format === 'pdf' ? singleStandeePages(copies, 'single', 1) : 0,
  };
}

export interface RenderedBatchSheet {
  body: Buffer;
  contentType: string;
  filename: string;
  /** DISTINCT codes on the sheet — retired codes are not among them. */
  standees: number;
  /** Times each code is printed. */
  copies: number;
  /** Cards on the paper: `standees × copies`. */
  cards: number;
  pages: number;
  /** Retired codes left off, so the caller can say so rather than look short. */
  skippedRetired: number;
}

/**
 * What a batch sheet WOULD contain, before anybody renders it.
 *
 * The dialog in front of the download shows this — how many codes, the grid,
 * and (from `perPage`) how many pages any number of copies comes to — so an
 * admin about to print ten copies of fifty codes sees "56 pages" before the
 * printer does. `maxCopies` travels with it so the field's ceiling is the
 * server's, not a number the client remembers.
 */
export interface BatchSheetPlan {
  standees: number;
  skippedRetired: number;
  columns: number;
  rows: number;
  perPage: number;
  maxCopies: number;
}

export function planBatchStandeeSheet(source: BatchSheetSource): BatchSheetPlan {
  const layout = computeSheetLayout();
  return {
    standees: source.items.length,
    skippedRetired: source.skippedRetired,
    columns: layout.columns,
    rows: layout.rows,
    perPage: layout.perPage,
    maxCopies: STANDEE_SHEET_MAX_COPIES,
  };
}

/**
 * A WHOLE BATCH as one printable PDF — the third caller, and the reason this
 * module's "one composer" rule earns its keep.
 *
 * It prints the SAME two lines under every square as the one-code sheet does,
 * from the same [STANDEE_TAGLINE] constant, because a standee cut off a batch
 * sheet and a standee printed one-up are the same physical object and must not
 * start saying different things. The layout differs; what is on a card does not.
 *
 * `copies` prints every code that many times, consecutively — a restaurant is
 * handed ten standees of ONE code, so the ten come off the sheet together. It
 * changes how many cards there are and nothing about any card.
 *
 * Takes a [BatchSheetSource] the caller has already loaded and been authorized
 * for — same contract as [renderStandeeSheet], which takes a record rather than
 * a code. Nothing here knows who may print a batch.
 */
export async function renderBatchStandeeSheet(
  source: BatchSheetSource,
  options: { copies?: number } = {}
): Promise<RenderedBatchSheet> {
  const copies = clampCopies(options.copies);
  const layout = computeSheetLayout();
  // Async only for this: the mark is decoded once per process and awaited
  // here, so the sheet builder itself can stay a pure function of its inputs.
  const logo = await qrLogoForPdf();

  return {
    body: buildStandeeSheetPdf({
      items: source.items,
      tagline: STANDEE_TAGLINE,
      label: source.label,
      logo,
      copies,
    }),
    contentType: 'application/pdf',
    // Named for the batch, like the vendor CSV beside it — an admin with a
    // downloads folder of these has to tell one print run from another unopened.
    // A copies suffix when there are copies, so the ten-up file and the plain
    // one do not collide in that folder either.
    filename:
      `standee-sheet-${slugifyBatchLabel(source.label)}` +
      `${copies === 1 ? '' : `-x${copies}`}.pdf`,
    standees: source.items.length,
    copies,
    cards: source.items.length * copies,
    pages: sheetPageCount(source.items.length, copies, layout),
    skippedRetired: source.skippedRetired,
  };
}
