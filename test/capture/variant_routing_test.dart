// test/capture/variant_routing_test.dart
//
// The router's pure flow-variant decisions (mirroring summary_gate_router_test):
//   - levelCRedirectForVariant — every Level C route bounces to the Capture
//     Summary under without_bottom (whose own gate redirect then routes an
//     incomplete session to the first incomplete level's review); with_bottom
//     allows.
//   - levelBCompleteNextRoute — Level B's completion continues to the Level C
//     intro with bottom, and ends at the Capture Summary without it.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';

void main() {
  group('levelCRedirectForVariant', () {
    test('without_bottom → bounce to the Capture Summary', () {
      expect(
        levelCRedirectForVariant(CaptureFlowVariant.withoutBottom),
        AppRoutes.captureSummary,
      );
    });

    test('with_bottom → allow (null)', () {
      expect(levelCRedirectForVariant(CaptureFlowVariant.withBottom), isNull);
    });
  });

  group('levelBCompleteNextRoute', () {
    test('with_bottom → Level C intro (3-ring flow continues)', () {
      expect(
        levelBCompleteNextRoute(CaptureFlowVariant.withBottom),
        AppRoutes.levelCIntro,
      );
    });

    test('without_bottom → Capture Summary (B is the final ring)', () {
      expect(
        levelBCompleteNextRoute(CaptureFlowVariant.withoutBottom),
        AppRoutes.captureSummary,
      );
    });
  });
}
