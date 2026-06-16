// scripts/analytics-qa.ts
//
// Self-contained QA for the analytics emit layer (no test framework in this
// repo). It spies on the console sink and asserts the typed `track()` behaves
// per the tracking plan. Run it in BOTH environments:
//
//   dev/staging (loud on invalid):
//     MONGODB_URI=mongodb://x JWT_SECRET=0123456789012345678901234567890123 \
//     AWS_REGION=x AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=x \
//     S3_BUCKET_RAW=x S3_BUCKET_ARTIFACTS=x CLOUDFRONT_BASE_URL=https://x.test \
//     NODE_ENV=development npx tsx scripts/analytics-qa.ts
//
//   production (silent-drop on invalid):
//     ...same env... NODE_ENV=production npx tsx scripts/analytics-qa.ts
//
// Exits non-zero on the first failed assertion.
import { env } from '@/config/env';
import { track, AnalyticsEvent } from '@/utils/analytics';

const PROD = env.NODE_ENV === 'production';

// ── Console capture ─────────────────────────────────────────────────────────
const logs: string[] = [];
const errors: string[] = [];
const warns: string[] = [];
const origLog = console.log.bind(console);
const origErr = console.error.bind(console);
const origWarn = console.warn.bind(console);

function startCapture(): void {
  logs.length = errors.length = warns.length = 0;
  console.log = (...a: unknown[]) => void logs.push(a.join(' '));
  console.error = (...a: unknown[]) => void errors.push(a.join(' '));
  console.warn = (...a: unknown[]) => void warns.push(a.join(' '));
}
function stopCapture(): void {
  console.log = origLog;
  console.error = origErr;
  console.warn = origWarn;
}

// ── Tiny assert harness ─────────────────────────────────────────────────────
let failures = 0;
function check(name: string, cond: boolean): void {
  (cond ? origLog : origErr)(`${cond ? 'PASS' : 'FAIL'}: ${name}`);
  if (!cond) failures++;
}
/** A dispatched event shows up as an "[analytics] <name>" console.log line. */
const dispatched = (event: string): boolean => logs.some((l) => l.includes(`[analytics] ${event}`));

origLog(`\n── analytics QA (NODE_ENV=${env.NODE_ENV}) ──`);

// 1) Valid emit reaches the sink (dev) / passes silently (prod).
startCapture();
track(AnalyticsEvent.AUTH_OTP_SENT, { channel: 'sms', identifier_hash: 'abc123', success: true });
stopCapture();
if (PROD) {
  check('valid props: no error/warn in prod', errors.length === 0 && warns.length === 0);
} else {
  check('valid props: dispatched to sink', dispatched('auth_otp_sent'));
  check('valid props: no error logged', errors.length === 0);
}

// 2) Invalid props (missing required `success`) are rejected, never dispatched.
startCapture();
// eslint-disable-next-line @typescript-eslint/no-explicit-any
track(AnalyticsEvent.AUTH_OTP_SENT, { channel: 'sms', identifier_hash: 'abc' } as any);
stopCapture();
check('invalid props: not dispatched', !dispatched('auth_otp_sent'));
check(
  PROD ? 'invalid props: silent-drop logs warn (prod)' : 'invalid props: loud error (dev)',
  PROD ? warns.some((w) => w.includes('invalid props')) : errors.some((e) => e.includes('invalid props'))
);

// 3) PII guardrail: a forbidden key is stripped + flagged, event still emits clean.
startCapture();
track(AnalyticsEvent.AUTH_OTP_SENT, {
  channel: 'sms',
  identifier_hash: 'abc',
  success: true,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  email: 'raw@example.com',
} as any);
stopCapture();
check('PII guardrail: dropped key flagged', warns.some((w) => w.includes('email')));
check('PII guardrail: raw value never dispatched', !logs.some((l) => l.includes('raw@example.com')));
if (!PROD) {
  check('PII guardrail: event still dispatched after strip', dispatched('auth_otp_sent'));
}

// 3b) project_resumed: valid props (with optional source) dispatch cleanly.
startCapture();
track(AnalyticsEvent.PROJECT_RESUMED, {
  user_id_hash: 'uhash',
  project_id: 'pid',
  source: 'projects_list',
  seconds_since_last_update: 42,
});
stopCapture();
if (PROD) {
  check('project_resumed: no error/warn in prod', errors.length === 0 && warns.length === 0);
} else {
  check('project_resumed: dispatched to sink', dispatched('project_resumed'));
}
// Bad source enum is rejected (not dispatched).
startCapture();
// eslint-disable-next-line @typescript-eslint/no-explicit-any
track(AnalyticsEvent.PROJECT_RESUMED, { user_id_hash: 'u', project_id: 'p', source: 'nope' } as any);
stopCapture();
check('project_resumed: invalid source rejected', !dispatched('project_resumed'));

// 4) Resilience: a throwing sink must NOT propagate out of track().
startCapture();
console.log = () => {
  throw new Error('sink exploded');
};
let threw = false;
try {
  track(AnalyticsEvent.PROJECT_DELETED, {
    user_id_hash: 'u',
    project_id: 'p',
    was_already_deleted: false,
  });
} catch {
  threw = true;
}
stopCapture();
check('resilience: throwing sink swallowed (no throw)', threw === false);

origLog(`\n${failures === 0 ? 'ALL PASS' : `${failures} FAILURE(S)`}\n`);
process.exit(failures === 0 ? 0 : 1);
