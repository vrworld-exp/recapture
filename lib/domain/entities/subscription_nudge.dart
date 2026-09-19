// lib/domain/entities/subscription_nudge.dart
//
// What `POST /rep/catalogs/:id/subscription/notify-owner` answered — the
// rep's "Notify owner to pay" nudge (Door 2, stage-04). Hand-synced with the
// route in `recapture-api/src/routes/rep.ts` and
// `services/subscription/nudgeService.ts`.
//
// A SEALED RESULT, NOT AN EXCEPTION, for the three answers the card has copy
// for: sent, on cooldown (429), and refused with a reason (409). Everything
// else — offline, 5xx, a revoked delegation — is still a thrown
// [CatalogFailure], because those are errors; a cooldown is a state.

/// Which channels the server says reached the owner.
enum NudgeChannel { sms, inApp, unknown }

extension NudgeChannelX on NudgeChannel {
  static NudgeChannel fromApiValue(String value) =>
      switch (value.toUpperCase()) {
        'SMS' => NudgeChannel.sms,
        'IN_APP' => NudgeChannel.inApp,
        _ => NudgeChannel.unknown,
      };
}

/// Why a 409 refused the nudge — the two codes the card has a sentence for.
enum NudgeRefusal {
  /// The owner has no phone on file (a legacy account). An admin's job.
  ownerUnreachable,

  /// Paid up — ACTIVE with more than a week left, or a comp. Nothing to ask.
  notNeeded,
}

sealed class NudgeResult {
  const NudgeResult();
}

/// 200: the owner was reached on [channels]. [nextAllowedAt] is when the
/// NEXT nudge on this restaurant is allowed, or null when one is allowed
/// right now (the per-catalog window has room left).
final class NudgeSent extends NudgeResult {
  const NudgeSent({required this.channels, required this.nextAllowedAt});

  final List<NudgeChannel> channels;
  final DateTime? nextAllowedAt;

  bool get bySms => channels.contains(NudgeChannel.sms);
  bool get inApp => channels.contains(NudgeChannel.inApp);
}

/// 429: the restaurant's window is spent. [nextAllowedAt] is the server's
/// instant where it sent one, else now + `retryAfter`.
final class NudgeCooldown extends NudgeResult {
  const NudgeCooldown({required this.nextAllowedAt});

  final DateTime nextAllowedAt;
}

/// 409: refused for a reason the rep can act on (or not).
final class NudgeRefused extends NudgeResult {
  const NudgeRefused(this.reason);

  final NudgeRefusal reason;
}
