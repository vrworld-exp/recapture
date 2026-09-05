// src/services/qrFallbackPage.ts
//
// The pages a diner sees when a scanned standee does NOT resolve to a menu.
//
// THE BRIEF FORBIDS EXACTLY ONE OUTCOME: a dead link. Every path through the
// public resolver that is not a redirect ends here, including a thrown error,
// so this module is the last thing standing between a phone camera and a blank
// browser tab. It is written to be unfailable:
//
//   - ZERO EXTERNAL REQUESTS. No CDN font, no remote image, no analytics
//     beacon, no favicon. Everything is inline. A diner on a saturated
//     restaurant wifi gets the page or nothing, and "nothing" is not allowed.
//   - NO TEMPLATE ENGINE and no new dependency — a plain string, so there is
//     nothing that can fail at render time.
//   - NO I/O AND NO ARGUMENT IT CANNOT LIVE WITHOUT. The ERROR page in
//     particular is rendered from inside the router's terminal error handler,
//     which is reached precisely when the database is down.
//   - NOTHING IS INTERPOLATED except the normalised code in the rep link, and
//     that one is guarded by QR_CODE_RE (see below), so this file needs no HTML
//     escaper. IF A FUTURE CHANGE INTERPOLATES ANYTHING ELSE, IT NEEDS AN
//     ESCAPER FIRST — this page has no login and no CSRF token, and its entire
//     XSS surface is currently zero by construction.
import { env } from '@/config/env';
import { QR_CODE_RE } from '@/utils/qrCodes';

/**
 * The four non-redirect outcomes.
 *
 * `UNKNOWN` renders the SAME page as `NOT_YET_LIVE`, deliberately: a different
 * page (or a different status) for an unminted code would tell an attacker
 * which codes exist — an enumeration oracle over every restaurant on the
 * platform. See routes/public.ts.
 */
export type FallbackKind = 'NOT_YET_LIVE' | 'REPLACED' | 'UNKNOWN' | 'ERROR';

/**
 * Sent on every fallback AND on the redirect.
 *
 * A code activated five minutes from now must not be shadowed by a cached
 * "not live yet" page sitting in a phone browser or a CDN.
 */
export const FALLBACK_CACHE_CONTROL = 'no-store';

/**
 * The whole stylesheet, inline.
 *
 * System font stack rather than a webfont, for the no-external-requests rule.
 * Sizes are generous because this is read on a phone held over a table at arm's
 * length, and the layout is a single centred column so there is no breakpoint
 * that can go wrong on an unusual viewport.
 *
 * helmet()'s default CSP allows `'unsafe-inline'` for styles but NOT for
 * scripts — which is fine, because this page has no script and must never grow
 * one.
 */
const STYLES = `
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px;
    background: #f6f5f2;
    color: #17171a;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
      "Helvetica Neue", Arial, sans-serif;
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
  }
  main {
    width: 100%;
    max-width: 30rem;
    background: #ffffff;
    border-radius: 20px;
    padding: 40px 28px;
    text-align: center;
    box-shadow: 0 1px 3px rgba(0,0,0,.06), 0 12px 32px rgba(0,0,0,.07);
  }
  .mark {
    width: 44px;
    height: 44px;
    margin: 0 auto 24px;
    border-radius: 50%;
    background: #17171a;
  }
  h1 { margin: 0 0 12px; font-size: 1.6rem; line-height: 1.25; letter-spacing: -.01em; }
  p { margin: 0 0 16px; font-size: 1.0625rem; color: #4a4a52; }
  p:last-of-type { margin-bottom: 0; }
  .note { font-size: .9375rem; color: #6b6b74; }
  .rep {
    margin: 28px 0 0;
    padding-top: 20px;
    border-top: 1px solid #e8e7e3;
    font-size: .8125rem;
    color: #8a8a93;
  }
  .rep a { color: #17171a; font-weight: 600; }
  @media (prefers-color-scheme: dark) {
    body { background: #0e0e10; color: #f4f4f6; }
    main { background: #1a1a1e; box-shadow: none; }
    .mark { background: #f4f4f6; }
    p { color: #b5b5bd; }
    .note { color: #92929b; }
    .rep { border-top-color: #2a2a30; color: #7d7d86; }
    .rep a { color: #f4f4f6; }
  }
`;

/**
 * Heading + body copy per state. No code, no restaurant name, no request id —
 * a diner cannot act on any of those and each one leaks something.
 *
 * The two "not live yet" entries are written out rather than aliased so that
 * changing one and forgetting the other is a visible diff, not a silent break
 * of the byte-identity property that hides which codes are minted.
 */
const NOT_LIVE_COPY = {
  title: 'This menu is not live yet',
  heading: 'This menu isn&rsquo;t live yet.',
  body: [
    'This restaurant is still setting up. Ask your server for a menu in the meantime &mdash; ' +
      'this code will start working as soon as they finish.',
    // An UNASSIGNED code is a demo surface as much as a holding page: this is
    // the first thing a curious diner ever reads about the product.
    '<span class="note">Mirage Menu lets a restaurant show its dishes in 3D, so you can look ' +
      'at a dish from every angle before you order. No app to install &mdash; just your ' +
      'camera.</span>',
  ],
};

const COPY: Record<FallbackKind, { title: string; heading: string; body: string[] }> = {
  NOT_YET_LIVE: NOT_LIVE_COPY,
  UNKNOWN: NOT_LIVE_COPY,
  REPLACED: {
    title: 'This code has been replaced',
    heading: 'This code has been replaced.',
    body: [
      'This standee is out of service. There should be a newer one on your table &mdash; ' +
        'scan that one instead, or ask your server for it.',
    ],
  },
  ERROR: {
    title: 'Something went wrong',
    heading: 'Something went wrong.',
    // No detail and no request id. This page is rendered when the database is
    // down; it must say the one true thing and stop.
    body: ['Try again in a moment.'],
  },
};

/**
 * The rep's one-tap activation link, or `''`.
 *
 * WHY IT IS HERE AT ALL: the rep's OS camera app already scans the standee and
 * lands on exactly this page, so this link gives activation on any phone with
 * no in-app QR scanner anywhere in the product. It is what lets the web client
 * ship without a scanner rather than with a gap.
 *
 * THE ONLY INTERPOLATION ON THE PAGE, and the guard is what keeps this file
 * escaper-free: `code` must match QR_CODE_RE — 8 characters of a 32-symbol
 * alphabet containing no `<`, `"`, `&` or `/` — or no link is rendered. A code
 * that fails the guard cannot carry markup because it cannot contain markup
 * characters. `WEB_APP_BASE_URL` is operator config validated as a URL at boot,
 * never request data.
 *
 * `WEB_APP_BASE_URL` unset renders the page WITHOUT the link rather than with a
 * broken one — a rep tapping through to `undefined/rep/activate` is worse than
 * a rep typing the code into the app.
 */
function repActivationLink(code: string | null): string {
  const base = env.WEB_APP_BASE_URL;
  if (!base || !code || !QR_CODE_RE.test(code)) return '';
  return (
    '<p class="rep">Are you a Mirage rep? ' +
    `<a href="${base}/rep/activate?code=${code}">Activate this code.</a></p>`
  );
}

/**
 * One of the four pages, as a complete HTML document.
 *
 * `code` is optional and only ever reaches the rep link. Callers on the ERROR
 * path pass nothing: `renderFallbackPage('ERROR')` touches no I/O, reads no
 * request state, and cannot throw.
 *
 * ON THE ENUMERATION PROPERTY: `UNKNOWN` and `NOT_YET_LIVE` differ by nothing
 * except the code inside the rep link — the value the scanner supplied in the
 * URL and therefore already knows. For the same input the two produce
 * byte-identical pages, so the response reveals nothing about which codes have
 * been minted.
 */
export function renderFallbackPage(kind: FallbackKind, code?: string | null): string {
  const copy = COPY[kind];
  const paragraphs = copy.body.map((line) => `<p>${line}</p>`).join('\n      ');
  // The rep link belongs only on the "not live yet" page — and therefore on
  // UNKNOWN too, or the two would stop being the same page.
  const rep = kind === 'NOT_YET_LIVE' || kind === 'UNKNOWN' ? repActivationLink(code ?? null) : '';

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="robots" content="noindex" />
    <title>${copy.title}</title>
    <style>${STYLES}</style>
  </head>
  <body>
    <main>
      <div class="mark" aria-hidden="true"></div>
      <h1>${copy.heading}</h1>
      ${paragraphs}
      ${rep}
    </main>
  </body>
</html>
`;
}
