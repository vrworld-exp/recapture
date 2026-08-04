// src/worker/engine/meshy/meshyClient.ts
//
// Thin HTTP transport for the Meshy AI Multi-Image to 3D API — NO business
// logic. Shapes are grounded in the live contract
// (https://docs.meshy.ai/en/api/multi-image-to-3d):
//
//   POST /openapi/v1/multi-image-to-3d      { image_urls: [...] } -> { result: taskId }
//   GET  /openapi/v1/multi-image-to-3d/:id  -> { id, status, progress, model_urls, ... }
//
// MONEY SAFETY: this module's only real judgement call is the HTTP-status →
// error-class mapping below. A quota/credit failure that is classified as
// retryable retries forever and burns credits, so the mapping is the thing to
// keep correct (and the thing the unit test pins).
//
// SECRETS: MESHY_API_KEY goes in the Authorization header and NOWHERE else —
// never a log line, never an error message. Image URLs are presigned S3 GETs
// (bearer credentials for that object), so they are never logged either.
import axios, { type AxiosInstance } from 'axios';
import { env } from '@/config/env';
import { NonRetryableJobError } from '@/worker/workerTypes';

/** Stable JobError codes this client raises — surfaced on the failed record. */
export const MeshyErrorCode = {
  /** 402 / credits exhausted. Terminal: a retry only fails again (or charges). */
  QUOTA_EXHAUSTED: 'MESHY_QUOTA_EXHAUSTED',
  /** 400 / 422 — the images or request shape are unusable. Terminal. */
  INVALID_INPUT: 'MESHY_INVALID_INPUT',
  /** 401 / 403 — the API key is missing/rejected. Terminal: retrying a bad
   * credential can never succeed, and it costs no credits either way. An
   * operator fixes this by setting MESHY_API_KEY, not by waiting. */
  AUTH_FAILED: 'MESHY_AUTH_FAILED',
  /** 404 on retrieve — the task id does not exist (or was purged). Terminal. */
  TASK_NOT_FOUND: 'MESHY_TASK_NOT_FOUND',
  /** The task itself reported status FAILED. Terminal. */
  GENERATION_FAILED: 'MESHY_GENERATION_FAILED',
  /** The task was canceled out from under us (Meshy side). Terminal. */
  GENERATION_CANCELED: 'MESHY_GENERATION_CANCELED',
  /** Exceeded MESHY_TASK_TIMEOUT_MS waiting for a terminal status. */
  TIMEOUT: 'MESHY_TIMEOUT',
} as const;

/** Meshy task lifecycle, verbatim from the retrieve response's `status`. */
export type MeshyTaskStatus = 'PENDING' | 'IN_PROGRESS' | 'SUCCEEDED' | 'FAILED' | 'CANCELED';

/** Downloadable result URLs. All EXPIRE (see `expiresAt`) — never persist one. */
export interface MeshyModelUrls {
  glb?: string;
  usdz?: string;
  fbx?: string;
}

/** The retrieve response, normalized to camelCase for our side of the seam. */
export interface MeshyTask {
  id: string;
  status: MeshyTaskStatus;
  /** 0–100. */
  progress: number;
  modelUrls: MeshyModelUrls;
  thumbnailUrl?: string;
  /** Instant the result URLs stop working, when Meshy reports one. */
  expiresAt?: Date;
  /** Meshy's own failure message when `status` is FAILED (diagnostics only). */
  taskError?: string;
}

/** The transport surface. Kept tiny so the processor can inject a fake. */
export interface MeshyClient {
  createMultiImageTask(imageUrls: string[]): Promise<{ taskId: string }>;
  getTask(taskId: string): Promise<MeshyTask>;
  cancelTask(taskId: string): Promise<void>;
}

const MULTI_IMAGE_PATH = '/openapi/v1/multi-image-to-3d';

/**
 * The Mirage Menu production generation preset — the fixed half of every
 * multi-image request. Sent EXPLICITLY rather than left to Meshy's defaults so
 * a result is reproducible across environments and across Meshy's own default
 * changes (which have already bitten us once — see `should_remesh`).
 *
 * The two remaining knobs, `target_polycount` and `texture_resolution`, stay in
 * config/env.ts because they are the ones an operator retunes against a device
 * test without a deploy. Both are now tuned for FIDELITY (200k triangles, 4k
 * maps), not for what a phone can hold: this request produces the SOURCE, and
 * src/modules/asset-pipeline produces the asset that is actually served. Nothing
 * in this preset should be traded away for file size — that is the pipeline's
 * job, and it is much better at it than a generator hitting a hard cap in one
 * step.
 *
 * Field by field, and why:
 *   ai_model 'latest'        — resolves to meshy-6, the best organic/food geometry.
 *   should_remesh true       — MUST be explicit: meshy-6 defaults this to FALSE,
 *                              which returns the raw unbounded mesh (see below).
 *                              Kept true even though we now ask for a HIGH
 *                              budget: false makes target_polycount ignored
 *                              entirely and output non-deterministic (observed
 *                              55k–1.2M triangles for the same kind of object).
 *                              A high PINNED budget is the goal, not an
 *                              unbounded one.
 *   topology 'triangle'      — GLB triangulates on export anyway.
 *   should_texture true      — Meshy's default; pinned so a default flip is inert.
 *   enable_pbr true          — a roughness map is what separates glossy gravy
 *                              from dry naan. NOTE: this adds a metallicRoughness
 *                              (and normal) texture per material, which is what
 *                              the asset pipeline's collapseConstantMetalRough
 *                              step exists to claw back when the map is flat.
 *   remove_lighting true     — no baked highlights/shadows; the viewer lights the
 *                              scene, so a model looks right under any menu theme.
 *   auto_size true           — real-world scale, so AR placement is correct
 *                              without the client guessing a scale factor.
 *   origin_at 'bottom'       — the model sits ON the table rather than sunk
 *                              half-through it when placed at a hit-test point.
 *   moderation false         — Meshy's default; food never trips it and the extra
 *                              pass only adds latency against MESHY_TASK_TIMEOUT_MS.
 *   alpha_thumbnail true     — a TRANSPARENT PNG poster, which is what the dark
 *                              (#0B0B0E) menu cards need. This is why the
 *                              re-hosted preview is `preview.png`/`image/png` in
 *                              meshyModelProcessor — the two must stay in step.
 *   multi_view_thumbnails    — OFF: nothing renders the extra views yet, and each
 *                              one costs generation time we would not spend.
 *   target_formats           — glb (the viewer) + usdz (iOS Quick Look). Anything
 *                              else is generation time for bytes we never serve.
 */
export const MESHY_PRESET = {
  ai_model: 'latest',
  should_remesh: true,
  topology: 'triangle',
  should_texture: true,
  enable_pbr: true,
  remove_lighting: true,
  auto_size: true,
  origin_at: 'bottom',
  moderation: false,
  alpha_thumbnail: true,
  multi_view_thumbnails: false,
  target_formats: ['glb', 'usdz'],
} as const;

/**
 * Fails fast when the Meshy credential is absent. Called at WORKER boot (the
 * only process that talks to Meshy) — see the MESHY_API_KEY note in config/env.ts
 * for why the shared schema leaves it optional.
 */
export function assertMeshyConfigured(): void {
  if (!env.MESHY_API_KEY) {
    throw new Error(
      'MESHY_API_KEY is required to process MESHY_MODEL_GENERATION jobs — set it in the worker environment.'
    );
  }
}

let http: AxiosInstance | undefined;

/** Lazily built so importing this module never requires the key to be present. */
function transport(): AxiosInstance {
  if (!http) {
    assertMeshyConfigured();
    http = axios.create({
      baseURL: env.MESHY_BASE_URL,
      headers: { Authorization: `Bearer ${env.MESHY_API_KEY}` },
      // Per-request ceiling only — the overall wait is bounded by the
      // processor's MESHY_TASK_TIMEOUT_MS budget, not by this.
      timeout: 30_000,
      // We classify every status ourselves (see toMeshyError).
      validateStatus: () => true,
    });
  }
  return http;
}

/** Test seam: drop the memoized instance so a re-created env/mock is picked up. */
export function resetMeshyTransport(): void {
  http = undefined;
}

/**
 * Maps one Meshy HTTP status onto the worker's error contract:
 *   • NonRetryableJobError → terminal FAILED, no retry, no credit burn;
 *   • plain Error          → the worker's retry/backoff path.
 * The `body` is NEVER interpolated into the message — it may echo the request
 * (and therefore our presigned image URLs) back at us.
 */
function toMeshyError(status: number, context: string): Error {
  if (status === 402) {
    return new NonRetryableJobError(
      MeshyErrorCode.QUOTA_EXHAUSTED,
      'Meshy rejected the request for insufficient credits.',
      context
    );
  }
  if (status === 401 || status === 403) {
    return new NonRetryableJobError(
      MeshyErrorCode.AUTH_FAILED,
      'Meshy rejected the API credential.',
      context
    );
  }
  if (status === 404) {
    return new NonRetryableJobError(
      MeshyErrorCode.TASK_NOT_FOUND,
      'Meshy has no such generation task.',
      context
    );
  }
  if (status === 400 || status === 422) {
    return new NonRetryableJobError(
      MeshyErrorCode.INVALID_INPUT,
      'Meshy rejected the source images as unusable.',
      context
    );
  }
  // 429 and 5xx are the classic transient pair; any other unexpected status is
  // treated as transient too — a retry is cheap (no task was created) and the
  // worker's maxAttempts still bounds it.
  return new Error(`Meshy request failed with status ${status} (${context})`);
}

function normalizeTask(raw: Record<string, unknown>, fallbackId: string): MeshyTask {
  const modelUrls = (raw.model_urls ?? {}) as Record<string, unknown>;
  const expiresAtMs = typeof raw.expires_at === 'number' ? raw.expires_at : undefined;
  return {
    id: typeof raw.id === 'string' ? raw.id : fallbackId,
    status: raw.status as MeshyTaskStatus,
    progress: typeof raw.progress === 'number' ? raw.progress : 0,
    modelUrls: {
      ...(typeof modelUrls.glb === 'string' ? { glb: modelUrls.glb } : {}),
      ...(typeof modelUrls.usdz === 'string' ? { usdz: modelUrls.usdz } : {}),
      ...(typeof modelUrls.fbx === 'string' ? { fbx: modelUrls.fbx } : {}),
    },
    ...(typeof raw.thumbnail_url === 'string' ? { thumbnailUrl: raw.thumbnail_url } : {}),
    ...(expiresAtMs !== undefined ? { expiresAt: new Date(expiresAtMs) } : {}),
    ...(typeof raw.task_error === 'string' ? { taskError: raw.task_error } : {}),
  };
}

export const meshyClient: MeshyClient = {
  /**
   * Submits 1–4 image URLs and returns Meshy's task id. THIS CALL SPENDS
   * CREDITS: the caller must persist the returned id before doing anything
   * else, so a crash can never turn into a second submission.
   *
   * The whole recipe is sent EXPLICITLY rather than left to Meshy's defaults —
   * see MESHY_PRESET above for the field-by-field reasoning. The load-bearing
   * one is `should_remesh`: it defaults to false on Meshy's newer models
   * (including the meshy-6 that `ai_model: 'latest'` resolves to), which returns
   * the raw generated mesh — unbounded in practice (observed 55k–1.2M triangles
   * for the same kind of captured object). Pinning remesh + target_polycount +
   * texture_resolution is what makes one generation REPRODUCIBLE.
   *
   * What it no longer makes true, deliberately, is "the result is directly
   * servable". This request asks for 200k triangles and 4k textures because a
   * low generation budget was breaking thin geometry at the source. The GLB it
   * returns is the ARCHIVE and the pipeline's input; the asset an owner loads is
   * the 'web' variant produced by src/modules/asset-pipeline and auto-promoted
   * once it passes its gates. See MESHY_TARGET_POLYCOUNT in config/env.ts for
   * the full policy and the WebView history behind it.
   *
   * Adding a field here is not free: an unknown parameter is a 400, which this
   * client classifies as TERMINAL. Check docs/meshy-integration.md and the live
   * /openapi/v1/multi-image-to-3d reference before adding one.
   */
  async createMultiImageTask(imageUrls: string[]): Promise<{ taskId: string }> {
    const res = await transport().post(MULTI_IMAGE_PATH, {
      image_urls: imageUrls,
      ...MESHY_PRESET,
      // The environment-tunable half of the recipe (config/env.ts), kept out of
      // the preset so it can be retuned per environment against a device test.
      target_polycount: env.MESHY_TARGET_POLYCOUNT,
      texture_resolution: env.MESHY_TEXTURE_RESOLUTION,
    });
    if (res.status < 200 || res.status >= 300) {
      throw toMeshyError(res.status, 'create multi-image task');
    }
    const taskId = (res.data as { result?: unknown })?.result;
    if (typeof taskId !== 'string' || taskId.length === 0) {
      // A 2xx with no task id means we may have been charged for a task we can
      // never poll. Terminal + loud rather than a retry that charges again.
      throw new NonRetryableJobError(
        MeshyErrorCode.GENERATION_FAILED,
        'Meshy accepted the request but returned no task id.'
      );
    }
    return { taskId };
  },

  async getTask(taskId: string): Promise<MeshyTask> {
    const res = await transport().get(`${MULTI_IMAGE_PATH}/${encodeURIComponent(taskId)}`);
    if (res.status < 200 || res.status >= 300) {
      throw toMeshyError(res.status, 'retrieve task');
    }
    return normalizeTask((res.data ?? {}) as Record<string, unknown>, taskId);
  },

  /**
   * Best-effort cancel (job canceled / claim lost mid-poll). Failure here is
   * swallowed: we are already unwinding, and a stuck Meshy task is Meshy's to
   * expire — turning cleanup into a job failure would be strictly worse.
   */
  async cancelTask(taskId: string): Promise<void> {
    await transport()
      .post(`${MULTI_IMAGE_PATH}/${encodeURIComponent(taskId)}/cancel`)
      .catch(() => undefined);
  },
};

let active: MeshyClient = meshyClient;

/** Injection seam — tests register a fake so CI never touches the live API. */
export function setMeshyClient(client: MeshyClient): void {
  active = client;
}

export function getMeshyClient(): MeshyClient {
  return active;
}
