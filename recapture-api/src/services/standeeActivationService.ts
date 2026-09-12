// src/services/standeeActivationService.ts
//
// What a standee in use turned INTO: the restaurant it activated, and who did
// the activating. The read behind the admin's QR button on an ACTIVE row.
//
// THE BATCH LIST SAYS "IN USE" AND NOTHING ELSE. An admin looking at a page of
// activated codes could see that a standee had been claimed, but not which
// restaurant now answers to it or which rep stood at that table — and those
// are the two questions that matter once a batch is in the field: "is this the
// menu I think it is?" and "who do I call about it?". This service answers
// both from the code, so the admin's screen can show the same QR panel the
// rep and the owner see (the Mirage link, copy, open, save) with the
// activating rep under it.
//
// THE REP IS THE LIST-SAFE SUMMARY, NOT THE CONTACT. `activatedBy` is the same
// `{id, displayName, hasAvatar}` the live-projects list carries for "Created
// by" — enough to draw a picture and a name. The RAW phone or email an admin
// dials comes from `GET /admin/users/:id`, one person per call, metered and
// audited, exactly as it does for a project owner: this route hands over the
// id, not the number, so the one unmasked-contact path stays the one path.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { QrCode } from '@/models/QrCode';
import type { CatalogStatus } from '@/models/types/catalog.types';
import { summarizeOwners, type AdminOwnerSummary } from '@/services/adminUsersService';
import { customerUrl } from '@/services/customerUrl';
import { normalizeQrCode } from '@/utils/qrCodes';

/** The restaurant a standee activated, as the admin's QR screen shows it. */
export interface StandeeActivationCatalog {
  id: string;
  name: string;
  businessName: string | null;
  status: CatalogStatus;
  /**
   * The link to SHOW and to draw — `customerUrl`, the Mirage page — or null
   * while the restaurant has been activated but never published. Never the
   * `/r/{code}` resolver the standee itself encodes.
   */
  publicUrl: string | null;
}

export interface StandeeActivation {
  code: string;
  activatedAt: string | null;
  catalog: StandeeActivationCatalog;
  /** Null when the activating account no longer resolves. */
  activatedBy: AdminOwnerSummary | null;
}

/**
 * The activation behind [code], or null when there is none to show.
 *
 * ONE NULL FOR EVERY "NOT IN USE". Unknown code, unassigned stock, a retired
 * standee and an active row whose catalog was deleted underneath it all
 * answer null, and the route maps that to one 404. The admin's list only
 * offers the button on ACTIVE rows, so the distinctions would only ever be
 * read by someone typing URLs — and to them the answer is the same: there is
 * no restaurant here.
 */
export async function loadStandeeActivation(rawCode: string): Promise<StandeeActivation | null> {
  const code = normalizeQrCode(rawCode);
  if (!code) return null;

  const qrCode = await QrCode.findOne({ code, deletedAt: null }).lean().exec();
  if (!qrCode || qrCode.state !== 'ACTIVE' || !qrCode.catalogId) return null;

  const catalog = await Catalog.findOne({ _id: qrCode.catalogId, deletedAt: null }).lean().exec();
  if (!catalog) return null;

  const activatedById = qrCode.activatedByUserId
    ? String(qrCode.activatedByUserId as Types.ObjectId)
    : null;
  const activatedBy = activatedById
    ? ((await summarizeOwners([activatedById])).get(activatedById) ?? null)
    : null;

  return {
    code,
    activatedAt: qrCode.activatedAt ? new Date(qrCode.activatedAt).toISOString() : null,
    catalog: {
      id: String(catalog._id),
      name: catalog.name,
      businessName: catalog.businessName ?? null,
      status: catalog.status,
      publicUrl: customerUrl(catalog),
    },
    activatedBy,
  };
}
