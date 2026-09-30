// src/services/staff/staffService.ts
//
// Staff access (more-customization Stage 14.3). REUSES the delegation model:
// a MANAGER or STAFF grant is a CatalogDelegation row with `kind`, exactly like
// a rep's — the restaurant still owns the catalog, the grant is read on EVERY
// request (so a revoke works on the very next one, with no token to expire),
// and rep code paths never see these rows (REP_KIND_FILTER).
//
// Invites are by phone. A ReCapture user who already has that verified number
// gets the grant at once; anyone else gets a StaffInvite that is claimed the
// first time they sign in with the number and open the staff area.
import { Types } from 'mongoose';

import { Catalog, type ICatalog } from '@/models/Catalog';
import { CatalogDelegation, type DelegationKind } from '@/models/CatalogDelegation';
import { StaffInvite } from '@/models/StaffInvite';
import { User } from '@/models/User';
import {
  MAX_STAFF_PER_CATALOG,
  permissionsFor,
  type ActorRole,
  type CatalogPermission,
} from '@/services/staff/staffPermissions';

type StaffKind = Exclude<DelegationKind, 'REP'>;
const STAFF_KINDS: StaffKind[] = ['MANAGER', 'STAFF'];

/** "98765 43210", "+91 98765-43210" → "+919876543210"; null when not a phone. */
export function normalizeInvitePhone(raw: string): string | null {
  const trimmed = raw.replace(/[\s\-()]/g, '');
  if (/^[6-9]\d{9}$/.test(trimmed)) return `+91${trimmed}`;
  if (/^0[6-9]\d{9}$/.test(trimmed)) return `+91${trimmed.slice(1)}`;
  return /^\+[1-9]\d{6,14}$/.test(trimmed) ? trimmed : null;
}

// ── Owner side ─────────────────────────────────────────────────────────────

export interface StaffMemberDto {
  /** The delegation id (member) or invite id (pending). */
  id: string;
  status: 'MEMBER' | 'INVITED';
  kind: StaffKind;
  name: string | null;
  phone: string | null;
  since: string;
}

export async function listStaff(catalogId: Types.ObjectId): Promise<StaffMemberDto[]> {
  const [grants, invites] = await Promise.all([
    CatalogDelegation.find({ catalogId, revokedAt: null, kind: { $in: STAFF_KINDS } })
      .lean()
      .exec(),
    StaffInvite.find({ catalogId, claimedAt: null, revokedAt: null }).lean().exec(),
  ]);
  const users = await User.find({ _id: { $in: grants.map((g) => g.repUserId) } })
    .select({ _id: 1, displayName: 1, phone: 1 })
    .lean()
    .exec();
  const byId = new Map(users.map((u) => [String(u._id), u]));
  return [
    ...grants.map((g) => {
      const u = byId.get(String(g.repUserId));
      return {
        id: String(g._id),
        status: 'MEMBER' as const,
        kind: g.kind as StaffKind,
        name: u?.displayName ?? null,
        phone: u?.phone ?? null,
        since: g.grantedAt.toISOString(),
      };
    }),
    ...invites.map((i) => ({
      id: String(i._id),
      status: 'INVITED' as const,
      kind: i.kind,
      name: i.name ?? null,
      phone: i.phone,
      since: i.createdAt.toISOString(),
    })),
  ];
}

export type InviteRejection = 'INVALID_PHONE' | 'SELF' | 'LIMIT' | 'ALREADY';

export async function inviteStaff(
  catalog: Pick<ICatalog, 'userId'> & { _id: Types.ObjectId },
  input: { phone: string; kind: StaffKind; name?: string }
): Promise<
  { outcome: 'REJECTED'; code: InviteRejection } | { outcome: 'OK'; member: StaffMemberDto }
> {
  const phone = normalizeInvitePhone(input.phone);
  if (!phone) return { outcome: 'REJECTED', code: 'INVALID_PHONE' };
  const owner = await User.findById(catalog.userId).select({ phone: 1 }).lean().exec();
  if (owner?.phone === phone) return { outcome: 'REJECTED', code: 'SELF' };

  const current = await listStaff(catalog._id);
  if (current.some((m) => m.phone === phone)) return { outcome: 'REJECTED', code: 'ALREADY' };
  if (current.length >= MAX_STAFF_PER_CATALOG) return { outcome: 'REJECTED', code: 'LIMIT' };

  const existing = await User.findOne({ phone, phoneVerified: true })
    .select({ _id: 1 })
    .lean()
    .exec();
  if (existing) {
    const live = await CatalogDelegation.findOne({
      repUserId: existing._id,
      catalogId: catalog._id,
      revokedAt: null,
    })
      .lean()
      .exec();
    // Already a field rep here: one live grant per person per catalog.
    if (live) return { outcome: 'REJECTED', code: 'ALREADY' };
    await CatalogDelegation.create({
      repUserId: existing._id,
      catalogId: catalog._id,
      kind: input.kind,
      grantedAt: new Date(),
      grantedByUserId: catalog.userId,
    });
  } else {
    await StaffInvite.create({
      catalogId: catalog._id,
      phone,
      kind: input.kind,
      ...(input.name ? { name: input.name } : {}),
      invitedByUserId: catalog.userId,
    });
  }
  const after = await listStaff(catalog._id);
  return { outcome: 'OK', member: after.find((m) => m.phone === phone)! };
}

/** Removes a member or cancels an invite. Effective on their next request. */
export async function revokeStaff(catalogId: Types.ObjectId, id: string): Promise<boolean> {
  if (!Types.ObjectId.isValid(id)) return false;
  const oid = new Types.ObjectId(id);
  const now = new Date();
  const grant = await CatalogDelegation.updateOne(
    { _id: oid, catalogId, revokedAt: null, kind: { $in: STAFF_KINDS } },
    { $set: { revokedAt: now } }
  ).exec();
  if (grant.modifiedCount) return true;
  const invite = await StaffInvite.updateOne(
    { _id: oid, catalogId, claimedAt: null, revokedAt: null },
    { $set: { revokedAt: now } }
  ).exec();
  return invite.modifiedCount > 0;
}

// ── Helper side ────────────────────────────────────────────────────────────

/** Turns open invites for this user's VERIFIED phone into grants. Idempotent. */
export async function claimInvites(userId: string): Promise<number> {
  const user = await User.findById(userId).select({ phone: 1, phoneVerified: 1 }).lean().exec();
  if (!user?.phone || !user.phoneVerified) return 0;
  const invites = await StaffInvite.find({
    phone: user.phone,
    claimedAt: null,
    revokedAt: null,
  }).exec();
  let claimed = 0;
  for (const invite of invites) {
    const owns = await Catalog.exists({ _id: invite.catalogId, userId: user._id }).exec();
    if (!owns) {
      try {
        await CatalogDelegation.create({
          repUserId: user._id,
          catalogId: invite.catalogId,
          kind: invite.kind,
          grantedAt: new Date(),
          grantedByUserId: invite.invitedByUserId,
        });
        claimed += 1;
      } catch (err) {
        if ((err as { code?: unknown }).code !== 11000) throw err;
      }
    }
    invite.claimedAt = new Date();
    await invite.save();
  }
  return claimed;
}

export interface StaffCatalogDto {
  catalogId: string;
  name: string;
  kind: StaffKind;
  permissions: readonly CatalogPermission[];
}

/** The catalogs this person helps run (claims pending invites first). */
export async function myStaffCatalogs(userId: string): Promise<StaffCatalogDto[]> {
  await claimInvites(userId);
  const grants = await CatalogDelegation.find({
    repUserId: new Types.ObjectId(userId),
    revokedAt: null,
    kind: { $in: STAFF_KINDS },
  })
    .lean()
    .exec();
  const catalogs = await Catalog.find({
    _id: { $in: grants.map((g) => g.catalogId) },
    deletedAt: null,
  })
    .select({ _id: 1, name: 1, businessName: 1 })
    .lean()
    .exec();
  const byId = new Map(catalogs.map((c) => [String(c._id), c]));
  return grants
    .filter((g) => byId.has(String(g.catalogId)))
    .map((g) => {
      const c = byId.get(String(g.catalogId))!;
      return {
        catalogId: String(g.catalogId),
        name: c.businessName || c.name,
        kind: g.kind as StaffKind,
        permissions: permissionsFor(g.kind as StaffKind),
      };
    });
}

/**
 * The catalog + role for a staff request — read fresh every time, so a revoke
 * takes effect immediately. Null for a stranger, a revoked grant, or a rep.
 */
export async function resolveStaffCatalog(
  userId: string,
  catalogId: string
): Promise<{ catalog: ICatalog; role: ActorRole } | null> {
  if (!Types.ObjectId.isValid(catalogId)) return null;
  const grant = await CatalogDelegation.findOne({
    repUserId: new Types.ObjectId(userId),
    catalogId: new Types.ObjectId(catalogId),
    revokedAt: null,
    kind: { $in: STAFF_KINDS },
  })
    .lean()
    .exec();
  if (!grant) return null;
  const catalog = await Catalog.findOne({ _id: grant.catalogId, deletedAt: null }).exec();
  return catalog ? { catalog, role: grant.kind as StaffKind } : null;
}
