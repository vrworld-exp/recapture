// lib/domain/catalog/subscription_publish_gate.dart
//
// The pre-publish subscription check, on the CLIENT — the third producer of a
// [PublishGate], and the one that exists because of a timing problem.
//
// THE PROBLEM. The two subscription gates are evaluated server-side by
// `services/subscription/subscriptionGate.ts`, but only when ops has flipped
// `subscriptionGatesEnabled` on the `client_configs` document (Stage 5 /
// docs/subscription/rollout.md). Until that flip the publish endpoint returns
// NO subscription gate at all, so an owner with no plan presses Publish and
// their menu simply goes live — the Subscription screen is reachable from the
// header chip and from Profile, and from nowhere in the flow that is actually
// about to cost money. That is the hole this file fills: the app asks the
// question at the moment Publish is pressed, whatever the server flag says.
//
// SO THE RULES ARE MIRRORED, NOT INVENTED. [evaluateSubscriptionGates] is a
// line-by-line copy of `evaluateSubscriptionGate`, in the same order, over the
// same two numbers — and it CAN be, because both numbers are the server's own:
// `status` and `threeDDishCap` come off the row, and `threeDDishCount` is
// counted server-side over `publishableProducts()`, the identical list the
// gate counts (README C1). Nothing here recounts a draft. Hand-synced, like
// every other cross-language type in this app (AGENTS.md §0.1): a rule changed
// on the server has to be changed here too.
//
// AND THE SERVER STILL WINS. [checkSubscriptionForPublish] prefers the gates
// the publish status actually returned; the client's set is used only when the
// server produced none. Once the flag is flipped, this file is a pre-flight
// that agrees with the verdict rather than a second opinion about it.
//
// FAIL OPEN, THREE TIMES OVER. A paywall invented by a bug is worse than a
// publish that should have been stopped, because the second one is recoverable
// and the first one locks a paying restaurant out of its own menu. So:
//   • a subscription that has not loaded yet is UNSETTLED — no gate, and the
//     caller must not treat that as permission either (see [isSettled]);
//   • a subscription that failed to load is READY — a flaky connection is not
//     evidence of an unpaid bill;
//   • a body with no `status` at all (an older API) is READY — see
//     [CatalogSubscription.isReported].
import '../entities/catalog_subscription.dart';
import 'publish_gate.dart';

/// The verdict of the pre-publish subscription check.
class SubscriptionPublishCheck {
  const SubscriptionPublishCheck({
    required this.gates,
    required this.isSettled,
    this.subscription,
  });

  /// Nothing known yet — the subscription read is still in flight.
  static const SubscriptionPublishCheck pending =
      SubscriptionPublishCheck(gates: [], isSettled: false);

  /// Nothing in the way.
  static const SubscriptionPublishCheck ready =
      SubscriptionPublishCheck(gates: [], isSettled: true);

  /// The subscription gates in force — the server's when it produced any,
  /// otherwise this file's. Empty means nothing is blocking.
  final List<PublishGate> gates;

  /// Whether this verdict is worth acting on.
  ///
  /// False means "ask again in a moment", and it is NOT the same as [blocks]
  /// being false: a screen that auto-starts a publish must wait for a settled
  /// verdict, or the paywall loses every race against the status read and the
  /// press it was meant to stop goes through anyway.
  final bool isSettled;

  /// The row the verdict was reached over, for the card's usage line and
  /// plan name. Null when the verdict came from the server's gates alone.
  final CatalogSubscription? subscription;

  bool get blocks => gates.isNotEmpty;

  /// The gate the card renders. The server emits at most one and so does
  /// [evaluateSubscriptionGates]; the first is the only one either way.
  PublishGate? get gate => gates.isEmpty ? null : gates.first;
}

/// The verdict, from whatever the two reads have come back with.
///
/// [serverGates] is the publish status' whole gate list — subscription rows
/// and everything else; only the subscription ones are read. [subscription] is
/// the loaded row, or null while loading or after a failed read, which
/// [isLoading] tells apart.
SubscriptionPublishCheck checkSubscriptionForPublish({
  required List<PublishGate> serverGates,
  required CatalogSubscription? subscription,
  required bool isLoading,
}) {
  // The server's own verdict, when it has one. Authoritative: it ran the same
  // rules over rows it read in one transaction, and it is what the publish
  // endpoint will refuse on.
  final fromServer = [
    for (final gate in serverGates)
      if (gate.code.isSubscription) gate,
  ];
  if (fromServer.isNotEmpty) {
    return SubscriptionPublishCheck(
      gates: fromServer,
      isSettled: true,
      // An unreported row carries no status, no cap and no count, so handing it
      // to the card would dress "an older API answered nothing" up as "this
      // restaurant is on no plan, with 0 of 0 dishes".
      subscription: subscription?.isReported == true ? subscription : null,
    );
  }

  if (subscription == null) {
    return isLoading
        ? SubscriptionPublishCheck.pending
        : SubscriptionPublishCheck.ready;
  }

  return SubscriptionPublishCheck(
    gates: evaluateSubscriptionGates(subscription),
    isSettled: true,
    subscription: subscription.isReported ? subscription : null,
  );
}

/// The client's mirror of the server's `evaluateSubscriptionGate`.
///
/// Rules, in the server's order:
///
///   1. A reported row of NONE → `SUBSCRIPTION_REQUIRED`, whatever the menu
///      holds. A catalog that has never been on any plan does not publish.
///   2. PAUSED / CANCELLED → `SUBSCRIPTION_REQUIRED` only when the menu
///      carries at least one 3D dish. A photo-only menu still publishes
///      (README C5): the plan lapsing takes the AR away, not the menu.
///   3. TRIAL / PENDING_PAYMENT / ACTIVE / GRACE / COMPED →
///      `SUBSCRIPTION_CAPACITY_EXCEEDED` when the count is over a cap that
///      exists. A comp is uncapped and never trips this; GRACE keeps full
///      access but not extra capacity.
///   4. Otherwise nothing. GRACE produces no gate of its own — "your plan has
///      lapsed, pay soon" is the banner above this card, not a blocker. Nor
///      does PENDING_PAYMENT: a rep's publish is meant to go live before
///      anybody pays, and "pay or this link goes" is the banner, not a refusal.
///
/// [SubscriptionStatus.unknown] — a status this build has not heard of —
/// deliberately falls through to rule 3 and then to nothing. A client one
/// deploy behind must not invent a paywall out of a word it does not know.
/// PENDING_PAYMENT falls through the same way, and that is not an accident of
/// the ordering: it is the rule. An older build that has never heard the word
/// reaches exactly the verdict this one does.
List<PublishGate> evaluateSubscriptionGates(CatalogSubscription subscription) {
  // An older API that sends no subscription DTO at all cannot be read as "no
  // subscription" — see [CatalogSubscription.isReported].
  if (!subscription.isReported) return const [];

  if (subscription.status == SubscriptionStatus.none) {
    return const [
      PublishGate(
        code: PublishGateCode.subscriptionRequired,
        message: 'No subscription yet — choose a plan to publish.',
      ),
    ];
  }

  if (subscription.status == SubscriptionStatus.paused ||
      subscription.status == SubscriptionStatus.cancelled) {
    if (subscription.threeDDishCount >= 1) {
      return const [
        PublishGate(
          code: PublishGateCode.subscriptionRequired,
          message: 'Your 3D menu needs an active plan. Photo-only menus can '
              'still be published.',
        ),
      ];
    }
    return const [];
  }

  final cap = subscription.threeDDishCap;
  if (cap != null && subscription.threeDDishCount > cap) {
    // The plan AS BOUGHT, exactly as the server labels it — the cap in force
    // belongs to the frozen snapshot, not to whatever the tier costs today.
    final planLabel = subscription.planSnapshot?.displayName ?? 'free trial';
    return [
      PublishGate(
        code: PublishGateCode.subscriptionCapacityExceeded,
        message: 'Menu has ${subscription.threeDDishCount} 3D dishes; your '
            '$planLabel covers $cap. Upgrade to publish all of them.',
      ),
    ];
  }

  return const [];
}

/// [gates] without the subscription rows — what the checklist draws once the
/// card has taken them.
List<PublishGate> gatesExcludingSubscription(List<PublishGate> gates) => [
      for (final gate in gates)
        if (!gate.code.isSubscription) gate,
    ];
