// lib/domain/capture/coverage_milestones.dart
//
// Pure Dart — NO Flutter/analytics imports. The milestone math for the
// `coverage_milestone` event: which of {25, 50, 75, 100}% a given raw coverage
// has reached, and which are NEWLY crossed given the ones already fired this
// session. A `>=` percentage comparison (not an integer fill count) so non-integer
// boundaries work — e.g. 25% of 30 segments = 7.5, so the 25% milestone fires when
// the 8th segment fills (8/30 = 26.7%), not the 7th.
//
// This is intentionally analytics-free and stateless so it is trivially testable;
// the fired-set tracking + emission live in the observer (CoverageAnalyticsTracker).

/// The coverage milestones, ascending. RAW ring coverage — distinct from the
/// Level A completion gate (minCoveragePct + min accepted count).
const List<int> kCoverageMilestones = [25, 50, 75, 100];

/// Coverage as a percentage in [0, 100]. 0 when there are no segments (no
/// division by zero).
double coveragePercent(int filledCount, int segmentCount) =>
    segmentCount <= 0 ? 0 : (filledCount / segmentCount) * 100;

/// The milestones reached at [pct] (`pct >= milestone`), ascending.
List<int> milestonesReachedAt(double pct) =>
    [for (final m in kCoverageMilestones) if (pct >= m) m];

/// The milestones reached at [pct] that are NOT in [alreadyFired], ascending —
/// the set to emit on this coverage change (a single fill can cross several at a
/// small segment count, so this can return more than one).
List<int> newlyCrossedMilestones({
  required double pct,
  required Set<int> alreadyFired,
}) =>
    [
      for (final m in kCoverageMilestones)
        if (pct >= m && !alreadyFired.contains(m)) m,
    ];
