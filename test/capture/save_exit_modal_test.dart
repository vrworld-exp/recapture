// test/capture/save_exit_modal_test.dart
//
// Tests for the Save & Exit confirmation: it resolves to the tapped choice,
// any dismissal (tap-outside / system back) resolves to cancel, the capture
// count is shown, and the shown/choice analytics fire (including
// dismissal-as-cancel).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/save_exit_decision.dart';
import 'package:recapture/presentation/widgets/save_exit_modal.dart';
import 'package:recapture/utils/analytics.dart';

/// Opens the modal; the returned list is appended with the resolved choice once
/// the dialog closes (so callers can dismiss/tap THEN read the result).
Future<List<SaveExitChoice>> _open(
  WidgetTester tester, {
  int count = 12,
}) async {
  final out = <SaveExitChoice>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                out.add(await showSaveExitConfirmation(
                  context,
                  ctx: SaveExitContext(
                    capturedCount: count,
                    hasUnsavedProgress: true,
                  ),
                ));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return out;
}

void main() {
  tearDown(() => Analytics.testSink = null);

  testWidgets('shows the capture count + all three actions', (tester) async {
    await _open(tester, count: 12);
    expect(find.textContaining('12 photos'), findsOneWidget);
    expect(find.text('Save & Exit'), findsOneWidget);
    expect(find.text('Discard & Exit'), findsOneWidget);
    expect(find.text('Keep Capturing'), findsOneWidget);
  });

  testWidgets('singular photo copy (not "1 photos")', (tester) async {
    await _open(tester, count: 1);
    expect(find.textContaining('1 photo'), findsOneWidget);
    expect(find.textContaining('1 photos'), findsNothing);
  });

  testWidgets('Save & Exit resolves saveExit', (tester) async {
    final out = await _open(tester);
    await tester.tap(find.text('Save & Exit'));
    await tester.pumpAndSettle();
    expect(out.single, SaveExitChoice.saveExit);
  });

  testWidgets('Discard & Exit resolves discardExit', (tester) async {
    final out = await _open(tester);
    await tester.tap(find.text('Discard & Exit'));
    await tester.pumpAndSettle();
    expect(out.single, SaveExitChoice.discardExit);
  });

  testWidgets('Keep Capturing resolves cancel', (tester) async {
    final out = await _open(tester);
    await tester.tap(find.text('Keep Capturing'));
    await tester.pumpAndSettle();
    expect(out.single, SaveExitChoice.cancel);
  });

  testWidgets('tap-outside (barrier) resolves cancel', (tester) async {
    final out = await _open(tester);
    await tester.tapAt(const Offset(10, 10)); // barrier, away from the dialog
    await tester.pumpAndSettle();
    expect(out.single, SaveExitChoice.cancel);
  });

  testWidgets('emits prompt_shown and choice analytics (incl. cancel)',
      (tester) async {
    final props = <String, Map<String, Object?>>{};
    Analytics.testSink = (name, p) => props[name] = p;

    await _open(tester, count: 7);
    expect(props[AnalyticsEvents.saveExitPromptShown]?['captured_count'], 7);

    await tester.tapAt(const Offset(10, 10)); // dismiss → cancel
    await tester.pumpAndSettle();
    expect(props[AnalyticsEvents.saveExitChoice]?['choice'], 'cancel');
    expect(props[AnalyticsEvents.saveExitChoice]?['captured_count'], 7);
  });

  test('SaveExitContext value equality', () {
    expect(
      const SaveExitContext(capturedCount: 2, hasUnsavedProgress: true),
      const SaveExitContext(capturedCount: 2, hasUnsavedProgress: true),
    );
    expect(
      const SaveExitContext(capturedCount: 2, hasUnsavedProgress: true),
      isNot(const SaveExitContext(capturedCount: 3, hasUnsavedProgress: true)),
    );
  });
}
