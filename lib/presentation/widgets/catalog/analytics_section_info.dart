// lib/presentation/widgets/catalog/analytics_section_info.dart
//
// Explainer copy for every dashboard section — the content behind the (i)
// buttons — and the button itself.
//
// KEPT OUT OF THE PANELS ON PURPOSE. The numbers on this screen are defined by
// Mirage's server-side aggregations, not by the widgets that draw them, so this
// copy has to track mirage-be/src/Controllers/analyticsController.js. Holding
// it in one file makes that drift visible in a single diff instead of hiding
// it across ten widgets. Mirage's own dashboard keeps the same copy in
// `sectionInfo.ts`; the two should say the same things about the same numbers.
//
// Rules for writing these:
//   • Say what is counted, in the reader's words, then how it is counted.
//   • Name the caveat. A business reading an inflated number and finding out
//     later is worse than a business reading a smaller number they can trust.
//   • Keep raw event-type strings out of `body`; `counting` is where someone
//     reconciling a figure against the event stream gets the mechanics.
import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';

/// Every section that carries an (i).
enum AnalyticsSection {
  overview,
  sessions,
  visitors,
  catalogOpens,
  productViews,
  arLaunches,
  contactClicks,
  browseTaps,
  directLinks,
  traffic,
  funnel,
  categories,
  searches,
  modelHealth,
  products,
  split,
  zoomed,
  devices,
}

/// One section's explainer.
class AnalyticsSectionInfo {
  const AnalyticsSectionInfo({
    required this.title,
    required this.body,
    this.counting = const <String>[],
    this.caveat,
  });

  /// Heading inside the sheet. Matches the section's own title.
  final String title;

  /// Plain-language answer to "what is this?" — one or two sentences.
  final String body;

  /// How the figure is derived. Precise, and safe to check against the
  /// aggregation.
  final List<String> counting;

  /// The thing that will otherwise get misread. Rendered set apart, in the
  /// warning hue.
  final String? caveat;
}

const Map<AnalyticsSection, AnalyticsSectionInfo> kAnalyticsSectionInfo = {
  AnalyticsSection.overview: AnalyticsSectionInfo(
    title: 'Analytics',
    body: 'Real customer behaviour from your live catalog — what visitors '
        'opened, looked at, launched in AR and tapped to contact. The range '
        'at the top scopes every panel on this screen, so any two cards can '
        'always be read against each other.',
    counting: [
      'Events are stamped with server receive time and bucketed by calendar '
          'day in Indian Standard Time (IST), so a late evening stays on the '
          'day it happened.',
      'Bots, crawlers and uptime pingers are dropped at ingest and never '
          'reach these numbers.',
      'Results are cached for up to 5 minutes — pull to refresh rebuilds '
          'them after that window.',
      'The widest window that can be requested is 365 days.',
    ],
    caveat: "Today's figures are still filling in. Compare whole days, not a "
        'part-day against a full one.',
  ),
  AnalyticsSection.sessions: AnalyticsSectionInfo(
    title: 'Sessions',
    body: 'One visit — a single person browsing your catalog in one sitting. '
        'This is the headline number because it is the most honest one on '
        'the screen.',
    counting: [
      'A session starts when the catalog opens in a fresh tab and ends when '
          'that tab closes.',
      'It also ends after 30 minutes with no activity. The clock resets on '
          'every action, so an hour of continuous browsing is still one '
          'session.',
      'The figure is the number of distinct sessions that produced at least '
          'one event in the range.',
    ],
    caveat: 'Not the same as QR scans — nothing here detects a scan. Most '
        'scans do become one session, but so does someone typing the link or '
        'opening it from history, and one person who leaves the page idle for '
        '40 minutes and comes back counts twice.',
  ),
  AnalyticsSection.visitors: AnalyticsSectionInfo(
    title: 'Unique visitors',
    body: 'An estimate of how many different people are behind those '
        'sessions, based on an anonymous id kept in the browser.',
    counting: [
      'Distinct visitor ids seen in the range.',
      'The id is first-party and anonymous — no name, no email, no '
          'cross-site tracking.',
    ],
    caveat: 'Runs high, which is why it is labelled an estimate. QR links '
        'often open in an in-app browser (Instagram, WhatsApp) or a private '
        'window where storage is wiped each time, so the same person picks up '
        'a new id on every scan. Quote sessions, not this.',
  ),
  AnalyticsSection.catalogOpens: AnalyticsSectionInfo(
    title: 'Catalog opens',
    body: 'How many times your catalog page was loaded. The top of the '
        'funnel, and the closest thing on this screen to raw footfall.',
    counting: [
      'One count per catalog page load — a reload or a return visit counts '
          'again.',
      'Deep links straight to a product still open the catalog, so they '
          'land here too.',
    ],
    caveat: 'Sits above sessions, because a single session can load the '
        'catalog more than once.',
  ),
  AnalyticsSection.productViews: AnalyticsSectionInfo(
    title: 'Product views',
    body: 'How many times a visitor opened a product to look at it properly '
        '— the detail sheet with the description, the price and the 3D '
        'model.',
    counting: [
      'Counted from card taps, featured taps, search results and shared '
          'links alike.',
      'Every open counts, so one visitor comparing four products registers '
          'four views.',
    ],
    caveat: 'Scrolling past a product is not a view. Only opening it is.',
  ),
  AnalyticsSection.arLaunches: AnalyticsSectionInfo(
    title: 'AR launches',
    body: 'Taps on the AR View button — the moment a visitor asks to see the '
        'product in their own space. The strongest single signal that the 3D '
        'catalog is earning its place.',
    counting: [
      'Counted at the tap, whether it came from the product card, the detail '
          'sheet or a QR auto-open.',
    ],
    caveat: 'A tap is not a confirmed AR session. Devices without AR '
        'support, and visitors who dismiss the system prompt, still count '
        'here. See 3D & AR health for how many actually entered AR.',
  ),
  AnalyticsSection.contactClicks: AnalyticsSectionInfo(
    title: 'Contact clicks',
    body: 'Visitors tapping a real contact channel — call, WhatsApp or '
        'email. The bottom of the funnel, and the number that turns into '
        'business.',
    counting: [
      'One count per channel tap.',
      'Opening the contact sheet is tracked separately and is not counted '
          'here — this is the channel tap itself.',
    ],
  ),
  AnalyticsSection.browseTaps: AnalyticsSectionInfo(
    title: 'Browse taps',
    body: 'Taps on the floating Menu button that opens the full category '
        'list. A visitor does this when the tabs across the top did not have '
        'what they were looking for.',
    counting: [
      'One count each time the category overlay is opened.',
      'Closing it is not a second count, and tapping the category that is '
          'already open is not counted at all.',
    ],
    caveat: 'High browse taps next to low category opens usually means the '
        'overlay is being opened and abandoned — worth checking that the '
        'category names read clearly.',
  ),
  AnalyticsSection.directLinks: AnalyticsSectionInfo(
    title: 'Direct links',
    body: 'Visits that landed straight on one product rather than on the '
        'catalog — a QR code printed beside a single item, or a link someone '
        'shared.',
    counting: [
      'Counted from the address the visitor arrived on, not from opening a '
          'product once already inside the catalog.',
      'The product has to exist in the catalog, so a stale link to a deleted '
          'item never counts.',
      'One count per product per page load, however many times the screen '
          're-renders.',
    ],
    caveat: 'These also add to Catalog opens and Product views — the catalog '
        'still loads, and the product still opens. This is the arrival '
        'route, not a separate audience.',
  ),
  AnalyticsSection.traffic: AnalyticsSectionInfo(
    title: 'Traffic over time',
    body: 'The funnel plotted day by day. Read it for shape — weekends, a '
        'campaign, a quiet stretch — rather than for exact values.',
    counting: [
      'Each bar is one calendar day in Indian Standard Time (IST).',
      'Pick a series with the chips; every series is drawn on its own scale.',
    ],
    caveat: 'The last bar is today and is still filling in, so a dip at the '
        'right edge is usually the clock rather than the traffic. Switch to '
        'Table for exact figures.',
  ),
  AnalyticsSection.funnel: AnalyticsSectionInfo(
    title: 'Conversion funnel',
    body: 'The whole journey in four steps: catalog opened → product viewed '
        '→ AR launched → contact clicked. The percentage on each step is how '
        'much of the step above it made it through.',
    counting: [
      'Each bar is a total count of that action in the range, drawn against '
          'the top of the funnel.',
      'The percentage is the stage divided by the stage directly above it, '
          'not by the top of the funnel.',
    ],
    caveat: 'These are actions, not people. One visitor who opens six '
        'products contributes six to the second stage, so a step can read '
        'higher than the one above it. Track the trend across ranges rather '
        'than the absolute drop-off.',
  ),
  AnalyticsSection.categories: AnalyticsSectionInfo(
    title: 'Categories opened',
    body: 'Which parts of the catalog pull attention. Tells you where to put '
        'a new product so that it actually gets seen.',
    counting: [
      'One count each time a category is opened, from the tab strip or the '
          'menu overlay.',
      'The card shows the top 5; More opens the full ranked list.',
    ],
    caveat: 'The All and featured tabs are excluded on purpose. All is the '
        'default view, so leaving it in would swamp every real category and '
        'make the comparison useless.',
  ),
  AnalyticsSection.searches: AnalyticsSectionInfo(
    title: 'Searches',
    body: 'What visitors typed into the search box, ranked by how often. The '
        'most direct statement of intent on this screen: everything else is '
        'a tap on something already put in front of them, this is them '
        'asking for something by name.',
    counting: [
      'Recorded once a query settles — a pause in typing — so "chicken" is '
          'one search, not eight.',
      'Queries are lowercased and trimmed before grouping, so Paneer and '
          'paneer are one row.',
      'Found is the average number of products the query matched. Empty is '
          'how many of those searches matched nothing.',
      'Capped at 20 distinct queries.',
    ],
    caveat: 'Rows with a high Empty count are the useful ones — they are '
        'products visitors expect you to have and cannot find. Read that '
        'column before the ranking.',
  ),
  AnalyticsSection.modelHealth: AnalyticsSectionInfo(
    title: '3D & AR health',
    body: 'Whether the 3D experience actually works on the phones in '
        "visitors' hands. Every other panel on this screen assumes it does; "
        'this is the one that checks.',
    counting: [
      'AR entered is a confirmed AR session on the device, against AR '
          'launches, which is only the tap.',
      'Loaded and Failed are the 3D model finishing or giving up, reported '
          'by the viewer itself.',
      'Load time is measured from the moment a model starts fetching, not '
          'from when the page opened, so scrolling is not counted as loading.',
      'Slow loads are anything over the threshold shown on the card.',
    ],
    caveat: 'A large gap between AR launches and AR entered is normal on '
        'desktop, which shows a QR hand-off instead of launching AR. It only '
        'signals a problem when mobile traffic dominates the range.',
  ),
  AnalyticsSection.products: AnalyticsSectionInfo(
    title: 'Top products',
    body: 'The product leaderboard. Views, AR launches and sessions side by '
        'side, so a product that gets looked at but never launched in AR is '
        'easy to spot next to one that does both.',
    counting: [
      'Views combines detail-sheet opens and direct product links.',
      'AR is taps on AR View. AR rate is AR divided by views.',
      'Sessions is how many separate visits the product appeared in — the '
          'de-duplicated read of the same activity.',
      'Ranked by views by default, sortable by any column, and holding the '
          'top 20. Tap a row to open the product.',
    ],
    caveat: 'A product that is no longer in your catalog keeps the views it '
        'earned and is labelled Unknown. Dropping it would make these totals '
        'disagree with the public page.',
  ),
  AnalyticsSection.split: AnalyticsSectionInfo(
    title: '3D vs image-only',
    body: 'How much of the attention went to products with a 3D model '
        'against products with only photos.',
    counting: [
      'Product views from the leaderboard, totalled per product type.',
      'Unknown is the views earned by products since deleted from this '
          'catalog.',
    ],
  ),
  AnalyticsSection.zoomed: AnalyticsSectionInfo(
    title: 'Zoomed items',
    body: 'Products visitors pinched in to inspect closely. Zooming is '
        'deliberate in a way that rotating is not, which makes this the '
        'sharpest read of genuine curiosity about a model.',
    counting: [
      'Only pinch-zoom gestures count. Rotating and panning are excluded — '
          'rotation is the default gesture and fires constantly.',
      'Three zoom gestures make one counted zoom, so an accidental nudge '
          'does not register.',
      'Products that never completed a full burst are left out rather than '
          'padding the list with zeroes.',
    ],
    caveat: 'A product missing from this list has not necessarily been '
        'ignored — it may simply have no 3D model.',
  ),
  AnalyticsSection.devices: AnalyticsSectionInfo(
    title: 'Devices',
    body: 'The split between phone, tablet and desktop, counted in sessions. '
        'On a QR catalog this is normally overwhelmingly mobile; a large '
        'desktop share usually means the link is being shared rather than '
        'scanned.',
    counting: [
      "Device type is read from the browser's user agent at ingest.",
      'Counted in sessions rather than events, so one long visit does not '
          'outweigh a short one.',
    ],
    caveat: 'An unknown slice is normal. Some in-app browsers report a user '
        'agent that cannot be classified.',
  ),
};

/// The (i) beside a section title. Opens the section's explainer in a sheet.
///
/// An `IconButton`, not a bare icon with a gesture: it is in the traversal
/// order, it has a tooltip, and it announces itself — the whole keyboard and
/// screen-reader story on web, for free.
class AnalyticsInfoHint extends StatelessWidget {
  const AnalyticsInfoHint({super.key, required this.section});

  final AnalyticsSection section;

  @override
  Widget build(BuildContext context) {
    final info = kAnalyticsSectionInfo[section]!;
    return IconButton(
      key: ValueKey('analytics_info_${section.name}'),
      icon: const Icon(Icons.info_outline, size: 16),
      color: AppColors.textMuted,
      tooltip: 'About ${info.title}',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: () => showAnalyticsSectionInfo(context, section),
    );
  }
}

/// The explainer sheet.
Future<void> showAnalyticsSectionInfo(
  BuildContext context,
  AnalyticsSection section,
) {
  final info = kAnalyticsSectionInfo[section]!;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface1,
    // Bounded on a wide window: a sheet stretched across 1600 px reads like
    // a banner, not a note.
    constraints: const BoxConstraints(maxWidth: 560),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
    ),
    builder: (sheetContext) {
      final textTheme = Theme.of(sheetContext).textTheme;
      return SafeArea(
        child: ListView(
          key: ValueKey('analytics_info_sheet_${section.name}'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          children: [
            Text(info.title, style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              info.body,
              style: textTheme.bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            if (info.counting.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                'How it is counted',
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              for (final line in info.counting)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '•  ',
                        style: textTheme.bodySmall
                            ?.copyWith(color: AppColors.textMuted),
                      ),
                      Expanded(
                        child: Text(
                          line,
                          style: textTheme.bodySmall
                              ?.copyWith(color: AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (info.caveat != null) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  info.caveat!,
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
