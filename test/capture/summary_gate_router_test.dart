// test/capture/summary_gate_router_test.dart
//
// The router's Summary-gate decision (pure helper): unlocked → allow (null);
// locked → bounce to the FIRST incomplete level's review route. The analytics +
// live gate are covered in completion_gate_provider_test.dart; this pins the
// route mapping the router redirect uses.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/domain/capture/completion_gate.dart';

LevelCompletionStatus _s(String code, int accepted) => LevelCompletionStatus(
      levelCode: code,
      acceptedCount: accepted,
      minAcceptedFrames: 1,
    );

void main() {
  test('unlocked gate → allow (null target)', () {
    final gate = evaluateSummaryGate([_s('A', 1), _s('B', 1), _s('C', 1)]);
    expect(summaryGateRedirectTarget(gate), isNull);
  });

  test('locked → bounces to the first incomplete level review', () {
    // B complete, A & C incomplete → first incomplete is A.
    expect(
      summaryGateRedirectTarget(
          evaluateSummaryGate([_s('A', 0), _s('B', 1), _s('C', 0)])),
      AppRoutes.levelAReview,
    );
    // Only C incomplete → Level C review.
    expect(
      summaryGateRedirectTarget(
          evaluateSummaryGate([_s('A', 1), _s('B', 1), _s('C', 0)])),
      AppRoutes.levelCReview,
    );
    // Only B incomplete → Level B review.
    expect(
      summaryGateRedirectTarget(
          evaluateSummaryGate([_s('A', 1), _s('B', 0), _s('C', 1)])),
      AppRoutes.levelBReview,
    );
  });

  test('empty gate (fail safe) → Projects, not Summary', () {
    expect(summaryGateRedirectTarget(evaluateSummaryGate([])),
        AppRoutes.projects);
  });
}
