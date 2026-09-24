// lib/domain/catalog/catalog_error_copy.dart
//
// THE TABLE. One sentence and one next action per error code the catalog
// surface can be handed — F10's half of the no-raw-text guarantee.
//
// The backend already refuses to pass upstream prose through: every failure
// leaves the API as `{status:"error", code:"<UPPER_SNAKE>", message:"..."}`
// with a message the backend wrote. That message is owner-safe, but it is
// still the SERVER's sentence: it cannot name the product the user just
// tapped, it does not know which of the two things on screen failed, and it
// never says what to do next. So the client reads THE CODE and writes its own.
//
// The structural consequence is the point: because every catalog surface goes
// through [catalogErrorCopy], there is no path by which a proxy's HTML, a
// stubbed response, an upstream 502 body or a server one deploy ahead can put
// text on this screen. A code this build has never heard of degrades to
// [kCatalogUnknownError], which is generic but honest.
//
// Publish's PER-ITEM sync codes (`PUBLISH_ASSET_MISSING` and friends) live in
// [syncErrorCopy] and are reached THROUGH this file — see the delegation at the
// bottom. They are one table split by origin, not two: those codes come from a
// publish run's stored rows, these come from an HTTP envelope, and only the
// envelope codes can arrive at an arbitrary call site.
//
// `test/catalog/feedback_test.dart` enumerates the backend's own sources and
// fails the build when a code here is missing — that test, not this comment, is
// what keeps the table honest.
import 'sync_error_copy.dart';

/// One failure, as the user reads it: what happened, and what to do next.
///
/// An alias rather than a second class. The publish screen already renders
/// [SyncErrorCopy]; a parallel type with the same two fields would be the exact
/// drift this file exists to prevent.
typedef CatalogErrorCopy = SyncErrorCopy;

/// The fallback for a code this build does not know.
///
/// Public so the enumerating test can tell "mapped" from "fell through" — an
/// unmapped code must fail CI, not quietly show this.
const CatalogErrorCopy kCatalogUnknownError = CatalogErrorCopy(
  'Something went wrong.',
  'Try again in a moment.',
);

/// Envelope codes, in the shape the API can emit them.
///
/// Wording rules, applied throughout: say what happened in the user's terms
/// (never an HTTP status, never a field path), then one action they can
/// actually take from where they are. A `null` action only where there is
/// genuinely nothing to do but wait.
const Map<String, CatalogErrorCopy> _copy = {
  // ── Catalog root ──────────────────────────────────────────────────────────
  'CATALOG_NOT_FOUND': CatalogErrorCopy(
    "You don't have a catalog yet.",
    'Create your catalog first.',
  ),
  'CATALOG_NOT_PUBLISHED': CatalogErrorCopy(
    'This catalog has not been published yet, so there is nothing online to '
        'show.',
    'Publish it first.',
  ),
  'CATALOG_NAME_TAKEN': CatalogErrorCopy(
    'Another business is already using this catalog name online.',
    'Try the suggested name, or pick a different one.',
  ),

  // ── Products and categories ───────────────────────────────────────────────
  'NOT_FOUND': CatalogErrorCopy(
    'That item is no longer in your catalog.',
    'Refresh to see what changed.',
  ),
  'CATEGORY_NOT_FOUND': CatalogErrorCopy(
    'That category no longer exists.',
    'Refresh, then pick a category again.',
  ),
  // "Item", not "product": the same code answers a duplicate CATEGORY name,
  // and a category manager telling the user another PRODUCT owns the name
  // sends them looking in the wrong list.
  'DUPLICATE_NAME': CatalogErrorCopy(
    'Another item in this catalog already uses this name.',
    'Rename it, then save again.',
  ),
  // Not a backend code — the CLIENT raises this one when the platform delivery
  // fails: a share sheet the user dismissed on a phone, a browser that refused
  // the download. There is no envelope behind it and no way to tell those two
  // apart from here, so the copy has to cover both without guessing which.
  //
  // The last clause matters more than it looks: the QR is still on screen, and
  // photographing it is a real way out that a café owner will not think of
  // while reading an error.
  'QR_SAVE_FAILED': CatalogErrorCopy(
    'The download was cancelled or blocked.',
    'Try again, or photograph the code on screen.',
  ),
  // ── One standee's sheet (admin and rep) ───────────────────────────────────
  // Both are REFUSALS, not outages: the same press gets the same answer, so
  // neither may fall through to "try again in a moment".
  'CODE_RETIRED': CatalogErrorCopy(
    'This standee was retired, so it cannot be printed again.',
    'Use a replacement standee.',
  ),
  'CODE_NOT_FOUND': CatalogErrorCopy(
    'That code is not one of yours.',
    'Check the eight characters, or ask an admin to assign it to you.',
  ),
  // ── The printable batch sheet (admin) ─────────────────────────────────────
  // Both refusals name a DIFFERENT button as the way out, which is exactly why
  // they cannot be left to fall through to "try again in a moment": an admin
  // following that advice presses the same button and gets the same refusal.
  'BATCH_TOO_LARGE': CatalogErrorCopy(
    'This batch is too big to lay out as printable sheets in one go.',
    'Download the print vendor CSV instead.',
  ),
  'NOTHING_TO_PRINT': CatalogErrorCopy(
    'Every code in this batch has been retired, so the sheet would be blank.',
    'Mint a replacement batch.',
  ),
  'ID_SET_MISMATCH': CatalogErrorCopy(
    'This list changed somewhere else while you were reordering it.',
    'Refresh, then drag again.',
  ),
  'INVALID_CURSOR': CatalogErrorCopy(
    'This list could not be loaded any further.',
    'Refresh to start again.',
  ),

  // ── 3D models ─────────────────────────────────────────────────────────────
  'MODEL_NOT_FOUND': CatalogErrorCopy(
    'That 3D model is no longer available.',
    'Pick a different model.',
  ),
  'MODEL_NOT_READY': CatalogErrorCopy(
    'That 3D model is still being built.',
    'Try again once it is ready.',
  ),

  // ── Images ────────────────────────────────────────────────────────────────
  'INVALID_KEY': CatalogErrorCopy(
    'That photo could not be attached.',
    'Add the photo again.',
  ),
  'OBJECT_NOT_FOUND': CatalogErrorCopy(
    'The photo did not finish uploading.',
    'Add the photo again.',
  ),
  'PAYLOAD_TOO_LARGE': CatalogErrorCopy(
    'That photo is too large.',
    'Choose a smaller photo.',
  ),
  'UNSUPPORTED_MEDIA_TYPE': CatalogErrorCopy(
    'That file type cannot be used as a product photo.',
    'Use a JPEG, PNG or WebP image.',
  ),

  // ── Publish (the ENVELOPE codes; per-item ones live in sync_error_copy) ───
  'PUBLISH_BLOCKED': CatalogErrorCopy(
    'Your catalog is not ready to publish yet.',
    'Open publish to see what is missing.',
  ),
  'PUBLISH_IN_PROGRESS': CatalogErrorCopy(
    'A publish is already running for this catalog.',
    'Open publish to watch it finish.',
  ),
  // DELETE /catalog only. The delete is aborted BEFORE anything local is
  // touched when the public page cannot be taken down, so the reassurance is
  // literally true and retrying really is the whole fix.
  'MIRAGE_UNAVAILABLE': CatalogErrorCopy(
    'Your public page could not be taken down, so nothing was deleted. Your '
        'catalog is exactly as it was.',
    'Try again shortly.',
  ),

  // ── Analytics ─────────────────────────────────────────────────────────────
  'ANALYTICS_UNAVAILABLE': CatalogErrorCopy(
    'Your numbers are not available right now. Nothing has been lost — this is '
        'only the report.',
    'Try again shortly.',
  ),

  // ── Subscription (the rep's trial door) ───────────────────────────────────
  // The three 409s POST /rep/catalogs/:id/subscription/trial can answer. Each
  // is a fact about the restaurant, not a failure to retry, so the action
  // says what happens instead.
  'TRIAL_ALREADY_USED': CatalogErrorCopy(
    'This restaurant has already used its free trial.',
    'The owner can activate a plan instead.',
  ),
  'SUBSCRIPTION_ACTIVE': CatalogErrorCopy(
    'This restaurant already has an active subscription.',
    'Nothing to start — the menu is covered.',
  ),
  'TRIAL_NOT_ELIGIBLE': CatalogErrorCopy(
    'This restaurant has paid before, so a free trial is not available.',
    'The owner can renew a plan instead.',
  ),

  // ── Payments (Stage 3) — the admin's decisions and the owner's checkout ──
  'PAYMENTS_UNAVAILABLE': CatalogErrorCopy(
    "Couldn't reach the payment service.",
    'Try again in a minute.',
  ),
  // POST /catalog/subscription/verify. Only ever after the sheet said
  // success, so never "unpaid": the server still settles the order itself.
  'INVALID_PAYMENT_SIGNATURE': CatalogErrorCopy(
    "We couldn't confirm this payment from the app.",
    'Your plan will update here once the payment is confirmed.',
  ),
  'ORDER_NOT_FOUND': CatalogErrorCopy(
    "We couldn't find this payment's order.",
    'Your plan will update here once the payment is confirmed.',
  ),
  'ALREADY_DECIDED': CatalogErrorCopy(
    'This payment request has already been verified or rejected.',
    'The list will refresh with the decision.',
  ),
  'AMOUNT_MISMATCH': CatalogErrorCopy(
    'The amount collected does not match the plan price.',
    'To verify it anyway, tick the override and explain why (20+ characters).',
  ),
  'CATALOG_DELETED': CatalogErrorCopy(
    'That catalog has been deleted, so the request was rejected.',
    null,
  ),
  'OVERRIDE_REQUIRED': CatalogErrorCopy(
    'This payment is not flagged as a duplicate.',
    'To refund it anyway, tick the override and explain why (30+ characters).',
  ),
  'NOT_REFUNDABLE': CatalogErrorCopy(
    'Only an online payment can be refunded here.',
    'Cash and complimentary entries have no provider payment to reverse.',
  ),
  'ALREADY_REFUNDED': CatalogErrorCopy(
    'This payment has already been refunded.',
    null,
  ),
  'NOT_IN_GRACE': CatalogErrorCopy(
    'Grace can only be extended while the subscription is in its grace period.',
    null,
  ),
  'PAYMENT_NOT_FOUND': CatalogErrorCopy(
    'That payment was not found.',
    'Refresh to see what changed.',
  ),
  'COLLECTOR_NOT_FOUND': CatalogErrorCopy(
    'That collector account was not found.',
    null,
  ),

  // ── The admin payment journal ─────────────────────────────────────────────
  'ALREADY_RESOLVED': CatalogErrorCopy(
    'An admin has already applied this payment to its catalog.',
    'The entry will refresh with what was done.',
  ),
  'NOT_APPLIED_YET': CatalogErrorCopy(
    'This payment has not been through the apply step yet.',
    'Press "Check with Razorpay" to finish it instead.',
  ),
  'NO_QUOTE': CatalogErrorCopy(
    'This payment carries no plan to apply.',
    'Start the plan from the restaurant panel instead.',
  ),
  'NOT_NEEDED': CatalogErrorCopy(
    'This payment was applied and the catalog already shows it.',
    'Nothing to fix here.',
  ),
  'ALREADY_RECORDED_ONLINE': CatalogErrorCopy(
    'That Razorpay payment is already on the ledger as an online payment.',
    'Open it under Payments instead of starting a second plan.',
  ),
  'DUPLICATE_REFERENCE': CatalogErrorCopy(
    'That reference is already on another cash entry for this restaurant.',
    'Check the ledger before recording it again.',
  ),
  'QUOTE_PRICE_CHANGED': CatalogErrorCopy(
    "This order's price differs from today's price for the same plan.",
    'Confirm you want the plan applied for what was paid, then try again.',
  ),
  'ALREADY_RECORDED': CatalogErrorCopy(
    'A payment is already recorded on this order.',
    'Refresh — there is nothing to capture.',
  ),
  'NOTHING_TO_CAPTURE': CatalogErrorCopy(
    'Razorpay holds no authorized payment on this order.',
    'Press "Check with Razorpay" to see what it has.',
  ),
  'CAPTURE_AMOUNT_MISMATCH': CatalogErrorCopy(
    'The authorized amount is not the order amount, so it was not captured.',
    'Let Razorpay release it, or record the payment with Start plan.',
  ),

  // ── Request-level ─────────────────────────────────────────────────────────
  'INVALID_REQUEST': CatalogErrorCopy(
    'Some of these details cannot be saved as they are.',
    'Check the highlighted fields, then save again.',
  ),
  'FORBIDDEN': CatalogErrorCopy(
    'That item does not belong to this catalog.',
    'Refresh to see what changed.',
  ),
  'UNAUTHENTICATED': CatalogErrorCopy(
    'You have been signed out.',
    'Sign in again to continue.',
  ),
  'RATE_LIMITED': CatalogErrorCopy(
    'That was a lot of requests at once.',
    'Wait a moment, then try again.',
  ),
  'INTERNAL_ERROR': CatalogErrorCopy(
    'Something went wrong on our side.',
    'Try again in a moment.',
  ),

  // ── Client-side sentinels ─────────────────────────────────────────────────
  //
  // Not the backend's, but they arrive at exactly the same call sites and must
  // read the same way. OFFLINE is deliberately its OWN sentence rather than a
  // shade of "something went wrong": nothing the user typed was wrong, nothing
  // was lost, and the fix is not on this screen.
  'OFFLINE': CatalogErrorCopy(
    "You're offline, so this did not reach us.",
    'Check your connection, then try again.',
  ),
  'MALFORMED_RESPONSE': CatalogErrorCopy(
    'We could not read the answer from the server.',
    'Try again in a moment.',
  ),
  'UNKNOWN': kCatalogUnknownError,
};

/// OUR sentence for [code], or null when this build has no mapping for it.
///
/// Callers rendering something should use [catalogErrorCopy]; this exists for
/// the enumerating test, which must be able to see the difference between a
/// mapped code and the fallback.
CatalogErrorCopy? catalogErrorCopyOrNull(String? code) {
  if (code == null || code.isEmpty) return null;
  final mapped = _copy[code];
  if (mapped != null) return mapped;
  // Per-item publish codes: one lookup, two tables, by origin.
  if (code.startsWith('PUBLISH_')) {
    final sync = syncErrorCopy(code);
    return identical(sync, kUnknownSyncErrorCopy) ? null : sync;
  }
  return null;
}

/// OUR sentence for [code]. Total by construction.
CatalogErrorCopy catalogErrorCopy(String? code) =>
    catalogErrorCopyOrNull(code) ?? kCatalogUnknownError;

/// "Try again in about 2 minutes." — the REAL wait, when a 429 named one.
///
/// The `RATE_LIMITED` entry above says "wait a moment", which is true of a
/// two-second window and a lie about a two-minute one; the publish window is
/// the second kind. Null when the server did not say, and the table's own
/// sentence stands — a made-up number is worse than a vague one.
///
/// Rounded, never counted down: whole minutes above 90 s, whole seconds below.
/// A live countdown is a different feature with a timer to own, and the header
/// is a single value read once.
String? retryAfterAction(int? seconds) {
  if (seconds == null || seconds <= 0) return null;
  if (seconds > 90) {
    final minutes = (seconds / 60).round();
    return 'Try again in about $minutes ${minutes == 1 ? 'minute' : 'minutes'}.';
  }
  return 'Try again in about $seconds ${seconds == 1 ? 'second' : 'seconds'}.';
}

/// The whole thing as one line: what failed, why, and what to do.
///
/// [subject] names the object and the attempt — "Chair 02 could not be
/// archived". Without it the user is left to guess which of the two things they
/// just did is the one that failed.
///
/// [actionOverride] replaces the table's next-action clause where the SERVER
/// told us something more specific than the table could know — today that is
/// only a 429's wait (see [retryAfterAction]). It is an action, never a
/// message: the "what happened" half still comes from the code, so this cannot
/// become a path for upstream prose.
String catalogErrorSentence(
  String? code, {
  String? subject,
  String? actionOverride,
}) {
  final copy = catalogErrorCopy(code);
  final lead = subject == null || subject.isEmpty ? '' : '$subject. ';
  final next = actionOverride ?? copy.action;
  final action = next == null ? '' : ' $next';
  return '$lead${copy.message}$action';
}
