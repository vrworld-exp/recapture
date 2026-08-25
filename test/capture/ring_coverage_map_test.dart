// test/capture/ring_coverage_map_test.dart
//
// Widget tests for the ring coverage map: the "X/N" readout matches the model,
// N=0 renders nothing, runtime N changes rebuild safely, out-of-range/invalid
// indices don't crash, reduce-motion settles (no perpetual pulse), and disposal
// mid-animation is clean.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/ring_coverage.dart';
import 'package:recapture/presentation/widgets/ring_coverage_map.dart';

const _key = ValueKey<String>('ring');

Future<void> _pump(
  WidgetTester tester,
  RingCoverage coverage, {
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Stack(
            children: [
              RingCoverageMap(key: _key, coverage: coverage),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders the X/N readout matching the model', (tester) async {
    await _pump(
      tester,
      const RingCoverage(segmentCount: 12, filledIndices: {0, 1, 2}),
    );
    expect(find.text('3/12'), findsOneWidget);
  });

  testWidgets('N = 0 renders nothing (no readout, no crash)', (tester) async {
    await _pump(tester, const RingCoverage(segmentCount: 0));
    expect(find.textContaining('/'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('complete ring reads N/N', (tester) async {
    await _pump(
      tester,
      const RingCoverage(segmentCount: 3, filledIndices: {0, 1, 2}),
    );
    expect(find.text('3/3'), findsOneWidget);
  });

  testWidgets('out-of-range filled/target indices do not crash; count is sane',
      (tester) async {
    await _pump(
      tester,
      const RingCoverage(
        segmentCount: 4,
        filledIndices: {0, 9, -2},
        targetIndex: 77,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('1/4'), findsOneWidget); // only index 0 counts
  });

  testWidgets('runtime N change rebuilds the ring', (tester) async {
    await _pump(
      tester,
      const RingCoverage(segmentCount: 8, filledIndices: {0}),
    );
    expect(find.text('1/8'), findsOneWidget);

    await _pump(
      tester,
      const RingCoverage(segmentCount: 16, filledIndices: {0, 1}),
    );
    await tester.pump();
    expect(find.text('2/16'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large N renders without crashing', (tester) async {
    await _pump(
      tester,
      RingCoverage(
        segmentCount: 24,
        filledIndices: List.generate(10, (i) => i).toSet(),
      ),
    );
    expect(find.text('10/24'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduce-motion: target set but no perpetual pulse (settles)',
      (tester) async {
    await _pump(
      tester,
      const RingCoverage(segmentCount: 6, filledIndices: {0}, targetIndex: 1),
      reduceMotion: true,
    );
    await tester.pumpAndSettle(); // no looping pulse under reduce-motion
    expect(find.text('1/6'), findsOneWidget);
  });

  testWidgets('newly-filled segment animates without error', (tester) async {
    await _pump(
      tester,
      const RingCoverage(segmentCount: 6, filledIndices: {0}),
    );
    await _pump(
      tester,
      const RingCoverage(segmentCount: 6, filledIndices: {0, 1}),
    );
    await tester.pump(const Duration(milliseconds: 150)); // mid fill ramp
    expect(find.text('2/6'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300)); // ramp completes
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposed mid-animation does not throw', (tester) async {
    await _pump(
      tester,
      const RingCoverage(segmentCount: 6, filledIndices: {0}, targetIndex: 2),
    );
    await tester.pump(const Duration(milliseconds: 100)); // pulse running
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
