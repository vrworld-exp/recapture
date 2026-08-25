// test/capture/level_a_settings_sheet_test.dart
//
// Tests for the settings model + the Level A Settings sheet: model helpers,
// controls reflect the supplied (live) settings, each change calls onChanged
// with the right delta + emits analytics, a parent-side revert (e.g. denied
// gallery permission) reflects live, and the close button dismisses.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_settings.dart';
import 'package:recapture/presentation/widgets/level_a_settings_sheet.dart';
import 'package:recapture/utils/analytics.dart';

Future<ValueNotifier<CaptureSettings>> _openSheet(
  WidgetTester tester, {
  CaptureSettings initial = const CaptureSettings(),
  void Function(CaptureSettings)? onChanged,
}) async {
  final notifier = ValueNotifier<CaptureSettings>(initial);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showLevelASettingsSheet(
                context,
                settings: notifier,
                onChanged: onChanged ?? (s) => notifier.value = s,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return notifier;
}

void main() {
  tearDown(() => Analytics.testSink = null);

  group('model', () {
    test('quality string round-trip + default', () {
      expect(qualityModeToString(QualityMode.high), 'high');
      expect(qualityModeToString(QualityMode.standard), 'standard');
      expect(qualityModeFromString('high'), QualityMode.high);
      expect(qualityModeFromString('standard'), QualityMode.standard);
      expect(qualityModeFromString(null), QualityMode.standard);
      expect(qualityModeFromString('garbage'), QualityMode.standard);
    });

    test('defaults: auto on, save off, standard', () {
      const s = CaptureSettings();
      expect(s.autoCapture, isTrue);
      expect(s.saveToGallery, isFalse);
      expect(s.quality, QualityMode.standard);
    });

    test('copyWith + equality', () {
      const a = CaptureSettings();
      expect(a.copyWith(saveToGallery: true),
          const CaptureSettings(saveToGallery: true));
      expect(a, const CaptureSettings());
      expect(a == a.copyWith(quality: QualityMode.high), isFalse);
    });
  });

  testWidgets('controls reflect the supplied settings', (tester) async {
    await _openSheet(
      tester,
      initial: const CaptureSettings(
        autoCapture: false,
        saveToGallery: true,
        quality: QualityMode.high,
      ),
    );
    expect(find.text('Capture settings'), findsOneWidget);
    final switches =
        tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches[0].value, isFalse); // auto-capture
    expect(switches[1].value, isTrue); // save-to-gallery
    // High selected in the segmented control.
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Standard'), findsOneWidget);
  });

  testWidgets('toggling auto-capture calls onChanged + emits analytics',
      (tester) async {
    final changes = <CaptureSettings>[];
    final events = <Map<String, Object?>>[];
    Analytics.testSink = (name, props) {
      if (name == AnalyticsEvents.captureSettingChanged) events.add(props);
    };
    await _openSheet(
      tester,
      initial: const CaptureSettings(autoCapture: true),
      onChanged: changes.add,
    );

    // Tap the first switch (auto-capture) off.
    await tester.tap(find.byType(Switch).first);
    await tester.pump();

    expect(changes.single.autoCapture, isFalse);
    expect(events.single['setting'], 'auto_capture');
    expect(events.single['value'], 'off');
  });

  testWidgets('changing quality to High emits high', (tester) async {
    Map<String, Object?>? evt;
    Analytics.testSink = (name, props) {
      if (name == AnalyticsEvents.captureSettingChanged) evt = props;
    };
    await _openSheet(tester, initial: const CaptureSettings());
    await tester.tap(find.text('High'));
    await tester.pump();
    expect(evt?['setting'], 'quality_mode');
    expect(evt?['value'], 'high');
  });

  testWidgets('parent revert reflects live in the open sheet', (tester) async {
    // Simulate: user turns save-to-gallery ON, parent denies and reverts to OFF.
    late ValueNotifier<CaptureSettings> notifier;
    notifier = await _openSheet(
      tester,
      initial: const CaptureSettings(saveToGallery: false),
      onChanged: (s) {
        if (s.saveToGallery) {
          // optimistic ON, then revert (permission denied)
          notifier.value = s;
          notifier.value = s.copyWith(saveToGallery: false);
        } else {
          notifier.value = s;
        }
      },
    );

    await tester.tap(find.byType(Switch).at(1)); // save-to-gallery ON
    await tester.pumpAndSettle();

    // Reverted to OFF — the switch shows OFF.
    final saveSwitch = tester.widgetList<Switch>(find.byType(Switch)).elementAt(1);
    expect(saveSwitch.value, isFalse);
  });

  testWidgets('close button dismisses', (tester) async {
    await _openSheet(tester);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Capture settings'), findsNothing);
  });

  testWidgets('emits device_type', (tester) async {
    Map<String, Object?>? evt;
    Analytics.testSink = (name, props) {
      if (name == AnalyticsEvents.captureSettingChanged) evt = props;
    };
    await _openSheet(tester);
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(
      evt?['device_type'],
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    );
  });
}
