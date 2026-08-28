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
