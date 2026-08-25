// test/capture/progress_meter_test.dart
//
// Widget tests for the progress meter: the text line matches the model, coverage
// is clamped and over-capture shows real numbers, the complete state appears and
// latches (no flicker around the threshold), value changes animate (and settle),
// reduce-motion updates instantly, and disposal mid-animation is clean.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_progress.dart';
import 'package:recapture/presentation/widgets/progress_meter.dart';

const _key = ValueKey<String>('meter');

Future<void> _pump(
  WidgetTester tester,
  CaptureProgress progress, {
  bool reduceMotion = false,
  bool showBar = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Stack(
            children: [
              ProgressMeter(key: _key, progress: progress, showBar: showBar),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _textContaining(String s) => find.textContaining(s);

/// ProgressMeter self-positions (returns a Positioned), so it must live in a
/// Stack. Wraps a meter for the inline pumpWidget calls below.
Widget _host(CaptureProgress progress, {bool reduceMotion = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(
        body: Stack(
          children: [ProgressMeter(key: _key, progress: progress)],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders "Accepted: X/N • Coverage: P%" from the model',
      (tester) async {
    await _pump(
      tester,
      const CaptureProgress(accepted: 12, target: 36, coveragePct: 68),
      reduceMotion: true,
    );
    expect(find.text('Accepted: 12/36 • Coverage: 68%'), findsOneWidget);
  });

  testWidgets('rounds coverage percentage', (tester) async {
    await _pump(
      tester,
      const CaptureProgress(accepted: 1, target: 10, coveragePct: 67.6),
      reduceMotion: true,
    );
    expect(_textContaining('Coverage: 68%'), findsOneWidget);
  });

  testWidgets('clamps out-of-range coverage to 0..100', (tester) async {
    await _pump(
      tester,
      const CaptureProgress(accepted: 0, target: 10, coveragePct: 150),
      reduceMotion: true,
    );
    expect(_textContaining('Coverage: 100%'), findsOneWidget);

    await _pump(
      tester,
      const CaptureProgress(accepted: 0, target: 10, coveragePct: -5),
      reduceMotion: true,
    );
    expect(_textContaining('Coverage: 0%'), findsOneWidget);
  });

  testWidgets('over-capture shows real numbers (38/36)', (tester) async {
    await _pump(
      tester,
      const CaptureProgress(accepted: 38, target: 36, coveragePct: 100),
      reduceMotion: true,
    );
    expect(_textContaining('Accepted: 38/36'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('target = 0 shows neutral 0/0, no crash', (tester) async {
    await _pump(
      tester,
      const CaptureProgress(accepted: 0, target: 0, coveragePct: 0),
      reduceMotion: true,
    );
    expect(_textContaining('Accepted: 0/0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows Complete when coverage meets the threshold',
      (tester) async {
    await _pump(
      tester,
      const CaptureProgress(
          accepted: 10, target: 10, coveragePct: 85, completeAtPct: 80),
      reduceMotion: true,
    );
    expect(find.text('Complete'), findsOneWidget);
  });

  testWidgets('not complete below threshold', (tester) async {
    await _pump(
      tester,
      const CaptureProgress(
          accepted: 5, target: 10, coveragePct: 50, completeAtPct: 80),
      reduceMotion: true,
    );
    expect(find.text('Complete'), findsNothing);
  });

  testWidgets('complete latches and does not flicker as values dip slightly',
      (tester) async {
    await tester.pumpWidget(_host(
      const CaptureProgress(
          accepted: 10, target: 10, coveragePct: 81, completeAtPct: 80),
      reduceMotion: true,
    ));
    await tester.pump();
    expect(find.text('Complete'), findsOneWidget);

    // Dip just below threshold but within the hysteresis margin → stays complete.
    await tester.pumpWidget(_host(
      const CaptureProgress(
          accepted: 9, target: 10, coveragePct: 79, completeAtPct: 80),
      reduceMotion: true,
    ));
    await tester.pump();
    expect(find.text('Complete'), findsOneWidget,
        reason: 'latched within margin');

    // Drop well below threshold → unlatches.
    await tester.pumpWidget(_host(
      const CaptureProgress(
          accepted: 5, target: 10, coveragePct: 50, completeAtPct: 80),
      reduceMotion: true,
    ));
    await tester.pump();
    expect(find.text('Complete'), findsNothing);
  });

  testWidgets('animated count settles to the latest value', (tester) async {
    await _pump(
      tester,
      const CaptureProgress(accepted: 11, target: 36, coveragePct: 30),
    );
    await tester.pumpWidget(_host(
      const CaptureProgress(accepted: 12, target: 36, coveragePct: 33),
    ));
    await tester.pumpAndSettle();
    expect(_textContaining('Accepted: 12/36'), findsOneWidget);
  });

  testWidgets('hides the bar when showBar is false', (tester) async {
    await _pump(
      tester,
      const CaptureProgress(accepted: 1, target: 10, coveragePct: 10),
      reduceMotion: true,
      showBar: false,
    );
    expect(find.byType(FractionallySizedBox), findsNothing);
  });

  testWidgets('disposed mid-animation is clean (no exception)', (tester) async {
    await _pump(
      tester,
      const CaptureProgress(accepted: 1, target: 36, coveragePct: 5),
    );
    await tester.pumpWidget(_host(
      const CaptureProgress(accepted: 20, target: 36, coveragePct: 60),
    ));
    await tester.pump(const Duration(milliseconds: 50)); // mid-animation
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
