// src/services/adminUsersService.ts
//
// "Who made this?" — the OWNER identity behind a live project, for ADMIN only.
//
// ─────────────────────────────────────────────────────────────────────────────
// PII: THIS IS A DELIBERATE EXCEPTION TO THE MASKED-ONLY RULE — one of two.
//
// Almost everywhere in this API a contact identifier leaves as a MASK
// (utils/maskIdentifier.ts) and never as itself — /auth/me, the sales-rep
// roster, every staff DTO. {@link getAdminUserDetail} ships the RAW phone and
// email, because the reason it exists is for an admin to CONTACT the person who
// captured a project, and a mask cannot be dialled.
//
// The OTHER exception is the rep's delegated restaurant profile
// (`accountPhone`, routes/rep.ts), which rests on a bound this one does not
// have: the rep typed that number themselves at activation. The two are
// independent — neither is a precedent for widening the other, and both are
// enumerated in AGENTS.md §PII.
//
// The exception is bounded, and every bound is load-bearing:
//   • ADMIN only — enforced at the route with its own requireRole('ADMIN')
//     above the router's MODEL_ARTIST gate. A MODEL_ARTIST browsing the same
//     list still sees only the opaque ownerId it always saw.
//   • ON DEMAND only — the raw values live on the DETAIL call an admin makes by
//     tapping one person. They are NOT on the list DTO: a page of twenty
//     projects must not put twenty phone numbers on the wire because someone
//     opened a tab. {@link summarizeOwners} is the list-safe shape and carries
//     no identifier at all.
//   • NEVER LOGGED, never in analytics. The route audits the read with HASHED
//     ids (utils/otp.ts -> hashIdentifier), which is the whole point of
//     auditing it.
//
// Widening any of those is a PII policy decision and belongs in AGENTS.md
// before it belongs in code.
// ─────────────────────────────────────────────────────────────────────────────
//
// AVATARS are served as BYTES, never as the presigned `avatarUrl` the account
// snapshot uses. Two reasons, both already established elsewhere in this repo:
// the raw bucket serves no CORS, so the Flutter WEB build cannot render a
// presigned URL as an image at all (see GET /auth/me/avatar/bytes and the admin
// photo-bytes proxy), and a presigned URL is a bearer credential for a
// photograph of someone's face — handing a page of them out is worse than
// serving the one image an admin actually opened.
import { Types } from 'mongoose';
import { User, type UserRole } from '@/models/User';
import { getObjectBytes } from '@/services/s3ObjectStore';
import { env } from '@/config/env';

/** Where avatars live — the PRIVATE raw bucket. Same constant as routes/auth.ts
 * derives; re-derived rather than shared so neither surface can move the other's
 * bucket by accident (moving avatars to CloudFront is a policy change). */
const AVATAR_BUCKET = env.S3_BUCKET_RAW;

/**
 * The LIST-SAFE owner shape: enough to draw a "Created by" label and nothing
 * more. No phone, no email, not even a mask — an admin who wants those taps
 * through to {@link getAdminUserDetail}.
 */
export interface AdminOwnerSummary {
  id: string;
  /** User-chosen name, or null when the account never set one (the OTP flow
   * never collects one, so this is common). The client falls back to initials
   * and then to the opaque id. */
  displayName: string | null;
  /** Whether the account HAS a profile picture — a boolean, not a URL, so the
   * client knows whether it is worth asking `/avatar/bytes` for one row. */
  hasAvatar: boolean;
}

/** The full identity behind one project — the sheet an admin opens. RAW
 * contact; see the PII block at the top of this file. */
export interface AdminUserDetail extends AdminOwnerSummary {
  /** RAW email, or null when the account has none. */
  email: string | null;
  /** RAW phone, or null when the account has none. */
  phone: string | null;
  emailVerified: boolean;
  phoneVerified: boolean;
  role: UserRole;
  createdAt: string;
}

/** The projection every path here reads — deliberately explicit, so a field
 * added to the schema is never shipped by accident. */
const SUMMARY_FIELDS = { displayName: 1, avatarKey: 1 } as const;

/**
 * Owner summaries for a PAGE of projects, keyed by user id.
 *
 * ONE query for the whole page, not one per row, and de-duplicated first: a
 * list is usually a handful of prolific capturers, so twenty rows are rarely
 * twenty users. Ids that no longer resolve are simply absent from the map —
 * a deleted account must render as the opaque id it always was, never as a
 * crash.
 */
export async function summarizeOwners(
  userIds: readonly string[]
): Promise<Map<string, AdminOwnerSummary>> {
  const unique = [...new Set(userIds)].filter((id) => Types.ObjectId.isValid(id));
  if (unique.length === 0) return new Map();

  const docs = await User.find(
    { _id: { $in: unique.map((id) => new Types.ObjectId(id)) } },
    SUMMARY_FIELDS
  )
    .lean()
    .exec();

  return new Map(
    docs.map((doc) => {
      const id = String(doc._id);
      return [
        id,
        {
          id,
          displayName: doc.displayName ?? null,
          hasAvatar: Boolean(doc.avatarKey),
        },
      ];
    })
  );
}

/**
 * One user's full identity, or null when the id does not resolve (the route
 * maps that to the standard 404 — an admin whose list row outlived the account
 * gets "no longer exists", not a 500).
 */
export async function getAdminUserDetail(userId: string): Promise<AdminUserDetail | null> {
  if (!Types.ObjectId.isValid(userId)) return null;

  const doc = await User.findById(userId).lean().exec();
  if (!doc) return null;

  return {
    id: String(doc._id),
    displayName: doc.displayName ?? null,
    hasAvatar: Boolean(doc.avatarKey),
    // The exception, and the only place it is taken. See the PII block above.
    email: doc.email ?? null,
    phone: doc.phone ?? null,
    emailVerified: Boolean(doc.emailVerified),
    phoneVerified: Boolean(doc.phoneVerified),
    role: doc.role,
    createdAt: new Date(doc.createdAt).toISOString(),
  };
}

/** What an avatar read resolved to. `absent` covers both "never set one" and
 * "the pointer outlived the object" — the client renders initials either way,
 * so distinguishing them would buy the caller nothing. */
export type AdminAvatarResult =
  | { outcome: 'ok'; body: Buffer; contentType: string }
  | { outcome: 'absent' };

/**
 * One user's avatar IMAGE BYTES, read through the API.
 *
 * The key comes from the USER DOCUMENT, never from the caller — the same
 * containment property that makes GET /auth/me/avatar/bytes safe. There is no
 * `?key=` here and there must never be one: that would turn an admin route into
 * an arbitrary-object reader for the private bucket.
 */
export async function readUserAvatarBytes(userId: string): Promise<AdminAvatarResult> {
  if (!Types.ObjectId.isValid(userId)) return { outcome: 'absent' };

  const doc = await User.findById(userId, { avatarKey: 1 }).lean().exec();
  const key = doc?.avatarKey;
  if (!key) return { outcome: 'absent' };

  const object = await getObjectBytes(AVATAR_BUCKET, key);
  if (object.outcome === 'absent') return { outcome: 'absent' };

  return { outcome: 'ok', body: object.body, contentType: object.contentType };
}
