// src/services/subscription/ownerStandeeService.ts
//
// The owner's own standee download: "print N standees of my menu's QR", drawn
// from the plan's complimentary allowance.
//
// ONE POOL, NOT TWO. `standeeAllocation.issued` was the admin's human counter
// (README C8: what was physically handed over). The owner's downloads draw
// from the SAME number, so a Taste plan is ten standees in total — whether an
// admin handed over the paper or the owner printed it. The admin's
// `setStandeesIssued` still overwrites the count outright; that is the
// correction tool, and it is why this module only ever INCREMENTS.
//
// LIFETIME, NOT PER PERIOD. The paid-period write sets `included` from the plan on
// every payment and only seeds `issued` on insert, so a renewal hands out
// nothing new and an upgrade hands out the difference (Taste → Signature is
// five more). Do not reset `issued` on renewal without revisiting that
// decision — it was chosen over a per-period allowance.
//
// THE COUNT IS SPENT ON A SUCCESSFUL RENDER, not on a successful save. The
// route renders first and consumes second, so a render that throws costs
// nothing; a response that never reaches the phone (a dropped connection
// after the bytes left) is still counted, because the server cannot tell it
// apart from one that arrived.
import { Types } from 'mongoose';
import { CatalogSubscription, type ICatalogSubscription } from '@/models/CatalogSubscription';
import type { SubscriptionStatus } from '@/models/types/subscription.types';

/**
 * Statuses that hold a PAID (or granted) plan and so may print from it.
 * TRIAL and PENDING_PAYMENT carry no plan — their allowance is 0 anyway — and
 * PAUSED / CANCELLED have stopped paying: the paper they already printed keeps
 * working, but no more comes out of a plan that is not running.
 */
const DOWNLOAD_STATUSES: readonly SubscriptionStatus[] = ['ACTIVE', 'GRACE', 'COMPED'];

export interface StandeeQuota {
  included: number;
  issued: number;
  remaining: number;
  /** False when the row's status does not allow printing, whatever is left. */
  canDownload: boolean;
}

type AllocationRow = Pick<ICatalogSubscription, 'status' | 'standeeAllocation'>;

function quotaOf(row: AllocationRow | null): StandeeQuota {
  const included = row?.standeeAllocation?.included ?? 0;
  const issued = row?.standeeAllocation?.issued ?? 0;
  const remaining = Math.max(0, included - issued);
  const canDownload = row != null && DOWNLOAD_STATUSES.includes(row.status) && remaining > 0;
  return { included, issued, remaining, canDownload };
}

/** What this catalog could still print. A catalog with no row has nothing. */
export async function standeeQuotaFor(catalogId: Types.ObjectId): Promise<StandeeQuota> {
  const row = await CatalogSubscription.findOne({ catalogId })
    .select({ status: 1, standeeAllocation: 1 })
    .lean<AllocationRow>()
    .exec();
  return quotaOf(row);
}

export type ConsumeStandeesResult =
  | { outcome: 'CONSUMED'; quota: StandeeQuota }
  /** Not enough left, or a status that does not print. `quota` is the truth now. */
  | { outcome: 'REFUSED'; quota: StandeeQuota };

/**
 * `issued += copies`, guarded in the SAME write on `issued + copies <=
 * included` and on a printing status. Two downloads racing for the last
 * standee cannot both win: the second one's filter no longer matches.
 */
export async function consumeStandees(
  catalogId: Types.ObjectId,
  copies: number
): Promise<ConsumeStandeesResult> {
  const updated = await CatalogSubscription.findOneAndUpdate(
    {
      catalogId,
      status: { $in: DOWNLOAD_STATUSES },
      $expr: {
        $lte: [
          { $add: [{ $ifNull: ['$standeeAllocation.issued', 0] }, copies] },
          { $ifNull: ['$standeeAllocation.included', 0] },
        ],
      },
    },
    { $inc: { 'standeeAllocation.issued': copies } },
    { new: true }
  )
    .select({ status: 1, standeeAllocation: 1 })
    .lean<AllocationRow>()
    .exec();

  if (!updated) return { outcome: 'REFUSED', quota: await standeeQuotaFor(catalogId) };
  return { outcome: 'CONSUMED', quota: quotaOf(updated) };
}
