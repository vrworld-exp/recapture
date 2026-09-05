// src/utils/qrCodes.ts
//
// The printed-standee code: how one is drawn, and how one typed by a human is
// normalised back to the stored form.
//
// THE WHOLE DESIGN RESTS ON ONE SENTENCE: the code is meaningless and
// permanent; the mapping is what moves. A code is never derived from a catalog
// id, a restaurant name, a batch number or a counter — it is drawn from a CSPRNG
// and means nothing until a row in QrCodeAssignment says what it points at. If a
// code could be guessed or walked, the public resolver would become an
// enumeration oracle over every restaurant on the platform.
import { randomBytes } from 'crypto';

/**
 * Crockford base32 with I, L, O and U removed.
 *
 * I/L collide with 1, O with 0, and U is dropped so a random 8-char draw cannot
 * spell an unfortunate word. 32 symbols is deliberate: 8 chars is 32^8 ≈ 1.1e12
 * codes, so a batch of 100k occupies under one ten-millionth of the space and a
 * guess is not a viable attack on the resolver.
 */
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

export const QR_CODE_LENGTH = 8;

/** The stored form: exactly QR_CODE_LENGTH alphabet characters, uppercase. */
export const QR_CODE_RE = new RegExp(`^[${ALPHABET}]{${QR_CODE_LENGTH}}$`);

/**
 * Largest byte value that maps to the alphabet without bias. Bytes at or above
 * this are redrawn rather than folded in.
 */
const UNBIASED_CEILING = Math.floor(256 / ALPHABET.length) * ALPHABET.length;

/**
 * Rejection sampling over crypto.randomBytes — NOT `byte % 32`.
 *
 * 256 is divisible by 32, so modulo happens to be uniform for THIS alphabet;
 * the rejection loop is here so that shortening the alphabet later (dropping a
 * glyph that turns out to misprint) cannot silently introduce bias. With the
 * current 32 symbols UNBIASED_CEILING is 256 and nothing is ever rejected, so
 * this costs one comparison per character today and stays correct tomorrow.
 */
export function generateQrCode(): string {
  let out = '';
  while (out.length < QR_CODE_LENGTH) {
    // Draw a whole buffer at a time; a per-character randomBytes(1) would be
    // the same entropy at many times the syscall cost when minting thousands.
    const buf = randomBytes(QR_CODE_LENGTH);
    for (const byte of buf) {
      if (byte >= UNBIASED_CEILING) continue;
      out += ALPHABET[byte % ALPHABET.length];
      if (out.length === QR_CODE_LENGTH) break;
    }
  }
  return out;
}

/**
 * Normalises user input to the stored form: uppercase, whitespace and hyphens
 * stripped. A standee may be printed as `ABCD-2345` for legibility while the
 * stored code is `ABCD2345`.
 *
 * Returns null for anything that is not exactly QR_CODE_LENGTH alphabet
 * characters after normalisation — so a malformed code never reaches the DB as
 * a query, which is what keeps the resolver's not-found path cheap.
 *
 * Note this does NOT map look-alike glyphs (a typed `O` does not become `0`).
 * The alphabet excludes them precisely so no such mapping is needed, and adding
 * one would make two different printed codes normalise to the same stored code.
 */
export function normalizeQrCode(raw: string): string | null {
  if (typeof raw !== 'string') return null;
  const normalized = raw.replace(/[\s-]/g, '').toUpperCase();
  return QR_CODE_RE.test(normalized) ? normalized : null;
}
