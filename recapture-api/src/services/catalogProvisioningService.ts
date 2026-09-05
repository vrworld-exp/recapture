// src/services/catalogProvisioningService.ts
//
// Binding a ReCapture catalog to a Mirage restaurant, and minting the public
// URL every printed QR encodes (features 40, 41, 42, 59 — task T-024).
//
// This file owns the one write in the whole feature that can never be taken
// back. `mirageRestaurantId` and `publicUrl` are set ONCE, together, under a
// conditional update guarded on the mapping still being absent, and no code
// path here or anywhere else may rewrite them — §8 of the architecture, and the
// reason feature 32 (a printed sticker keeps working through renames,
// republishes and product churn) holds at all.
//
// THE URL IS STORED, NOT COMPUTED. `MIRAGE_PUBLIC_BASE_URL` is read exactly
// once per catalog, at provisioning. Changing that variable later does not
// repoint an issued URL, and `publicUrlScheme` records how the string was
// derived so a future scheme change grandfathers old catalogs visibly instead
// of silently rewriting them.
//
// Nothing here bumps `draftRevision`: provisioning is a publish-time projection,
// not an authoring edit, and bumping it would leave a catalog permanently
// reading "draft changes not yet live" after every successful publish.
import { Types } from 'mongoose';

import { env } from '@/config/env';
import { BUCKET_ARTIFACTS } from '@/config/s3';
import { Catalog, type ICatalog } from '@/models/Catalog';
import type { PublicUrlScheme } from '@/models/types/catalog.types';
import { getObjectBytes } from '@/services/s3ObjectStore';
import {
  getMirageClient,
  assertMirageConfigured,
  MirageError,
  MirageErrorCode,
  bytesUpload,
  type MirageFileUpload,
  type MirageRestaurant,
  type MirageSocialLinks,
} from '@/services/mirage';
import { isDuplicateKeyError } from '@/services/catalogService';
import { appendSlugSuffix, toCatalogSlug } from '@/utils/catalogNames';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { hashIdentifier } from '@/utils/otp';
import { parseProductImageKey, productImageContentTypeFor } from '@/utils/productImageKeys';

/** How `publicUrl` is derived today. Recorded on the document at minting. */
const PUBLIC_URL_SCHEME: PublicUrlScheme = 'MIRAGE_OBJECT_ID';

/** The frozen mapping, as every caller downstream reads it. */
export interface CatalogMappingDto {
  mirageRestaurantId: string;
  publicUrl: string;
  publicUrlScheme: PublicUrlScheme;
}

/** The stable code a name collision surfaces to the client. */
export const CATALOG_NAME_TAKEN = 'CATALOG_NAME_TAKEN' as const;

/**
 * Outcome of provisioning.
 *
 * `NAME_TAKEN` is the one failure a business can act on themselves, so it is a
 * result rather than a thrown error and it carries a name that is known to be
 * free. Everything else that can go wrong here is a {@link MirageError} left to
 * the publish processor's classifier — retryable transport, a rejected
 * credential and a Mirage 5xx are its business, not this service's.
 */
export type ProvisionCatalogResult =
  | { outcome: 'ALREADY_PROVISIONED'; mapping: CatalogMappingDto }
  | { outcome: 'ADOPTED'; mapping: CatalogMappingDto }
  | { outcome: 'CREATED'; mapping: CatalogMappingDto }
  | { outcome: 'NAME_TAKEN'; code: typeof CATALOG_NAME_TAKEN; suggestedName: string }
  | { outcome: 'CATALOG_GONE' };

/**
 * Fails fast when the public host is absent.
 *
 * Separate from assertMirageConfigured() because it guards a different thing:
 * that one asks "can we talk to Mirage", this one asks "can we mint a URL we
 * will never be able to change". Provisioning without it would either store a
 * `undefined/<id>` URL or force a later rewrite — both fatal to feature 32 — so
 * it must fail BEFORE the M2 call, not after.
 */
function assertPublicUrlConfigured(): void {
  if (env.MIRAGE_PUBLIC_BASE_URL) return;
  throw new MirageError(
    MirageErrorCode.NOT_CONFIGURED,
    'terminal',
    'Mirage publishing is not configured — missing MIRAGE_PUBLIC_BASE_URL.',
    'provisioning'
  );
}

/**
 * The Mirage menu URL for a Mirage restaurant id.
 *
 * THERE ARE EXACTLY TWO CALLERS AND THE LIST IS CLOSED:
 *
 *  1. {@link persistMapping}, at the moment the mapping is first written. Every
 *     read of a catalog's own URL — the QR renderer, the share sheet, the
 *     catalog DTO — returns the STORED string, never a recomputed one. §8 says
 *     a third caller of that kind should fail code review on that basis alone.
 *  2. The public resolver (services/qrResolverService.ts), which needs WHERE
 *     THE MENU LIVES rather than what the catalog's stored URL says. Under the
 *     same-day-activation scheme those stopped being the same string:
 *     activation writes `{PUBLIC_RESOLVER_BASE_URL}/r/{code}` into
 *     `publicUrl`, so a resolver redirecting there would redirect to itself
 *     forever. It is exported for that one caller so the format string exists
 *     in exactly one place — a second copy is how the two drift apart.
 */
export function mintPublicUrl(mirageRestaurantId: string): string {
  return `${env.MIRAGE_PUBLIC_BASE_URL}/${mirageRestaurantId}`;
}

/** The mapping as stored, or null on a document that has none yet. */
function mappingOf(catalog: ICatalog): CatalogMappingDto | null {
  if (!catalog.mirageRestaurantId || !catalog.publicUrl) return null;
  return {
    mirageRestaurantId: catalog.mirageRestaurantId,
    publicUrl: catalog.publicUrl,
    publicUrlScheme: catalog.publicUrlScheme ?? PUBLIC_URL_SCHEME,
  };
}

/**
 * The form a name is COMPARED in.
 *
 * The slug, not a lowercased copy: Mirage stores slugs, so every name in a
 * `listRestaurants` response is already one, and a lowercase-only fold left
 * "cafe_2" and "Cafe 2 Go" looking unrelated — which is how a candidate name
 * gets suggested that Mirage then refuses.
 */
const normalized = (name: string): string =>
  toCatalogSlug(name, { maxLength: CATALOG_NAME_SLUG_MAX });

/** `Catalog.name`'s own bound — slugging must not shorten past it. */
const CATALOG_NAME_SLUG_MAX = 120;

/**
 * Would Mirage refuse to create a restaurant called [desired]?
 *
 * Mirage's uniqueness check is an UNANCHORED case-insensitive regex built from
 * the requested name (adminController.js:276-282), so it rejects "Cafe" while
 * "Blue Cafe House" exists — a containment test, not an equality test. Modelling
 * it faithfully here is what lets provisioning fail with a usable suggestion
 * instead of spending a doomed M2 call to discover the same thing.
 */
function collidesInMirage(desired: string, existingName: string): boolean {
  return normalized(existingName).includes(normalized(desired));
}

/**
 * A name Mirage will accept, given everything it currently holds.
 *
 * Safe to append to freely: the Mirage `name` is a BOOKKEEPING LABEL only. The
 * public URL is built from the immutable `_id` and the business's displayed name
 * comes from the ReCapture catalog record, so a disambiguated Mirage name has no
 * customer-visible effect (§7.5).
 *
 * The numeric suffixes are what a human would try first; [fallbackSuffix] (the
 * catalog id's tail) is the guaranteed terminator, because a value derived from
 * a Mongo id cannot already be in use by another catalog.
 */
export function suggestAvailableName(
  desired: string,
  existingNames: readonly string[],
  fallbackSuffix: string
): string {
  const isFree = (candidate: string): boolean =>
    !existingNames.some((existing) => collidesInMirage(candidate, existing));

  // Suffixed through appendSlugSuffix so a suggestion is itself a valid stored
  // name: the client hands it straight back as the new catalog name, and a
  // suggestion carrying a space would be silently rewritten on the way in and
  // then no longer be the name that was checked as free.
  const base = desired.trim();
  for (let n = 2; n <= 9; n++) {
    const candidate = appendSlugSuffix(base, n);
    if (isFree(candidate)) return candidate;
  }
  return appendSlugSuffix(base, fallbackSuffix);
}

/** The catalog id's tail — a disambiguator no other catalog can be using. */
function fallbackSuffixFor(catalog: ICatalog): string {
  return (catalog._id as Types.ObjectId).toHexString().slice(-6);
}

/** A `NAME_TAKEN` outcome, built from an already-fetched restaurant list. */
function nameTaken(
  catalog: ICatalog,
  existing: readonly MirageRestaurant[]
): ProvisionCatalogResult {
  return {
    outcome: 'NAME_TAKEN',
    code: CATALOG_NAME_TAKEN,
    suggestedName: suggestAvailableName(
      catalog.name,
      existing.map((r) => r.name),
      fallbackSuffixFor(catalog)
    ),
  };
}

/**
 * Mirage wants digits only and prefixes `+91` itself (adminController.js:288).
 *
 * So a stored `+91 98765 43210` must go out as `9876543210`, or the public page
 * shows `+91+919876543210`. A number that is not a plain 10-digit Indian mobile
 * after normalisation is OMITTED rather than guessed at — a wrong phone number
 * on a customer-facing page is worse than none.
 */
function mirageDigits(phone: string | undefined): string | undefined {
  if (!phone) return undefined;
  let digits = phone.replace(/\D/g, '');
  if (digits.length > 10 && digits.startsWith('91')) digits = digits.slice(2);
  return digits.length === 10 ? digits : undefined;
}

/**
 * The WhatsApp number as `wa.me` needs to read it.
 *
 * The public page builds `https://wa.me/{value}` verbatim
 * (mirage-fe/src/features/menu/MenuScreen.tsx:1071), and `wa.me` accepts DIGITS
 * ONLY — a stored `+91 98765 43210` produces a link that opens to an error. So
 * the separators come off here, at the seam, exactly as they do for `phoneNo`.
 *
 * A bare 10-digit number is given the `91` country code for the same reason
 * Mirage prefixes `+91` onto `phone`: without a country code `wa.me` cannot
 * resolve the number at all, and this is the market both fields already assume.
 * Anything else is passed through as digits — an international number typed with
 * its own country code is already correct.
 */
function whatsappDigits(value: string | undefined): string {
  const digits = (value ?? '').replace(/\D/g, '');
  if (digits.length === 0) return '';
  return digits.length === 10 ? `91${digits}` : digits;
}

/**
 * The link block Mirage's restaurant record carries (restaurantModel.js:75-105).
 *
 * EVERY KEY IS ALWAYS PRESENT, `''` for an unset one, and that is the whole
 * point. Mirage merges `socialLinks` key by key rather than replacing the object
 * (adminController.js:685-689), so an omitted key keeps whatever it held. Send
 * only the filled-in handles and "remove my Instagram" silently fails — the
 * handle stays live on the customer-facing page forever, while the app shows it
 * as deleted.
 *
 * `x` and `linkedin` are deliberately NOT sent: ReCapture has no field for
 * either, so they are left to whatever Mirage's own admin UI put there rather
 * than being cleared by a system that does not know about them.
 */
function mirageLinks(catalog: ICatalog): {
  website: string;
  socialLinks: MirageSocialLinks;
} {
  const socials = catalog.contact?.socials;
  return {
    website: (catalog.contact?.website ?? '').trim(),
    socialLinks: {
      instagram: (socials?.instagram ?? '').trim(),
      facebook: (socials?.facebook ?? '').trim(),
      youtube: (socials?.youtube ?? '').trim(),
      whatsapp: whatsappDigits(socials?.whatsapp),
    },
  };
}

/**
 * The catalog logo as multipart bytes, or undefined when there is nothing
 * usable to send.
 *
 * Every failure here is a SKIP, never a throw: a missing or oversize logo must
 * not block provisioning, because provisioning is what mints the QR. Mirage
 * falls back to its own stock icon and the next publish carries the logo once
 * the business has fixed it.
 *
 * ⚠ The filename's extension is load-bearing. Mirage builds its S3 key as
 * `res_icons/{Date.now()}-{name}.{originalname.split('.').pop()}`
 * (adminController.js:302-305), so an extensionless filename produces a stored
 * icon URL with no extension.
 */
async function loadLogoUpload(catalog: ICatalog): Promise<MirageFileUpload | undefined> {
  if (!catalog.logoKey) return undefined;

  const parsed = parseProductImageKey(catalog.logoKey);
  if (!parsed.ok) {
    console.warn(`[catalog] skipping logo — key is not ours (${parsed.reason})`);
    return undefined;
  }

  const fetched = await getObjectBytes(BUCKET_ARTIFACTS, catalog.logoKey);
  if (fetched.outcome === 'absent') {
    console.warn('[catalog] skipping logo — the stored key has no object behind it');
    return undefined;
  }
  if (fetched.body.byteLength > env.MIRAGE_MAX_ASSET_BYTES) {
    console.warn('[catalog] skipping logo — larger than MIRAGE_MAX_ASSET_BYTES');
    return undefined;
  }

  // Buffered rather than streamed on purpose: a logo is bounded to
  // PRODUCT_IMAGE_MAX_BYTES, and the streaming shape exists for models.
  return bytesUpload(
    `logo.${parsed.value.ext}`,
    // Derived from the KEY, not from S3's ContentType: the extension is what the
    // presigned signature bound at upload, so it cannot disagree with the bytes.
    productImageContentTypeFor(parsed.value.ext),
    fetched.body
  );
}

/** Result of the one irreversible write. */
type PersistResult =
  | { outcome: 'PERSISTED'; mapping: CatalogMappingDto }
  | { outcome: 'LOST_RACE'; mapping: CatalogMappingDto }
  | { outcome: 'RESTAURANT_TAKEN' }
  | { outcome: 'CATALOG_GONE' };

/**
 * Writes the mapping and the minted URL, once.
 *
 * The guard `mirageRestaurantId: null` (which in Mongo matches an absent field
 * too) is the whole safety property: a second provisioning attempt — a retried
 * job, a concurrent run, a replay after a crash between M2 and this write —
 * matches nothing and returns the WINNER's mapping instead of overwriting it.
 * A read-then-write would let two runs both pass the check, and the loser would
 * silently repoint a URL that may already be on a sticker.
 *
 * `RESTAURANT_TAKEN` comes from the unique index on `mirageRestaurantId`: some
 * other catalog already owns this Mirage restaurant, so adopting it would
 * publish this user's products onto someone else's public page.
 */
async function persistMapping(
  catalog: ICatalog,
  mirageRestaurantId: string
): Promise<PersistResult> {
  const catalogId = catalog._id as Types.ObjectId;

  // A REP-ACTIVATED CATALOG ARRIVES HERE WITH publicUrl ALREADY SET — written
  // at activation, pointing at the printed standee, before Mirage existed for
  // this restaurant. Minting over it would break every code already in the
  // field and assertMappingImmutable would (correctly) throw on the next
  // publish. Mirage provisioning owns `mirageRestaurantId`; it does NOT own the
  // public URL.
  //
  // Note what is NOT done here: the guard below still matches only on
  // `mirageRestaurantId: null`. Widening it to `publicUrl: null` as well would
  // make activation's own URL cause provisioning to skip the Mirage mapping
  // entirely — the catalog would never be published at all.
  const preserved = catalog.publicUrl;
  const publicUrl = preserved ?? mintPublicUrl(mirageRestaurantId);
  const urlFields = preserved
    ? {}
    : { publicUrl, publicUrlScheme: PUBLIC_URL_SCHEME };

  const mapping: CatalogMappingDto = {
    mirageRestaurantId,
    publicUrl,
    publicUrlScheme: catalog.publicUrlScheme ?? PUBLIC_URL_SCHEME,
  };

  try {
    const updated = await Catalog.findOneAndUpdate(
      { _id: catalogId, deletedAt: null, mirageRestaurantId: null },
      {
        $set: {
          mirageRestaurantId: mapping.mirageRestaurantId,
          mirageProvisionedAt: new Date(),
          ...urlFields,
        },
      },
      { new: true, runValidators: true }
    ).exec();

    if (updated) return { outcome: 'PERSISTED', mapping };
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;
    return { outcome: 'RESTAURANT_TAKEN' };
  }

  // The guard did not match: either someone else provisioned first, or the
  // catalog went away underneath us.
  const current = await Catalog.findOne({ _id: catalogId, deletedAt: null }).exec();
  if (!current) return { outcome: 'CATALOG_GONE' };

  const existing = mappingOf(current);
  if (!existing) return { outcome: 'CATALOG_GONE' };

  return { outcome: 'LOST_RACE', mapping: existing };
}

/**
 * Turns a persist outcome into the service's result, and emits the one-per-
 * catalog provisioning event.
 *
 * A LOST_RACE is reported as ALREADY_PROVISIONED rather than as an error: both
 * callers wanted a mapping and both got the same one. It does NOT emit, because
 * the winner already did.
 */
function finish(
  catalog: ICatalog,
  persisted: PersistResult,
  existing: readonly MirageRestaurant[],
  opts: { adoptedExisting: boolean }
): ProvisionCatalogResult {
  switch (persisted.outcome) {
    case 'PERSISTED':
      track(AnalyticsEvent.CATALOG_CLIENT_PROVISIONED, {
        user_id_hash: hashIdentifier(catalog.userId.toString()),
        catalog_id: (catalog._id as Types.ObjectId).toHexString(),
        adopted_existing: opts.adoptedExisting,
      });
      return {
        outcome: opts.adoptedExisting ? 'ADOPTED' : 'CREATED',
        mapping: persisted.mapping,
      };
    case 'LOST_RACE':
      return { outcome: 'ALREADY_PROVISIONED', mapping: persisted.mapping };
    case 'RESTAURANT_TAKEN':
      return nameTaken(catalog, existing);
    case 'CATALOG_GONE':
      return { outcome: 'CATALOG_GONE' };
  }
}

/**
 * Binds the catalog to a Mirage restaurant and freezes its public URL.
 *
 * Idempotent by construction — an already-provisioned catalog returns its stored
 * mapping without a single Mirage call — which matters because the publish
 * processor calls this at the top of EVERY run, not just the first.
 *
 * The order of §7.5 is followed exactly, and the ordering is the point:
 *   1. M1 list, and ADOPT an exact case-insensitive name match, so a pilot
 *      business that already exists in Mirage keeps its page and its URL;
 *   2. otherwise refuse early if Mirage's containment rule would reject the
 *      name, handing back one that is known to be free;
 *   3. otherwise M2 create, and persist the id BEFORE anything else can fail —
 *      a restaurant we created but did not record is an orphan nobody can find.
 */
export async function provisionCatalog(catalogId: Types.ObjectId): Promise<ProvisionCatalogResult> {
  const catalog = await Catalog.findOne({ _id: catalogId, deletedAt: null }).exec();
  if (!catalog) return { outcome: 'CATALOG_GONE' };

  const alreadyMapped = mappingOf(catalog);
  if (alreadyMapped) return { outcome: 'ALREADY_PROVISIONED', mapping: alreadyMapped };

  assertMirageConfigured();
  assertPublicUrlConfigured();

  const client = getMirageClient();
  const existing = await client.listRestaurants();

  // (1) Adopt an exact name match.
  const exact = existing.find((r) => normalized(r.name) === normalized(catalog.name));
  if (exact) {
    return finish(catalog, await persistMapping(catalog, exact.id), existing, {
      adoptedExisting: true,
    });
  }

  // (2) Mirage's containment rule would reject this name — say so before
  //     spending a call on it, and suggest one that is free.
  if (existing.some((r) => collidesInMirage(catalog.name, r.name))) {
    return nameTaken(catalog, existing);
  }

  // (3) Create. `location` is always a string (Mirage 400s otherwise), and the
  //     logo and link block ride along, so the very first published page is
  //     already branded and reachable.
  const logo = await loadLogoUpload(catalog);
  const phoneNo = mirageDigits(catalog.contact?.phone);
  const links = mirageLinks(catalog);

  let created: MirageRestaurant;
  try {
    created = await client.createRestaurant({
      name: catalog.name,
      location: catalog.contact?.address ?? '',
      ...(phoneNo !== undefined ? { phoneNo } : {}),
      website: links.website,
      socialLinks: links.socialLinks,
      ...(logo ? { image: logo } : {}),
    });
  } catch (err) {
    // Someone created a colliding restaurant between our list and our create.
    // Re-read: an exact match is now adoptable, anything else is a name clash.
    if (err instanceof MirageError && err.code === MirageErrorCode.ALREADY_EXISTS) {
      const after = await client.listRestaurants();
      const nowExact = after.find((r) => normalized(r.name) === normalized(catalog.name));
      if (!nowExact) return nameTaken(catalog, after);

      return finish(catalog, await persistMapping(catalog, nowExact.id), after, {
        adoptedExisting: true,
      });
    }
    throw err;
  }

  return finish(catalog, await persistMapping(catalog, created.id), existing, {
    adoptedExisting: false,
  });
}

// ── Branding (features 42, 59) ──────────────────────────────────────────────

export type SyncBrandingResult =
  | { outcome: 'SYNCED'; logoSent: boolean }
  | { outcome: 'NOT_PROVISIONED' }
  | { outcome: 'NAME_TAKEN'; code: typeof CATALOG_NAME_TAKEN; suggestedName: string }
  | { outcome: 'CATALOG_GONE' };

/**
 * Pushes the catalog's branding onto its Mirage restaurant (M3).
 *
 * Run on every publish, not only when something changed: Mirage is another
 * system with its own admin UI, so a divergence there is corrected by the next
 * publish instead of persisting forever.
 *
 * Both `name` and `location` are always sent as strings. Mirage's update handler
 * accepts a partial body today, but it type-checks whatever is present, and an
 * omitted `location` on a restaurant that has one is the kind of silent gap that
 * only shows up on a customer's phone. `website` and `socialLinks` travel on the
 * same call and for the same reason — see {@link mirageLinks} for why every
 * social key is sent even when it is empty.
 *
 * ⚠ A rename can collide on Mirage's containment rule even though the original
 * create did not (adminController.js:496-508). It is reported, never retried
 * under a mangled name — but note what is NOT at stake: the public URL is built
 * from the immutable `_id`, so a refused rename leaves the QR, the page and
 * every published product working under the old label.
 */
export async function syncCatalogBranding(catalogId: Types.ObjectId): Promise<SyncBrandingResult> {
  const catalog = await Catalog.findOne({ _id: catalogId, deletedAt: null }).exec();
  if (!catalog) return { outcome: 'CATALOG_GONE' };
  if (!catalog.mirageRestaurantId) return { outcome: 'NOT_PROVISIONED' };

  assertMirageConfigured();

  const client = getMirageClient();
  const logo = await loadLogoUpload(catalog);
  const phoneNo = mirageDigits(catalog.contact?.phone);
  const links = mirageLinks(catalog);

  try {
    await client.updateRestaurant(catalog.mirageRestaurantId, {
      name: catalog.name,
      location: catalog.contact?.address ?? '',
      ...(phoneNo !== undefined ? { phoneNo } : {}),
      website: links.website,
      socialLinks: links.socialLinks,
      ...(logo ? { image: logo } : {}),
    });

    return { outcome: 'SYNCED', logoSent: Boolean(logo) };
  } catch (err) {
    if (err instanceof MirageError && err.code === MirageErrorCode.ALREADY_EXISTS) {
      const existing = await client.listRestaurants();
      return {
        outcome: 'NAME_TAKEN',
        code: CATALOG_NAME_TAKEN,
        suggestedName: suggestAvailableName(
          catalog.name,
          // The restaurant being renamed is not a competitor with itself.
          existing.filter((r) => r.id !== catalog.mirageRestaurantId).map((r) => r.name),
          fallbackSuffixFor(catalog)
        ),
      };
    }
    throw err;
  }
}
