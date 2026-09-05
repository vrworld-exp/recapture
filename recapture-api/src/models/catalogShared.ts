// src/models/catalogShared.ts
//
// Mongoose sub-schemas shared by more than one catalog collection. Kept in one
// place so the shape of a sync failure cannot drift between products and
// categories — the publish screen renders both through the same widget.
//
// Not in models/types/catalog.types.ts: that file is deliberately mongoose-free
// (services and the worker import it for the vocabularies alone).
import { Schema } from 'mongoose';
import type { SyncError } from './types/catalog.types';

/**
 * Why a row's last sync attempt failed. `code` is a ReCapture UPPER_SNAKE code
 * and `message` is OUR sentence — Mirage's prose is a classification input
 * inside the adapter and never reaches storage or a response body.
 */
export const SyncErrorSchema = new Schema<SyncError>(
  {
    code: { type: String, required: true },
    message: { type: String, required: true },
    at: { type: Date, required: true },
  },
  { _id: false }
);
