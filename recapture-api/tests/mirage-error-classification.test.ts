// tests/mirage-error-classification.test.ts
//
// The Mirage adapter's contract: the (status, message) → failure-class table,
// and the request plumbing every write depends on.
//
// WHY THIS SUITE IS THE CONTRACT: Mirage has no tests, no types and no API
// version. It answers HTTP 400 for validation errors, for not-found, for a bad
// api key, for a non-admin token, AND from its global 404 handler — so the
// status code classifies nothing and the prose `message` is the only remaining
// signal. Every fixture below QUOTES a real message from `mirage-be/`, with the
// source line it came from. If someone edits that prose, this suite is where it
// shows up; nothing else in either codebase would notice.
//
// Getting a row wrong is expensive in a specific way:
//   • a `retryable` misread as `terminal` fails a product a retry would have
//     published;
//   • a `terminal` misread as `retryable` burns the whole backoff ladder on a
//     request that can never succeed;
//   • an `already exist` misread as anything else is a DUPLICATE Mirage item —
//     the one outcome the architecture forbids outright.
//
// Hermetic: axios.create is stubbed, so CI never touches the live Mirage (which
// shares a database with production).
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import axios from 'axios';

import { env } from '@/config/env';
import {
  classifyMirageFailure,
  classifyMirageTransportFailure,
  isMirageConfigured,
  mirageClient,
  MirageError,
  MirageErrorCode,
  resetMirageTransport,
  type MirageFailureClass,
} from '@/services/mirage';

interface FakeResponse {
  status: number;
  data?: unknown;
}

let request: ReturnType<typeof vi.fn>;
let post: ReturnType<typeof vi.fn>;

/**
 * Stubs the axios instance the adapter builds, and captures its config.
 *
 * `send()` always goes through `.request(...)`; the admin-login path uses
 * `.post(...)`, so both are stubbed. Responses are consumed in order, and the
 * last one repeats — which is what makes the auth-retry test readable.
 */
function stubTransport(...responses: FakeResponse[]): {
  config: Record<string, unknown>;
} {
  const captured: { config: Record<string, unknown> } = { config: {} };
  let call = 0;
  request = vi.fn().mockImplementation(async () => {
    const response = responses[Math.min(call, responses.length - 1)];
    call++;
    return response;
  });
  post = vi.fn().mockResolvedValue({ status: 200, data: { token: 'minted-token' } });

  vi.spyOn(axios, 'create').mockImplementation(((config: Record<string, unknown>) => {
    captured.config = config;
    return { request, post } as never;
  }) as never);

  return captured;
}

/** The request options the adapter passed to axios on call [index]. */
function sentAt(index: number): {
  method: string;
  url: string;
  data: unknown;
  headers: Record<string, string>;
  params?: Record<string, unknown>;
} {
  return request.mock.calls[index][0];
}

const sent = () => sentAt(0);

beforeEach(() => {
  resetMirageTransport();
  // env is a plain parsed object; every MIRAGE_* key is optional by schema so
  // an API that never publishes still boots. The suite supplies them here
  // rather than in vitest.config.ts, so the "not configured" test can unset one.
  Object.assign(env, {
    MIRAGE_BASE_URL: 'https://mirage.test',
    MIRAGE_API_KEY: 'test-api-key',
    MIRAGE_ADMIN_TOKEN: 'test-admin-token',
    MIRAGE_ADMIN_USER_ID: undefined,
    MIRAGE_ADMIN_PASSWORD: undefined,
    MIRAGE_ASSET_CDN_URL: 'https://mirage-cdn.test',
    MIRAGE_ASSET_BUCKET: 'maya-restaurants',
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  resetMirageTransport();
});

// ── The table ───────────────────────────────────────────────────────────────

interface Row {
  what: string;
  status: number;
  message?: string;
  /** The mirage-be source line this message was read from. */
  source: string;
  expect: MirageFailureClass;
  code: string;
}

/**
 * Every row quotes a REAL Mirage message. Keep the `source` citation when
 * adding one — it is the only documentation Mirage's API has.
 */
const ROWS: Row[] = [
  // ── auth: the api key. Note the 400 — this row exists because of it. ──────
  {
    what: 'a missing api key',
    status: 400,
    message: 'Api key is not given.',
    source: 'Middlewares/apiKeyValidator.js:30',
    expect: 'auth',
    code: MirageErrorCode.API_KEY_REJECTED,
  },
  {
    what: 'an unknown api key',
    status: 400,
    message: 'Invalid Api key.',
    source: 'Middlewares/apiKeyValidator.js:34',
    expect: 'auth',
    code: MirageErrorCode.API_KEY_REJECTED,
  },

  // ── auth: the admin JWT ──────────────────────────────────────────────────
  {
    what: 'an expired admin token',
    status: 403,
    message: 'jwt expired | Login again please with valid email and password.',
    source: 'Middlewares/middleware.js:52',
    expect: 'auth',
    code: MirageErrorCode.AUTH_REJECTED,
  },
  {
    what: 'a malformed admin token',
    status: 403,
    message: 'jwt malformed | Login again please with valid email and password.',
    source: 'Middlewares/middleware.js:61',
    expect: 'auth',
    code: MirageErrorCode.AUTH_REJECTED,
  },
  {
    what: 'no token header at all',
    status: 401,
    message: 'Unauthorized. No token found.',
    source: 'Middlewares/middleware.js:29',
    expect: 'auth',
    code: MirageErrorCode.AUTH_REJECTED,
  },
  {
    what: 'a token whose payload is unusable',
    status: 401,
    message: 'Data in token is bad or inomplete)',
    source: 'Middlewares/middleware.js:85,186 (misspelling is Mirage’s)',
    expect: 'auth',
    code: MirageErrorCode.AUTH_REJECTED,
  },
  {
    what: 'a non-admin token',
    status: 400,
    // Mirage’s isAdmin guard checks `role === "admin"` but says "chef" — a
    // copy-paste bug on their side. Matching the literal string is the only option.
    message: 'Only chef can access this api.',
    source: 'Middlewares/middleware.js:125,149',
    expect: 'auth',
    code: MirageErrorCode.AUTH_REJECTED,
  },
  {
    what: 'a request with no logged-in user',
    status: 400,
    message: 'Bad Request.(Please logIn)',
    source: 'Middlewares/middleware.js:118,142',
    expect: 'auth',
    code: MirageErrorCode.AUTH_REJECTED,
  },

  // ── reconcile: THE idempotency substitute ────────────────────────────────
  {
    what: 'a duplicate restaurant name',
    status: 400,
    message: 'Restaurant already exist. Name should be unique',
    source: 'Controllers/adminController.js:288',
    expect: 'reconcile',
    code: MirageErrorCode.ALREADY_EXISTS,
  },
  {
    what: 'a duplicate category name',
    status: 400,
    message: 'Category already exist.Category name should be unique',
    source: 'Controllers/adminController.js:732,898',
    expect: 'reconcile',
    code: MirageErrorCode.ALREADY_EXISTS,
  },
  {
    what: 'a duplicate product name — the replayed create',
    status: 400,
    message: 'Product already exist.Product name should be unique',
    source: 'Controllers/adminController.js:1092,1374',
    expect: 'reconcile',
    code: MirageErrorCode.ALREADY_EXISTS,
  },

  // ── terminal: the asset was refused ──────────────────────────────────────
  {
    what: 'multer rejecting an oversize file',
    status: 500,
    message: 'File too large',
    source: 'libs/multer.js:7 (100 MB cap) via multer LIMIT_FILE_SIZE',
    expect: 'terminal',
    code: MirageErrorCode.ASSET_TOO_LARGE,
  },
  {
    what: 'a 413 with no body',
    status: 413,
    source: 'proxy/body-size rejection ahead of Mirage',
    expect: 'terminal',
    code: MirageErrorCode.ASSET_TOO_LARGE,
  },

  // ── retryable ────────────────────────────────────────────────────────────
  {
    what: "Mirage's own catch-all server error",
    status: 500,
    message: 'Error by server (Cannot read properties of undefined)',
    source: 'Controllers/adminController.js catch blocks',
    expect: 'retryable',
    code: MirageErrorCode.SERVER_ERROR,
  },
  {
    what: 'a sleeping instance behind its host',
    status: 503,
    message: 'Service Unavailable',
    source: 'mirage-be/index.js self-ping tier',
    expect: 'retryable',
    code: MirageErrorCode.SERVER_ERROR,
  },
  {
    what: 'rate limiting',
    status: 429,
    message: 'Too many requests',
    source: 'not produced by any admin route today; kept for safety',
    expect: 'retryable',
    code: MirageErrorCode.RATE_LIMITED,
  },

  // ── terminal: a referenced entity is gone ────────────────────────────────
  {
    what: 'a missing parent category on create-item',
    status: 400,
    message: 'Category not found',
    source: 'Controllers/adminController.js:876,1074',
    expect: 'terminal',
    code: MirageErrorCode.NOT_FOUND,
  },
  {
    what: 'a missing restaurant',
    status: 400,
    message: 'Restaurant not found',
    source: 'Controllers/adminController.js:443,1081',
    expect: 'terminal',
    code: MirageErrorCode.NOT_FOUND,
  },
  {
    what: 'deleting an item that is already gone',
    status: 404,
    message: 'No item found with given itemId (65f0…)',
    source: 'Controllers/adminController.js:1646',
    expect: 'terminal',
    code: MirageErrorCode.NOT_FOUND,
  },
  {
    what: 'an unresolvable restaurant reference',
    status: 400,
    message: 'Invalid restaurant name or id (blue-cafe)',
    source: 'Controllers/adminController.js:597,644',
    expect: 'terminal',
    code: MirageErrorCode.NOT_FOUND,
  },

  // ── terminal catch-all ───────────────────────────────────────────────────
  {
    // The NOT_FOUND rule's /not found/i catches this before the catch-all. Both
    // rules are `terminal`, so the retry behaviour is identical either way — but
    // a route typo therefore arrives wearing the same code as a genuinely
    // deleted parent. The publish processor (T-028) must key its
    // clear-the-mapping-and-recreate repair on the operation it was performing,
    // not on this code alone.
    what: "Mirage's global 404 handler, served as a 400",
    status: 400,
    message: 'Path not found.(400)',
    source: 'mirage-be/index.js:221',
    expect: 'terminal',
    code: MirageErrorCode.NOT_FOUND,
  },
  {
    what: 'a 400 with no message at all',
    status: 400,
    source: 'any handler that returns bare',
    expect: 'terminal',
    code: MirageErrorCode.INVALID_REQUEST,
  },
];

describe('classifyMirageFailure — the (status, message) table', () => {
  for (const row of ROWS) {
    it(`${row.what} → ${row.expect} [${row.source}]`, () => {
      const error = classifyMirageFailure(row.status, row.message, 'test');

      expect(error.failureClass).toBe(row.expect);
      expect(error.code).toBe(row.code);
      expect(error.status).toBe(row.status);
      expect(error.isRetryable).toBe(row.expect === 'retryable');
    });
  }

  it('keeps our message ours and Mirage’s prose diagnostic-only', () => {
    const error = classifyMirageFailure(
      400,
      'Product already exist.Product name should be unique',
      'create item'
    );

    // What we store and show never interpolates Mirage's wording — a user must
    // not be told about "Products" on a page that calls them something else.
    expect(error.message).toBe('Mirage already has an entity with this name.');
    expect(error.message).not.toContain('Product already exist');
    // The raw string survives for worker logs, which is how a reworded Mirage
    // handler gets noticed at all.
    expect(error.mirageMessage).toBe('Product already exist.Product name should be unique');
    expect(error.context).toBe('create item');
  });

  it('a 5xx stays retryable even when its interpolated text says "not found"', () => {
    // Mirage's catch-all is `Error by server (${error.message})`, and that inner
    // message can contain any word. Reading one as terminal would fail a product
    // that a retry would have published — so the 5xx rule must win.
    const error = classifyMirageFailure(
      500,
      'Error by server (Cast to ObjectId failed, category not found)',
      'create item'
    );

    expect(error.failureClass).toBe('retryable');
    expect(error.code).toBe(MirageErrorCode.SERVER_ERROR);
  });

  it('an "already exist" message wins over the terminal catch-all', () => {
    // Ordering regression guard: if the catch-all ever moved above the
    // reconcile rule, every replayed create would become a hard failure and the
    // publish run would stop converging.
    expect(
      classifyMirageFailure(400, 'Category already exist.Category name should be unique', 'x')
        .failureClass
    ).toBe('reconcile');
  });

  it('classification is case-insensitive', () => {
    expect(classifyMirageFailure(400, 'PRODUCT ALREADY EXIST', 'x').failureClass).toBe(
      'reconcile'
    );
    expect(classifyMirageFailure(400, 'invalid api KEY.', 'x').failureClass).toBe('auth');
  });
});

describe('classifyMirageTransportFailure — no response arrived', () => {
  const cases: Array<{ what: string; cause: unknown; code: string }> = [
    {
      what: 'connection refused',
      cause: Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' }),
      code: MirageErrorCode.UNREACHABLE,
    },
    {
      what: 'a reset socket',
      cause: Object.assign(new Error('socket hang up'), { code: 'ECONNRESET' }),
      code: MirageErrorCode.UNREACHABLE,
    },
    {
      what: 'the axios timeout',
      cause: Object.assign(new Error('timeout of 60000ms exceeded'), {
        code: 'ECONNABORTED',
      }),
      code: MirageErrorCode.TIMEOUT,
    },
    {
      what: 'a DNS failure',
      cause: Object.assign(new Error('getaddrinfo ENOTFOUND mirage.test'), {
        code: 'ENOTFOUND',
      }),
      code: MirageErrorCode.UNREACHABLE,
    },
  ];

  for (const c of cases) {
    it(`${c.what} is retryable`, () => {
      const error = classifyMirageTransportFailure(c.cause, 'create item');

      // An unreachable Mirage is the textbook transient case: the catalog must
      // not flip state and the worker's backoff already bounds it.
      expect(error.failureClass).toBe('retryable');
      expect(error.isRetryable).toBe(true);
      expect(error.code).toBe(c.code);
      expect(error.status).toBe(0);
    });
  }
});

describe('mirageClient — request plumbing', () => {
  it('mounts /api/v1 and sends the apikey header on the instance', async () => {
    const captured = stubTransport({ status: 200, data: { status: true, data: [] } });

    await mirageClient.listRestaurants();

    expect(captured.config.baseURL).toBe('https://mirage.test/api/v1');
    expect((captured.config.headers as Record<string, string>).apikey).toBe('test-api-key');
    // Every status is classified by us, so axios must not throw on its own.
    expect(typeof captured.config.validateStatus).toBe('function');
    expect((captured.config.validateStatus as (s: number) => boolean)(400)).toBe(true);
    // A whole GLB goes out in one body; axios defaults to 10 MB.
    expect(captured.config.maxBodyLength).toBe(Infinity);
  });

  it('sends the admin token header on a write', async () => {
    stubTransport({ status: 200, data: { status: true, data: { _id: 'r1', name: 'A' } } });

    await mirageClient.updateRestaurant('r1', { name: 'A', location: '' });

    expect(sent().headers.token).toBe('test-admin-token');
    expect(sent().method).toBe('put');
    expect(sent().url).toBe('/update-restaurant/r1');
  });

  it('injects CLOUD_FRONT_URL and BUCKET_NAME into every write body', async () => {
    // NON-NEGOTIABLE: Mirage reads both from the BODY and stores
    // `${CLOUD_FRONT_URL}/${key}` verbatim. Omit them and a customer-facing URL
    // becomes the literal string "undefined/<key>".
    stubTransport({ status: 200, data: { status: true, data: { _id: 'c1', name: 'Chairs' } } });

    await mirageClient.createCategory({ name: 'Chairs', restaurantId: 'r1' });

    expect(sent().data).toMatchObject({
      name: 'Chairs',
      restaurant: 'r1',
      CLOUD_FRONT_URL: 'https://mirage-cdn.test',
      BUCKET_NAME: 'maya-restaurants',
    });
  });

  it('always sends both name and location on update-restaurant', async () => {
    // M3 400s unless BOTH are strings — it is a full replace, not a patch.
    stubTransport({ status: 200, data: { status: true, data: { _id: 'r1', name: 'A' } } });

    await mirageClient.updateRestaurant('r1', { name: 'A', location: '' });

    const body = sent().data as Record<string, unknown>;
    expect(body.name).toBe('A');
    expect(body.location).toBe('');
  });

  it('turns a replayed create into a reconcile, not a duplicate', async () => {
    // THE case the whole reconcile class exists for. Mirage answers 400 (never
    // 2xx) for every "already exist" — verified across adminController.js:288,
    // :732, :1092 — and treating it as anything but `reconcile` would make the
    // caller create a SECOND Mirage item, the one outcome the architecture
    // forbids outright.
    stubTransport({
      status: 400,
      data: { status: false, message: 'Product already exist.Product name should be unique' },
    });

    await expect(
      mirageClient.createItem({ name: 'Chair', categoryId: 'c1', restaurantId: 'r1' })
    ).rejects.toMatchObject({
      code: MirageErrorCode.ALREADY_EXISTS,
      failureClass: 'reconcile',
    });
  });

  it('treats a 2xx carrying {status:false} as a failure, not a success', async () => {
    // Mirage's own boolean flag is authoritative even on a 200 — and neither it
    // nor its prose may reach a ReCapture response body.
    stubTransport({ status: 200, data: { status: false, message: 'Category not found' } });

    await expect(
      mirageClient.createItem({ name: 'Chair', categoryId: 'c1', restaurantId: 'r1' })
    ).rejects.toMatchObject({ failureClass: 'terminal', code: MirageErrorCode.NOT_FOUND });
  });

  it('rejects a 2xx whose body has no payload', async () => {
    stubTransport({ status: 200, data: { status: true } });

    await expect(mirageClient.createCategory({ name: 'C', restaurantId: 'r1' })).rejects
      .toMatchObject({ code: MirageErrorCode.MALFORMED_RESPONSE, failureClass: 'terminal' });
  });

  it('normalizes an item field by field and never spreads Mirage fields through', async () => {
    stubTransport({
      status: 200,
      data: {
        status: true,
        data: {
          _id: 'i1',
          name: 'Walnut Chair',
          price: 4999,
          imgOnly: false,
          model: { src: 'https://cdn/model.glb', iosSrc: 'https://cdn/model.usdz' },
          category: { _id: 'c1', name: 'Chairs' },
          restaurant: 'r1',
          // Fields we do not model must NOT ride along into our type.
          __v: 3,
          isDeleted: false,
        },
      },
    });

    const item = await mirageClient.createItem({
      name: 'Walnut Chair',
      categoryId: 'c1',
      restaurantId: 'r1',
    });

    expect(item).toEqual({
      id: 'i1',
      name: 'Walnut Chair',
      price: 4999,
      modelSrc: 'https://cdn/model.glb',
      modelIosSrc: 'https://cdn/model.usdz',
      categoryId: 'c1', // populated ref flattened to its id
      restaurantId: 'r1',
      imgOnly: false,
    });
  });

  it('deleting an item that is already gone converges instead of failing', async () => {
    // A replayed publish run must reach the same end state, so "it was not
    // there" is a success with existed:false.
    stubTransport({ status: 404, data: { status: false, message: 'No item found with given itemId (i1)' } });

    // `deletedCategory` is reported on every outcome: a Mirage that predates
    // the ?keepCategory flag cascades regardless, and the caller has to clear
    // its cached mirageCategoryId when it does. Nothing was deleted here, so
    // nothing cascaded.
    await expect(mirageClient.deleteItem('i1')).resolves.toEqual({
      existed: false,
      deletedCategory: false,
    });
  });

  it('a transport throw becomes a retryable MirageError, not a raw axios error', async () => {
    stubTransport({ status: 200 });
    request.mockRejectedValueOnce(
      Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' })
    );

    await expect(mirageClient.listRestaurants()).rejects.toMatchObject({
      name: 'MirageError',
      code: MirageErrorCode.UNREACHABLE,
      failureClass: 'retryable',
    });
  });
});

describe('mirageClient — admin credential', () => {
  it('re-mints the token once on an auth failure when logging in', async () => {
    // A login-mode token expires (Mirage's JWT_EXPIRE defaults to 1d) and the
    // first call after that is the only symptom. One retry, then it is an
    // operator problem.
    Object.assign(env, {
      MIRAGE_ADMIN_TOKEN: undefined,
      MIRAGE_ADMIN_USER_ID: 'a'.repeat(24),
      MIRAGE_ADMIN_PASSWORD: 'test-password',
    });
    resetMirageTransport();

    stubTransport(
      { status: 403, data: { status: false, message: 'jwt expired | Login again please' } },
      { status: 200, data: { status: true, data: [] } }
    );

    await expect(mirageClient.listRestaurants()).resolves.toEqual([]);

    expect(request).toHaveBeenCalledTimes(2);
    // Two logins: the first mint, then the forced re-mint after the rejection.
    expect(post).toHaveBeenCalledTimes(2);
    expect(post).toHaveBeenCalledWith('/login-user', {
      id: 'a'.repeat(24),
      password: 'test-password',
    });
  });

  it('does not retry when the token was configured by an operator', async () => {
    // Re-minting is impossible with a pre-supplied token, so a second attempt
    // would just replay the same rejected credential.
    stubTransport({
      status: 403,
      data: { status: false, message: 'jwt expired | Login again please' },
    });

    await expect(mirageClient.listRestaurants()).rejects.toMatchObject({
      code: MirageErrorCode.AUTH_REJECTED,
      failureClass: 'auth',
    });
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('refuses to call Mirage at all when it is not configured', async () => {
    Object.assign(env, {
      MIRAGE_BASE_URL: undefined,
      MIRAGE_API_KEY: undefined,
      MIRAGE_ADMIN_TOKEN: undefined,
    });
    resetMirageTransport();
    stubTransport({ status: 200, data: { status: true, data: [] } });

    expect(isMirageConfigured()).toBe(false);
    await expect(mirageClient.listRestaurants()).rejects.toBeInstanceOf(MirageError);
    // Fail fast — an operator problem must not look like a Mirage outage.
    expect(request).not.toHaveBeenCalled();
  });
});
