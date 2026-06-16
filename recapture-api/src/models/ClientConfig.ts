// src/models/ClientConfig.ts
import { Schema, model } from 'mongoose';

/**
 * Store for the runtime config served by GET /remote-config. A single global
 * document holds the current tuning; ops edit it to change client behaviour
 * without an app release. There is intentionally no per-user/per-project config.
 *
 * The fields are stored loosely (`Mixed`, `strict: false`) ON PURPOSE: the read
 * path validates the document against `remoteConfigSchema` and degrades to baked
 * defaults if it is missing or malformed, so the model must not itself reject a
 * malformed write — the resilience lives in the serving layer, not the schema.
 */
const ClientConfigSchema = new Schema(
  {
    version: { type: Number },
    pitchBands: { type: Schema.Types.Mixed },
    thresholds: { type: Schema.Types.Mixed },
    segmentCounts: { type: Schema.Types.Mixed },
  },
  {
    timestamps: true,
    collection: 'client_configs',
    strict: false,
    minimize: false,
  }
);

export const ClientConfig = model('ClientConfig', ClientConfigSchema);
