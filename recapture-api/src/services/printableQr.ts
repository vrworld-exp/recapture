// src/services/printableQr.ts
//
// What a PRINTED QR looks like for a catalog — shared by the owner's
// `/catalog/qr` and the rep's `/rep/catalogs/:id/qr`, which must render the
// SAME bytes (and the same ETag) for the same restaurant. Before these lived
// here, Stage 7 gave the owner route the branded style and the rep route kept
// printing the plain square.
import type { Types } from 'mongoose';

import type { ICatalog } from '@/models/Catalog';
import { resolveQrStyle, type BrandingSource } from '@/services/brandedQr';
import { resolveCustomizationEntitlements } from '@/services/subscription/customizationEntitlements';

/**
 * Stage 8.1: the style to PRINT. A plan without the branded QR prints the
 * plain square — the style stays saved and comes back with an upgrade.
 */
export async function printableQrStyle(doc: ICatalog | null) {
  if (!doc?.qrStyle) return resolveQrStyle(null);
  const { entitlements } = await resolveCustomizationEntitlements(doc._id as Types.ObjectId);
  return entitlements.brandedQr ? resolveQrStyle(doc.qrStyle) : resolveQrStyle(null);
}

/** Stage 7: what a branded render reads off the catalog document. */
export function brandingOf(doc: ICatalog): BrandingSource {
  return {
    catalogName: doc.name,
    appearance: doc.appearance ?? null,
    ...(doc.logoKey ? { logoKey: doc.logoKey } : {}),
    ...(doc.coverImageKey ? { coverImageKey: doc.coverImageKey } : {}),
  };
}
