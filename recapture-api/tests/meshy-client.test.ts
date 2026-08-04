// tests/meshy-client.test.ts
//
// The meshyClient's HTTP-status → error-class mapping. This is the mapping that
// decides whether a failure RETRIES: getting the 402 row wrong means a quota
// failure retries forever and burns credits, so every row is pinned here.
//
// Hermetic: axios.create is stubbed, so CI never touches the live Meshy API.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import axios from 'axios';

import { env } from '@/config/env';
import { NonRetryableJobError } from '@/worker/workerTypes';
import {
  meshyClient,
  MeshyErrorCode,
  MESHY_PRESET,
  resetMeshyTransport,
} from '@/worker/engine/meshy/meshyClient';

interface FakeResponse {
  status: number;
  data?: unknown;
}

let post: ReturnType<typeof vi.fn>;
let get: ReturnType<typeof vi.fn>;

/** Stubs the axios instance meshyClient builds, and captures its config. */
function stubTransport(response: FakeResponse): { config: Record<string, unknown> } {
  const captured: { config: Record<string, unknown> } = { config: {} };
  post = vi.fn().mockResolvedValue(response);
  get = vi.fn().mockResolvedValue(response);
  vi.spyOn(axios, 'create').mockImplementation(((config: Record<string, unknown>) => {
    captured.config = config;
    return { post, get } as never;
  }) as never);
  return captured;
}

beforeEach(() => {
  // The transport is memoized and built lazily; drop it so each test's stub wins.
  resetMeshyTransport();
  // @ts-expect-error — env is a plain parsed object; the key is optional by schema.
  env.MESHY_API_KEY = 'test-meshy-key';
});

afterEach(() => {
  vi.restoreAllMocks();
  resetMeshyTransport();
});

describe('meshyClient — request shape', () => {
  it('posts image_urls to the multi-image endpoint with a bearer key and returns result as taskId', async () => {
    const captured = stubTransport({ status: 200, data: { result: 'task-abc' } });

    const result = await meshyClient.createMultiImageTask(['https://s3/a', 'https://s3/b']);

    expect(result).toEqual({ taskId: 'task-abc' });
    // Field name is the live contract's: `image_urls`, not `images`/`image_url`.
    expect(post).toHaveBeenCalledWith('/openapi/v1/multi-image-to-3d', {
      image_urls: ['https://s3/a', 'https://s3/b'],
      ...MESHY_PRESET,
      target_polycount: env.MESHY_TARGET_POLYCOUNT,
      texture_resolution: env.MESHY_TEXTURE_RESOLUTION,
    });
    expect(captured.config.baseURL).toBe(env.MESHY_BASE_URL);
    expect((captured.config.headers as Record<string, string>).Authorization).toBe(
      'Bearer test-meshy-key'
    );
  });

  it('pins a HIGH but bounded mesh budget instead of taking Meshy defaults', async () => {
    // The regression this guards: with should_remesh left to Meshy's default
    // (false on its newer models — including the meshy-6 that ai_model 'latest'
    // resolves to) the returned GLB is unbounded — live results ranged 55k to
    // 1.2M triangles for the same kind of object, i.e. non-deterministic output.
    //
    // The budget is now a QUALITY number, not the phone's: a low cap was
    // breaking thin geometry at the source, and the asset pipeline's simplify
    // stage is what brings the result back down to something a WebView loads.
    // So this asserts "high AND pinned", which is the whole intent.
    stubTransport({ status: 200, data: { result: 'task-abc' } });

    await meshyClient.createMultiImageTask(['https://s3/a']);

    const body = post.mock.calls[0]?.[1] as Record<string, unknown>;
    // Pinned: remesh on, budget explicit. Turning remesh off would make
    // target_polycount ignored entirely.
    expect(body.should_remesh).toBe(true);
    expect(body.target_polycount).toBe(env.MESHY_TARGET_POLYCOUNT);
    // High: far above the 12k phone budget this used to carry. The exact value
    // is retunable, but "generation asks for fidelity" is not.
    expect(env.MESHY_TARGET_POLYCOUNT).toBeGreaterThanOrEqual(100_000);
    // Meshy's own accepted range — a budget outside it is rejected at 400,
    // which this client classifies as TERMINAL (no retry, no second charge).
    expect(env.MESHY_TARGET_POLYCOUNT).toBeGreaterThanOrEqual(100);
    expect(env.MESHY_TARGET_POLYCOUNT).toBeLessThanOrEqual(300_000);
  });

  it('asks for a texture resolution above what it serves, as the resample source', async () => {
    // The pipeline resamples every texture to the profile's per-slot budget, so
    // this is source detail for that resample — not what the phone decodes.
    stubTransport({ status: 200, data: { result: 'task-abc' } });

    await meshyClient.createMultiImageTask(['https://s3/a']);

    const body = post.mock.calls[0]?.[1] as Record<string, unknown>;
    expect(body.texture_resolution).toBe(env.MESHY_TEXTURE_RESOLUTION);
    expect(['4k', '8k']).toContain(env.MESHY_TEXTURE_RESOLUTION);
  });

  it('budgets enough wall-clock for a high-fidelity task without changing poll cadence', async () => {
    // Both knobs above cost Meshy time, and a timeout raises MESHY_TIMEOUT whose
    // retry SPENDS CREDITS AGAIN. Raising the total budget must not touch the
    // poll interval: each poll doubles as the worker's claim-lease renewal, so
    // it has to stay well under WORKER_CLAIM_TIMEOUT_MS or a live generation is
    // re-claimed mid-flight.
    expect(env.MESHY_TASK_TIMEOUT_MS).toBeGreaterThanOrEqual(1_800_000);
    expect(env.MESHY_POLL_INTERVAL_MS * 4).toBeLessThan(env.WORKER_CLAIM_TIMEOUT_MS);
  });

  it('sends the Mirage Menu preset verbatim — every field Meshy would otherwise default', () => {
    // A value table, not a shape check: each of these overrides a Meshy default
    // that would silently change the product. `alpha_thumbnail` in particular is
    // coupled to meshyModelProcessor re-hosting the poster as preview.png.
    //
    // It is also the guard against inventing parameters: an unknown field comes
    // back a 400, which this client treats as terminal. A new key here has to be
    // verified against the live /openapi/v1/multi-image-to-3d reference first.
    expect(MESHY_PRESET).toEqual({
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
    });
  });

  it('leaves the two device-tunable knobs on env, not baked into the preset', () => {
    // Still true, and still for the same reason: these are what an operator
    // retunes per environment against a real device (now against the pipeline's
    // profile too), so they must not be frozen into the preset constant.
    expect(MESHY_PRESET).not.toHaveProperty('target_polycount');
    expect(MESHY_PRESET).not.toHaveProperty('texture_resolution');
  });

  it('normalizes the retrieve response into a typed MeshyTask', async () => {
    stubTransport({
      status: 200,
      data: {
        id: 'task-abc',
        status: 'IN_PROGRESS',
        progress: 42,
        model_urls: { glb: 'https://meshy/x.glb', usdz: 'https://meshy/x.usdz' },
        thumbnail_url: 'https://meshy/x.jpg',
        expires_at: 1_800_000_000_000,
      },
    });

    const task = await meshyClient.getTask('task-abc');

    expect(task.status).toBe('IN_PROGRESS');
    expect(task.progress).toBe(42);
    expect(task.modelUrls.glb).toBe('https://meshy/x.glb');
    expect(task.thumbnailUrl).toBe('https://meshy/x.jpg');
    expect(task.expiresAt).toEqual(new Date(1_800_000_000_000));
  });
});

describe('meshyClient — status to error class (the money mapping)', () => {
  // [status, expected code] — a NonRetryableJobError means the worker fails the
  // job terminally instead of retrying (and re-charging).
  const terminal: [number, string][] = [
    [402, MeshyErrorCode.QUOTA_EXHAUSTED],
    [401, MeshyErrorCode.AUTH_FAILED],
    [403, MeshyErrorCode.AUTH_FAILED],
    [404, MeshyErrorCode.TASK_NOT_FOUND],
    [400, MeshyErrorCode.INVALID_INPUT],
    [422, MeshyErrorCode.INVALID_INPUT],
  ];

  for (const [status, code] of terminal) {
    it(`${status} is NON-retryable (${code})`, async () => {
      stubTransport({ status, data: { message: 'nope' } });

      const err = await meshyClient.createMultiImageTask(['a']).catch((e: unknown) => e);

      expect(err).toBeInstanceOf(NonRetryableJobError);
      expect((err as NonRetryableJobError).code).toBe(code);
    });
  }

  // A plain Error routes through the worker's retry/backoff path.
  for (const status of [429, 500, 502, 503]) {
    it(`${status} is retryable (plain Error)`, async () => {
      stubTransport({ status, data: {} });

      const err = await meshyClient.createMultiImageTask(['a']).catch((e: unknown) => e);

      expect(err).toBeInstanceOf(Error);
      expect(err).not.toBeInstanceOf(NonRetryableJobError);
    });
  }

  it('a 2xx with no task id is terminal — a retry would only charge again', async () => {
    stubTransport({ status: 200, data: {} });

    const err = await meshyClient.createMultiImageTask(['a']).catch((e: unknown) => e);

    expect(err).toBeInstanceOf(NonRetryableJobError);
  });

  it('never leaks the API key or the response body into the error message', async () => {
    stubTransport({ status: 402, data: { image_urls: ['https://s3/presigned?X-Amz-Signature=SECRET'] } });

    const err = (await meshyClient
      .createMultiImageTask(['https://s3/presigned?X-Amz-Signature=SECRET'])
      .catch((e: unknown) => e)) as Error;

    expect(err.message).not.toContain('test-meshy-key');
    expect(err.message).not.toContain('X-Amz-Signature');
  });
});

describe('assertMeshyConfigured', () => {
  it('refuses to build a transport without a key', async () => {
    resetMeshyTransport();
    // @ts-expect-error — clearing the optional key to simulate a bare env.
    env.MESHY_API_KEY = undefined;

    await expect(meshyClient.getTask('t')).rejects.toThrow(/MESHY_API_KEY is required/);
  });
});
