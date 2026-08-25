// test/widgets/permission_card_test.dart
//
// Component tests for PermissionCard — the presentational permission row consumed
// by the Permissions Gate (Screen 4A). The card is a pure function of its inputs:
// it maps status → (icon + text + colour + action) and emits callbacks; it never
// touches permission_handler or navigates.
//
// Repo notes: the real status type is `AppPermissionStatus` and criticality is
// `PermissionRequirement` (reused, not redefined). There is no `limited` UI
// status — PermissionsService folds iOS limited/provisional into `granted` — so
// there is no separate "Manage" affordance to test here. Icons are IconData
// (no asset pipeline), so there is no missing-asset failure mode.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/domain/entities/permission_item.dart';
import 'package:recapture/platform/permissions_service.dart';
import 'package:recapture/presentation/widgets/permission_card.dart';

PermissionItem _itemOf(AppPermissionType type) =>
    defaultPermissionItems.firstWhere((i) => i.type == type);

final _camera = _itemOf(AppPermissionType.camera); // required
final _motion = _itemOf(AppPermissionType.motion); // recommended
final _photos = _itemOf(AppPermissionType.photos); // optional

Future<void> _pump(
  WidgetTester tester, {
  required AppPermissionStatus status,
  PermissionItem? item,
  bool inFlight = false,
  VoidCallback? onAllow,
  VoidCallback? onOpenSettings,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(
      body: PermissionCard(
        item: item ?? _camera,
        status: status,
        isInFlight: inFlight,
        onAllow: onAllow,
        onOpenSettings: onOpenSettings,
      ),
    ),
  ));
}

void _noop() {}

void main() {
  // ── Status → action (exhaustive) ───────────────────────────────────────────
  group('status → action', () {
    testWidgets('granted → "Granted" + check icon, no action button', (tester) async {
      await _pump(tester, status: AppPermissionStatus.granted, onAllow: _noop, onOpenSettings: _noop);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('Granted'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('notRequested → "Allow"', (tester) async {
      await _pump(tester, status: AppPermissionStatus.notRequested, onAllow: _noop);
      expect(find.widgetWithText(TextButton, 'Allow'), findsOneWidget);
    });

    testWidgets('denied → "Allow"', (tester) async {
      await _pump(tester, status: AppPermissionStatus.denied, onAllow: _noop);
      expect(find.widgetWithText(TextButton, 'Allow'), findsOneWidget);
    });

    testWidgets('permanentlyDenied → "Settings"', (tester) async {
      await _pump(tester, status: AppPermissionStatus.permanentlyDenied, onOpenSettings: _noop);
      expect(find.widgetWithText(TextButton, 'Settings'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
    });

    testWidgets('restricted → "Settings"', (tester) async {
      await _pump(tester, status: AppPermissionStatus.restricted, onOpenSettings: _noop);
      expect(find.widgetWithText(TextButton, 'Settings'), findsOneWidget);
    });

    testWidgets('in-flight → spinner, no action', (tester) async {
      await _pump(tester, status: AppPermissionStatus.notRequested, inFlight: true, onAllow: _noop);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('every status renders without throwing (exhaustive)', (tester) async {
      for (final s in AppPermissionStatus.values) {
        await _pump(tester, status: s, onAllow: _noop, onOpenSettings: _noop);
        expect(tester.takeException(), isNull, reason: 'status $s threw');
      }
    });
  });

  // ── Callback wiring ────────────────────────────────────────────────────────
  group('callbacks', () {
    testWidgets('tapping Allow fires onRequest only', (tester) async {
      var allow = 0, settings = 0;
      await _pump(tester,
          status: AppPermissionStatus.denied,
          onAllow: () => allow++,
          onOpenSettings: () => settings++);
      await tester.tap(find.text('Allow'));
      expect(allow, 1);
      expect(settings, 0);
    });

    testWidgets('tapping Settings fires onOpenSettings only', (tester) async {
      var allow = 0, settings = 0;
      await _pump(tester,
          status: AppPermissionStatus.permanentlyDenied,
          onAllow: () => allow++,
          onOpenSettings: () => settings++);
      await tester.tap(find.text('Settings'));
      expect(settings, 1);
      expect(allow, 0);
    });
  });

  // ── Colour independence (greyscale-legible) ────────────────────────────────
  testWidgets('granted vs permanently-denied differ by ICON + TEXT, not colour alone',
      (tester) async {
    await _pump(tester, status: AppPermissionStatus.granted, onOpenSettings: _noop);
    expect(find.byIcon(Icons.check_circle), findsOneWidget); // distinct icon
    expect(find.text('Granted'), findsOneWidget); // distinct text

    await _pump(tester, status: AppPermissionStatus.permanentlyDenied, onOpenSettings: _noop);
    expect(find.byIcon(Icons.error_outline), findsOneWidget); // different icon
    expect(find.text('Settings'), findsOneWidget); // and text
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  // ── Criticality = emphasis/label only, never the action ────────────────────
  testWidgets('same status → same action across required/recommended/optional',
      (tester) async {
    for (final entry in {
      _camera: '(required)',
      _motion: '(recommended)',
      _photos: '(optional)',
    }.entries) {
      await _pump(tester, item: entry.key, status: AppPermissionStatus.denied, onAllow: _noop);
      expect(find.widgetWithText(TextButton, 'Allow'), findsOneWidget,
          reason: '${entry.key.title} should still show Allow');
      expect(find.text(entry.value), findsOneWidget); // only the label differs
    }
  });

  // ── Combined semantics label ───────────────────────────────────────────────
  testWidgets('exposes a combined "title, criticality, status" semantics label',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, status: AppPermissionStatus.granted, onOpenSettings: _noop);
    // e.g. "Camera, required, granted"
    expect(find.bySemanticsLabel(RegExp(r'Camera,\s*required,\s*granted')), findsOneWidget);
    handle.dispose();
  });

  // ── Missing-callback resilience ────────────────────────────────────────────
  group('missing callbacks', () {
    testWidgets('permanentlyDenied without onOpenSettings → status chip, no dangling button',
        (tester) async {
      await _pump(tester, status: AppPermissionStatus.permanentlyDenied); // no callbacks
      expect(tester.takeException(), isNull);
      expect(find.text('Blocked'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('denied without onAllow → "Not granted" chip, no dangling button',
        (tester) async {
      await _pump(tester, status: AppPermissionStatus.denied); // no callbacks
      expect(tester.takeException(), isNull);
      expect(find.text('Not granted'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });
  });

  // ── Resilience ─────────────────────────────────────────────────────────────
  testWidgets('long content + large text scale → no overflow', (tester) async {
    const longItem = PermissionItem(
      type: AppPermissionType.camera,
      title: 'A very long permission title that should wrap gracefully indeed',
      rationale:
          'An extended rationale paragraph explaining at length exactly why this '
          'permission is needed, long enough to force wrapping under large text.',
      icon: Icons.camera_alt_outlined,
      requirement: PermissionRequirement.required,
    );
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        // The screen hosts cards in a scrolling list, so a tall card scrolls
        // rather than overflows. The card itself must not overflow HORIZONTALLY.
        child: Scaffold(
          body: ListView(
            children: const [
              PermissionCard(
                item: longItem,
                status: AppPermissionStatus.notRequested,
                isInFlight: false,
              ),
            ],
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
