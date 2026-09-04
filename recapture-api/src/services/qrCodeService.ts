// src/services/qrCodeService.ts
//
// Minting, exporting and looking up pre-printed standee codes — pure inventory.
// Nothing here knows what a code POINTS AT; assignment is a later concern.
import { Types } from 'mongoose';
import { env } from '@/config/env';
import { QrBatch } from '@/models/QrBatch';
import { QrCode, type IQrCode } from '@/models/QrCode';
import { generateQrCode, normalizeQrCode } from '@/utils/qrCodes';

/**
 * Rounds of "generate, insert, see what collided". Each round only redraws the
 * slots that actually failed, so this is a bound on retries, not on batch size.
 *
 * At 8 characters over a 32-symbol alphabet even one collision in a 10,000-code
 * batch is vanishingly unlikely, so in practice round 0 always completes. Five
 * is a guard against a pathological RNG, not a expected-path tuning knob.
 */
const MAX_MINT_ROUNDS = 5;

/**
 * The export was asked for a URL and the deployment has no public origin
 * configured. Typed so the route answers 409 rather than leaking a stack.
 */
export class QrResolverNotConfiguredError extends Error {
  constructor() {
    super('PUBLIC_RESOLVER_BASE_URL is not configured');
    this.name = 'QrResolverNotConfiguredError';
  }
}

/** Minting could not reach the requested count within MAX_MINT_ROUNDS. */
export class QrMintExhaustedError extends Error {
  constructor(requested: number, minted: number) {
    super(`Minted only ${minted} of ${requested} codes after ${MAX_MINT_ROUNDS} rounds`);
    this.name = 'QrMintExhaustedError';
  }
}

/**
 * Inserts `codes` for `batchId`, tolerating duplicate-key failures, and reports
 * how many of the batch now exist.
 *
 * insertMany({ordered:false}) is what makes this work: an ORDERED insert stops
 * at the first duplicate and silently drops the rest of the batch, which would
 * hand the print vendor a short CSV nobody noticed was short.
 *
 * The success count is read back from the DB rather than parsed out of the bulk
 * write error. The driver's error shape for a partial unordered insert has
 * moved between versions (`insertedDocs`, `result.nInserted`, `writeErrors`),
 * and counting the rows that are actually there cannot be wrong.
 */
async function insertCodesUnordered(
  batchId: Types.ObjectId,
  codes: string[]
): Promise<number> {
  try {
    await QrCode.insertMany(
      codes.map((code) => ({ code, batchId, state: 'UNASSIGNED' as const, deletedAt: null })),
      { ordered: false }
    );
  } catch (err) {
    // A duplicate `code` is the expected, handled outcome — the caller redraws
    // the shortfall. Anything else (a connection drop, a validation failure) is
    // a real fault and must not be swallowed into a silently short batch.
    const code = (err as { code?: number }).code;
    const hasWriteErrors = Array.isArray((err as { writeErrors?: unknown[] }).writeErrors);
    if (code !== 11000 && !hasWriteErrors) throw err;
  }
  return QrCode.countDocuments({ batchId }).exec();
}

/**
 * Mints `count` codes in ONE batch, retrying only the slots that collided.
 *
 * On failure the batch is rolled back — codes and batch document both removed —
 * rather than left behind partially filled. A batch whose `count` disagrees with
 * its row count is exactly the short-print-run hazard this path exists to
 * prevent, so it must not be a state the collection can be found in.
 */
export async function mintBatch(params: {
  count: number;
  label: string;
  createdByUserId: Types.ObjectId;
}): Promise<{ batchId: Types.ObjectId; minted: number }> {
  const batch = await QrBatch.create({
    label: params.label,
    count: params.count,
    createdByUserId: params.createdByUserId,
  });
  const batchId = batch._id as Types.ObjectId;

  try {
    let minted = 0;
    for (let round = 0; round < MAX_MINT_ROUNDS && minted < params.count; round++) {
      const shortfall = params.count - minted;

      // De-duplicate WITHIN the draw before hitting the DB: two identical codes
      // in one insertMany would collide with each other, burning a retry round
      // on a collision the database never needed to see.
      //
      // The attempt budget is what makes this loop TERMINATE. An unbounded
      // `while (draw.size < shortfall)` spins forever against a degenerate RNG
      // — the one failure mode where hanging the request is worse than the
      // short batch it was trying to avoid. Falling short here is harmless: the
      // round simply inserts fewer, and MAX_MINT_ROUNDS turns a generator that
      // cannot deliver into a clean QrMintExhaustedError instead of a hang.
      const attemptBudget = shortfall * 4 + 32;
      const draw = new Set<string>();
      for (let attempt = 0; attempt < attemptBudget && draw.size < shortfall; attempt++) {
        draw.add(generateQrCode());
      }

      minted = await insertCodesUnordered(batchId, [...draw]);
    }

    if (minted < params.count) throw new QrMintExhaustedError(params.count, minted);
    return { batchId, minted };
  } catch (err) {
    await QrCode.deleteMany({ batchId }).exec();
    await QrBatch.deleteOne({ _id: batchId }).exec();
    throw err;
  }
}

/** Filesystem-safe stem for the download filename. Never parsed back. */
export function slugifyBatchLabel(label: string): string {
  const slug = label
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
  return slug || 'batch';
}

/**
 * The vendor's print file: one `code,url` line per standee, no header, so the
 * line count is the batch count and a short run is visible at a glance.
 *
 * Returns null when the batch does not exist. THROWS when
 * PUBLIC_RESOLVER_BASE_URL is unset — a CSV of URLs against a guessed host is
 * worse than no CSV, because it gets printed onto ten thousand physical
 * standees before anyone notices.
 *
 * The URL is emitted exactly as the resolver will accept it and exactly as
 * stage 4 writes it into `catalog.publicUrl`; these three strings must stay
 * byte-identical or a printed code resolves to nothing.
 */
export async function exportBatchCsv(batchId: Types.ObjectId): Promise<string | null> {
  const base = env.PUBLIC_RESOLVER_BASE_URL;
  if (!base) throw new QrResolverNotConfiguredError();

  const batch = await QrBatch.findById(batchId).exec();
  if (!batch) return null;

  // Sorted by code so a re-export of the same batch is byte-identical — a
  // vendor diffing two downloads should see nothing, not a reshuffle.
  const codes = await QrCode.find({ batchId, deletedAt: null }, { code: 1 })
    .sort({ code: 1 })
    .lean()
    .exec();

  return codes.map((c) => `${c.code},${base}/r/${c.code}`).join('\n');
}

/**
 * Looks up one code by its printed form. Normalises first, so a malformed code
 * costs zero database round trips — which is what keeps the public resolver's
 * not-found path cheap enough to be safe to expose.
 */
export async function findByCode(code: string): Promise<IQrCode | null> {
  const normalized = normalizeQrCode(code);
  if (!normalized) return null;
  return QrCode.findOne({ code: normalized, deletedAt: null }).exec();
}
