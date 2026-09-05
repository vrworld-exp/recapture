// src/routes/public.ts
//
// GET /r/:code — the printed standee. THE ONLY ROUTER IN THIS API THAT DOES NOT
// SPEAK THE JSON ENVELOPE.
//
// Its client is a phone camera opening a browser, not a Dio instance that
// understands `{status, code, message}`, so it answers with 302 redirects and
// text/html and nothing else. That carve-out is written down in AGENTS.md
// ("Envelope carve-out — the public router only") and NO OTHER ROUTER MAY COPY
// IT. The decision itself lives in services/qrResolverService.ts; this file is
// only status codes, headers and which page to render.
//
// NO RATE LIMIT, DELIBERATELY. A popular restaurant's standee is SUPPOSED to be
// scanned a hundred times an hour, and a per-code limit takes the menu down at
// dinner rush — the exact moment it matters. Abuse protection, if it is ever
// needed, belongs at the edge (Render/Cloudflare) where it can see the client,
// not in this handler where it can only see the restaurant.
import { Router, type ErrorRequestHandler, type Response } from 'express';

import { asyncHandler } from '@/utils/asyncHandler';
import { normalizeQrCode } from '@/utils/qrCodes';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { resolveCode } from '@/services/qrResolverService';
import {
  renderFallbackPage,
  FALLBACK_CACHE_CONTROL,
  type FallbackKind,
} from '@/services/qrFallbackPage';

const router = Router();

/**
 * Every fallback answer, in one place.
 *
 * `200`, NOT `404`, and both halves of that matter:
 *
 *  1. A bare `404` from this router would fall through to `notFound` and the
 *     diner would read `{"status":"error","code":"NOT_FOUND"}` off a standee.
 *     That is the dead link the brief forbids.
 *  2. `404` for unknown and `200` for unassigned is an ENUMERATION ORACLE: it
 *     tells an attacker which codes are minted, and a minted code is a specific
 *     restaurant's menu. Unknown and unassigned share this status, this
 *     content type and this page, so the two are indistinguishable from
 *     outside.
 *
 * `no-store` because a code activated five minutes from now must not be
 * shadowed by a cached "not live yet" page in a phone browser or a CDN.
 */
function sendFallback(res: Response, kind: FallbackKind, code: string | null): void {
  res
    .status(200)
    .type('html')
    .set('Cache-Control', FALLBACK_CACHE_CONTROL)
    .send(renderFallbackPage(kind, code));
}

/**
 * GET /r/:code — resolve one printed standee.
 *
 * | state                      | response                                  |
 * |----------------------------|-------------------------------------------|
 * | ACTIVE, catalog published  | record scan, 302 → the Mirage menu URL    |
 * | ACTIVE, not yet published  | 200 HTML — "this menu isn't live yet"     |
 * | UNASSIGNED                 | 200 HTML — "this menu isn't live yet"     |
 * | RETIRED                    | 200 HTML — "this code has been replaced"  |
 * | unknown                    | 200 HTML — the same page as UNASSIGNED    |
 */
router.get(
  '/:code',
  asyncHandler(async (req, res) => {
    const outcome = await resolveCode(req.params.code);

    if (outcome.kind === 'REDIRECT') {
      // 302, NOT 301. A permanent redirect is cached by the browser more or
      // less forever, so it would survive the code being retired or repointed —
      // the standee would keep sending diners to the previous restaurant with
      // no request ever reaching us to say otherwise. `no-store` on top, for
      // the same reason.
      res.set('Cache-Control', FALLBACK_CACHE_CONTROL);
      track(AnalyticsEvent.QR_CODE_SCANNED, { outcome: 'REDIRECT' });
      res.redirect(302, outcome.url);
      return;
    }

    track(AnalyticsEvent.QR_CODE_SCANNED, { outcome: outcome.fallback });
    // Re-normalised here rather than threaded through ResolveOutcome: it is a
    // pure string operation, and it keeps the service returning a decision
    // rather than a decision plus render data. It reaches only the rep
    // activation link.
    sendFallback(res, outcome.fallback, normalizeQrCode(req.params.code));
  })
);

/**
 * LAST IN THIS ROUTER, and mounted here rather than relying on
 * middleware/errorHandler.ts, because that one emits the JSON envelope and a
 * diner must never see it. A thrown error renders the ERROR page — which is
 * exactly why renderFallbackPage takes no required argument and touches no I/O:
 * this handler runs when the database is down.
 *
 * The four-argument signature is not optional. Drop `_next` and Express treats
 * this as ordinary middleware, the carve-out silently stops catching, and every
 * internal error becomes a JSON blob on a phone again. `asyncHandler` forwards
 * the route's rejections into it.
 */
const terminalErrorHandler: ErrorRequestHandler = (err, _req, res, _next) => {
  console.error('[qr-resolver] unhandled error — serving the fallback page', err);
  track(AnalyticsEvent.QR_CODE_SCANNED, { outcome: 'ERROR' });
  sendFallback(res, 'ERROR', null);
};

router.use(terminalErrorHandler);

export default router;
