// src/services/customerUrl.ts
//
// THE LINK A PERSON IS SHOWN, as distinct from the link a catalog STORES.
//
// `catalog.publicUrl` is written once and never rewritten (feature 32). Under
// the MIRAGE_OBJECT_ID scheme it is the Mirage menu page by ObjectId. Under
// RECAPTURE_SHORT_CODE it is `{PUBLIC_RESOLVER_BASE_URL}/r/{code}` — a redirect
// through THIS API, minted at rep activation before Mirage has heard of the
// restaurant, so a standee already on the table can be remapped without a
// reprint. That indirection is the standee's business and it stays.
//
// BUT THAT SECOND STRING IS THE API'S OWN HOST, and it was what a rep or an
// owner got handed to copy, open, share and reprint from the QR screen. The
// backend's domain on a sticker, in a WhatsApp message or under a "Open" button
// is exposure for no reason a customer benefits from: the menu's address is the
// Mirage page, and that is the only address anyone outside this codebase should
// ever see. So every surface that SHOWS a link — the catalog DTO, the rep's
// restaurant list, publish status, the publish response, and both QR renders —
// asks [customerUrl], which answers with the Mirage page BY NAME as soon as the
// restaurant exists there and with NOTHING before that. The stored string is
// never displayed; the resolver keeps redirecting the printed standees.
//
// NOT A THIRD WRITER OF `publicUrl`. Nothing here is stored, and nothing here
// touches `catalogQrService`, which still draws whatever string it is given
// verbatim. The ObjectId format string (`mintPublicUrl`) lives here too so
// `persistMapping` and the resolver share one expression with this file.
import { env } from '@/config/env';
import type { ICatalog } from '@/models/Catalog';

/** The Mirage menu URL for a Mirage restaurant id — the STORED / redirect form. */
export function mintPublicUrl(mirageRestaurantId: string): string {
  return `${env.MIRAGE_PUBLIC_BASE_URL}/${mirageRestaurantId}`;
}

/** The two fields the answer is decided from — a full document or a lean one. */
export type CustomerUrlSource = Pick<ICatalog, 'name' | 'mirageRestaurantId'>;

/**
 * The link to show for this catalog, or null when there is none to show yet.
 *
 * `{MIRAGE_PUBLIC_BASE_URL}/{catalog.name}` — the NAME, not the ObjectId. Every
 * catalog name is stored as the lowercase-underscore slug Mirage stores it
 * under (AGENTS.md, "Catalog names"), and Mirage's public `/:restaurant` route
 * looks that slug up by name first (mirage-be `itemController.js`,
 * `restaurantSlugQuery`) and only falls back to `findById` for an ObjectId. So
 * both forms open the same page, and the name is the one a person can read,
 * say aloud and recognise on a printed sheet — `menu.example/spice_garden`
 * rather than `menu.example/66f1a2…`. That is the form asked for on every
 * display surface.
 *
 * WHAT THIS COSTS, stated so nobody rediscovers it: a catalog RENAME changes
 * this link, where the ObjectId form never did. The stored `publicUrl` and the
 * standee resolver are untouched by that — a printed standee redirects through
 * `mintPublicUrl`, the ObjectId form — so a square printed from a standee keeps
 * working across a rename; a square reprinted from the QR screen carries the
 * name it was printed under.
 *
 * Null before the first publish: the Mirage restaurant does not exist yet, so
 * there is no menu page — "publish first" is the honest answer, never the
 * resolver URL (which shows a rep the backend and a customer "not live yet").
 * Null also when `MIRAGE_PUBLIC_BASE_URL` has been removed from a live
 * deployment: `undefined/<name>` must never reach a screen.
 */
export function customerUrl(catalog: CustomerUrlSource): string | null {
  if (!catalog.mirageRestaurantId || !env.MIRAGE_PUBLIC_BASE_URL) return null;
  return `${env.MIRAGE_PUBLIC_BASE_URL}/${catalog.name}`;
}
