// src/services/subscription/paymentLedgerService.ts
//
// The ledger as the OWNER reads it: their catalog's last fifty rows, each with
// a simple receipt number (RECAPTURE_SUBSCRIPTION_PLAN.md §7 rule 7 — a
// receipt, not a GST invoice). Refund rows are included so the history is
// honest; there is no refund ACTION anywhere on an owner route (AC-5.1).
//
// Built field by field. What the owner never sees: provider ids, the frozen
// snapshot, who verified, admin notes.
import type { Types } from 'mongoose';

import { PaymentRecord, type IPaymentRecord } from '@/models/PaymentRecord';
import type {
  Actor,
  BillingInterval,
  ManualMethod,
  PaymentKind,
  PlanId,
  VerificationStatus,
} from '@/models/types/subscription.types';

export const OWNER_LEDGER_LIMIT = 50;

export interface OwnerPaymentDto {
  id: string;
  kind: PaymentKind;
  amountPaise: number;
  currency: string;
  /** ISO. */
  createdAt: string;
  method: ManualMethod | null;
  verificationStatus: VerificationStatus | null;
  /** Null on a comp or a refund, which carry no quote. */
  planId: PlanId | null;
  interval: BillingInterval | null;
  receiptNo: string;
}

/** `RC-` + the last eight hex chars of the row id — stable, short, not guessable in bulk. */
export function receiptNoFor(id: Types.ObjectId | string): string {
  return `RC-${String(id).slice(-8).toUpperCase()}`;
}

export function toOwnerPaymentDto(row: IPaymentRecord): OwnerPaymentDto {
  return {
    id: String(row._id),
    kind: row.kind,
    amountPaise: row.amountPaise,
    currency: row.currency,
    createdAt: row.createdAt.toISOString(),
    method: row.method ?? null,
    verificationStatus: row.verificationStatus ?? null,
    planId: row.quote?.planId ?? null,
    interval: row.quote?.interval ?? null,
    receiptNo: receiptNoFor(row._id as Types.ObjectId),
  };
}

/** Newest first, bounded. Open checkout orders are part of the history too. */
export async function listPaymentsForOwner(catalogId: Types.ObjectId): Promise<OwnerPaymentDto[]> {
  const rows = await PaymentRecord.find({ catalogId })
    .sort({ createdAt: -1, _id: -1 })
    .limit(OWNER_LEDGER_LIMIT)
    .lean<IPaymentRecord[]>()
    .exec();
  return rows.map(toOwnerPaymentDto);
}

/**
 * The same rows as an ADMIN reads them: plus the outcome note (which is
 * where DUPLICATE_SUSPECTED lives), who acted, and whether the row can still
 * be refunded from the app. Opaque actor ids and roles — no contact.
 */
export interface AdminPaymentDto extends OwnerPaymentDto {
  note: string | null;
  initiatedBy: { userId: string; role: Actor['role'] };
  verifiedBy: { userId: string; role: Actor['role'] } | null;
  /** The PAID row a REFUNDED row reverses. */
  refundsPaymentId: string | null;
  /** A PAID row with a provider payment id and no REFUNDED row against it yet. */
  isRefundable: boolean;
}

export async function listPaymentsForAdmin(catalogId: Types.ObjectId): Promise<AdminPaymentDto[]> {
  const rows = await PaymentRecord.find({ catalogId })
    .sort({ createdAt: -1, _id: -1 })
    .limit(OWNER_LEDGER_LIMIT)
    .lean<IPaymentRecord[]>()
    .exec();
  const refunded = new Set(
    rows
      .filter((r) => r.kind === 'REFUNDED' && r.refundsPaymentId)
      .map((r) => String(r.refundsPaymentId))
  );
  return rows.map((row) => ({
    ...toOwnerPaymentDto(row),
    note: row.note ?? null,
    initiatedBy: { userId: String(row.initiatedBy.userId), role: row.initiatedBy.role },
    verifiedBy: row.verifiedBy
      ? { userId: String(row.verifiedBy.userId), role: row.verifiedBy.role }
      : null,
    refundsPaymentId: row.refundsPaymentId ? String(row.refundsPaymentId) : null,
    isRefundable:
      row.kind === 'PAID' && Boolean(row.providerPaymentId) && !refunded.has(String(row._id)),
  }));
}
