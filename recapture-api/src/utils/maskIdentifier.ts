// src/utils/maskIdentifier.ts
//
// The ONE server-side display mask for a user's contact identifier. `GET /auth/me`
// keeps the standing PII stance (no RAW phone/email ever leaves the API) but the
// Profile screen still has to show the user WHICH account they are signed into —
// so it ships a masked form and nothing else.
//
// MIRRORS the client's `OtpRequest.maskedDestination`
// (lib/application/auth/otp_request.dart) so the OTP screen ("Sent to …") and the
// Profile screen never disagree about how the same identifier looks:
//   phone → dial prefix + last 3 digits   '+919876543210' → '+91 ••••• ••210'
//   email → first character + domain      'ashish@gmail.com' → 'a•••@gmail.com'
//
// ONE DELIBERATE DIVERGENCE from the Dart original: where the client falls back
// to a partial/raw value (a ≤6-char phone is returned verbatim; a '@'-less email
// becomes '•••'), this returns null. The client is masking an identifier it just
// typed, so a degenerate value is harmless there; here a fallback would be the
// API shipping raw PII, which is exactly what this stance forbids. A null tells
// the client to hide the contact row.
//
// Pure — no DB, no throw, no logging.

/** The subset of a user document this mask needs. */
export interface MaskableIdentity {
  phone?: string | null;
  email?: string | null;
}

/** Mask character, matching the client's U+2022 BULLET. */
const DOT = '•';

/**
 * The display-masked contact identifier for [identity] — phone first (it is the
 * primary channel), then email. Returns null when there is no identifier, or
 * when the one present is too short / malformed to mask safely.
 */
export function maskIdentifier(identity: MaskableIdentity): string | null {
  const phone = identity.phone?.trim();
  if (phone) return maskPhone(phone);

  const email = identity.email?.trim();
  if (email) return maskEmail(email);

  return null;
}

/**
 * '+919876543210' → '+91 ••••• ••210'. A phone of 6 characters or fewer cannot
 * be masked without revealing most of it → null (the Dart mirror returns the raw
 * value here; see the file header for why the server must not).
 */
export function maskPhone(phone: string): string | null {
  if (phone.length <= 6) return null;
  const head = phone.slice(0, 3);
  const tail = phone.slice(-3);
  return `${head} ${DOT.repeat(5)} ${DOT.repeat(2)}${tail}`;
}

/**
 * 'ashish@gmail.com' → 'a•••@gmail.com'. No '@', or an '@' at index 0 (no local
 * part to mask), is unmaskable → null.
 */
export function maskEmail(email: string): string | null {
  const at = email.indexOf('@');
  if (at <= 0) return null;
  return `${email[0]}${DOT.repeat(3)}${email.slice(at)}`;
}

/** Which channel the (masked) identifier belongs to — drives the client's icon. */
export function contactChannelFor(identity: MaskableIdentity): 'sms' | 'email' {
  return identity.phone ? 'sms' : 'email';
}
