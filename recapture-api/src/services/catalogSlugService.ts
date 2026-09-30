// src/services/catalogSlugService.ts
//
// The menu's pretty address (more-customization Stage 8.2, phase 1):
// `https://<slug>.<MENU_SUBDOMAIN_BASE>`, served by the same Mirage page.
//
// ⚠ AN ADDITIONAL ADDRESS, NEVER A REPLACEMENT. `Catalog.publicUrl` is frozen —
// every printed QR encodes it — and nothing here reads or writes it. Mirage
// resolves the slug to the restaurant through its own public endpoint; the
// original URL keeps working exactly as before.
//
// Saving a slug is allowed on any plan (enforce at publish, stage-08 §8.1); it
// reaches Mirage only on a plan that covers a custom address.
import { Types } from 'mongoose';

import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { bumpDraftRevision, findOwnedCatalog, isDuplicateKeyError } from '@/services/catalogService';

export const SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$/;

/** Hosts we run, or that would read as ours / as something official. */
export const RESERVED_SLUGS = new Set([
  'www',
  'api',
  'app',
  'admin',
  'mail',
  'menu',
  'menus',
  'mirage',
  'recapture',
  'mayasabha',
  'mayasabhaxr',
  'static',
  'cdn',
  'assets',
  'help',
  'support',
  'status',
  'blog',
  'docs',
  'dev',
  'staging',
  'test',
  'demo',
  'login',
  'signup',
  'account',
  'billing',
  'pay',
  'payments',
  'qr',
  'r',
]);

export type SlugProblem = 'INVALID' | 'RESERVED';

/** Why [slug] cannot be used, or null. Lower-case expected. */
export function slugProblem(slug: string): SlugProblem | null {
  if (!SLUG_RE.test(slug) || slug.includes('--')) return 'INVALID';
  if (RESERVED_SLUGS.has(slug)) return 'RESERVED';
  return null;
}

/** The pretty address for [slug], or null when no subdomain host is configured. */
export function slugUrl(slug: string | undefined | null): string | null {
  if (!slug || !env.MENU_SUBDOMAIN_BASE) return null;
  return `https://${slug}.${env.MENU_SUBDOMAIN_BASE}`;
}

export type SetSlugResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'INVALID' }
  | { outcome: 'RESERVED' }
  | { outcome: 'TAKEN' }
  | { outcome: 'SAVED'; slug: string | null; url: string | null };

/**
 * Sets (or with null, clears) the caller's menu address. Uniqueness is the
 * partial unique index's job — a read-then-write would let two owners race to
 * the same name — so E11000 is translated to TAKEN.
 */
export async function setCatalogSlug(userId: string, raw: string | null): Promise<SetSlugResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const slug = raw === null ? null : raw.trim().toLowerCase();
  if (slug !== null) {
    const problem = slugProblem(slug);
    if (problem) return { outcome: problem };
  }
  if ((catalog.slug ?? null) === slug) {
    return { outcome: 'SAVED', slug, url: slugUrl(slug) };
  }

  try {
    await Catalog.updateOne(
      { _id: catalog._id },
      slug === null ? { $unset: { slug: '' } } : { $set: { slug } }
    ).exec();
  } catch (err) {
    if (isDuplicateKeyError(err)) return { outcome: 'TAKEN' };
    throw err;
  }
  // The address reaches the menu at the next publish, like everything else.
  await bumpDraftRevision(catalog._id as Types.ObjectId);
  return { outcome: 'SAVED', slug, url: slugUrl(slug) };
}
