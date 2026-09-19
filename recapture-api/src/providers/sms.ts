// src/providers/sms.ts
import { randomUUID } from 'crypto';
import { env } from '@/config/env';

export interface DispatchResult {
  providerMessageId: string;
}

/**
 * SMS dispatch seam.
 *
 * STUB: no SMS SDK is wired into this service yet. Replace the body with the
 * real client (e.g. Twilio / AWS SNS) — the call site in the OTP service stays
 * the same. The plaintext `code` must never be logged.
 *
 * `OTP_SIMULATE_DISPATCH_FAILURE=true` makes this throw, to exercise the 502
 * rollback path without a real provider.
 */
export async function sendSms(phone: string, code: string): Promise<DispatchResult> {
  if (env.OTP_SIMULATE_DISPATCH_FAILURE) {
    throw new Error('Simulated SMS dispatch failure');
  }
  // TODO(provider): await smsClient.send({ to: phone, body: `Your code is ${code}` });
  void phone;
  void code;
  return { providerMessageId: `stub-sms-${randomUUID()}` };
}

// ── Templated messages (everything that is not an OTP) ─────────────────────

/**
 * The non-OTP messages this service sends. One name per template; the text
 * lives in {@link SMS_TEMPLATES} and nowhere else, so a wording change is one
 * edit and the analytics/log line can name the template without quoting it.
 */
export type SmsTemplate = 'SUBSCRIPTION_PAY_NUDGE';

/**
 * Template bodies. `{name}` placeholders are filled from `vars` by
 * {@link renderSmsTemplate}; a placeholder with no var renders empty rather
 * than leaking the brace, and a var with no placeholder is ignored.
 *
 * SUBSCRIPTION_PAY_NUDGE — `restaurant` is the catalog's display name and
 * `what` is a server-chosen clause ("trial ends in 5 days", "payment is
 * overdue", …; services/subscription/nudgeService.ts picks it from the
 * subscription status).
 */
export const SMS_TEMPLATES: Record<SmsTemplate, string> = {
  SUBSCRIPTION_PAY_NUDGE:
    '{restaurant}: your Mirage Menu {what} — open the ReCapture app to pay and keep your 3D menu live.',
};

/** The template with its placeholders filled. Exported so a test can pin the copy. */
export function renderSmsTemplate(template: SmsTemplate, vars: Record<string, string>): string {
  return SMS_TEMPLATES[template].replace(/\{(\w+)\}/g, (_, key: string) => vars[key] ?? '');
}

/**
 * The second entry point on the same seam, for templated (non-OTP) messages.
 * `sendSms` above is OTP-shaped and its call site is untouched — this exists
 * so a nudge does not have to pretend to be a code.
 *
 * STUB, like `sendSms`: honours `OTP_SIMULATE_DISPATCH_FAILURE` and returns a
 * stub id. The ONE log line names the template and the stub id — never the
 * phone, never the rendered body (it carries the restaurant's name).
 */
export async function sendTemplatedSms(
  phone: string,
  template: SmsTemplate,
  vars: Record<string, string>
): Promise<DispatchResult> {
  if (env.OTP_SIMULATE_DISPATCH_FAILURE) {
    throw new Error('Simulated SMS dispatch failure');
  }
  const body = renderSmsTemplate(template, vars);
  // TODO(provider): await smsClient.send({ to: phone, body });
  void phone;
  void body;
  const providerMessageId = `stub-sms-${randomUUID()}`;
  console.log(`[sms] ${template} dispatched (stub)`, { providerMessageId });
  return { providerMessageId };
}
