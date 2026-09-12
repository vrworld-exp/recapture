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
import '../../../domain/catalog/publish_gate.dart';
import '../../../domain/catalog/publish_status.dart';
import '../../../domain/entities/catalog_status.dart';
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
  final String listTitle;
  final String itemNoun;
  final String itemNounPlural;

  String items(int count) => count == 1 ? itemNoun : itemNounPlural;
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
bool publishAutoStartReady({
  required PublishScreenState state,
  required bool isOnline,
}) =>
    isOnline && state.status.hasValue && state.canPublish;

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
  });

  final PublishScreenState state;
  final PublishStatus status;
  final bool isOnline;
  final PublishVoice voice;
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
                if (state.suggestedName case final suggested?) ...[
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
                if (!inFlight && status.failures.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  _FailureCard(
                    status: status,
                    busy: state.isRequesting,
                    voice: voice,
                    onRetryFailed: isOnline ? onRetryFailed : null,
                  ),
                ],
                if (!inFlight && status.isLive && status.failures.isEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  _SuccessCard(status: status, onOpenQr: onOpenQr),
                ],
                if (status.gates.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  _GateChecklist(
                    gates: status.gates,
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
    required this.onPublish,
    required this.onUnpublish,
  });

  final PublishScreenState state;
  final PublishStatus status;
  final bool isOnline;
  final bool inFlight;
  final PublishVoice voice;
  final VoidCallback onPublish;
  final VoidCallback? onUnpublish;

  @override
  Widget build(BuildContext context) {
    // Every reason the button is off, in the order the user would discover
    // them. `null` onPressed is the theme's disabled state — there is no path
    // here that fires a request we already know will be refused.
    final blocked = !isOnline || inFlight || !state.canPublish;
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
  // ever looking at the list below. The FINISHED run's counts, not the last
  // in-flight poll's: a failure that landed between the two polls is on the
  // run document and not yet on the previous frame.
  final counts = after.run?.counts ?? before.run?.counts;
  final failed = counts?.failed ?? 0;
  return switch ((after.isLive, failed)) {
    (_, > 0) => '$failed of ${counts?.total ?? failed} could not be published. '
        'Retry them below.',
    (true, _) => liveLine,
    (false, _) => offlineLine,
  };
}
