// test/capture/verdict_badge_test.dart
//
// The verdict→colour/icon/label mapping must match the post-shot toast tokens
// exactly (single visual language across capture + review).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_colors.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/presentation/widgets/verdict_badge.dart';

void main() {
  group('static mapping', () {
    test('colours match the post-shot toast tokens', () {
      expect(VerdictBadge.colorFor(CaptureVerdict.accepted), AppColors.success);
      expect(VerdictBadge.colorFor(CaptureVerdict.warn), AppColors.warning);
      expect(VerdictBadge.colorFor(CaptureVerdict.reject), AppColors.mirageRed);
    });

    test('icons match the post-shot toast glyphs', () {
      expect(VerdictBadge.iconFor(CaptureVerdict.accepted), Icons.check_circle);
      expect(VerdictBadge.iconFor(CaptureVerdict.warn),
          Icons.warning_amber_rounded);
      expect(VerdictBadge.iconFor(CaptureVerdict.reject), Icons.error_outline);
    });

    test('labels are human-readable', () {
      expect(VerdictBadge.labelFor(CaptureVerdict.accepted), 'Accepted');
      expect(VerdictBadge.labelFor(CaptureVerdict.warn), 'Warned');
      expect(VerdictBadge.labelFor(CaptureVerdict.reject), 'Rejected');
    });
  });

  testWidgets('renders the verdict glyph in its accent colour', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: VerdictBadge(verdict: CaptureVerdict.reject)),
    ));
    final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
    expect(icon.color, AppColors.mirageRed);
  });
}
