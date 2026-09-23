// lib/presentation/widgets/catalog/publish_body.dart
//
// The publish screen's body — the cards, the checklist, the progress line, the
// actions — for WHOEVER is publishing (features 36-39, 52, 53, 68, 69).
//
// ONE BODY, TWO SCREENS. The owner's `/catalog/publish` and the rep's
// `/rep/catalogs/:id/publish` render this widget over the same
// [PublishScreenState]; what differs between them is where the fix links go,
// whether "take offline" exists, and a handful of sentences in which "your
// catalog" is the wrong thing to call a restaurant a rep is standing in. Those
// are parameters. Everything else is deliberately NOT a parameter, because a
// rep and an owner looking at the same run must see the same thing.
//
// IT IS BUILT AROUND PARTIAL FAILURE. Publishing ten products is ten sequential
// unbatched uploads against a server that may be waking from a sleeping tier,
// so "seven of ten went live" is the ORDINARY outcome, not the exceptional one.
// A screen that only knows "publishing…" and "done" leaves the user with three
// products missing from their menu and no way to find out which, so the failure
// list, the per-product reasons and the one-tap retry are the main event here,
// not an error path bolted on the side.
//
// FOUR RULES THIS FILE DOES NOT BEND:
//   1. The client holds NO publish state. Every number comes from the status
//      endpoint (see publish_flow.dart).
//   2. No raw upstream text. Failure sentences are looked up from the code by
//      `sync_error_copy.dart`; the payload's own message is never parsed.
//   3. `publicUrl` is displayed verbatim and never composed, normalised or
//      rebuilt — every printed QR resolves through it.
//   4. Never let the user press Publish into a guaranteed failure. The gate
//      checklist is the server's own, and each row goes to the fix.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../application/catalog/publish_flow.dart';
import '../../../data/repositories/catalog_failure.dart' show CatalogErrorCodes;
import '../../../domain/catalog/publish_gate.dart';
import '../../../domain/catalog/publish_status.dart';
import '../../../domain/catalog/subscription_copy.dart';
import '../../../domain/catalog/subscription_publish_gate.dart';
import '../../../domain/entities/catalog_status.dart';
import '../../../domain/entities/catalog_subscription.dart';
import '../app_button.dart';
import '../app_status_pill.dart';
import 'publish_link_actions.dart';

/// Above this width the screen keeps its content in one readable column rather
/// than stretching a checklist across a desktop monitor. Decided from
/// CONSTRAINTS, never from `kIsWeb`.
const double kPublishContentMaxWidth = 640;

/// The sentences that differ between an owner publishing THEIR catalog and a
/// rep publishing a restaurant's MENU on its behalf.
///
/// Kept to a handful on purpose. Progress numbers, failure reasons, the gate
/// checklist and the live card read identically on both screens — a rep and
/// an owner describing the same run to each other in different words is the
/// failure this widget exists to prevent.
class PublishVoice {
  const PublishVoice({
    required this.neverPublished,
    required this.gettingReady,
    required this.publishFirstCta,
    required this.nameTakenTitle,
    required this.nameTakenBody,
    required this.nothingPublished,
    required this.listTitle,
    required this.itemNoun,
    required this.itemNounPlural,
  });

  /// The owner's own words.
  static const owner = PublishVoice(
    neverPublished: 'This catalog has never been published.',
    gettingReady: 'Getting your catalog ready…',
    publishFirstCta: 'Publish catalog',
    nameTakenTitle: 'That catalog name is already taken',
    nameTakenBody: 'Catalog names have to be unique. We can rename yours to ',
    nothingPublished: 'Nothing was published',
    listTitle: 'Products',
    itemNoun: 'product',
    itemNounPlural: 'products',
  );

  /// A rep, about a restaurant that is not theirs.
  static const rep = PublishVoice(
    neverPublished: 'This menu has never been published.',
    gettingReady: 'Getting the menu ready…',
    publishFirstCta: 'Publish menu',
    nameTakenTitle: 'That restaurant name is already taken online',
    nameTakenBody: 'Names have to be unique online. We can rename it to ',
    nothingPublished: 'The menu did not go live',
    listTitle: 'Dishes',
    itemNoun: 'dish',
    itemNounPlural: 'dishes',
  );

  final String neverPublished;
  final String gettingReady;
  final String publishFirstCta;
  final String nameTakenTitle;

  /// Followed by the quoted suggestion and " and publish.".
  final String nameTakenBody;

  /// The headline on a run that failed with NO product row to blame — the
  /// restaurant step never got off the ground, so there is no item list to
  /// point at and the sentence has to carry the whole story itself.
  final String nothingPublished;

  final String listTitle;
  final String itemNoun;
  final String itemNounPlural;

  String items(int count) => count == 1 ? itemNoun : itemNounPlural;

  /// Whether this is the rep's voice — the one sentence that differs in the
  /// grace banner ("pay" vs "notify the owner") is decided from this, not
  /// from a second flag that could disagree with the voice.
  bool get isRep => identical(this, rep);
}

/// The query flag a Publish BUTTON adds to the publish route: `?start=1`.
///
/// ONE PRESS, NOT TWO. The publish screen used to be a door and a button: the
/// header's "Publish" opened it, and a second "Publish" on it started the run.
/// Every user who pressed the first one had already decided, and read the
/// second as the first not having worked. So a button that SAYS Publish now
/// opens the screen with this flag, and the screen starts the run itself the
/// moment it knows it can — see [publishAutoStartReady]. Doors that only WATCH
/// ("Publishing… see progress", the analytics screen's nudge) do not set it.
const String kPublishStartQuery = 'start';

/// Whether a screen opened with [kPublishStartQuery] should fire its publish
/// now — the same conditions that enable the button, so the auto-start can
/// never send a request the button would have refused.
///
/// A null status (still loading) is "not yet", not "no": the caller asks again
/// on the next build. Gates, a run already in flight, or being offline answer
/// "no", and the screen then shows exactly what a press would have shown — the
/// checklist, the progress line, or the offline notice.
/// A settled, blocking [check] answers "no" on its own: the subscription is a
/// blocker the SERVER may not have evaluated (its gates are behind an ops
/// flag), so `state.canPublish` cannot be trusted to have seen it. An UNSETTLED
/// check also answers "no" — but the caller must ask again rather than give up,
/// or the paywall loses the race against the first status read and the press it
/// existed to stop goes through. See [PublishScreen] for that half.
bool publishAutoStartReady({
  required PublishScreenState state,
  required bool isOnline,
  SubscriptionPublishCheck subscription = SubscriptionPublishCheck.ready,
}) =>
    isOnline &&
    state.status.hasValue &&
    state.canPublish &&
    subscription.isSettled &&
    !subscription.blocks;

/// Whether a screen opened with [kPublishStartQuery] should stop waiting and
/// spend its intent — the shared half of both screens' auto-start latch.
///
/// The intent stays ARMED — not spent — while the only thing between the user
/// and a run will clear ITSELF on this screen:
///
///   • an unsettled or blocking subscription (they may be paying right now;
///     this is the pay-then-publish continuation), and
///   • a gate set that is entirely "wait for it" — a preview image rendering,
///     a model generating ([PublishStatus.isWaitingOnGates]).
///
/// Every OTHER gate is fixed on another screen, and coming back from that
/// screen to find a publish already running would be a surprise, so those spend
/// the intent.
///
/// Spending it on a self-clearing gate is how a user who tapped Publish while
/// a thumbnail was still rendering sat and watched the checklist empty itself
/// and the button quietly enable, with nothing ever starting.
///
/// AN ARMED INTENT CANNOT WAIT FOREVER, and needs nothing extra to bound it:
/// the gate wait stops at its own cap (~15 minutes, past the backend's
/// generation timeout), and once the loop stops the gates cannot clear, so the
/// intent expires with the loop.
///
/// It lives here, beside [publishAutoStartReady], so the owner's screen and the
/// rep's share one RULE while keeping their two bodies (different providers,
/// different voice). The two screens each had their own copy of this guard, and
/// each had the same bug.
bool publishAutoStartSettled({
  required PublishScreenState state,
  required SubscriptionPublishCheck subscription,
}) {
  if (!state.status.hasValue) return false; // still loading — ask next build
  if (!subscription.isSettled || subscription.blocks) return false;
  if (state.value?.isWaitingOnGates ?? false) return false;
  return true;
}

class PublishBody extends StatelessWidget {
  const PublishBody({
    super.key,
    required this.state,
    required this.status,
    required this.isOnline,
    required this.voice,
    required this.onPublish,
    required this.onRetryFailed,
    required this.onFixGate,
    required this.onOpenPreview,
    required this.onRename,
    required this.onOpenQr,
    this.onUnpublish,
    this.canFix,
    this.subscription,
    this.onOpenSubscription,
    this.subscriptionCheck = SubscriptionPublishCheck.ready,
  });

  final PublishScreenState state;
  final PublishStatus status;
  final bool isOnline;
  final PublishVoice voice;

  /// The catalog's subscription summary, for the GRACE banner above the
  /// checklist (Stage 5). Null — no row, or a screen that has not loaded the
  /// catalog yet — draws nothing. PAUSED needs no banner here: the gate row
  /// already says it, and saying it twice is nagging.
  final SubscriptionSummary? subscription;

  /// Where the GRACE banner's and the paywall card's button goes: the owner's
  /// plans screen, or the rep's card. Null hides the button and leaves the
  /// sentence.
  final VoidCallback? onOpenSubscription;

  /// The pre-publish subscription verdict — the paywall card, and the reason
  /// Publish is off when it is showing.
  ///
  /// Defaults to READY so every existing caller (and every test that only
  /// cares about a run) keeps the behaviour it had. The two publish screens
  /// pass a real one.
  final SubscriptionPublishCheck subscriptionCheck;
  final VoidCallback onPublish;
  final VoidCallback onRetryFailed;
  final ValueChanged<PublishGate> onFixGate;
  final VoidCallback onOpenPreview;
  final ValueChanged<String> onRename;
  final VoidCallback onOpenQr;

  /// Null hides "take offline" altogether — the rep's door has no such route,
  /// and a control that would answer 404 is worse than none.
  final VoidCallback? onUnpublish;

  /// Whether this door has a screen that fixes [gate]. Null means every gate
  /// with a fix label gets its button; the rep passes one because a rep has
  /// no section manager to send "Rename category" to, and a button that
  /// opens nothing is worse than the sentence on its own.
  final bool Function(PublishGate gate)? canFix;

  @override
  Widget build(BuildContext context) {
    final run = status.run;
    final inFlight = status.isPublishing || (run?.state.isInFlight ?? false);
    // The paywall card takes the subscription rows; the checklist draws what
    // is left. A blocker that costs money is not a line item between "rename a
    // category" and "pick a category", and showing it in both places would
    // read as two separate problems.
    final paywallGate = status.isPublishing ? null : subscriptionCheck.gate;
    final checklistGates = paywallGate == null
        ? status.gates
        : gatesExcludingSubscription(status.gates);

    // THE RUN ITSELF FAILED, AND NO ROW CAN EXPLAIN IT. A RESTAURANT step that
    // fails aborts the walk and marks no product (there is no row for the
    // restaurant, and faking one would make "Retry failed" re-run products that
    // were never attempted), so `failures` is empty and both the failure card
    // and the success card used to be skipped — the screen simply went back to
    // its resting state and said nothing at all.
    //
    // Gated on the run's STATE being FAILED, not on `hasError` alone: a
    // SUCCEEDED or PARTIAL run carrying a stale error from an older document
    // must draw nothing. `failed` is terminal by construction, and a state this
    // build does not recognise reads as in-flight — so a newer server renders
    // no failure card rather than a wrong one.
    final runFailure = !inFlight &&
            status.failures.isEmpty &&
            (run?.hasError ?? false) &&
            run?.state == PublishRunState.failed
        ? run
        : null;

    // ONE CARD, TWO SOURCES. A name collision reaches this screen either
    // synchronously (the 409 from a press, on `state.suggestedName`) or as the
    // run-level error of a run that discovered it mid-flight — and the way out
    // is the same rename either way, so it is the same card.
    final suggestedName = state.suggestedName ??
        (runFailure?.errorCode == CatalogErrorCodes.catalogNameTaken
            ? runFailure?.suggestedName
            : null);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        0,
        AppSpacing.screenPadding,
        AppSpacing.xxxl,
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: kPublishContentMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusCard(status: status, voice: voice),
                if (!isOnline) ...[
                  const SizedBox(height: AppSpacing.md),
                  const _Banner(
                    key: ValueKey('publish_offline_banner'),
                    icon: Icons.wifi_off_outlined,
                    color: AppColors.textMuted,
                    // Disabled with a reason beats a button that fires a
                    // request guaranteed to fail and reports it as an error the
                    // user might think they caused.
                    title: "You're offline",
                    body: 'Publishing needs a connection. Reconnect and this '
                        'page will pick up where it left off.',
                  ),
                ],
                // FIRST of the things that can stop a publish, because it is
                // the only one the user cannot fix by editing their menu.
                if (paywallGate case final gate?) ...[
                  const SizedBox(height: AppSpacing.md),
                  _SubscriptionPaywallCard(
                    gate: gate,
                    subscription: subscriptionCheck.subscription,
                    voice: voice,
                    isOnline: isOnline,
                    onOpenSubscription: onOpenSubscription,
                  ),
                ],
                // Requirement 2, ABOVE the grace banner: publishing works in
                // both states, but only one of them is a countdown on the QR
                // code. `hasPaymentDue` is false once the page is actually dark
                // — that case reaches the paywall card above instead, because a
                // dark page with 3D dishes is a blocked publish, not a warning.
                if (subscription?.hasPaymentDue == true) ...[
                  const SizedBox(height: AppSpacing.md),
                  _PaymentDueBanner(
                    daysLeft: subscription?.daysLeft,
                    paymentDueAt: subscription?.paymentDueAt,
                    voice: voice,
                    onOpenSubscription: onOpenSubscription,
                  ),
                ] else if (subscription?.status == SubscriptionStatus.grace) ...[
                  const SizedBox(height: AppSpacing.md),
                  _GraceBanner(
                    daysLeft: subscription?.daysLeft,
                    graceFrom: subscription?.graceFrom,
                    voice: voice,
                    onOpenSubscription: onOpenSubscription,
                  ),
                ],
                if (suggestedName case final suggested?) ...[
                  const SizedBox(height: AppSpacing.md),
                  _NameTakenCard(
                    suggested: suggested,
                    busy: state.isRequesting,
                    voice: voice,
                    onRename: onRename,
                  ),
                ],
                if (inFlight) ...[
                  const SizedBox(height: AppSpacing.md),
                  _RunProgress(
                    status: status,
                    paused: state.isPollingPaused,
                    voice: voice,
                  ),
                ],
                // A failed READ, said quietly and in place. NEVER a toast: a
                // dropped poll is not a failed publish, and this screen
                // announcing one as the other is exactly what sent users to
                // look for a failure list that was not there.
                if (state.pollFailure != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _PollFailureNote(
                    stopped: state.pollStopped,
                    inFlight: inFlight,
                  ),
                ],
                if (!inFlight && status.failures.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  _FailureCard(
                    status: status,
                    busy: state.isRequesting,
                    voice: voice,
                    onRetryFailed: isOnline ? onRetryFailed : null,
                  ),
                ],
                // The run-level failure, in the failure card's place and
                // mutually exclusive with it — `runFailure` is non-null only
                // when there is no failed row. A rename card above has already
                // taken the one run error that has a better answer than
                // "try again", so this never doubles up with it.
                if (runFailure case final failed? when suggestedName == null)
                  ...[
                  const SizedBox(height: AppSpacing.md),
                  _RunFailureCard(
                    run: failed,
                    voice: voice,
                    busy: state.isRequesting,
                    onPublish: !isOnline ||
                            !state.canPublish ||
                            paywallGate != null
                        ? null
                        : onPublish,
                  ),
                ],
                if (!inFlight &&
                    status.isLive &&
                    status.failures.isEmpty &&
                    runFailure == null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _SuccessCard(status: status, onOpenQr: onOpenQr),
                ],
                if (checklistGates.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  _GateChecklist(
                    gates: checklistGates,
                    isWaiting: status.isWaitingOnGates,
                    canFix: canFix ?? (_) => true,
                    onFix: onFixGate,
                    onOpenPreview: onOpenPreview,
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                _Actions(
                  state: state,
                  status: status,
                  isOnline: isOnline,
                  inFlight: inFlight,
                  voice: voice,
                  // The server may not have evaluated the subscription at all
                  // (its gates sit behind an ops flag), so `state.canPublish`
                  // is not enough to keep this press off a paywalled catalog.
                  blockedBySubscription: paywallGate != null,
                  onPublish: onPublish,
                  onUnpublish: onUnpublish,
                ),
                if (status.products.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xxl),
                  _ProductList(products: status.products, voice: voice),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Where the catalog stands: live or not, when it last went out, and whether
/// the draft has moved since.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.voice});

  final PublishStatus status;
  final PublishVoice voice;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _Chip(
                label: status.status.label,
                color: status.isLive ? AppColors.success : AppColors.textMuted,
              ),
              // Feature 38. Server-DERIVED — never recomputed here, and true
              // after a partial run because some products genuinely are not
              // live.
              if (status.hasDraftChanges)
                const _Chip(
                  label: 'Draft changes not yet live',
                  color: AppColors.warning,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            status.lastPublishedAt == null
                ? voice.neverPublished
                : 'Last published ${_ago(status.lastPublishedAt!)}.',
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// A run in flight: the counts, the bar, and an honest word about staleness.
class _RunProgress extends StatelessWidget {
  const _RunProgress({
    required this.status,
    required this.paused,
    required this.voice,
  });

  final PublishStatus status;
  final bool paused;
  final PublishVoice voice;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final run = status.run;
    final counts = run?.counts ?? const PublishRunCounts();
    final unpublishing = run?.mode.isUnpublish ?? false;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.royalGold.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // Taking a catalog offline reads nothing like putting it online.
            unpublishing ? 'Taking your catalog offline…' : 'Publishing…',
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            counts.total > 0
                ? '${counts.synced} of ${counts.total} published'
                : voice.gettingReady,
            key: const ValueKey('publish_progress_counts'),
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: LinearProgressIndicator(
              // Null renders indeterminate: a determinate bar pinned at zero
              // while the planner works reads as "stuck", not as "starting".
              value: counts.progress,
              minHeight: 6,
              backgroundColor: AppColors.surface2,
              color: AppColors.mirageRed,
            ),
          ),
          if (counts.failed > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              '${counts.failed} failed so far — you can retry them when this '
              'run finishes.',
              style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
            ),
          ],
          if (status.hasChangesSincePublishStarted) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              // NOT reassurance. A run plans from a snapshot taken when
              // Publish was pressed; an edit made since is genuinely not in
              // it, and someone reading "Publishing…" would leave believing
              // it was. The button re-enables the moment this run ends.
              'Your latest changes are not in this publish. Press Publish '
              'again once it finishes and they go up right after.',
              key: const ValueKey('publish_stale_run_note'),
              style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
            ),
          ],
          if (paused) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              // Says the numbers are old rather than quietly showing old ones.
              'Paused while this tab is in the background. It will catch up '
              'the moment you come back.',
              key: const ValueKey('publish_paused_note'),
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// A finished run that left work undone (features 53, 68).
class _FailureCard extends StatelessWidget {
  const _FailureCard({
    required this.status,
    required this.busy,
    required this.voice,
    required this.onRetryFailed,
  });

  final PublishStatus status;
  final bool busy;
  final PublishVoice voice;

  /// Null disables the retry — offline, with the reason already on screen.
  final VoidCallback? onRetryFailed;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final failures = status.failures;
    final published = status.published.length;
    final total = status.products.length;
    final everything = published == 0;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // The honest headline in both shapes. With nothing published the
            // catalog is NOT live, and saying "0 of 10 published" while a
            // success card sat above it would be the worst of both.
            everything
                ? 'Nothing was published — none of the $total '
                    '${voice.items(total)} went live'
                : '$published of $total published · '
                    '${failures.length} failed',
            key: const ValueKey('publish_failure_headline'),
            style: textTheme.titleMedium?.copyWith(color: AppColors.error),
          ),
          const SizedBox(height: AppSpacing.md),
          for (final failure in failures)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: _FailureRow(product: failure),
            ),
          AppButton(
            key: const ValueKey('publish_retry_failed'),
            label: 'Retry failed',
            icon: Icons.refresh,
            isLoading: busy,
            onPressed: onRetryFailed,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            // Retry is scoped server-side to the FAILED rows, which is why
            // pressing it after "8 of 10" is cheap.
            'Only the failed ${voice.itemNounPlural} are tried again.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// A run that failed with nothing to blame it on (F1).
///
/// THE CARD THAT WAS MISSING. When a run fails at the RESTAURANT step the walk
/// aborts before a single product is attempted, so no row is marked FAILED —
/// and `_FailureCard` (which renders rows) and `_SuccessCard` (which needs the
/// catalog live) were both correctly skipped, leaving the screen silently back
/// at rest with the button re-enabled, as though the press had never happened.
///
/// The way out is Publish, NOT "Retry failed": there are no failed rows to
/// retry, and `requestRetry` would answer `NOTHING_TO_RETRY` — a success
/// message for a catalog that is not live.
class _RunFailureCard extends StatelessWidget {
  const _RunFailureCard({
    required this.run,
    required this.voice,
    required this.busy,
    required this.onPublish,
  });

  final PublishRun run;
  final PublishVoice voice;
  final bool busy;

  /// Null disables Try again — offline, paywalled, or otherwise exactly the
  /// conditions that disable the main Publish button.
  final VoidCallback? onPublish;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // From the CODE, through the total envelope+sync table. The payload's own
    // `message` is never parsed, so there is no field upstream prose could
    // have arrived in — and an error code this build has never seen degrades
    // to the generic sentence rather than showing a raw code.
    final copy = run.errorCopy;

    return Container(
      key: const ValueKey('publish_run_failure'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            voice.nothingPublished,
            style: textTheme.titleMedium?.copyWith(color: AppColors.error),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            copy.message,
            style: textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          if (copy.action case final action?) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              action,
              style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          AppButton(
            key: const ValueKey('publish_run_failure_retry'),
            label: 'Try again',
            icon: Icons.refresh,
            isLoading: busy,
            onPressed: onPublish,
          ),
        ],
      ),
    );
  }
}

/// "We could not refresh" — and which kind of could-not it is (F4, F5).
///
/// A MUTED LINE, not an error card. The publish itself is fine; what failed is
/// this screen's own reading of it, and the difference between those two is the
/// whole of F4. The stopped variant exists because a loop that has given up
/// must say so — otherwise the numbers just quietly stop moving and the user
/// has no reason to think a pull-to-refresh would help.
class _PollFailureNote extends StatelessWidget {
  const _PollFailureNote({required this.stopped, required this.inFlight});

  final bool stopped;

  /// A run is on screen. Only then is "your publish is still running" true —
  /// a stale read of a resting screen has no run to reassure anyone about.
  final bool inFlight;

  @override
  Widget build(BuildContext context) => stopped
      ? const _Banner(
          key: ValueKey('publish_poll_stopped_note'),
          icon: Icons.sync_problem_outlined,
          color: AppColors.textMuted,
          title: "Couldn't refresh",
          body: 'Pull down to try again.',
        )
      : _Banner(
          key: const ValueKey('publish_poll_stale_note'),
          icon: Icons.sync_outlined,
          color: AppColors.textMuted,
          title: "Couldn't refresh just now",
          body: inFlight
              ? 'Your publish is still running. Retrying…'
              : 'These numbers are from a moment ago. Retrying…',
        );
}

/// One failed product: its name, OUR sentence, and the next action.
class _FailureRow extends StatelessWidget {
  const _FailureRow({required this.product});

  final PublishProductStatus product;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Looked up from the CODE. The payload's own message is never parsed, so
    // upstream prose has no field it could have arrived in.
    final copy = product.failureCopy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(product.displayName, style: textTheme.bodyMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          copy.message,
          style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
        ),
        if (copy.action case final action?)
          Text(
            action,
            style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
          ),
      ],
    );
  }
}

/// Live on Mirage (feature 69).
class _SuccessCard extends StatelessWidget {
  const _SuccessCard({required this.status, required this.onOpenQr});

  final PublishStatus status;
  final VoidCallback onOpenQr;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final url = status.publicUrl;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle,
                  size: 18, color: AppColors.success),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Live on Mirage',
                style: textTheme.titleMedium?.copyWith(
                  color: AppColors.success,
                ),
              ),
            ],
          ),
          if (url != null && url.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            SelectableText(
              // VERBATIM. Not shortened, not prettified, not re-cased: this is
              // what every printed QR resolves through.
              url,
              key: const ValueKey('publish_public_url'),
              style:
                  textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            PublishLinkActions(url: url),
            const SizedBox(height: AppSpacing.sm),
            AppButton.secondary(
              key: const ValueKey('publish_open_qr'),
              label: 'View QR code',
              icon: Icons.qr_code_2,
              isFullWidth: false,
              onPressed: onOpenQr,
            ),
          ],
        ],
      ),
    );
  }
}

/// The pre-flight checklist — the server's own gates, each with the way to fix
/// it (feature 36).
class _GateChecklist extends StatelessWidget {
  const _GateChecklist({
    required this.gates,
    required this.isWaiting,
    required this.canFix,
    required this.onFix,
    required this.onOpenPreview,
  });

  final List<PublishGate> gates;

  /// Nothing here is the user's to fix — the screen is re-checking on its own.
  final bool isWaiting;

  final bool Function(PublishGate gate) canFix;

  final ValueChanged<PublishGate> onFix;
  final VoidCallback onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      key: const ValueKey('publish_gate_checklist'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Before you can publish',
            style: textTheme.titleMedium?.copyWith(color: AppColors.warning),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            // SAY WHICH KIND OF WAIT THIS IS. Every remaining blocker clearing
            // itself is a different instruction from "go and fix these": the
            // user's job is to do nothing, and a checklist that does not say so
            // reads as a list they are failing to action. It also promises the
            // re-check the notifier is now actually performing, so nobody
            // reloads the page to find out whether their photo finished.
            isWaiting
                ? 'Nothing for you to do — these finish on their own. This '
                    'page re-checks and unlocks Publish as soon as they do.'
                : 'This is the same check the server runs, so fixing everything '
                    'here is enough.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          for (final gate in gates)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    gate.code.resolvesItself
                        ? Icons.hourglass_empty
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: gate.code.resolvesItself
                        ? AppColors.textMuted
                        : AppColors.warning,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    // The backend's own sentence. Gates are computed purely
                    // from ReCapture rows — Mirage is never consulted to build
                    // one — so there is no upstream prose to strip.
                    child: Text(gate.message, style: textTheme.bodySmall),
                  ),
                  if (gate.code.fixLabel case final label?
                      when canFix(gate)) ...[
                    const SizedBox(width: AppSpacing.sm),
                    TextButton(
                      onPressed: () => onFix(gate),
                      child: Text(label),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          AppButton.secondary(
            key: const ValueKey('publish_open_preview'),
            label: 'See them in preview',
            icon: Icons.visibility_outlined,
            isFullWidth: false,
            onPressed: onOpenPreview,
          ),
        ],
      ),
    );
  }
}

/// A Mirage name collision, with the way out (edge case: unprovisioned catalog
/// whose name is taken).
class _NameTakenCard extends StatelessWidget {
  const _NameTakenCard({
    required this.suggested,
    required this.busy,
    required this.voice,
    required this.onRename,
  });

  final String suggested;
  final bool busy;
  final PublishVoice voice;
  final ValueChanged<String> onRename;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const ValueKey('publish_name_taken'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            voice.nameTakenTitle,
            style: textTheme.titleMedium?.copyWith(color: AppColors.warning),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${voice.nameTakenBody}"$suggested" and publish.',
            style:
                textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            key: const ValueKey('publish_accept_suggested_name'),
            label: 'Use "$suggested" and publish',
            isLoading: busy,
            onPressed: () => onRename(suggested),
          ),
        ],
      ),
    );
  }
}

/// Publish, and — once there is something live, on a door that has one — the
/// way to take it down.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.state,
    required this.status,
    required this.isOnline,
    required this.inFlight,
    required this.voice,
    required this.blockedBySubscription,
    required this.onPublish,
    required this.onUnpublish,
  });

  final PublishScreenState state;
  final PublishStatus status;
  final bool isOnline;
  final bool inFlight;
  final PublishVoice voice;

  /// A subscription gate is showing. Its card carries the reason and the way
  /// out, so this only has to switch the button off.
  final bool blockedBySubscription;

  final VoidCallback onPublish;
  final VoidCallback? onUnpublish;

  @override
  Widget build(BuildContext context) {
    // Every reason the button is off, in the order the user would discover
    // them. `null` onPressed is the theme's disabled state — there is no path
    // here that fires a request we already know will be refused.
    final blocked =
        !isOnline || inFlight || !state.canPublish || blockedBySubscription;
    final unpublish = onUnpublish;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppButton(
          key: const ValueKey('publish_cta'),
          label: inFlight
              ? 'Publishing…'
              : status.lastPublishedAt == null
                  ? voice.publishFirstCta
                  : 'Publish changes',
          icon: Icons.cloud_upload_outlined,
          isLoading: state.isRequesting || inFlight,
          onPressed: blocked ? null : onPublish,
        ),
        if (unpublish != null && status.hasPublicUrl && status.isLive) ...[
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            key: const ValueKey('publish_unpublish'),
            onPressed: inFlight || state.isRequesting ? null : unpublish,
            child: const Text('Take catalog offline'),
          ),
        ],
      ],
    );
  }
}

/// Every product with where it stands (feature 52).
///
/// `showWhenNeverPublished` is on here and nowhere else: on a product card in
/// the grid, "Not published" on every row of a catalog nobody has published is
/// noise — on THIS screen the absence is exactly the information.
class _ProductList extends StatelessWidget {
  const _ProductList({required this.products, required this.voice});

  final List<PublishProductStatus> products;
  final PublishVoice voice;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(voice.listTitle, style: textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        for (final product in products)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    product.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      color: product.hasFailed
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                SyncStatusPill(
                  status: product.syncStatus,
                  showWhenNeverPublished: true,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The pre-publish paywall — a subscription gate, as a card rather than a
/// checklist row.
///
/// WHY IT IS NOT A ROW. Every other gate is a five-second edit the user makes
/// and comes back from; this one is a purchase. It needs the reason, the
/// numbers behind it, the second way out (archive the 3D dishes and publish a
/// photo-only menu, which genuinely works), and one button that goes to the
/// place where money changes hands. A row with a "See plans" text button next
/// to "Rename category" gives it none of that.
///
/// WHY IT IS AMBER, NOT RED. Nothing has broken and nothing is lost: the menu,
/// the photos, the categories and the QR code are all exactly where the user
/// left them, and the card says so. Red is for the grace banner, where a clock
/// is actually running out.
class _SubscriptionPaywallCard extends StatelessWidget {
  const _SubscriptionPaywallCard({
    required this.gate,
    required this.subscription,
    required this.voice,
    required this.isOnline,
    required this.onOpenSubscription,
  });

  final PublishGate gate;

  /// The row the verdict came from, for the usage line. Null when the gate was
  /// the server's and the row was not loaded.
  final CatalogSubscription? subscription;

  final PublishVoice voice;

  /// Offline, the button is off: the plans screen cannot be paid on without a
  /// connection, and the offline banner above already says why.
  final bool isOnline;

  final VoidCallback? onOpenSubscription;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final copy = publishPaywallCopy(
      gate,
      subscription: subscription,
      isRep: voice.isRep,
    );
    final open = onOpenSubscription;

    return Container(
      key: const ValueKey('publish_subscription_gate'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.workspace_premium_outlined,
                  size: 20, color: AppColors.warning),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  copy.title,
                  key: const ValueKey('publish_subscription_gate_title'),
                  style: textTheme.titleMedium?.copyWith(
                    color: AppColors.warning,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            copy.body,
            style: textTheme.bodyMedium?.copyWith(
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          if (copy.detail case final detail?) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              '3D/AR dishes: $detail',
              key: const ValueKey('publish_subscription_gate_usage'),
              style: textTheme.bodySmall?.copyWith(color: AppColors.warning),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(
            // OUR sentence for the gate — the backend's own owner-safe copy
            // when it produced the row, this build's mirror of it when it did
            // not. Kept under the explanation rather than instead of it: it is
            // the precise reason, and the paragraph above is the way out.
            gate.message,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          if (open != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppButton(
              key: const ValueKey('publish_subscription_cta'),
              label: isOnline ? copy.actionLabel : 'Needs a connection',
              icon: Icons.lock_outline,
              onPressed: isOnline ? open : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// The GRACE banner (Stage 5): the server's countdown, and the next action
/// in the voice of whoever is standing here — an owner pays, a rep tells the
/// owner. Red because the clock is running; a banner, not a gate, because
/// publishing still works in grace.
/// Requirement 2's banner on the publish screen: the menu is live, a payment is
/// due, and the link goes when the deadline does. Publishing still works — which
/// is why this is a banner and not the paywall card above it.
class _PaymentDueBanner extends StatelessWidget {
  const _PaymentDueBanner({
    required this.daysLeft,
    required this.paymentDueAt,
    required this.voice,
    required this.onOpenSubscription,
  });

  /// The SERVER's countdown (D6), rendered verbatim.
  final int? daysLeft;
  final DateTime? paymentDueAt;
  final PublishVoice voice;
  final VoidCallback? onOpenSubscription;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final isRep = voice.isRep;
    return Container(
      key: const ValueKey('publish_payment_due_banner'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.timer_outlined, size: 16, color: AppColors.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  paymentDueBannerTitle(daysLeft),
                  style:
                      textTheme.bodyMedium?.copyWith(color: AppColors.error),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  paymentDueBannerBody(
                    isRep: isRep,
                    paymentDueAt: paymentDueAt,
                  ),
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary, height: 1.4),
                ),
                if (onOpenSubscription != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('publish_payment_due_cta'),
                      onPressed: onOpenSubscription,
                      // A rep standing at the table can take the payment there
                      // and then, so the label is the same as the owner's — the
                      // grace banner's "Notify owner" is for a restaurant the
                      // rep has already left.
                      child: const Text('Pay now'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GraceBanner extends StatelessWidget {
  const _GraceBanner({
    required this.daysLeft,
    required this.graceFrom,
    required this.voice,
    required this.onOpenSubscription,
  });

  final int? daysLeft;

  /// Which state the row lapsed from, for the E16 wording.
  final SubscriptionStatus? graceFrom;
  final PublishVoice voice;
  final VoidCallback? onOpenSubscription;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final isRep = voice.isRep;
    return Container(
      key: const ValueKey('publish_grace_banner'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  graceBannerLine(daysLeft, graceFrom: graceFrom),
                  style:
                      textTheme.bodyMedium?.copyWith(color: AppColors.error),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  graceBannerAction(isRep: isRep),
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary, height: 1.4),
                ),
                if (onOpenSubscription != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('publish_grace_cta'),
                      onPressed: onOpenSubscription,
                      child: Text(isRep ? 'Notify owner' : 'Pay now'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: textTheme.bodyMedium?.copyWith(color: color)),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  body,
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
        ),
      );
}

/// Coarse relative time. Deliberately coarse: the exact minute a catalog went
/// live is not a thing anyone needs, and this app carries no `intl` dependency
/// to format a real date with.
String _ago(DateTime when) {
  final delta = DateTime.now().toUtc().difference(when.toUtc());
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) {
    return '${delta.inHours} ${delta.inHours == 1 ? 'hour' : 'hours'} ago';
  }
  return '${delta.inDays} ${delta.inDays == 1 ? 'day' : 'days'} ago';
}

/// The toasts a publish screen speaks in, once a run this screen WATCHED
/// starts or ends (features 68, 69).
///
/// Shared for the same reason as the body: "7 of 10 could not be published"
/// must be the same sentence whoever is holding the phone. [liveLine] and
/// [offlineLine] are the two that name the thing, so they come from the
/// screen.
String? publishTransitionToast({
  required PublishStatus before,
  required PublishStatus after,
  required String liveLine,
  required String offlineLine,
}) {
  final wasRunning = before.isPublishing;
  final isRunning = after.isPublishing;
  if (wasRunning == isRunning) return null;

  if (isRunning) {
    return after.run?.mode.isUnpublish ?? false
        ? 'Taking your catalog offline. This keeps going if you leave.'
        : 'Publishing started. This keeps going if you leave this screen.';
  }

  // Finished. WHICH ending it was, not just that it ended — "done" over a
  // run that failed half its products is the message that stops someone
  // ever looking at the list below.
  final run = after.run ?? before.run;

  // COUNT THE ROWS, NOT THE STEPS. `run.counts` are PLAN STEP counts: they
  // include the RESTAURANT step and one per CATEGORY, so "1 of 12 could not be
  // published" was describing a twelve-step plan over ten products. The failure
  // list the sentence points at is products, so the number has to be products.
  final failedRows = after.failures.length;

  // A run that failed with NO failed row — the restaurant step never got off
  // the ground. Pointing at a retry list that is not rendered, for a retry that
  // would answer NOTHING_TO_RETRY, is how the old sentence sent people looking
  // for a card that does not exist. The reason goes in the toast instead, from
  // the CODE as everywhere else.
  if (run != null &&
      run.hasError &&
      run.state == PublishRunState.failed &&
      failedRows == 0) {
    return 'Publishing could not finish. ${run.errorCopy.message}';
  }

  return switch ((after.isLive, failedRows)) {
    (_, > 0) => '$failedRows of ${after.products.length} could not be '
        'published. Retry them below.',
    (true, _) => liveLine,
    (false, _) => offlineLine,
  };
}
