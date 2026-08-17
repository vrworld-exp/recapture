// src/services/mirage/mirageErrors.ts
//
// Turning a Mirage failure into something ReCapture can act on. This is the
// hardest part of the whole integration and it deserves its own file.
//
// WHY IT IS HARD: Mirage returns HTTP 400 for validation errors, for not-found,
// for a bad api key, for a non-admin token, AND from its global 404 handler
// (mirage-be/index.js:221). The status code alone therefore classifies nothing.
// The only remaining signal is the prose `message`, which is unversioned,
// untested and untyped — Mirage has no test suite at all. So every rule below
// cites the Mirage source line it was read from, and every rule is pinned by a
// fixture quoting the real message in tests/mirage-error-classification.test.ts.
//
// WHY IT DOES NOT THROW NonRetryableJobError: that class lives in src/worker/,
// and services must not import from the worker — the analytics proxy calls this
// adapter from a request path, not a job. The adapter classifies; the publish
// PROCESSOR translates a `terminal` class into NonRetryableJobError. One
// classifier, two consumers.

/**
 * What the caller should do about a failure.
 *
 *   retryable — transport/5xx/429. Let the worker's existing backoff handle it
 *               (1→2→4 min, capped at 30). Nothing was durably written that we
 *               know of, and the catalog state must not move.
 *   reconcile — Mirage says the entity already exists but will not tell us its
 *               id. The caller LISTS (M11/M12/M1), adopts the existing id, and
 *               converts the action to an UPDATE. This is the entire substitute
 *               for the idempotency support Mirage does not have.
 *   auth      — the credential was rejected. Worth exactly ONE retry with a
 *               freshly minted admin token; after that it is an operator
 *               problem, not a transient one.
 *   terminal  — retrying can never succeed (bad input, missing parent, oversize
 *               asset). Fail this unit, keep the rest of the run going.
 */
export const MIRAGE_FAILURE_CLASSES = ['retryable', 'reconcile', 'auth', 'terminal'] as const;
export type MirageFailureClass = (typeof MIRAGE_FAILURE_CLASSES)[number];

/** Stable ReCapture codes. These, never Mirage prose, are what we store and show. */
export const MirageErrorCode = {
  /** No response at all — refused, reset, DNS, socket hang up. */
  UNREACHABLE: 'MIRAGE_UNREACHABLE',
  /** The request exceeded MIRAGE_REQUEST_TIMEOUT_MS. */
  TIMEOUT: 'MIRAGE_TIMEOUT',
  /** 5xx — Mirage's own `Error by server (...)` path, and anything unhandled. */
  SERVER_ERROR: 'MIRAGE_SERVER_ERROR',
  /** 429 — not currently produced by any admin route, kept for safety. */
  RATE_LIMITED: 'MIRAGE_RATE_LIMITED',
  /** The `apikey` header is missing or unknown. */
  API_KEY_REJECTED: 'MIRAGE_API_KEY_REJECTED',
  /** The admin JWT is missing, expired, malformed, or not an admin. */
  AUTH_REJECTED: 'MIRAGE_AUTH_REJECTED',
  /** "…already exist…" — the reconcile trigger. */
  ALREADY_EXISTS: 'MIRAGE_ALREADY_EXISTS',
  /** A referenced restaurant/category/item is not there. */
  NOT_FOUND: 'MIRAGE_NOT_FOUND',
  /** Multer refused the file (100 MB cap) — our preflight should catch it first. */
  ASSET_TOO_LARGE: 'MIRAGE_ASSET_TOO_LARGE',
  /** Anything else Mirage rejected as bad input. */
  INVALID_REQUEST: 'MIRAGE_INVALID_REQUEST',
  /** 2xx whose body was not the shape Mirage documents. */
  MALFORMED_RESPONSE: 'MIRAGE_MALFORMED_RESPONSE',
  /** MIRAGE_* env is absent — an operator problem, raised before any call. */
  NOT_CONFIGURED: 'MIRAGE_NOT_CONFIGURED',
} as const;

export type MirageErrorCodeValue = (typeof MirageErrorCode)[keyof typeof MirageErrorCode];

/**
 * A classified Mirage failure.
 *
 * `message` is OURS and safe to log. `mirageMessage` is the raw prose and is
 * DIAGNOSTIC ONLY: it may never be rendered to a user, stored on a catalog row,
 * or copied into an analytics prop. It is kept because when a Mirage handler
 * changes wording, the classification table above is what breaks, and the raw
 * string in a worker log is the only way to notice.
 */
export class MirageError extends Error {
  constructor(
    public readonly code: MirageErrorCodeValue,
    public readonly failureClass: MirageFailureClass,
    message: string,
    public readonly context: string,
    public readonly status?: number,
    public readonly mirageMessage?: string
  ) {
    super(message);
    this.name = 'MirageError';
  }

  /** True when the worker should let its own backoff retry the whole job. */
  get isRetryable(): boolean {
    return this.failureClass === 'retryable';
  }
}

interface ClassificationRule {
  /** HTTP statuses this rule applies to; omitted means "any status". */
  statuses?: number[];
  /** Case-insensitive match against Mirage's `message`; omitted means "any". */
  match?: RegExp;
  code: MirageErrorCodeValue;
  failureClass: MirageFailureClass;
  /** OUR message. Never interpolates Mirage's prose. */
  message: string;
}

/**
 * THE TABLE. Order is significant — the first matching rule wins, so the
 * specific message rules must precede the catch-all status rules.
 *
 * Every `match` below is quoted from a real Mirage source line. Keep the
 * citation when you add a rule; it is the only documentation Mirage's API has.
 */
export const MIRAGE_CLASSIFICATION_RULES: readonly ClassificationRule[] = [
  // ── auth: the api key ─────────────────────────────────────────────────────
  // apiKeyValidator.js:30 "Api key is not given." / :34 "Invalid Api key."
  // Note the status is 400, NOT 401 — this rule exists because of that.
  {
    statuses: [400, 401, 403],
    match: /api key/i,
    code: MirageErrorCode.API_KEY_REJECTED,
    failureClass: 'auth',
    message: 'Mirage rejected the API key.',
  },

  // ── auth: the admin JWT ───────────────────────────────────────────────────
  // middleware.js:52,61,69 "<jwt error> | Login again please with valid email
  // and password." (403), :28 "…No token found." (401), :85 "Data in token is
  // bad or inomplete)" (401), :105 "Payload is empty , LogIn again" (401).
  {
    statuses: [400, 401, 403],
    match: /login again|jwt expired|jwt malformed|jwt must be provided|no token found|data in token/i,
    code: MirageErrorCode.AUTH_REJECTED,
    failureClass: 'auth',
    message: 'Mirage rejected the admin credential.',
  },
  // middleware.js:142 "Bad Request.(Please logIn)" and :149 "Only chef can
  // access this api." — the latter is isAdmin's message, a copy-paste bug in
  // Mirage (it guards `role === "admin"`). Both are 400, both mean the token is
  // not an admin token. Matching the literal string is the only option.
  {
    statuses: [400, 401, 403],
    match: /please log ?in|only chef can access/i,
    code: MirageErrorCode.AUTH_REJECTED,
    failureClass: 'auth',
    message: 'Mirage rejected the admin credential.',
  },

  // ── reconcile ─────────────────────────────────────────────────────────────
  // adminController.js:220 "Restaurant already exist. Name should be unique",
  // :567 "Category already exist.Category name should be unique",
  // :896 "Product already exist.Product name should be unique".
  // Mirage does NOT return the existing id, which is why this is its own class:
  // the caller has to go and find it.
  {
    statuses: [400, 409],
    match: /already exist/i,
    code: MirageErrorCode.ALREADY_EXISTS,
    failureClass: 'reconcile',
    message: 'Mirage already has an entity with this name.',
  },

  // ── terminal: the asset was refused ───────────────────────────────────────
  // multer's own LIMIT_FILE_SIZE surfaces as "File too large"; libs/multer.js
  // caps at 100 MB. Our preflight (MIRAGE_MAX_ASSET_BYTES) should reject first,
  // so reaching here means the preflight and the cap disagree.
  {
    match: /file too large|limit_file_size/i,
    code: MirageErrorCode.ASSET_TOO_LARGE,
    failureClass: 'terminal',
    message: 'The file is larger than Mirage accepts.',
  },
  {
    statuses: [413],
    code: MirageErrorCode.ASSET_TOO_LARGE,
    failureClass: 'terminal',
    message: 'The file is larger than Mirage accepts.',
  },

  // ── retryable ─────────────────────────────────────────────────────────────
  // Placed BEFORE the message-matched terminal rules on purpose: Mirage's
  // catch-all is `Error by server (${error.message})` with a 500, and that
  // interpolated message can contain any word — including "not found". A 5xx is
  // transient whatever it says, and misreading one as terminal would fail a
  // product that a retry would have published.
  {
    statuses: [429],
    code: MirageErrorCode.RATE_LIMITED,
    failureClass: 'retryable',
    message: 'Mirage is rate limiting us.',
  },
  // Mirage runs on a tier that sleeps (index.js self-pings every 30 s), so a
  // 5xx here is very often "it was still waking up".
  {
    statuses: [500, 502, 503, 504],
    code: MirageErrorCode.SERVER_ERROR,
    failureClass: 'retryable',
    message: 'Mirage is having trouble right now.',
  },

  // ── terminal: a referenced entity is gone ─────────────────────────────────
  // adminController.js:877 "Category not found", :884 "Restaurant not found",
  // :1305 "No item found with given itemId (…)" (404), :440/:487 "Invalid
  // restaurant name or id (…)".
  //
  // This class is load-bearing for the cascade bug: Mirage's delete-item also
  // deletes the CATEGORY when it removed that category's last item
  // (adminController.js:1312-1319), so the next create-item against the stale
  // mapping lands exactly here. The processor's response is to clear the
  // mapping and re-create, not to fail the product.
  {
    match: /not found|invalid restaurant name or id|does not exist/i,
    code: MirageErrorCode.NOT_FOUND,
    failureClass: 'terminal',
    message: 'Mirage no longer has the referenced entity.',
  },
  {
    statuses: [404],
    code: MirageErrorCode.NOT_FOUND,
    failureClass: 'terminal',
    message: 'Mirage no longer has the referenced entity.',
  },

  // ── terminal catch-all ────────────────────────────────────────────────────
  // Everything else Mirage says no to, including its global 404 handler
  // (index.js:221 "Path not found.(400)", served as HTTP 400).
  {
    code: MirageErrorCode.INVALID_REQUEST,
    failureClass: 'terminal',
    message: 'Mirage rejected the request.',
  },
];

/**
 * Classify one Mirage failure response. Exported for the contract test, which
 * drives it with the real messages quoted above.
 *
 * `status` is the HTTP status (or 0 when there was no response at all);
 * `mirageMessage` is the `message` field of Mirage's `{status:false,message}`
 * body, which may be absent.
 */
export function classifyMirageFailure(
  status: number,
  mirageMessage: string | undefined,
  context: string
): MirageError {
  const text = mirageMessage ?? '';
  const rule = MIRAGE_CLASSIFICATION_RULES.find((candidate) => {
    if (candidate.statuses && !candidate.statuses.includes(status)) return false;
    if (candidate.match && !candidate.match.test(text)) return false;
    return true;
  });

  // The table's last rule has neither a status nor a match filter, so `rule` is
  // always defined. The fallback exists only to keep this total under `strict`.
  const resolved = rule ?? MIRAGE_CLASSIFICATION_RULES[MIRAGE_CLASSIFICATION_RULES.length - 1];

  return new MirageError(
    resolved.code,
    resolved.failureClass,
    resolved.message,
    context,
    status,
    mirageMessage
  );
}

/**
 * Classify a transport-level failure — no HTTP response arrived. Always
 * retryable: an unreachable Mirage is the textbook transient case, and the
 * worker's backoff plus the run's PARTIAL/FAILED accounting already bound it.
 */
export function classifyMirageTransportFailure(cause: unknown, context: string): MirageError {
  const code = (cause as { code?: unknown } | null)?.code;
  const isTimeout =
    code === 'ECONNABORTED' ||
    code === 'ETIMEDOUT' ||
    (cause instanceof Error && /timeout/i.test(cause.message));

  return new MirageError(
    isTimeout ? MirageErrorCode.TIMEOUT : MirageErrorCode.UNREACHABLE,
    'retryable',
    isTimeout ? 'Mirage did not respond in time.' : 'Mirage is unreachable.',
    context,
    0,
    cause instanceof Error ? cause.message : undefined
  );
}
