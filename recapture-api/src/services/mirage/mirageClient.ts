// src/services/mirage/mirageClient.ts
//
// The ONLY module in ReCapture that knows Mirage exists.
//
// It owns four things and nothing else — no business logic, no catalog state:
//   1. CREDENTIALS. The `apikey` header and the admin JWT live here and nowhere
//      else. They are never returned, never logged, and never reach the Flutter
//      client. The credential is UNSCOPED — it can read and write every business
//      in Mirage — so widening this module's surface widens that blast radius.
//   2. THE ENVELOPE. Mirage answers `{status: <boolean>, message, data}`. That
//      boolean `status` must never appear in a ReCapture response, so it is
//      unwrapped here and only here.
//   3. CLASSIFICATION. Delegated to mirageErrors.ts, which is where the reasons
//      live. Every method throws MirageError or returns a normalized shape.
//   4. THE BODY-SUPPLIED WRITE TARGETS. Mirage reads `CLOUD_FRONT_URL` and
//      `BUCKET_NAME` from the request body on every write and bakes the CDN host
//      into the URL it stores; omit them and it persists a customer-facing URL
//      that literally starts with "undefined". They are injected here so no
//      caller can forget.
//
// Endpoint ids (M1, M2, …) refer to the table in
// docs/next-phase/01-codebase-findings.md, each of which cites a real handler in
// mirage-be/src/Controllers/.
import axios, { type AxiosInstance, type AxiosResponse } from 'axios';
import { env } from '@/config/env';
import {
  MirageError,
  MirageErrorCode,
  classifyMirageFailure,
  classifyMirageTransportFailure,
} from './mirageErrors';
import type {
  CreateCategoryInput,
  CreateItemInput,
  CreateRestaurantInput,
  MirageAnalyticsQuery,
  MirageAnalyticsSummary,
  MirageCategory,
  MirageFileUpload,
  MirageItem,
  MiragePublicCatalog,
  MirageRestaurant,
  MirageTimeseriesPoint,
  MirageTopProductRow,
  UpdateCategoryInput,
  UpdateItemInput,
  UpdateRestaurantInput,
} from './mirageTypes';

/** Everything Mirage exposes to us, as one injectable surface. */
export interface MirageClient {
  /** M1 — every restaurant. Used to ADOPT a pre-existing business by name. */
  listRestaurants(): Promise<MirageRestaurant[]>;
  /** M2 — provision a restaurant. Its `_id` becomes the permanent public URL. */
  createRestaurant(input: CreateRestaurantInput): Promise<MirageRestaurant>;
  /** M3 — branding. Both `name` and `location` must always be sent. */
  updateRestaurant(id: string, input: UpdateRestaurantInput): Promise<MirageRestaurant>;
  /**
   * M4 — DESTROYS the restaurant, its categories and its items, and with them
   * the ObjectId every printed QR is built from. Never part of unpublish.
   */
  deleteRestaurant(id: string): Promise<void>;
  /** M11 — a restaurant's categories. The reconcile read for categories. */
  listCategories(restaurantRef: string): Promise<MirageCategory[]>;
  /** M5 — create a category. Required before any item can reference it. */
  createCategory(input: CreateCategoryInput): Promise<MirageCategory>;
  /** M6 — rename a category. */
  updateCategory(id: string, input: UpdateCategoryInput): Promise<MirageCategory>;
  /** M12 — a category's items. The reconcile read for products. */
  listItemsForCategory(categoryRef: string): Promise<MirageItem[]>;
  /** M8 — create an item. Persist the returned id before doing anything else. */
  createItem(input: CreateItemInput): Promise<MirageItem>;
  /** M9 — update an item. Cannot change description, category or imgOnly. */
  updateItem(id: string, input: UpdateItemInput): Promise<MirageItem>;
  /**
   * M10 — HARD delete. Also deletes the item's CATEGORY when it was that
   * category's last item. Resolves `{ existed: false }` when the item was
   * already gone, so a replayed delete is a success, not a failure.
   */
  deleteItem(id: string): Promise<{ existed: boolean }>;
  /** M14 — the public page's own read. Post-publish verification. */
  getPublicCatalog(slug: string): Promise<MiragePublicCatalog>;
  /** M27 */
  analyticsSummary(query: MirageAnalyticsQuery): Promise<MirageAnalyticsSummary>;
  /** M28 */
  analyticsTimeseries(query: MirageAnalyticsQuery): Promise<MirageTimeseriesPoint[]>;
  /** M29 */
  analyticsTopProducts(query: MirageAnalyticsQuery): Promise<MirageTopProductRow[]>;
}

/**
 * Fails fast when the Mirage configuration is absent. Called at the point of
 * use — the publish worker and the analytics proxy — because config/env.ts
 * leaves every MIRAGE_* var optional so an API that does neither still boots.
 * Same shape as assertMeshyConfigured().
 */
export function assertMirageConfigured(): void {
  const missing: string[] = [];
  if (!env.MIRAGE_BASE_URL) missing.push('MIRAGE_BASE_URL');
  if (!env.MIRAGE_API_KEY) missing.push('MIRAGE_API_KEY');
  if (!env.MIRAGE_ADMIN_TOKEN && !(env.MIRAGE_ADMIN_USER_ID && env.MIRAGE_ADMIN_PASSWORD)) {
    missing.push('MIRAGE_ADMIN_TOKEN (or MIRAGE_ADMIN_USER_ID + MIRAGE_ADMIN_PASSWORD)');
  }
  if (missing.length > 0) {
    throw new MirageError(
      MirageErrorCode.NOT_CONFIGURED,
      'terminal',
      `Mirage publishing is not configured — missing ${missing.join(', ')}.`,
      'configuration'
    );
  }
}

/** Present so a caller can degrade gracefully instead of catching to branch. */
export function isMirageConfigured(): boolean {
  try {
    assertMirageConfigured();
    return true;
  } catch {
    return false;
  }
}

let http: AxiosInstance | undefined;

/** Lazily built so importing this module never requires the config to be present. */
function transport(): AxiosInstance {
  if (!http) {
    assertMirageConfigured();
    http = axios.create({
      // Mirage mounts every route we use under /api/v1 (mirage-be/index.js).
      baseURL: `${env.MIRAGE_BASE_URL}/api/v1`,
      headers: { apikey: env.MIRAGE_API_KEY as string },
      timeout: env.MIRAGE_REQUEST_TIMEOUT_MS,
      // A whole GLB goes out in one multipart body; axios defaults to 10 MB.
      maxBodyLength: Infinity,
      maxContentLength: Infinity,
      // Every status is classified by us (see mirageErrors.ts).
      validateStatus: () => true,
    });
  }
  return http;
}

/** Test seam: drop the memoized instance so a changed env/mock is picked up. */
export function resetMirageTransport(): void {
  http = undefined;
  cachedAdminToken = undefined;
}

// ── Admin token ─────────────────────────────────────────────────────────────

interface CachedToken {
  token: string;
  mintedAt: number;
}

let cachedAdminToken: CachedToken | undefined;

/**
 * The admin JWT for Mirage's `token` header.
 *
 * A configured MIRAGE_ADMIN_TOKEN wins outright. Otherwise we log in with
 * `{ id, password }` — where `id` is the admin user's 24-character ObjectId,
 * NOT an email (userController.js:93-101) — and cache the result.
 *
 * ⚠ The login path is fragile through no fault of ours: Mirage SIGNS with
 * `process.env.JWT_SECRET` (userController.js:115) and VERIFIES with
 * `process.env.JWT_SECRET_KEY` (middleware.js:40). If the deployed Mirage sets
 * only one of those two names, a token we mint here will never verify, and
 * every call will come back as the `auth` class. That is why a pre-minted token
 * is the preferred configuration. Q2 in docs/next-phase/06-open-questions.md.
 */
async function getAdminToken(): Promise<string> {
  if (env.MIRAGE_ADMIN_TOKEN) return env.MIRAGE_ADMIN_TOKEN;

  const ttlMs = env.MIRAGE_ADMIN_TOKEN_TTL_SECONDS * 1000;
  if (cachedAdminToken && Date.now() - cachedAdminToken.mintedAt < ttlMs) {
    return cachedAdminToken.token;
  }

  let res: AxiosResponse<unknown>;
  try {
    res = await transport().post('/login-user', {
      id: env.MIRAGE_ADMIN_USER_ID,
      password: env.MIRAGE_ADMIN_PASSWORD,
    });
  } catch (cause) {
    throw classifyMirageTransportFailure(cause, 'mirage admin login');
  }

  const body = asRecord(res.data);
  const token = body && typeof body.token === 'string' ? body.token : undefined;
  if (res.status < 200 || res.status >= 300 || !token) {
    // A failed login is an `auth` failure however Mirage phrases it — retrying
    // it inside one request would just replay the same rejected credential.
    throw classifyMirageFailure(res.status, messageOf(res), 'mirage admin login');
  }

  cachedAdminToken = { token, mintedAt: Date.now() };
  return token;
}

/** Drops the cached token so the next call re-mints it (the `auth` retry). */
function invalidateAdminToken(): void {
  cachedAdminToken = undefined;
}

// ── Request plumbing ────────────────────────────────────────────────────────

type ScalarField = string | number | boolean | undefined;

interface RequestSpec {
  method: 'get' | 'post' | 'put' | 'delete';
  path: string;
  /** Human phrase for error messages and logs, e.g. 'create item'. */
  context: string;
  /** Send the admin `token` header. Every /admin write needs it; M14 does not. */
  requiresAdmin: boolean;
  query?: Record<string, ScalarField>;
  /** Form/JSON fields. Undefined values are dropped. */
  fields?: Record<string, ScalarField>;
  /** Multipart file parts, keyed by Mirage's field name (`image` | `object`). */
  files?: Partial<Record<'image' | 'object', MirageFileUpload>>;
  /** Inject CLOUD_FRONT_URL + BUCKET_NAME. True for every write. */
  assetTargets?: boolean;
  /**
   * Which body key holds the payload. `'data'` for almost everything; `null`
   * returns the whole body, which M14 needs because it answers with
   * `{restaurantData, data, allCategry}` rather than one `data` object.
   */
  dataKey?: string | null;
  /** Statuses to resolve as a successful `undefined` instead of throwing. */
  tolerateStatuses?: number[];
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === 'object' ? (value as Record<string, unknown>) : undefined;
}

/**
 * Mirage's failure text, for CLASSIFICATION ONLY.
 *
 * Falls back to a truncated raw body because a multer rejection escapes through
 * Express's default handler as an HTML page, and "File too large" inside that
 * page is the only signal that the upload was refused for its size.
 */
function messageOf(res: AxiosResponse<unknown>): string | undefined {
  const body = asRecord(res.data);
  if (body && typeof body.message === 'string') return body.message;
  if (typeof res.data === 'string' && res.data.length > 0) return res.data.slice(0, 300);
  return undefined;
}

/** True when Mirage said "no" — either by HTTP status or by its boolean flag. */
function isFailure(res: AxiosResponse<unknown>): boolean {
  if (res.status < 200 || res.status >= 300) return true;
  const body = asRecord(res.data);
  return body?.status === false;
}

function buildMultipart(spec: RequestSpec, fields: Record<string, ScalarField>): FormData {
  const form = new FormData();
  for (const [key, value] of Object.entries(fields)) {
    if (value !== undefined) form.append(key, String(value));
  }
  for (const [field, file] of Object.entries(spec.files ?? {})) {
    if (!file) continue;
    // Buffer → Blob: axios streams the spec-compliant FormData itself. Mirage
    // writes the part to disk and readFileSync's it regardless, so nothing is
    // gained by streaming into it.
    form.append(field, new Blob([new Uint8Array(file.bytes)], { type: file.contentType }), file.filename);
  }
  return form;
}

async function send<T>(spec: RequestSpec, retriedAuth = false): Promise<T> {
  const fields: Record<string, ScalarField> = { ...(spec.fields ?? {}) };
  if (spec.assetTargets) {
    // Non-negotiable on every write: Mirage destructures both from the BODY and
    // stores `${CLOUD_FRONT_URL}/${key}` verbatim (adminController.js:244, 385,
    // 686, 832, 980 destructure them; :197, 317, 487, 763, 925 build the URL).
    // Omit them and a customer-facing URL becomes the literal "undefined/<key>".
    fields.CLOUD_FRONT_URL = env.MIRAGE_ASSET_CDN_URL;
    fields.BUCKET_NAME = env.MIRAGE_ASSET_BUCKET;
  }

  const hasFiles = Object.values(spec.files ?? {}).some(Boolean);
  const headers: Record<string, string> = {};
  if (spec.requiresAdmin) headers.token = await getAdminToken();

  const body = hasFiles
    ? buildMultipart(spec, fields)
    : Object.keys(fields).length > 0
      ? Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined))
      : undefined;

  let res: AxiosResponse<unknown>;
  try {
    res = await transport().request({
      method: spec.method,
      url: spec.path,
      params: spec.query,
      data: body,
      headers,
    });
  } catch (cause) {
    throw classifyMirageTransportFailure(cause, spec.context);
  }

  if (spec.tolerateStatuses?.includes(res.status)) {
    return undefined as T;
  }

  if (isFailure(res)) {
    const error = classifyMirageFailure(res.status, messageOf(res), spec.context);
    // ONE retry on an auth failure, with a freshly minted token — a login-mode
    // token expires (Mirage's JWT_EXPIRE defaults to 1d) and the first call
    // after that is the only symptom. A second failure is an operator problem.
    if (error.failureClass === 'auth' && spec.requiresAdmin && !retriedAuth && !env.MIRAGE_ADMIN_TOKEN) {
      invalidateAdminToken();
      return send<T>(spec, true);
    }
    throw error;
  }

  if (spec.dataKey === null) return res.data as T;

  const payload = asRecord(res.data)?.[spec.dataKey ?? 'data'];
  if (payload === undefined || payload === null) {
    throw new MirageError(
      MirageErrorCode.MALFORMED_RESPONSE,
      'terminal',
      'Mirage returned a success with no payload.',
      spec.context,
      res.status
    );
  }
  return payload as T;
}

// ── Normalizers (field by field, never a spread) ────────────────────────────

function str(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function num(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

/** Mirage ids arrive as ObjectId strings; a populated ref arrives as an object. */
function idOf(value: unknown): string | undefined {
  if (typeof value === 'string' && value.length > 0) return value;
  const record = asRecord(value);
  const nested = record?._id;
  return typeof nested === 'string' ? nested : undefined;
}

function idList(value: unknown): string[] {
  return Array.isArray(value) ? value.map(idOf).filter((id): id is string => Boolean(id)) : [];
}

function requireId(raw: Record<string, unknown>, context: string): string {
  const id = idOf(raw._id) ?? idOf(raw.id);
  if (!id) {
    throw new MirageError(
      MirageErrorCode.MALFORMED_RESPONSE,
      'terminal',
      'Mirage returned an entity with no id.',
      context
    );
  }
  return id;
}

function toRestaurant(raw: Record<string, unknown>): MirageRestaurant {
  return {
    id: requireId(raw, 'read restaurant'),
    name: str(raw.name) ?? '',
    location: str(raw.location) ?? '',
    ...(str(raw.icon) ? { icon: str(raw.icon) } : {}),
    ...(str(raw.phone) ? { phone: str(raw.phone) } : {}),
    ...(str(raw.description) ? { description: str(raw.description) } : {}),
    ...(str(raw.clientType) ? { clientType: str(raw.clientType) } : {}),
    categoryIds: idList(raw.categories),
  };
}

function toCategory(raw: Record<string, unknown>): MirageCategory {
  return {
    id: requireId(raw, 'read category'),
    name: str(raw.name) ?? '',
    ...(idOf(raw.restaurant) ? { restaurantId: idOf(raw.restaurant) } : {}),
    ...(str(raw.image) ? { image: str(raw.image) } : {}),
    productIds: idList(raw.products),
  };
}

function toItem(raw: Record<string, unknown>): MirageItem {
  const model = asRecord(raw.model);
  return {
    id: requireId(raw, 'read item'),
    name: str(raw.name) ?? '',
    ...(str(raw.description) ? { description: str(raw.description) } : {}),
    ...(num(raw.price) !== undefined ? { price: num(raw.price) } : {}),
    ...(str(raw.image) ? { image: str(raw.image) } : {}),
    ...(str(model?.src) ? { modelSrc: str(model?.src) } : {}),
    ...(str(model?.iosSrc) ? { modelIosSrc: str(model?.iosSrc) } : {}),
    ...(idOf(raw.category) ? { categoryId: idOf(raw.category) } : {}),
    ...(idOf(raw.restaurant) ? { restaurantId: idOf(raw.restaurant) } : {}),
    ...(typeof raw.imgOnly === 'boolean' ? { imgOnly: raw.imgOnly } : {}),
  };
}

function toList<T>(payload: unknown, map: (raw: Record<string, unknown>) => T): T[] {
  if (!Array.isArray(payload)) return [];
  return payload
    .map(asRecord)
    .filter((raw): raw is Record<string, unknown> => raw !== undefined)
    .map(map);
}

// ── The client ──────────────────────────────────────────────────────────────

export const mirageClient: MirageClient = {
  async listRestaurants(): Promise<MirageRestaurant[]> {
    const data = await send<unknown>({
      method: 'get',
      path: '/get-all-restaurants',
      context: 'list restaurants',
      requiresAdmin: true,
    });
    return toList(data, toRestaurant);
  },

  /**
   * THE PROVISIONING CALL. Its response id becomes `catalog.mirageRestaurantId`
   * and, through it, the permanent public URL — persist it before anything else.
   *
   * `location` is always sent (Mirage 400s when it is not a string), and
   * `description` is deliberately absent: no restaurant write endpoint accepts
   * one.
   */
  async createRestaurant(input: CreateRestaurantInput): Promise<MirageRestaurant> {
    const data = await send<Record<string, unknown>>({
      method: 'post',
      path: '/create-restaurant',
      context: 'create restaurant',
      requiresAdmin: true,
      assetTargets: true,
      fields: { name: input.name, location: input.location, phoneNo: input.phoneNo },
      ...(input.image ? { files: { image: input.image } } : {}),
    });
    return toRestaurant(data);
  },

  async updateRestaurant(id: string, input: UpdateRestaurantInput): Promise<MirageRestaurant> {
    const data = await send<Record<string, unknown>>({
      method: 'put',
      path: `/update-restaurant/${encodeURIComponent(id)}`,
      context: 'update restaurant',
      requiresAdmin: true,
      assetTargets: true,
      // BOTH must be strings on every call — this is a full replace, not a patch.
      fields: { name: input.name, location: input.location, phoneNo: input.phoneNo },
      ...(input.image ? { files: { image: input.image } } : {}),
    });
    return toRestaurant(data);
  },

  async deleteRestaurant(id: string): Promise<void> {
    await send<unknown>({
      method: 'delete',
      path: `/delete-restaurant/${encodeURIComponent(id)}`,
      context: 'delete restaurant',
      requiresAdmin: true,
      dataKey: null,
    });
  },

  async listCategories(restaurantRef: string): Promise<MirageCategory[]> {
    const data = await send<unknown>({
      method: 'get',
      path: `/get-all-categories-admin/${encodeURIComponent(restaurantRef)}`,
      context: 'list categories',
      requiresAdmin: true,
    });
    return toList(data, toCategory);
  },

  async createCategory(input: CreateCategoryInput): Promise<MirageCategory> {
    const data = await send<Record<string, unknown>>({
      method: 'post',
      path: '/create-category',
      context: 'create category',
      requiresAdmin: true,
      assetTargets: true,
      fields: { name: input.name, restaurant: input.restaurantId },
      ...(input.image ? { files: { image: input.image } } : {}),
    });
    return toCategory(data);
  },

  async updateCategory(id: string, input: UpdateCategoryInput): Promise<MirageCategory> {
    const data = await send<Record<string, unknown>>({
      method: 'put',
      path: `/update-category/${encodeURIComponent(id)}`,
      context: 'update category',
      requiresAdmin: true,
      assetTargets: true,
      fields: { name: input.name },
      ...(input.image ? { files: { image: input.image } } : {}),
    });
    return toCategory(data);
  },

  async listItemsForCategory(categoryRef: string): Promise<MirageItem[]> {
    const data = await send<unknown>({
      method: 'get',
      path: `/get-all-items-for-cat/${encodeURIComponent(categoryRef)}`,
      context: 'list items for category',
      requiresAdmin: true,
    });
    return toList(data, toItem);
  },

  /**
   * THE MONEY CALL for idempotency. Mirage has no idempotency key and will not
   * return an existing entity's id, so the caller MUST persist the returned id
   * before doing anything else — that single write is what makes a crash cost
   * zero duplicates. A `reconcile` failure here means the create already landed
   * (or the name collides): list via listItemsForCategory and adopt the id.
   */
  async createItem(input: CreateItemInput): Promise<MirageItem> {
    const data = await send<Record<string, unknown>>({
      method: 'post',
      path: '/create-item',
      context: 'create item',
      requiresAdmin: true,
      assetTargets: true,
      fields: {
        name: input.name,
        category: input.categoryId,
        restaurant: input.restaurantId,
        price: input.price,
        description: input.description,
        isNonVeg: input.isNonVeg,
      },
      files: {
        ...(input.image ? { image: input.image } : {}),
        ...(input.object ? { object: input.object } : {}),
      },
    });
    return toItem(data);
  },

  async updateItem(id: string, input: UpdateItemInput): Promise<MirageItem> {
    const data = await send<Record<string, unknown>>({
      method: 'put',
      path: `/update-item/${encodeURIComponent(id)}`,
      context: 'update item',
      requiresAdmin: true,
      assetTargets: true,
      fields: { name: input.name, price: input.price, isNonVeg: input.isNonVeg },
      files: {
        ...(input.image ? { image: input.image } : {}),
        ...(input.object ? { object: input.object } : {}),
      },
    });
    return toItem(data);
  },

  /**
   * Deleting an item that is already gone is a SUCCESS, not a failure: a
   * replayed run must converge, and Mirage answers 404 for a missing item
   * (adminController.js:1303-1308) — the one route that does not flatten
   * everything to 400.
   *
   * ⚠ The caller must handle the cascade: Mirage also deletes the CATEGORY when
   * this was its last item (adminController.js:1660-1676), so any cached
   * `mirageCategoryId` for that category is now stale and must be cleared.
   */
  async deleteItem(id: string): Promise<{ existed: boolean }> {
    try {
      await send<unknown>({
        method: 'delete',
        path: `/delete-item/${encodeURIComponent(id)}`,
        context: 'delete item',
        requiresAdmin: true,
        dataKey: null,
      });
      return { existed: true };
    } catch (error) {
      if (error instanceof MirageError && error.code === MirageErrorCode.NOT_FOUND) {
        return { existed: false };
      }
      throw error;
    }
  },

  /**
   * The read the public catalog page itself performs. Note the response is NOT
   * the usual `{data}` envelope — it is `{restaurantData, data, allCategry}`
   * (the misspelling is Mirage's, itemController.js:657-664).
   */
  async getPublicCatalog(slug: string): Promise<MiragePublicCatalog> {
    const body = await send<Record<string, unknown>>({
      method: 'get',
      path: `/get-data-for-new-ui/${encodeURIComponent(slug)}`,
      context: 'read public catalog',
      requiresAdmin: false,
      dataKey: null,
    });

    const restaurant = asRecord(body.restaurantData) ?? {};
    return {
      restaurant: {
        id: requireId(restaurant, 'read public catalog'),
        name: str(restaurant.name) ?? '',
        ...(str(restaurant.location) ? { location: str(restaurant.location) } : {}),
        ...(str(restaurant.phone) ? { phone: str(restaurant.phone) } : {}),
        ...(str(restaurant.icon) ? { icon: str(restaurant.icon) } : {}),
        ...(str(restaurant.description) ? { description: str(restaurant.description) } : {}),
        ...(str(restaurant.clientType) ? { clientType: str(restaurant.clientType) } : {}),
      },
      categories: toList(body.allCategry, toCategory),
      items: toList(body.data, toItem),
    };
  },

  async analyticsSummary(query: MirageAnalyticsQuery): Promise<MirageAnalyticsSummary> {
    return send<MirageAnalyticsSummary>({
      method: 'get',
      path: '/analytics/summary',
      context: 'analytics summary',
      requiresAdmin: true,
      query: analyticsParams(query),
    });
  },

  async analyticsTimeseries(query: MirageAnalyticsQuery): Promise<MirageTimeseriesPoint[]> {
    const data = await send<unknown>({
      method: 'get',
      path: '/analytics/timeseries',
      context: 'analytics timeseries',
      requiresAdmin: true,
      query: analyticsParams(query),
    });
    return Array.isArray(data) ? (data as MirageTimeseriesPoint[]) : [];
  },

  async analyticsTopProducts(query: MirageAnalyticsQuery): Promise<MirageTopProductRow[]> {
    const data = await send<unknown>({
      method: 'get',
      path: '/analytics/top-products',
      context: 'analytics top products',
      requiresAdmin: true,
      query: analyticsParams(query),
    });
    return Array.isArray(data) ? (data as MirageTopProductRow[]) : [];
  },
};

/**
 * `restaurant` is ALWAYS taken from the caller's mapping. Mirage's analytics
 * routes are admin-scoped and unscoped by default — omit this and the response
 * is every business's numbers, which is a cross-tenant leak, not an empty page.
 */
function analyticsParams(query: MirageAnalyticsQuery): Record<string, ScalarField> {
  return {
    restaurant: query.restaurantId,
    from: query.from,
    to: query.to,
    days: query.days,
    limit: query.limit,
  };
}

let active: MirageClient = mirageClient;

/** Injection seam — tests register a fake so CI never touches the live Mirage. */
export function setMirageClient(client: MirageClient): void {
  active = client;
}

export function getMirageClient(): MirageClient {
  return active;
}

/** Restores the real client (paired with setMirageClient in test teardown). */
export function resetMirageClient(): void {
  active = mirageClient;
}
