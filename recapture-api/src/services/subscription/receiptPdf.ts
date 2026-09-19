// src/services/subscription/receiptPdf.ts
//
// The owner's receipt: one A4 page, text only, written by hand out of
// `pdfPrimitives` like every other PDF here (see that file's header for why
// there is no PDF library in the tree).
//
// A RECEIPT, NOT A TAX INVOICE (RECAPTURE_SUBSCRIPTION_PLAN.md §7 rule 7). No
// GSTIN, no tax breakdown, no "invoice" anywhere on the page, and one sentence
// that says so — the restaurant's accountant is the reader this line is for.
//
// NO CONTACT DETAILS. The page names the catalog and the plan; it never
// carries the owner's phone or email, so a receipt forwarded to a bookkeeper
// or left on a counter gives nothing away.
//
// The base-14 fonts are single-byte, so every string goes through
// `asciiFold` — which is also why the amount reads "Rs." and not "₹": the
// rupee sign is not in WinAnsi, and embedding a font for one glyph is not
// worth the weight (the whole file is under 4 KB as it is).
import type { IPaymentRecord } from '@/models/PaymentRecord';
import {
  A4_HEIGHT_PT,
  A4_WIDTH_PT,
  HELVETICA_BOLD_OBJECT,
  HELVETICA_OBJECT,
  asciiFold,
  assemblePdf,
  contentStreamObject,
  pdfText,
} from '@/services/pdfPrimitives';
import { receiptNoFor } from '@/services/subscription/paymentLedgerService';
import { toDisplayName } from '@/utils/catalogNames';

const DAY_MS = 86_400_000;

/** The one sentence a receipt must carry (§7 rule 7). Exported so the test pins the exact words. */
export const RECEIPT_NO_GST_LINE =
  'This is a payment receipt, not a tax invoice. No GST has been charged.';

export interface ReceiptInput {
  /** A PAID, MANUAL (VERIFIED) or COMP row — the route has already checked. */
  record: Pick<
    IPaymentRecord,
    | '_id'
    | 'kind'
    | 'amountPaise'
    | 'currency'
    | 'quote'
    | 'method'
    | 'reference'
    | 'note'
    | 'appliedAt'
    | 'verifiedAt'
    | 'createdAt'
  >;
  /** The catalog's STORED name (a slug); de-slugged here. */
  catalogName: string;
}

/** Whether a ledger row is one the owner may hold a receipt for. */
export function isReceiptEligible(
  row: Pick<IPaymentRecord, 'kind' | 'verificationStatus'>
): boolean {
  return (
    row.kind === 'PAID' ||
    row.kind === 'COMP' ||
    (row.kind === 'MANUAL' && row.verificationStatus === 'VERIFIED')
  );
}

export function receiptFileName(receiptNo: string): string {
  return `receipt-${receiptNo}.pdf`;
}

// ── Formatting ──────────────────────────────────────────────────────────────

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "19 Sep 2026", in UTC — the same calendar the periods are counted in. */
export function formatReceiptDate(date: Date): string {
  return `${date.getUTCDate()} ${MONTHS[date.getUTCMonth()]} ${date.getUTCFullYear()}`;
}

/** Indian digit grouping: 119900 → "Rs. 1,199.00"; 12345678 → "Rs. 1,23,456.78". */
export function formatInrPaise(paise: number): string {
  const rupees = Math.floor(paise / 100);
  const rest = String(paise % 100).padStart(2, '0');
  const digits = String(rupees);
  let grouped: string;
  if (digits.length <= 3) {
    grouped = digits;
  } else {
    const tail = digits.slice(-3);
    let head = digits.slice(0, -3);
    const groups: string[] = [];
    while (head.length > 2) {
      groups.unshift(head.slice(-2));
      head = head.slice(0, -2);
    }
    if (head.length > 0) groups.unshift(head);
    grouped = `${groups.join(',')},${tail}`;
  }
  return `Rs. ${grouped}.${rest}`;
}

function methodLabel(record: ReceiptInput['record']): string {
  switch (record.kind) {
    case 'PAID':
      return 'Online';
    case 'COMP':
      return 'Complimentary';
    case 'MANUAL':
      switch (record.method) {
        case 'CASH':
          return 'Cash';
        case 'BANK_TRANSFER':
          return 'Bank transfer';
        case 'CHEQUE':
          return 'Cheque';
        case 'UPI':
          return 'UPI';
        default:
          return 'Manual';
      }
    default:
      return record.kind;
  }
}

/**
 * The days this row paid for, if it earned a period. A PAID row that was
 * flagged (amount mismatch, duplicate, orphan) took money but applied no
 * period, and the receipt says exactly that rather than inventing dates.
 */
function periodLine(record: ReceiptInput['record']): string {
  const quote = record.quote;
  if (!quote) return record.kind === 'COMP' ? 'Complimentary access - see your subscription' : '-';
  const days = quote.interval === 'YEARLY' ? 365 : 30;
  const start =
    record.kind === 'PAID' && !record.note && record.appliedAt
      ? record.appliedAt
      : record.kind === 'MANUAL' && record.verifiedAt
        ? record.verifiedAt
        : null;
  if (!start) return 'Not applied to a plan period - under review';
  const end = new Date(start.getTime() + days * DAY_MS);
  return `${formatReceiptDate(start)} to ${formatReceiptDate(end)} (${days} days)`;
}

function planLine(record: ReceiptInput['record']): string {
  const quote = record.quote;
  if (!quote) return record.kind === 'COMP' ? 'Complimentary' : '-';
  return `${quote.planSnapshot.displayName} - ${quote.interval === 'YEARLY' ? 'yearly' : 'monthly'}`;
}

// ── Layout ──────────────────────────────────────────────────────────────────

const MARGIN = 56;
const LABEL_X = MARGIN;
const VALUE_X = MARGIN + 150;

/** One `BT … ET` block. Text is folded to ASCII and escaped here and nowhere else. */
function text(font: 'F1' | 'F2', size: number, x: number, y: number, value: string): string {
  return `BT /${font} ${size} Tf ${x.toFixed(2)} ${y.toFixed(2)} Td (${pdfText(asciiFold(value))}) Tj ET`;
}

/**
 * Renders the receipt. Deterministic: the same row renders the same bytes,
 * which is what makes "download it again" and "download it on another
 * device" hand out the identical document.
 */
export function renderReceipt(input: ReceiptInput): Buffer {
  const { record } = input;
  const receiptNo = receiptNoFor(String(record._id));
  const ops: string[] = [];
  let y = A4_HEIGHT_PT - MARGIN;

  ops.push(text('F2', 20, MARGIN, y, 'ReCapture'));
  y -= 26;
  ops.push(text('F2', 14, MARGIN, y, 'Payment receipt'));
  y -= 12;
  // A rule under the header.
  ops.push(`0.6 w ${MARGIN} ${y.toFixed(2)} m ${(A4_WIDTH_PT - MARGIN).toFixed(2)} ${y.toFixed(2)} l S`);
  y -= 30;

  const rows: [string, string][] = [
    ['Receipt no.', receiptNo],
    ['Date', formatReceiptDate(record.createdAt)],
    ['Restaurant', toDisplayName(input.catalogName)],
    ['Plan', planLine(record)],
    ['Period covered', periodLine(record)],
    ['Amount', formatInrPaise(record.amountPaise)],
    ['Method', methodLabel(record)],
    ['Reference', record.reference ?? '-'],
  ];
  for (const [label, value] of rows) {
    ops.push(text('F1', 10, LABEL_X, y, label));
    ops.push(text('F2', 11, VALUE_X, y, value));
    y -= 22;
  }

  y -= 18;
  ops.push(text('F1', 9, MARGIN, y, RECEIPT_NO_GST_LINE));
  y -= 14;
  ops.push(text('F1', 9, MARGIN, y, 'Payments are non-refundable. Keep this receipt for your records.'));

  const content = contentStreamObject(ops.join('\n'));
  const objects: Buffer[] = [
    Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'),
    Buffer.from('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    Buffer.from(
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${A4_WIDTH_PT} ${A4_HEIGHT_PT}] ` +
        '/Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>'
    ),
    Buffer.from(HELVETICA_OBJECT),
    Buffer.from(HELVETICA_BOLD_OBJECT),
    content,
  ];
  return assemblePdf(objects);
}
