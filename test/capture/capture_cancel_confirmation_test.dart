// test/capture/capture_cancel_confirmation_test.dart
//
// The "Cancel → Keep as Draft" confirmation: three clearly-ranked actions (Keep as
// Draft primary, Discard destructive, Keep editing neutral) and the safe-default
// contract — ANY dismissal (tap-outside / system back on the dialog) resolves to
// keepEditing, never an accidental leave/discard.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/capture_cancel.dart';
import 'package:recapture/presentation/widgets/capture_cancel_confirmation.dart';

void main() {
  testWidgets('shows the three ranked actions', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          }),
        ),
      ),
    );
    // ignore: unawaited_futures
    showCaptureCancelConfirmation(ctx);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('capture_cancel_dialog')), findsOneWidget);
    expect(find.byKey(const Key('cancel_keep_draft')), findsOneWidget);
    expect(find.byKey(const Key('cancel_discard')), findsOneWidget);
    expect(find.byKey(const Key('cancel_keep_editing')), findsOneWidget);
    expect(find.text('Keep as Draft'), findsOneWidget);
    expect(find.text('Discard captures'), findsOneWidget);
    expect(find.text('Keep editing'), findsOneWidget);
  });

  testWidgets('Keep as Draft resolves keepDraft', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
          home: Scaffold(
              body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }))),
    );
    final future = showCaptureCancelConfirmation(ctx);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel_keep_draft')));
    await tester.pumpAndSettle();
    expect(await future, CaptureCancelChoice.keepDraft);
  });

  testWidgets('Discard resolves discard', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
          home: Scaffold(
              body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }))),
    );
    final future = showCaptureCancelConfirmation(ctx);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel_discard')));
    await tester.pumpAndSettle();
    expect(await future, CaptureCancelChoice.discard);
  });

  testWidgets('Keep editing resolves keepEditing', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
          home: Scaffold(
              body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }))),
    );
    final future = showCaptureCancelConfirmation(ctx);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel_keep_editing')));
    await tester.pumpAndSettle();
    expect(await future, CaptureCancelChoice.keepEditing);
  });

  testWidgets('barrier tap (dismiss) resolves keepEditing — safe default',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
          home: Scaffold(
              body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }))),
    );
    final future = showCaptureCancelConfirmation(ctx);
    await tester.pumpAndSettle();
    // Tap outside the dialog (top-left corner) → barrier dismiss.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(await future, CaptureCancelChoice.keepEditing);
  });
}
