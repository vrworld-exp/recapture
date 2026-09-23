// lib/domain/catalog/subscription_copy.dart
//
// The ONE source of subscription status copy — the owner's status line and
// the rep's chip — so the two surfaces can never describe one restaurant in
// two vocabularies. The table:
//
//   | status    | owner line                                          | rep chip     |
//   | NONE      | No subscription yet                                 | No plan      |
//   | PENDING_  | Live now — payment due in N days, then this page     | Due Nd       |
//   |  PAYMENT  |   switches off                             (danger)  |              |
//   | TRIAL     | Free trial — N days left, up to 10 3D dishes        | Trial Nd     |
//   | ACTIVE    | Active until <d MMM yyyy> · <Plan>                  | Active       |
//   | GRACE     | Payment overdue — 3D menu pauses in N days  (red)   | Overdue Nd   |
//   |           |   from TRIAL: Your free trial has ended — …          |              |
//   |           |   from COMPED: Your complimentary period has ended — |              |
//   | PAUSED    | 3D menu paused — your photo menu is still live      | 3D paused    |
//   | CANCELLED | Cancelled — resubscribe anytime                     | Cancelled    |
//   | COMPED    | Complimentary until <date>                          | Comped       |
//
// Every N is the SERVER's `daysLeft` (D6) — nothing here looks at a clock.
// Period lengths are "30 days" / "365 days" (E34), never "a month" / "a year":
// the server counts days flat, and the copy must not promise a calendar.
import '../entities/catalog_subscription.dart';
import 'publish_gate.dart';

/// How urgent a status line is — the colour the screen picks, decided here so
/// the owner screen and the rep card agree.
enum SubscriptionTone { neutral, good, warning, danger }

/// The owner's status line for [subscription].
String ownerStatusLine(
  CatalogSubscription subscription, {
  required int trialThreeDCap,
}) =>
    _ownerLine(
      status: subscription.status,
      daysLeft: subscription.daysLeft,
      periodEnd: subscription.periodEnd,
      planName: subscription.planName,
      graceFrom: subscription.graceFrom,
      trialThreeDCap: subscription.threeDDishCap ?? trialThreeDCap,
    );

String _ownerLine({
  required SubscriptionStatus status,
  required int? daysLeft,
  required DateTime? periodEnd,
  required String? planName,
  required SubscriptionStatus? graceFrom,
  required int trialThreeDCap,
}) {
  final days = daysLeft ?? 0;
  return switch (status) {
    SubscriptionStatus.none => 'No subscription yet',
    SubscriptionStatus.trial => 'Free trial — ${_days(days)} left, '
        'up to $trialThreeDCap 3D dishes',
    // NOT "your trial ends in N days". This restaurant has no trial, and what
    // runs out is the LIVE PAGE, not a feature on it — the one sentence here
    // that has to be read as a deadline rather than a reminder.
    SubscriptionStatus.pendingPayment =>
      'Live now — payment due in ${_days(days)}, then this page switches off',
    SubscriptionStatus.active => periodEnd == null
        ? 'Active${planName == null ? '' : ' · $planName'}'
        : 'Active until ${formatSubscriptionDate(periodEnd)}'
            '${planName == null ? '' : ' · $planName'}',
    SubscriptionStatus.grace => graceLine(graceFrom, days),
    SubscriptionStatus.paused =>
      '3D menu paused — your photo menu is still live',
    SubscriptionStatus.cancelled => 'Cancelled — resubscribe anytime',
    SubscriptionStatus.comped => periodEnd == null
        ? 'Complimentary'
        : 'Complimentary until ${formatSubscriptionDate(periodEnd)}',
    SubscriptionStatus.unknown => 'Subscription status unavailable',
  };
}

/// The rep's chip for a list row.
String repStatusChip(SubscriptionSummary? summary) {
  if (summary == null) return 'No plan';
  final days = summary.daysLeft ?? 0;
  return switch (summary.status) {
    SubscriptionStatus.none => 'No plan',
    SubscriptionStatus.trial => 'Trial ${days}d',
    SubscriptionStatus.pendingPayment => 'Due ${days}d',
    SubscriptionStatus.active => 'Active',
    SubscriptionStatus.grace => 'Overdue ${days}d',
    SubscriptionStatus.paused => '3D paused',
    SubscriptionStatus.cancelled => 'Cancelled',
    SubscriptionStatus.comped => 'Comped',
    SubscriptionStatus.unknown => 'Unknown',
  };
}

/// The tone a status renders in, on either surface.
SubscriptionTone subscriptionTone(SubscriptionStatus status) =>
    switch (status) {
      SubscriptionStatus.active ||
      SubscriptionStatus.comped =>
        SubscriptionTone.good,
      SubscriptionStatus.trial => SubscriptionTone.warning,
      // DANGER, like grace, and for a sharper reason: a lapsed plan costs a
      // restaurant its 3D, this costs it the printed QR.
      SubscriptionStatus.pendingPayment => SubscriptionTone.danger,
      SubscriptionStatus.grace => SubscriptionTone.danger,
      SubscriptionStatus.paused ||
      SubscriptionStatus.cancelled ||
      SubscriptionStatus.none ||
      SubscriptionStatus.unknown =>
        SubscriptionTone.neutral,
    };

/// The usage line: "12 / 15 (Signature plan)", "12 / 10 (trial)", or
/// "12 (unlimited)" for a comp. The cap is the SERVER's, the label the row's.
String threeDUsageLine(CatalogSubscription subscription) {
  final cap = subscription.threeDDishCap;
  if (cap == null) return '${subscription.threeDDishCount} (unlimited)';
  final label = switch (subscription.status) {
    SubscriptionStatus.trial => 'trial',
    // Not "plan": there is no plan. The cap is the window's, and calling it a
    // plan is how an owner comes to believe they already have one.
    SubscriptionStatus.pendingPayment => 'before payment',
    _ => subscription.planName ?? 'plan',
  };
  return '${subscription.threeDDishCount} / $cap ($label)';
}

String _days(int n) => n == 1 ? '1 day' : '$n days';

// ── Stage 5: the paused card and the grace banners ──────────────────────────
//
// The A9 sentence the owner sees first on the catalog screen while PAUSED,
// and the one-line banner while in GRACE. Both surfaces — the catalog screen
// and the publish screen — read from here, so a restaurant is described the
// same way on both. N is the SERVER's daysLeft (D6), never a client clock.

/// The PAUSED card's title (A9). One string, every surface.
const String kPausedCardTitle = 'Your 3D menu is paused';

/// The PAUSED card's body (A9): what is still live, and what brings 3D back.
const String kPausedCardBody =
    'Your photo menu is still live at the same QR — pay to restore 3D.';

/// The rep's secondary line under "3D paused": the customer page is not
/// dark, and the rep should say so to a worried owner.
const String kPausedPhotoMenuLine = 'Photo menu is still live at the same QR';

/// The GRACE sentence, in the words that fit how the row got there (E16):
/// a trial that ran out was never "overdue", and neither was a comp.
/// [graceFrom] is the server's `graceFrom`; null (a row written before it
/// existed, or an older server) reads as the paid-period wording, which is
/// the common case and the safe one.
String graceLine(SubscriptionStatus? graceFrom, int? daysLeft) {
  final days = _days(daysLeft ?? 0);
  return switch (graceFrom) {
    SubscriptionStatus.trial =>
      'Your free trial has ended — choose a plan within $days to keep 3D live',
    SubscriptionStatus.comped =>
      'Your complimentary period has ended — choose a plan within $days',
    _ => 'Payment overdue — 3D menu pauses in $days',
  };
}

/// The GRACE banner on the owner's catalog screen and the publish screen —
/// [graceLine] under its Stage 5 name, so both banners and the status line
/// can never say three different things about one restaurant.
String graceBannerLine(int? daysLeft, {SubscriptionStatus? graceFrom}) =>
    graceLine(graceFrom, daysLeft);

/// The GRACE banner's second line on the PUBLISH screen, in the voice of
/// whoever is standing there: the owner can pay; the rep can only tell them.
String graceBannerAction({required bool isRep}) => isRep
    ? 'Publishing still works. Notify the owner to pay to keep 3D live.'
    : 'Publishing still works. Pay now to keep your 3D menu live.';

// ── The pending-payment window (requirement 2) ───────────────────────────────
//
// A rep or staff member published this restaurant before anybody paid for it.
// The menu is LIVE — that is the point — and a deadline is running, after which
// the customer page itself switches off.
//
// WHY THIS COPY IS NOT THE GRACE COPY. Every other lapse in this file costs a
// restaurant its 3D and promises the photo menu stays up (AC-4). This one costs
// them the printed QR. Reusing a sentence about 3D pausing would be a lie about
// the only case where the link really does die, so nothing is shared: no noun,
// no verb, no button label.

/// The payment-due banner's title while the page is still LIVE. `N` is the
/// server's `daysLeft`, never a client clock.
String paymentDueBannerTitle(int? daysLeft) {
  final days = daysLeft ?? 0;
  if (days <= 0) return 'Your live menu switches off today';
  return 'Your live menu switches off in ${_days(days)}';
}

/// The banner's second line, in the voice of whoever is standing there.
String paymentDueBannerBody({required bool isRep, DateTime? paymentDueAt}) {
  final by = paymentDueAt == null
      ? ''
      : ' before ${formatSubscriptionDate(paymentDueAt)}';
  return isRep
      ? 'This restaurant is live but has not been paid for. Take payment$by, or '
          'start the free trial, to keep the QR working.'
      : 'Your menu is live, but it has not been paid for yet. Choose a plan$by '
          'to keep your QR code working — nothing is deleted.';
}

/// The card shown once the window has expired and the page IS dark — the
/// counterpart of [kPausedCardTitle], for the one case where the customer page
/// really did go down.
const String kPageOffCardTitle = 'Your live menu is switched off';

String pageOffCardBody({required bool isRep}) => isRep
    ? 'The QR code stops working until this restaurant is on a plan. Every dish, '
        'photo and category is still here, and the same QR comes back the moment '
        'it is paid for.'
    : 'Your QR code is not working because your menu was never paid for. Nothing '
        'has been deleted — choose a plan and the same QR code comes straight '
        'back on.';

// ── The pre-publish paywall card ────────────────────────────────────────────
//
// What the publish screen says when a subscription gate is what stands between
// a finished menu and a live one. Three sentences and a button label, chosen
// from the GATE and the row behind it — not from a status alone, because
// "you are over your cap" and "you have no plan" are the same status often
// enough that guessing between them would eventually tell a paying restaurant
// it has no plan.
//
// TWO VOICES, as everywhere else on that screen: the owner can pay, the rep
// can only ask the owner to. Neither is told to do something the other's
// surface does.

/// One paywall card's words.
class PublishPaywallCopy {
  const PublishPaywallCopy({
    required this.title,
    required this.body,
    required this.actionLabel,
    this.detail,
  });

  final String title;
  final String body;

  /// The usage line, where numbers are the point ("12 / 10 (Taste plan)").
  /// Null when there is nothing numeric to show.
  final String? detail;

  /// The primary button. Says `Pay now` only where a plan is already picked
  /// and paying is one step; `See plans` where a tier has to be chosen first,
  /// because a button called Pay that opens a comparison table is a lie.
  final String actionLabel;
}

/// The card for [gate], over the row it was evaluated against (null when the
/// gate came from the server and the row was not loaded — the copy then falls
/// back to the wording that assumes least).
PublishPaywallCopy publishPaywallCopy(
  PublishGate gate, {
  CatalogSubscription? subscription,
  required bool isRep,
}) {
  if (gate.code == PublishGateCode.subscriptionCapacityExceeded) {
    return PublishPaywallCopy(
      title: 'More 3D dishes than your plan covers',
      body: isRep
          ? 'The owner needs the next plan up to publish all of them — or '
              'archive the extra 3D dishes and publish the rest now.'
          : 'Upgrade to the next plan to publish all of them — or archive the '
              'extra 3D dishes and publish the rest now. Your photo dishes are '
              'never capped.',
      detail: subscription == null ? null : threeDUsageLine(subscription),
      actionLabel: isRep ? 'Open subscription' : 'See plans',
    );
  }

  // SUBSCRIPTION_REQUIRED, in the words of how the row got there.
  //
  // FIRST, THE ONE CASE THAT BREAKS THE PROMISE THE REST OF THIS MAKES. A row
  // whose page was deactivated is PAUSED like any other, so without this it
  // would be told "your photo menu is still live at the same QR" — the exact
  // opposite of the truth, to the one owner who can check it in a second by
  // opening their own link. Deliberately ahead of the status switch.
  if (subscription?.isPageDeactivated == true) {
    return PublishPaywallCopy(
      title: kPageOffCardTitle,
      body: pageOffCardBody(isRep: isRep),
      detail: subscription == null ? null : threeDUsageLine(subscription),
      actionLabel: isRep ? 'Open subscription' : 'See plans',
    );
  }

  return switch (subscription?.status) {
    SubscriptionStatus.paused => PublishPaywallCopy(
        title: kPausedCardTitle,
        body: isRep
            ? '$kPausedPhotoMenuLine. The owner pays in the app to bring 3D '
                'back — or archive the 3D dishes to publish a photo-only menu.'
            : '$kPausedCardBody Or archive your 3D dishes and publish a '
                'photo-only menu.',
        detail: subscription == null ? null : threeDUsageLine(subscription),
        actionLabel: isRep ? 'Notify owner' : 'Pay now',
      ),
    SubscriptionStatus.cancelled => PublishPaywallCopy(
        title: 'This subscription is cancelled',
        body: isRep
            ? 'The owner resubscribes in the app to publish the 3D dishes — or '
                'archive them to publish a photo-only menu.'
            : 'Resubscribe to publish your 3D dishes — or archive them and '
                'publish a photo-only menu. Nothing has been deleted.',
        detail: subscription == null ? null : threeDUsageLine(subscription),
        actionLabel: isRep ? 'Open subscription' : 'See plans',
      ),
    // NONE, and the fallback for a row that was never loaded.
    _ => PublishPaywallCopy(
        title: 'Choose a plan to publish',
        body: isRep
            ? 'This restaurant is not on a plan yet. Start the free trial, or '
                'hand the phone to the owner to pay in the app.'
            : 'Your menu is not on a plan yet. Pick one and publish — your '
                'dishes, photos, categories and QR code stay exactly as they '
                'are.',
        actionLabel: isRep ? 'Open subscription' : 'See plans',
      ),
  };
}

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `18 Oct 2026` — local time, resolved in Dart like every other date in the
/// app (no l10n framework here).
String formatSubscriptionDate(DateTime utc) {
  final local = utc.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

/// Paise → whole rupees for DISPLAY, Indian grouping: 1007160 → "₹10,072",
/// 123456700 → "₹12,34,567". Rounds to the nearest rupee; the paise figure
/// stays the truth on the wire.
String formatRupees(int paise) {
  final digits = (paise / 100).round().toString();
  if (digits.length <= 3) return '₹$digits';
  final tail = digits.substring(digits.length - 3);
  var head = digits.substring(0, digits.length - 3);
  final groups = <String>[];
  while (head.length > 2) {
    groups.insert(0, head.substring(head.length - 2));
    head = head.substring(0, head.length - 2);
  }
  if (head.isNotEmpty) groups.insert(0, head);
  return '₹${groups.join(',')},$tail';
}

// ── Stage 3: the checkout button ────────────────────────────────────────────

/// The consent line shown above Pay and again in the pre-checkout sheet
/// (AC-5.2). One string, two places, so they can never drift.
const String kPaymentConsentLine =
    'All payments are final, except an accidental duplicate payment, '
    'which will be refunded on review.';

int _planRank(PlanId id) => switch (id) {
      PlanId.taste => 0,
      PlanId.signature => 1,
      PlanId.masterchef => 2,
      PlanId.unknown => -1,
    };

/// ONE button, three labels (§9): `Renew` while a paid plan is running or
/// overdue, `Upgrade` when the selected plan is a higher tier than the one
/// running, `Pay` everywhere else (no plan, trial, paused, cancelled, comped).
String checkoutButtonLabel(CatalogSubscription subscription, PlanId selected) {
  final status = subscription.status;
  final paidPlanRunning =
      status == SubscriptionStatus.active || status == SubscriptionStatus.grace;
  if (!paidPlanRunning) return 'Pay';
  final current = subscription.planId;
  if (current != null && _planRank(selected) > _planRank(current)) {
    return 'Upgrade';
  }
  return 'Renew';
}

/// "30 days" / "365 days" — the length of a paid period, as the server
/// counts it (E34). Used wherever a period is named; the price rate
/// ("₹1,199 / month") is a different thing and keeps its own words.
String periodLengthLabel(BillingInterval interval) =>
    interval == BillingInterval.yearly ? '365 days' : '30 days';

/// "30-day" / "365-day", for "a new 30-day period".
String _periodAdjective(BillingInterval interval) =>
    interval == BillingInterval.yearly ? '365-day' : '30-day';

/// The E9 early-renewal line, or null when nothing is forfeited. A fresh
/// period always starts at the payment (AC-3.5), so the days left on a
/// running period are lost — this says so, in amber, above Pay. It is a
/// warning, not a rule change. [daysForfeited] is the SERVER's figure: the
/// order's `daysForfeited` once one exists, the status DTO's `daysLeft`
/// before that (the same number, from the same row).
String? earlyRenewalLine({
  required int daysForfeited,
  required BillingInterval interval,
}) {
  if (daysForfeited <= 0) return null;
  return 'Your current period ends in ${_days(daysForfeited)}. '
      'Paying now starts a new ${_periodAdjective(interval)} period today.';
}

/// Days a payment now would forfeit, read off the status DTO the way the
/// server computes `daysForfeited` for an order: the days left on a running
/// ACTIVE / TRIAL / COMPED period; GRACE and PAUSED have none to lose.
int daysForfeitedFor(CatalogSubscription subscription) {
  final days = subscription.daysLeft;
  if (days == null || days <= 0) return 0;
  return switch (subscription.status) {
    SubscriptionStatus.active ||
    SubscriptionStatus.trial ||
    SubscriptionStatus.comped =>
      days,
    _ => 0,
  };
}

/// [earlyRenewalLine] for a checkout that has not minted its order yet — the
/// pre-checkout sheet, which opens BEFORE `POST …/order`.
String? paymentForfeitWarning(
  CatalogSubscription subscription, {
  required BillingInterval interval,
}) =>
    earlyRenewalLine(
      daysForfeited: daysForfeitedFor(subscription),
      interval: interval,
    );

/// "QR standees: 6 of 15 delivered" — the same sentence on the owner screen,
/// the rep card and the admin panel. Null when the plan includes none (a
/// trial, a comp, no row): a line that says "0 of 0" is noise.
///
/// The numbers are the ADMIN's counter (README C8) — what was physically
/// handed over — not a count of activated codes, and nothing here derives one
/// from the other.
String? standeeDeliveryLine(CatalogSubscription subscription) {
  final included = subscription.standeeIncluded ?? 0;
  if (included <= 0) return null;
  final issued = subscription.standeeIssued ?? 0;
  return 'QR standees: $issued of $included delivered';
}

/// The B6 sentence — "your price was locked; renewals are the new price" —
/// only when the frozen snapshot's price differs from the plan's current
/// price. Null otherwise, so the card says nothing on the common day.
/// Numbers from the server, rounded to rupees here for display only.
String? lockedPriceNotice(CatalogSubscription subscription) {
  final change = subscription.priceChange;
  final periodEnd = subscription.periodEnd;
  if (change == null || periodEnd == null) return null;
  return 'Your current price ${formatRupees(change.lockedPaise)}/month was '
      'locked until ${formatSubscriptionDate(periodEnd)}. '
      'Renewals are ${formatRupees(change.currentPaise)}/month.';
}

/// What deleting the catalog does to its subscription — the C9 bullet in the
/// delete dialog. Null when there is nothing running (no row, PAUSED,
/// CANCELLED, COMPED): the money sentence would be a scare with nothing
/// behind it. `planName` is the plan's display name when one is known.
String? deleteSubscriptionConsequence(
  SubscriptionStatus? status, {
  String? planName,
}) =>
    switch (status) {
      SubscriptionStatus.active || SubscriptionStatus.grace =>
        'Your ${planName ?? 'paid'} subscription ends now. Payments are '
            'non-refundable — the unused days are not credited.',
      SubscriptionStatus.trial =>
        'Your free trial ends and cannot be restarted.',
      _ => null,
    };
