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
import { randomBytes } from 'crypto';
import { Readable } from 'stream';

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
  DeleteItemOptions,
  DeleteItemResult,
  MirageAddress,
  MirageAnalyticsQuery,
  MirageAnalyticsSummary,
  MirageAvailability,
  MirageCategory,
  MirageFileField,
  MirageFileUpload,
  MirageItem,
  MiragePublicCatalog,
  MirageRestaurant,
  MirageSocialLinks,
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
  /**
   * M3 — branding, and the `isPublished` flag feature 39's unpublish flips.
   * A PARTIAL update since the phase-2 rework: omitted fields are left alone.
   */
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
  /** M6 — rename a category, or just reorder it. */
  updateCategory(id: string, input: UpdateCategoryInput): Promise<MirageCategory>;
  /** M12 — a category's items. The reconcile read for products. */
  listItemsForCategory(categoryRef: string): Promise<MirageItem[]>;
  /** M8 — create an item. Persist the returned id before doing anything else. */
  createItem(input: CreateItemInput): Promise<MirageItem>;
  /**
   * M9 — update an item. Now applies `description` and `category` too, and
   * re-derives `imgOnly` from what the document ends up holding.
   */
  updateItem(id: string, input: UpdateItemInput): Promise<MirageItem>;
  /**
   * M10 — HARD delete. By default it also deletes the item's CATEGORY when it
   * was that category's last item; `keepCategory` opts out. Resolves
   * `{ existed: false }` when the item was already gone, so a replayed delete is
   * a success, not a failure.
   */
  deleteItem(id: string, options?: DeleteItemOptions): Promise<DeleteItemResult>;
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

/**
 * What a caller may put in a request field.
 *
 * Everything Mirage receives is a STRING: every admin write goes through
 * multer's `uploadFieldsMW`, so the body arrives as `"true"`, `"3"`,
 * `'["a","b"]'`, and helper.js's `parse*Field` functions coerce it back. The
 * client serialises here so no call site has to remember which of Mirage's
 * fields wants JSON and which wants a bare scalar.
 */
type FieldValue =
  | string
  | number
  | boolean
  | readonly string[]
  | Record<string, string | undefined>
  | undefined;

/**
 * One field, as Mirage's parsers expect to read it.
 *
 *   string[]  -> a JSON array string  (parseTagsField, helper.js:50-71)
 *   object    -> a JSON object string (parseObjectField, helper.js:113-124)
 *   boolean   -> "true"/"false"       (parseBooleanField, helper.js:22-33)
 *   number    -> its decimal form     (parseNumberField, helper.js:35-47)
 *
 * An empty object serialises to `undefined`, not `"{}"`: Mirage reads an empty
 * value as "field absent", and an object with nothing in it is an update that
 * says nothing.
 */
function serializeField(value: FieldValue): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  if (Array.isArray(value)) return JSON.stringify(value);
  const entries = Object.entries(value as Record<string, string | undefined>).filter(
    ([, entry]) => entry !== undefined
  );
  return entries.length > 0 ? JSON.stringify(Object.fromEntries(entries)) : undefined;
}

interface RequestSpec {
  method: 'get' | 'post' | 'put' | 'delete';
  path: string;
  /** Human phrase for error messages and logs, e.g. 'create item'. */
  context: string;
  /** Send the admin `token` header. Every /admin write needs it; M14 does not. */
  requiresAdmin: boolean;
  query?: Record<string, ScalarField>;
  /** Form/JSON fields. Undefined values are dropped. */
  fields?: Record<string, FieldValue>;
  /** Multipart file parts, keyed by Mirage's field name (multer.js:15-19). */
  files?: Partial<Record<MirageFileField, MirageFileUpload>>;
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

/**
 * The multipart body, encoded BY HAND as a stream.
 *
 * WHY NOT `FormData` + `Blob`. The spec-compliant pair would require every part
 * to exist as an in-memory Blob first, which for a 90 MiB GLB means holding the
 * whole model in this process — twice, counting the copy `new Uint8Array(buf)`
 * makes. Render's instance does not survive two concurrent publishes doing that.
 * Encoding it ourselves lets a `stream` part be piped straight from S3 into the
 * socket, so peak memory is one 64 KiB chunk regardless of file size. It costs
 * about forty lines and no dependency (`form-data` would be a second HTTP-ish
 * library for one function).
 *
 * The boundary is random per request, as the format requires. Every part header
 * is ASCII and every value we interpolate is either a serialised field or a
 * filename we chose ourselves — never caller-controlled prose — so there is
 * nothing here that can inject a premature boundary.
 */
interface MultipartBody {
  stream: Readable;
  contentType: string;
  /**
   * Exact length, so the request goes out with a real Content-Length rather
   * than chunked. Computable only because every stream part declares its size —
   * which the asset preflight already had to fetch anyway.
   */
  contentLength: number;
}

const CRLF = '\r\n';

function partHeader(boundary: string, field: string, file?: MirageFileUpload): string {
  const disposition = file
    ? `form-data; name="${field}"; filename="${file.filename}"`
    : `form-data; name="${field}"`;
  const type = file ? `Content-Type: ${file.contentType}${CRLF}` : '';
  return `--${boundary}${CRLF}Content-Disposition: ${disposition}${CRLF}${type}${CRLF}`;
}

export function buildMultipart(
  spec: Pick<RequestSpec, 'files'>,
  fields: Record<string, string>
): MultipartBody {
  const boundary = `----recapture${randomBytes(16).toString('hex')}`;
  const files = Object.entries(spec.files ?? {}).filter(
    (entry): entry is [MirageFileField, MirageFileUpload] => Boolean(entry[1])
  );

  const preludes: string[] = [];
  for (const [key, value] of Object.entries(fields)) {
    preludes.push(`${partHeader(boundary, key)}${value}${CRLF}`);
  }

  const epilogue = `--${boundary}--${CRLF}`;

  let contentLength = Buffer.byteLength(preludes.join(''), 'utf8') + Buffer.byteLength(epilogue);
  for (const [field, file] of files) {
    contentLength +=
      Buffer.byteLength(partHeader(boundary, field, file), 'utf8') +
      (file.kind === 'bytes' ? file.bytes.byteLength : file.size) +
      Buffer.byteLength(CRLF);
  }

  async function* body(): AsyncGenerator<Buffer> {
    for (const prelude of preludes) yield Buffer.from(prelude, 'utf8');
    for (const [field, file] of files) {
      yield Buffer.from(partHeader(boundary, field, file), 'utf8');
      if (file.kind === 'bytes') {
        yield file.bytes;
      } else {
        // The whole point: chunks flow through, nothing accumulates.
        for await (const chunk of file.open()) {
          yield Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        }
      }
      yield Buffer.from(CRLF, 'utf8');
    }
    yield Buffer.from(epilogue, 'utf8');
  }

  return {
    stream: Readable.from(body()),
    contentType: `multipart/form-data; boundary=${boundary}`,
    contentLength,
  };
}

async function send<T>(spec: RequestSpec, retriedAuth = false): Promise<T> {
  const fields: Record<string, string> = {};
  for (const [key, value] of Object.entries(spec.fields ?? {})) {
    const serialized = serializeField(value);
    if (serialized !== undefined) fields[key] = serialized;
  }
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

  let body: unknown;
  if (hasFiles) {
    const multipart = buildMultipart(spec, fields);
    body = multipart.stream;
    headers['content-type'] = multipart.contentType;
    // Without this axios falls back to chunked encoding. multer copes, but a
    // real length is what lets Mirage's proxy reject an oversize body up front
    // instead of after 90 MiB have already crossed the wire.
    headers['content-length'] = String(multipart.contentLength);
  } else if (Object.keys(fields).length > 0) {
    body = fields;
  }

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

function strList(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === 'string') : [];
}

/** Picks a fixed set of string keys out of a nested Mirage block. */
function pickStrings<K extends string>(
  value: unknown,
  keys: readonly K[]
): Partial<Record<K, string>> | undefined {
  const raw = asRecord(value);
  if (!raw) return undefined;
  const out: Partial<Record<K, string>> = {};
  for (const key of keys) {
    const found = str(raw[key]);
    if (found) out[key] = found;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

const SOCIAL_LINK_KEYS = [
  'instagram',
  'facebook',
  'x',
  'youtube',
  'linkedin',
  'whatsapp',
] as const;
const ADDRESS_KEYS = ['line1', 'line2', 'city', 'state', 'postalCode', 'country'] as const;

function toRestaurant(raw: Record<string, unknown>): MirageRestaurant {
  const socialLinks = pickStrings<keyof MirageSocialLinks & string>(
    raw.socialLinks,
    SOCIAL_LINK_KEYS
  );
  const address = pickStrings<keyof MirageAddress & string>(raw.address, ADDRESS_KEYS);
  return {
    id: requireId(raw, 'read restaurant'),
    name: str(raw.name) ?? '',
    location: str(raw.location) ?? '',
    ...(str(raw.icon) ? { icon: str(raw.icon) } : {}),
    ...(str(raw.phone) ? { phone: str(raw.phone) } : {}),
    ...(str(raw.description) ? { description: str(raw.description) } : {}),
    ...(str(raw.website) ? { website: str(raw.website) } : {}),
    ...(socialLinks ? { socialLinks } : {}),
    ...(address ? { address } : {}),
    // Absent on documents written before the field existed, and Mirage treats
    // only an EXPLICIT false as unpublished — so absence must stay absence here
    // rather than collapsing to a default we would then read back as truth.
    ...(typeof raw.isPublished === 'boolean' ? { isPublished: raw.isPublished } : {}),
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
    ...(num(raw.sortPosition) !== undefined ? { sortPosition: num(raw.sortPosition) } : {}),
    productIds: idList(raw.products),
  };
}

function toItem(raw: Record<string, unknown>): MirageItem {
  const model = asRecord(raw.model);
  const availability = str(raw.availability);
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
    ...(Array.isArray(raw.tags) ? { tags: strList(raw.tags) } : {}),
    ...(availability === 'IN_STOCK' || availability === 'OUT_OF_STOCK'
      ? { availability: availability as MirageAvailability }
      : {}),
    ...(typeof raw.featured === 'boolean' ? { featured: raw.featured } : {}),
    ...(num(raw.sortPosition) !== undefined ? { sortPosition: num(raw.sortPosition) } : {}),
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
      fields: {
        name: input.name,
        location: input.location,
        phoneNo: input.phoneNo,
        description: input.description,
        website: input.website,
        socialLinks: input.socialLinks,
        address: input.address,
        isPublished: input.isPublished,
      },
      ...(input.image ? { files: { image: input.image } } : {}),
    });
    return toRestaurant(data);
  },

  /**
   * A PARTIAL update since the phase-2 rework (adminController.js:378-404) — an
   * omitted field is left alone rather than 400-ing the call. That is what makes
   * `{ isPublished: false }` legal on its own, which feature 39's unpublish
   * needs: it must take the page down without touching branding, and above all
   * without `delete-restaurant`, which would destroy the `_id` behind every
   * printed QR.
   */
  async updateRestaurant(id: string, input: UpdateRestaurantInput): Promise<MirageRestaurant> {
    const data = await send<Record<string, unknown>>({
      method: 'put',
      path: `/update-restaurant/${encodeURIComponent(id)}`,
      context: 'update restaurant',
      requiresAdmin: true,
      assetTargets: true,
      fields: {
        name: input.name,
        location: input.location,
        phoneNo: input.phoneNo,
        description: input.description,
        website: input.website,
        socialLinks: input.socialLinks,
        address: input.address,
        isPublished: input.isPublished,
      },
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
      fields: {
        name: input.name,
        restaurant: input.restaurantId,
        sortPosition: input.sortPosition,
      },
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
      fields: { name: input.name, sortPosition: input.sortPosition },
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
        tags: input.tags,
        availability: input.availability,
        featured: input.featured,
        sortPosition: input.sortPosition,
        // URL transfer mode (M1). Serialised like any other field; the
        // current Mirage handlers ignore them, which is exactly why the
        // default transfer mode still sends bytes.
        imageUrl: input.assetUrls?.imageUrl,
        objectUrl: input.assetUrls?.objectUrl,
        objectIosUrl: input.assetUrls?.objectIosUrl,
      },
      files: {
        ...(input.image ? { image: input.image } : {}),
        ...(input.object ? { object: input.object } : {}),
        ...(input.objectIos ? { objectIos: input.objectIos } : {}),
      },
    });
    return toItem(data);
  },

  /**
   * `description` and `category` ARE applied now (adminController.js:1460-1490),
   * so a re-filed product keeps its Mirage id and with it its whole analytics
   * history. `imgOnly` is re-derived by Mirage from the document's own state
   * afterwards, which is why nothing here sends it.
   *
   * ⚠ `name` should be sent on every update, changed or not — see UpdateItemInput.
   */
  async updateItem(id: string, input: UpdateItemInput): Promise<MirageItem> {
    const data = await send<Record<string, unknown>>({
      method: 'put',
      path: `/update-item/${encodeURIComponent(id)}`,
      context: 'update item',
      requiresAdmin: true,
      assetTargets: true,
      fields: {
        name: input.name,
        price: input.price,
        description: input.description,
        category: input.categoryId,
        isNonVeg: input.isNonVeg,
        tags: input.tags,
        availability: input.availability,
        featured: input.featured,
        sortPosition: input.sortPosition,
        // URL transfer mode (M1). Serialised like any other field; the
        // current Mirage handlers ignore them, which is exactly why the
        // default transfer mode still sends bytes.
        imageUrl: input.assetUrls?.imageUrl,
        objectUrl: input.assetUrls?.objectUrl,
        objectIosUrl: input.assetUrls?.objectIosUrl,
      },
      files: {
        ...(input.image ? { image: input.image } : {}),
        ...(input.object ? { object: input.object } : {}),
        ...(input.objectIos ? { objectIos: input.objectIos } : {}),
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
   * ⚠ THE CASCADE. By default Mirage also deletes the CATEGORY when this was
   * its last item (adminController.js:1660-1672). `keepCategory: true` opts out
   * (`?keepCategory=true`, adminController.js:1655-1656), which is what a
   * publish wants — an archived product must not silently destroy the category
   * its siblings will be filed under on the next run.
   *
   * The response's `deletedCategory` flag is reported back either way, because a
   * Mirage deployment that predates the query flag will still cascade, and the
   * caller has to clear its cached `mirageCategoryId` when it does.
   */
  async deleteItem(id: string, options: DeleteItemOptions = {}): Promise<DeleteItemResult> {
    try {
      const body = await send<Record<string, unknown>>({
        method: 'delete',
        path: `/delete-item/${encodeURIComponent(id)}`,
        context: 'delete item',
        requiresAdmin: true,
        dataKey: null,
        ...(options.keepCategory ? { query: { keepCategory: true } } : {}),
      });
      return { existed: true, deletedCategory: body?.deletedCategory === true };
    } catch (error) {
      if (error instanceof MirageError && error.code === MirageErrorCode.NOT_FOUND) {
        return { existed: false, deletedCategory: false };
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
