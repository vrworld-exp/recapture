// test/capture/instruction_banner_test.dart
//
// Widget tests for the single instruction banner: one pill at a time, crossfade
// on a changed id, no re-animation on identical re-emits, coalescing of rapid
// changes (latest-wins, intermediates never flashed), 2-line + max-width cap,
// null→fade-out, subtle warning treatment, reduce-motion instant swap, and clean
// disposal mid-transition.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_instruction.dart';
import 'package:recapture/presentation/widgets/instruction_banner.dart';

const _bannerKey = ValueKey<String>('banner');

CaptureInstruction _i(
  String id,
  String message, {
  InstructionSeverity severity = InstructionSeverity.info,
}) =>
    CaptureInstruction(id: id, message: message, severity: severity);

Future<void> _pump(
  WidgetTester tester,
  CaptureInstruction? instruction, {
  bool reduceMotion = false,
  Duration coalesce = const Duration(milliseconds: 120),
  Duration crossfade = const Duration(milliseconds: 220),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Stack(
            children: [
              InstructionBanner(
                key: _bannerKey, // stable key → updates reuse State
                instruction: instruction,
                coalesceWindow: coalesce,
                crossfade: crossfade,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _warningPill() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).border != null,
    );

void main() {
  group('CaptureInstruction', () {
    test('value equality by id + message + severity', () {
      expect(_i('a', 'Hi'), _i('a', 'Hi'));
      expect(_i('a', 'Hi') == _i('a', 'Bye'), isFalse);
      expect(_i('a', 'Hi', severity: InstructionSeverity.warning) == _i('a', 'Hi'),
          isFalse);
    });
  });

  testWidgets('renders the message pill', (tester) async {
    await _pump(tester, _i('move', 'Move closer'));
    expect(find.text('Move closer'), findsOneWidget);
  });

  testWidgets('null instruction hides the pill; a later message brings it back',
      (tester) async {
    await _pump(tester, null);
    expect(find.byType(Text), findsNothing);

    await _pump(tester, _i('a', 'Hold steady'));
    await tester.pump(const Duration(milliseconds: 120)); // debounce
    await tester.pumpAndSettle();
    expect(find.text('Hold steady'), findsOneWidget);
  });

  testWidgets('changing id crossfades old→new with exactly one pill after',
      (tester) async {
    await _pump(tester, _i('a', 'First'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);

    await _pump(tester, _i('b', 'Second'));
    await tester.pump(const Duration(milliseconds: 120)); // debounce applies
    await tester.pumpAndSettle(); // crossfade completes
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('First'), findsNothing); // no lingering second pill
  });

  testWidgets('same id, changed message restyles instantly (no debounce)',
      (tester) async {
    await _pump(tester, _i('x', 'A'));
    await tester.pumpAndSettle();

    await _pump(tester, _i('x', 'A2')); // same id → instant restyle
    await tester.pump(); // single frame, no coalesce wait
    expect(find.text('A2'), findsOneWidget);
    expect(find.text('A'), findsNothing);
  });

  testWidgets('rapid different instructions coalesce to the latest', (tester) async {
    await _pump(tester, _i('a', 'A'));
    await tester.pumpAndSettle();

    // Fire B then C within the coalesce window (each < 120ms apart).
    await _pump(tester, _i('b', 'B'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('B'), findsNothing, reason: 'intermediate never displayed');

    await _pump(tester, _i('c', 'C'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('B'), findsNothing);

    await tester.pump(const Duration(milliseconds: 120)); // debounce fires for C
    await tester.pumpAndSettle();
    expect(find.text('C'), findsOneWidget);
    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsNothing);
  });

  testWidgets('long message is capped at 2 lines + ellipsis within max width',
      (tester) async {
    const long =
        'Walk slowly left around the object while keeping it centered and held '
        'perfectly steady so the frame stays sharp and well exposed for capture';
    await _pump(tester, _i('long', long));
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(find.text(long));
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);

    // The pill is constrained to <= 80% of the 800px test screen width.
    final widths = tester
        .widgetList<ConstrainedBox>(
          find.ancestor(of: find.text(long), matching: find.byType(ConstrainedBox)),
        )
        .map((c) => c.constraints.maxWidth)
        .where((w) => w.isFinite);
    expect(widths.any((w) => w <= 800 * 0.8 + 0.5), isTrue);
  });

  testWidgets('warning severity applies a subtle border treatment', (tester) async {
    await _pump(tester, _i('w', 'Too dark', severity: InstructionSeverity.warning));
    await tester.pumpAndSettle();
    expect(_warningPill(), findsOneWidget);

    await _pump(tester, _i('w', 'Too dark')); // back to info, same id → instant
    await tester.pump();
    expect(_warningPill(), findsNothing);
  });

  testWidgets('reduce-motion swaps instantly while still coalescing',
      (tester) async {
    await _pump(tester, _i('a', 'A'), reduceMotion: true);
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('A'), findsOneWidget);

    await _pump(tester, _i('b', 'B'), reduceMotion: true);
    await tester.pump(const Duration(milliseconds: 120)); // debounce only
    await tester.pump(); // no 220ms crossfade needed
    expect(find.text('B'), findsOneWidget);
    expect(find.text('A'), findsNothing);
  });

  testWidgets('disposed mid-transition does not throw (no setState after dispose)',
      (tester) async {
    await _pump(tester, _i('a', 'A'));
    await tester.pumpAndSettle();

    await _pump(tester, _i('b', 'B'));
    await tester.pump(const Duration(milliseconds: 60)); // mid debounce
    await tester.pumpWidget(const SizedBox()); // dispose the banner
    await tester.pump(const Duration(milliseconds: 300)); // would-be timer/anim
    expect(tester.takeException(), isNull);
  });
}
