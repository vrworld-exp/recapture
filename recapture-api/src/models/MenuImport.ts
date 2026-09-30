// src/models/MenuImport.ts
//
// One "import my printed menu" run (more-customization Stage 13.1):
//   UPLOADING → (start) → PROCESSING → READY | FAILED → APPLIED → UNDONE
//
// The pages sit in S3 under `{env}/imports/{catalogId}/{importId}/`; the
// MENU_IMPORT job reads each one with the AI provider, and the cleaned draft
// (services/menuImport/sanitize.ts) is stored here for the review screen. Apply
// creates the rows tagged with this import's id — which is what Undo removes —
// and bumps draftRevision once. Nothing here ever publishes.
import { Schema, model, Document, Types } from 'mongoose';

import type { MenuDraft } from '@/services/menuImport/sanitize';

export const MENU_IMPORT_STATUSES = [
  'UPLOADING',
  'PROCESSING',
  'READY',
  'FAILED',
  'APPLIED',
  'UNDONE',
] as const;
export type MenuImportStatus = (typeof MENU_IMPORT_STATUSES)[number];

export const MENU_IMPORT_MAX_PAGES = 10;
export const MENU_IMPORT_MAX_PER_DAY = 5;
export const MENU_IMPORT_MEDIA_TYPES = [
  'image/jpeg',
  'image/png',
  'image/webp',
  'application/pdf',
] as const;

export interface MenuImportFile {
  key: string;
  contentType: string;
}

export interface IMenuImport extends Document {
  catalogId: Types.ObjectId;
  /** Who started it — the owner, or a rep on a delegated catalog. */
  createdByUserId: Types.ObjectId;
  status: MenuImportStatus;
  files: MenuImportFile[];
  /** Pages read so far, for the progress bar. */
  pagesDone: number;
  draft?: MenuDraft;
  costInr: number;
  error?: { code: string; message: string };
  appliedAt?: Date;
  /** What Apply did — exactly what Undo may reverse. */
  applied?: {
    categoryIds: Types.ObjectId[];
    productIds: Types.ObjectId[];
    priceUpdates: { productId: Types.ObjectId; from: number | null; to: number }[];
  };
  /** Pages deleted from S3 (after apply / undo, or 30 days). */
  filesPurgedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

const MenuImportSchema = new Schema<IMenuImport>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    createdByUserId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    status: { type: String, enum: MENU_IMPORT_STATUSES, required: true, default: 'UPLOADING' },
    files: {
      type: [new Schema<MenuImportFile>({ key: String, contentType: String }, { _id: false })],
      default: [],
    },
    pagesDone: { type: Number, default: 0 },
    // Mixed: a read model written once by the worker, validated by sanitize.ts.
    draft: { type: Schema.Types.Mixed },
    costInr: { type: Number, default: 0 },
    error: { type: new Schema({ code: String, message: String }, { _id: false }) },
    appliedAt: { type: Date },
    applied: { type: Schema.Types.Mixed },
    filesPurgedAt: { type: Date },
  },
  { timestamps: true, minimize: false }
);

// "This catalog's imports, newest first" and the per-day cap count.
MenuImportSchema.index({ catalogId: 1, createdAt: -1 });
// The 30-day file purge.
MenuImportSchema.index({ filesPurgedAt: 1, createdAt: 1 });

export const MenuImport = model<IMenuImport>('MenuImport', MenuImportSchema);
