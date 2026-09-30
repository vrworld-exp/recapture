// src/services/staff/staffPermissions.ts
//
// What each kind of helper may do on a catalog (more-customization Stage 14.3).
// The SERVER enforces this on every staff route — the app hiding a button is a
// courtesy, never the control.
//
//   permission     owner  MANAGER  STAFF
//   availability     ✓       ✓       ✓
//   prices           ✓       ✓       —
//   publish          ✓       ✓       ✓   (staff: only after an availability change)
//
// Appearance, subscription, billing, customers and the PDF stay owner-only by
// not existing on the staff router at all.
import type { DelegationKind } from '@/models/CatalogDelegation';

export const CATALOG_PERMISSIONS = ['availability', 'prices', 'publish'] as const;
export type CatalogPermission = (typeof CATALOG_PERMISSIONS)[number];

export type ActorRole = 'OWNER' | Exclude<DelegationKind, 'REP'>;

const MATRIX: Record<ActorRole, readonly CatalogPermission[]> = {
  OWNER: ['availability', 'prices', 'publish'],
  MANAGER: ['availability', 'prices', 'publish'],
  STAFF: ['availability', 'publish'],
};

export const permissionsFor = (role: ActorRole): readonly CatalogPermission[] => MATRIX[role];

export const can = (role: ActorRole, permission: CatalogPermission): boolean =>
  MATRIX[role].includes(permission);

/** At most this many live helpers (members + open invites) per catalog. */
export const MAX_STAFF_PER_CATALOG = 5;
