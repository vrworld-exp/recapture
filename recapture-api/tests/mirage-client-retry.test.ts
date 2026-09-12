// tests/mirage-client-retry.test.ts
//
// The Mirage client's in-place retry: WHAT it retries, what it refuses to, and
// that a retried multipart body is rebuilt rather than replayed.
//
// The refusals are the load-bearing half. Mirage's create handlers check
// uniqueness before they upload, so a write re-sent while its first copy is
// still executing over there produces two items. The policy under test is that
// a write is only repeated when the failure PROVES Mirage never took it — a
// refused connection, a proxy-level 502/503, a 429 — and that a TIMEOUT is
// never repeated here for any method (the worker's one-minute backoff is the
// gap that makes re-sending a timed-out write safe).
//
// The transport is mocked at `axios.create`, so the whole request pipeline —
// field serialisation, the multipart encoder, classification, the retry loop —
// runs for real against scripted responses.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import axios from 'axios';
import { Readable } from 'stream';

import { env } from '@/config/env';
import {
  isRetryableInPlace,
  mirageClient,
  resetMirageTransport,
  warmUpMirage,
} from '@/services/mirage/mirageClient';
import {
  MirageError,
  MirageErrorCode,
  classifyMirageFailure,
  classifyMirageTransportFailure,
  type MirageStreamUpload,
} from '@/services/mirage';

type Scripted = { status: number; data: unknown } | { reject: { code?: string; message: string } };

const request = vi.fn();
const get = vi.fn();
const post = vi.fn();

/** What axios does with a stream body before any response exists: read it. */
async function drain(body: unknown): Promise<void> {
  if (body instanceof Readable) {
    for await (const _chunk of body) {
      // consumed
    }
  }
}

function script(fn: ReturnType<typeof vi.fn>, steps: Scripted[]): void {
  for (const step of steps) {
    fn.mockImplementationOnce(async (config?: { data?: unknown }) => {
      await drain(config?.data);
      if ('reject' in step) {
        throw Object.assign(new Error(step.reject.message), step.reject);
      }
      return { status: step.status, data: step.data, headers: {} };
    });
  }
}

const ok = (data: unknown): Scripted => ({ status: 200, data: { status: true, data } });

/** Runs `promise` while draining every retry delay the client schedules. */
async function settle<T>(promise: Promise<T>): Promise<T> {
  // Attach the rejection handler first so a scripted failure never surfaces
  // as an unhandled rejection while the timers are being advanced.
  const guarded = promise.then(
    (value) => ({ ok: true as const, value }),
    (error: unknown) => ({ ok: false as const, error })
  );
  await vi.advanceTimersByTimeAsync(10_000);
  const result = await guarded;
  if (result.ok) return result.value;
  throw result.error;
}

const savedEnv = {
  base: env.MIRAGE_BASE_URL,
  key: env.MIRAGE_API_KEY,
  token: env.MIRAGE_ADMIN_TOKEN,
};

beforeEach(() => {
  env.MIRAGE_BASE_URL = 'https://mirage.test';
  env.MIRAGE_API_KEY = 'test-api-key';
  env.MIRAGE_ADMIN_TOKEN = 'test-admin-token';
  resetMirageTransport();
  request.mockReset();
  get.mockReset();
  post.mockReset();
  vi.spyOn(axios, 'create').mockReturnValue({ request, get, post } as never);
  vi.spyOn(console, 'warn').mockImplementation(() => undefined);
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  env.MIRAGE_BASE_URL = savedEnv.base;
  env.MIRAGE_API_KEY = savedEnv.key;
  env.MIRAGE_ADMIN_TOKEN = savedEnv.token;
  resetMirageTransport();
});

describe('isRetryableInPlace — the policy table', () => {
  const transport = (code: string, message: string): MirageError =>
    classifyMirageTransportFailure(Object.assign(new Error(message), { code }), 'test');
  const http = (status: number, message?: string): MirageError =>
    classifyMirageFailure(status, message, 'test');

  it('never repeats a timeout, for a read or a write', () => {
    const cause = Object.assign(new Error('timeout of 60000ms exceeded'), { code: 'ECONNABORTED' });
    const error = classifyMirageTransportFailure(cause, 'test');
    expect(error.code).toBe(MirageErrorCode.TIMEOUT);
    expect(isRetryableInPlace('get', error, cause)).toBe(false);
    expect(isRetryableInPlace('post', error, cause)).toBe(false);
  });

  it('repeats a write only when the connection was never made', () => {
    const refused = Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' });
    const reset = Object.assign(new Error('socket hang up'), { code: 'ECONNRESET' });
    expect(isRetryableInPlace('post', transport('ECONNREFUSED', 'x'), refused)).toBe(true);
    expect(isRetryableInPlace('put', transport('ENOTFOUND', 'x'), { code: 'ENOTFOUND' })).toBe(
      true
    );
    // A reset after the body went out may have been processed — a write waits
    // for the worker's backoff, a read is free to go again.
    expect(isRetryableInPlace('post', transport('ECONNRESET', 'x'), reset)).toBe(false);
    expect(isRetryableInPlace('get', transport('ECONNRESET', 'x'), reset)).toBe(true);
  });

  it('repeats a write on a proxy-level 502/503 and a 429, not on a 500/504', () => {
    expect(isRetryableInPlace('post', http(502))).toBe(true);
    expect(isRetryableInPlace('post', http(503))).toBe(true);
    expect(isRetryableInPlace('post', http(429))).toBe(true);
    expect(isRetryableInPlace('post', http(500, 'Error by server (boom)'))).toBe(false);
    expect(isRetryableInPlace('post', http(504))).toBe(false);
    // A read repeats on every 5xx.
    expect(isRetryableInPlace('get', http(500, 'Error by server (boom)'))).toBe(true);
    expect(isRetryableInPlace('get', http(504))).toBe(true);
  });

  it('never repeats anything that is not retryable to begin with', () => {
    expect(isRetryableInPlace('get', http(400, 'Restaurant not found'))).toBe(false);
    expect(isRetryableInPlace('get', http(400, 'Invalid Api key.'))).toBe(false);
    expect(
      isRetryableInPlace('post', http(400, 'Product already exist.Product name should be unique'))
    ).toBe(false);
  });
});

describe('send — the retry loop', () => {
  it('a read that is refused once succeeds on the second attempt', async () => {
    script(request, [
      { reject: { code: 'ECONNREFUSED', message: 'connect ECONNREFUSED 1.2.3.4:443' } },
      ok([{ _id: 'r1', name: 'Blue Cafe', location: '' }]),
    ]);

    const restaurants = await settle(mirageClient.listRestaurants());

    expect(restaurants).toHaveLength(1);
    expect(request).toHaveBeenCalledTimes(2);
  });

  it('gives up after the configured attempts and throws the last classification', async () => {
    script(request, [
      { status: 502, data: '<html>Bad Gateway</html>' },
      { status: 502, data: '<html>Bad Gateway</html>' },
      { status: 502, data: '<html>Bad Gateway</html>' },
    ]);

    await expect(settle(mirageClient.listRestaurants())).rejects.toMatchObject({
      code: MirageErrorCode.SERVER_ERROR,
      failureClass: 'retryable',
    });
    expect(request).toHaveBeenCalledTimes(3);
  });

  it('a write that times out is thrown straight away — never re-sent in place', async () => {
    script(request, [{ reject: { code: 'ECONNABORTED', message: 'timeout of 60000ms exceeded' } }]);

    await expect(
      settle(mirageClient.createCategory({ name: 'mains', restaurantId: 'r1' }))
    ).rejects.toMatchObject({ code: MirageErrorCode.TIMEOUT });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('a write that Mirage answered with a 500 is thrown straight away', async () => {
    script(request, [{ status: 500, data: { status: false, message: 'Error by server (x)' } }]);

    await expect(
      settle(mirageClient.updateRestaurant('r1', { name: 'x', location: '' }))
    ).rejects.toMatchObject({ code: MirageErrorCode.SERVER_ERROR });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('a multipart write retried after a 502 rebuilds its body instead of replaying a drained stream', async () => {
    let opened = 0;
    const object: MirageStreamUpload = {
      kind: 'stream',
      filename: 'model.glb',
      contentType: 'model/gltf-binary',
      size: 6,
      open: () => {
        opened += 1;
        return Readable.from([Buffer.from('ABCDEF')]);
      },
    };

    script(request, [
      { status: 502, data: '<html>Bad Gateway</html>' },
      ok({ _id: 'i1', name: 'biryani', category: 'c1', restaurant: 'r1' }),
    ]);

    const item = await settle(
      mirageClient.createItem({ name: 'biryani', categoryId: 'c1', restaurantId: 'r1', object })
    );

    expect(item.id).toBe('i1');
    expect(request).toHaveBeenCalledTimes(2);
    // The stream part's factory ran once per attempt — a second attempt that
    // reused the first stream would send an empty body.
    expect(opened).toBe(2);

    const [first, second] = request.mock.calls.map(
      (call) => (call[0] as { headers: Record<string, string>; data: unknown }).headers
    );
    expect(first['content-type']).toMatch(/^multipart\/form-data; boundary=/);
    expect(second['content-type']).toMatch(/^multipart\/form-data; boundary=/);
    // A fresh boundary per build proves the body was not the same object.
    expect(first['content-type']).not.toBe(second['content-type']);
    expect(first['content-length']).toBe(second['content-length']);
  });
});

describe('warmUpMirage', () => {
  it('pings the root, retries a timeout, and reports whether Mirage answered', async () => {
    script(get, [
      { reject: { code: 'ECONNABORTED', message: 'timeout of 60000ms exceeded' } },
      { status: 200, data: 'Server is live now.' },
    ]);

    await expect(settle(warmUpMirage())).resolves.toBe(true);
    expect(get).toHaveBeenCalledTimes(2);
    expect(get.mock.calls[0]?.[0]).toBe('https://mirage.test/');
  });

  it('never throws when Mirage stays silent', async () => {
    script(get, [
      { reject: { code: 'ECONNREFUSED', message: 'refused' } },
      { reject: { code: 'ECONNREFUSED', message: 'refused' } },
      { reject: { code: 'ECONNREFUSED', message: 'refused' } },
    ]);

    await expect(settle(warmUpMirage())).resolves.toBe(false);
    expect(get).toHaveBeenCalledTimes(3);
  });

  it('is a no-op when Mirage is not configured', async () => {
    env.MIRAGE_BASE_URL = undefined;
    resetMirageTransport();

    await expect(warmUpMirage()).resolves.toBe(false);
    expect(get).not.toHaveBeenCalled();
  });
});
