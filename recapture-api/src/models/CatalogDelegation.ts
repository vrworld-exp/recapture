// src/models/CatalogDelegation.ts
import { Schema, model, Document, Types } from 'mongoose';

/**
 * An explicit, revocable, audited grant: "this rep may act on this catalog".
 *
 * THE RESTAURANT OWNS THE CATALOG — never the rep. That single rule is what
 * preserves the unique index on `Catalog.userId`, every `userId`-scoped query in
 * the authoring services, and `resolveOwnedModel`'s ownership proof; none of
 * them had to be weakened to let a rep write. A rep's access is this row and
 * nothing else, so revoking is one field write and takes effect on the very
 * next request — no token to expire, no cache to bust.
 *
 * REVOKED RATHER THAN DELETED, for the same reason QrCode has a RETIRED state:
 * "who could act on this catalog last March" is an audit question that a
 * deleted row cannot answer, and a rep whose access was withdrawn is exactly
 * the case someone will later need to reconstruct.
 */
export interface ICatalogDelegation extends Document {
  repUserId: Types.ObjectId;
  catalogId: Types.ObjectId;
  grantedAt: Date;
  /** Null while the grant is live. Set — never unset — when it is withdrawn. */
  revokedAt: Date | null;
  /**
   * Who granted it. Absent when the rep granted it to themselves by activating
   * the code, which is the ordinary path; present when staff granted it.
   */
  grantedByUserId?: Types.ObjectId;
  createdAt: Date;
  updatedAt: Date;
}

const CatalogDelegationSchema = new Schema<ICatalogDelegation>(
  {
    repUserId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    grantedAt: { type: Date, required: true },
    // `default: null` rather than absent, so the partial index below matches on
    // a field that is really there. A missing field and an explicit null are
    // the same to a query but not to everyone reading the collection.
    revokedAt: { type: Date, default: null },
    grantedByUserId: { type: Schema.Types.ObjectId, ref: 'User' },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// One LIVE grant per rep per catalog. The partial filter is load-bearing: a
// plain unique index on {repUserId, catalogId} would make a revoked grant block
// the re-grant forever, and "revoke by mistake, grant again" is an ordinary
// Monday. A partial index is the only thing in Mongo that expresses "unique
// while live", and it is what lets grantDelegation be a blind upsert rather
// than a read-then-write two concurrent activations would both pass.
CatalogDelegationSchema.index(
  { repUserId: 1, catalogId: 1 },
  { unique: true, partialFilterExpression: { revokedAt: null } }
);

// "Who can act on this catalog" — the audit view, and the revoke-all sweep.
CatalogDelegationSchema.index({ catalogId: 1, revokedAt: 1 });

// "Which catalogs may this rep act on" — GET /rep/catalogs, the rep's home
// screen, run on every app open.
CatalogDelegationSchema.index({ repUserId: 1, revokedAt: 1 });

export const CatalogDelegation = model<ICatalogDelegation>(
  'CatalogDelegation',
  CatalogDelegationSchema
);
