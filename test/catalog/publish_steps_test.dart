// test/catalog/publish_steps_test.dart
//
// The step-by-step timeline under the publish progress bar: which step is
// active for a given run, and that a takedown reads in reverse.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/catalog/publish_status.dart';
import 'package:recapture/presentation/widgets/catalog/publish_steps.dart';

import 'publish_fakes.dart' show runPayload;

PublishRun _run({
  String state = 'RUNNING',
  String mode = 'FULL',
  int total = 10,
  int synced = 0,
}) =>
    PublishRun.fromMap(
        runPayload(state: state, mode: mode, total: total, synced: synced));

void main() {
  group('publishActiveStep', () {
    test('walks Request → Preparing → Uploading → Live', () {
      expect(publishActiveStep(null), 0);
      expect(publishActiveStep(_run(state: 'QUEUED')), 1);
      expect(publishActiveStep(_run(total: 0)), 1,
          reason: 'nothing counted yet');
      expect(publishActiveStep(_run(total: 10, synced: 4)), 2);
      expect(publishActiveStep(_run(state: 'SUCCEEDED')), 3);
    });
  });

  group('publishStepLabels', () {
    test('a publish puts the menu live, with the live count', () {
      expect(publishStepLabels(_run(total: 10, synced: 4)), [
        'Request sent',
        'Preparing the menu',
        'Uploading dishes (4/10)',
        'Menu is live',
      ]);
    });

    test('a takedown reads in reverse', () {
      expect(publishStepLabels(_run(mode: 'UNPUBLISH', total: 3, synced: 1)), [
        'Request sent',
        'Switching the page off',
        'Removing dishes (1/3)',
        'Menu is offline',
      ]);
    });
  });

  testWidgets(
      'marks finished steps done and pulses the active one, '
      'and stays still when motion is reduced', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: PublishStepTimeline(run: _run(total: 10, synced: 4)),
        ),
      ),
    ));
    await tester.pumpAndSettle(); // would time out if the pulse kept going

    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    expect(find.text('Uploading dishes (4/10)'), findsOneWidget);
  });
}
