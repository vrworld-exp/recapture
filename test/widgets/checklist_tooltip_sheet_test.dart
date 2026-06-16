// test/widgets/checklist_tooltip_sheet_test.dart
//
// Tests the platform-adaptive tip surface behind showChecklistTooltip:
//   - Android (default) → Material modal bottom sheet (a BottomSheet is present)
//   - iOS               → Cupertino modal popup (no BottomSheet; same content)
// plus content parity, scroll, dismissal, and the no-stacking guard.
//
// Platform is forced via ThemeData.platform (what Theme.of(context).platform
// reads), per the component's contract — never dart:io. The repo has no l10n and
// ships no image assets (icons are IconData), so copy is inline and there is no
// missing-illustration failure mode.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/domain/entities/checklist_item.dart';
import 'package:recapture/presentation/widgets/checklist_tooltip_sheet.dart';

const _item = ChecklistItem(
  id: 'lighting',
  icon: Icons.wb_sunny_outlined,
  title: 'Good lighting',
  shortDescription: 'short',
  tooltipContent: 'Even, diffuse lighting gives the cleanest reconstruction.',
);

const _longItem = ChecklistItem(
  id: 'long',
  icon: Icons.wb_sunny_outlined,
  title: 'Long tip',
  shortDescription: 'short',
  tooltipContent:
      'Line one of a very long tip body. Line two with more detail. Line three '
      'keeps going. Line four. Line five. Line six. Line seven. Line eight. '
      'Line nine. Line ten. Line eleven. Line twelve. Line thirteen elongates '
      'the content well beyond a single screen so it must scroll rather than clip. '
      'Line fourteen. Line fifteen. Line sixteen. Line seventeen. Line eighteen.',
);

late BuildContext _ctx;

Future<void> _pumpHost(
  WidgetTester tester,
  TargetPlatform platform, {
  MediaQueryData? mq,
}) async {
  Widget home = Scaffold(
    body: Builder(builder: (c) {
      _ctx = c;
      return const SizedBox.expand();
    }),
  );
  if (mq != null) home = MediaQuery(data: mq, child: home);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark.copyWith(platform: platform),
    home: home,
  ));
}

Future<void> _open(WidgetTester tester, {ChecklistItem item = _item}) async {
  showChecklistTooltip(_ctx, item);
  await tester.pumpAndSettle();
}

void main() {
  setUp(debugResetChecklistTooltipGuard);

  // ── Platform branch ────────────────────────────────────────────────────────
  group('platform-adaptive presentation', () {
    testWidgets('Android → Material modal bottom sheet with the content', (tester) async {
      await _pumpHost(tester, TargetPlatform.android);
      await _open(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text(_item.title), findsOneWidget);
      expect(find.text(_item.tooltipContent), findsOneWidget);
    });

    testWidgets('iOS → Cupertino popup (no BottomSheet) with the SAME content',
        (tester) async {
      await _pumpHost(tester, TargetPlatform.iOS);
      await _open(tester);

      expect(find.byType(BottomSheet), findsNothing); // not the Material path
      expect(find.text(_item.title), findsOneWidget);
      expect(find.text(_item.tooltipContent), findsOneWidget);
    });
  });

  // ── Content parity ─────────────────────────────────────────────────────────
  testWidgets('content is identical across platforms (shared widget)', (tester) async {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      await _pumpHost(tester, platform);
      await _open(tester);
      expect(find.text(_item.title), findsOneWidget, reason: '$platform title');
      expect(find.text(_item.tooltipContent), findsOneWidget, reason: '$platform body');
      // close so the next iteration starts clean
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      debugResetChecklistTooltipGuard();
    }
  });

  // ── Scroll ─────────────────────────────────────────────────────────────────
  testWidgets('long content scrolls (no clip) on both platforms', (tester) async {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      await _pumpHost(tester, platform);
      await _open(tester, item: _longItem);
      expect(find.byType(SingleChildScrollView), findsOneWidget, reason: '$platform');
      expect(find.text(_longItem.tooltipContent), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$platform overflow');
      // Dismiss before the next platform (the re-pumped app reuses the Navigator).
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      debugResetChecklistTooltipGuard();
    }
  });

  // ── Dismiss ────────────────────────────────────────────────────────────────
  group('dismiss', () {
    testWidgets('close button (Android)', (tester) async {
      await _pumpHost(tester, TargetPlatform.android);
      await _open(tester);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text(_item.title), findsNothing);
    });

    testWidgets('close button (iOS)', (tester) async {
      await _pumpHost(tester, TargetPlatform.iOS);
      await _open(tester);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text(_item.title), findsNothing);
    });

    testWidgets('scrim tap (Android)', (tester) async {
      await _pumpHost(tester, TargetPlatform.android);
      await _open(tester);
      await tester.tapAt(const Offset(10, 10)); // outside the sheet
      await tester.pumpAndSettle();
      expect(find.text(_item.title), findsNothing);
    });
  });

  // ── No stacking ────────────────────────────────────────────────────────────
  testWidgets('rapid double invocation opens only one tip', (tester) async {
    await _pumpHost(tester, TargetPlatform.android);
    showChecklistTooltip(_ctx, _item);
    showChecklistTooltip(_ctx, _item); // blocked by the guard
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text(_item.title), findsOneWidget);
  });

  // ── Resilience ─────────────────────────────────────────────────────────────
  testWidgets('large text scale on a small screen → no overflow', (tester) async {
    await _pumpHost(
      tester,
      TargetPlatform.android,
      mq: const MediaQueryData(
        size: Size(320, 480),
        textScaler: TextScaler.linear(2.0),
      ),
    );
    await _open(tester, item: _longItem);
    expect(tester.takeException(), isNull);
  });
}
