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
import { resolverUrlFor } from '@/services/qrCodeService';

/** The line printed under every standee code. */
export const STANDEE_TAGLINE = 'Created for mirage menu';

export type StandeeSheetFormat = 'png' | 'pdf';

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
}): Promise<RenderStandeeSheetResult> {
  const { record, format } = params;
  if (record.state === 'RETIRED') return { outcome: 'CODE_RETIRED' };

  const url = resolverUrlFor(record.code);
  const size = clampQrSize(params.size);

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
  });

  return {
    outcome: 'RENDERED',
    body: rendered.body,
    contentType: rendered.contentType,
    filename: rendered.filename,
    url,
    size,
  };
}
