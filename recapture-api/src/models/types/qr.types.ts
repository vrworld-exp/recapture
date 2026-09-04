// src/models/types/qr.types.ts
//
// Shared vocabulary for the pre-printed QR inventory (models/QrCode.ts,
// QrBatch.ts, QrCodeAssignment.ts, QrScanDaily.ts).
//
// Lives here, beside the other model type files, for the same reason
// catalog.types.ts does: routes, services and the scan-rollup worker all need
// it, and services must not import from the worker.

/**
 * Lifecycle of one physical standee.
 *
 *   UNASSIGNED — minted and (probably) printed, pointing at nothing. This is
 *                the resting state of stock sitting in a box; it resolves to a
 *                not-found page, never to a guessable catalog.
 *   ACTIVE     — carries a catalogId and resolves to that catalog's menu.
 *   RETIRED    — deliberately taken out of service (a lost or damaged standee
 *                replaced by a second code onto the SAME catalog). Retired
 *                rather than deleted so the scan history stays attributable and
 *                the code can never be re-minted onto something else.
 */
export const QR_CODE_STATES = ['UNASSIGNED', 'ACTIVE', 'RETIRED'] as const;
export type QrCodeState = (typeof QR_CODE_STATES)[number];
