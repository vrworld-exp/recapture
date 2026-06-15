// src/providers/email.ts
import { randomUUID } from 'crypto';
import { env } from '@/config/env';
import type { DispatchResult } from './sms';

/**
 * Email dispatch seam.
 *
 * STUB: no email SDK is wired into this service yet. Replace the body with the
 * real client (e.g. AWS SES / Postmark) — the call site in the OTP service stays
 * the same. The plaintext `code` must never be logged.
 *
 * `OTP_SIMULATE_DISPATCH_FAILURE=true` makes this throw, to exercise the 502
 * rollback path without a real provider.
 */
export async function sendEmail(email: string, code: string): Promise<DispatchResult> {
  if (env.OTP_SIMULATE_DISPATCH_FAILURE) {
    throw new Error('Simulated email dispatch failure');
  }
  // TODO(provider): await emailClient.send({ to: email, subject, body w/ `code` });
  void email;
  void code;
  return { providerMessageId: `stub-email-${randomUUID()}` };
}
