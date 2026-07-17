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
   */
  async createMultiImageTask(imageUrls: string[]): Promise<{ taskId: string }> {
    const res = await transport().post(MULTI_IMAGE_PATH, { image_urls: imageUrls });
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
