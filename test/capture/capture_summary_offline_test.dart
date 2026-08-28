// test/capture/capture_summary_offline_test.dart
//
// The connectivity-reactive offline banner on the Capture Summary (Screen 8): it
// appears live when offline and hides when reconnected (debounced against flapping,
// no false flash at entry), the Upload CTA is blocked offline (with analytics), and
// the banner-shown event fires on the hidden→shown edge only. Connectivity is driven
// through the CENTRALIZED source by overriding connectivityStatusProvider.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/platform/connectivity_watcher.dart';
import 'package:recapture/presentation/screens/capture/capture_summary_screen.dart';
import 'package:recapture/utils/analytics.dart';

class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

CapturedPhotoRecord _accepted(int seg, String path) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 0,
      sensorTimestampNs: seg * 1000 + 1,
    );

/// All levels complete → Upload is eligible (so offline can block an otherwise-
/// enabled CTA).
LevelCaptureLedgerRegistry _completeRegistry() {
  final reg = LevelCaptureLedgerRegistry();
  // Every ring is 16 segments under the default with_bottom variant → each
  // needs ≥13 filled (80%) to be complete.
  for (final e in {'mid': 13, 'high': 13, 'low': 13}.entries) {
    final ledger = reg.ledgerFor(e.key);
    for (var i = 0; i < e.value; i++) {
      ledger.recordAccepted(_accepted(i, '/${e.key}/$i.jpg'));
    }
  }
  return reg;
}

void main() {
  late List<({String name, Map<String, Object?> props})> events;
  late StreamController<AppConnectivityStatus> conn;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
    conn = StreamController<AppConnectivityStatus>.broadcast();
  });
  tearDown(() {
    Analytics.testSink = null;
    conn.close();
  });

  List<({String name, Map<String, Object?> props})> named(String name) =>
      events.where((e) => e.name == name).toList();

  Future<void> pump(WidgetTester tester) async {
    Widget stub(String l) => Scaffold(body: Text(l));
    final router = GoRouter(
      initialLocation: AppRoutes.captureSummary,
      routes: [
        GoRoute(
            path: AppRoutes.captureSummary,
            builder: (_, __) => const CaptureSummaryScreen()),
        GoRoute(path: AppRoutes.uploading, builder: (_, __) => stub('UPLOADING')),
        GoRoute(path: AppRoutes.projects, builder: (_, __) => stub('PROJECTS')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          levelCaptureLedgerRegistryProvider
              .overrideWithValue(_completeRegistry()),
          captureConfigProvider.overrideWith(_StubConfigNotifier.new),
          connectivityStatusProvider.overrideWith((ref) => conn.stream),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
  }

  // Push a connectivity state and let it propagate through the debounce (400ms).
  // Two plain pumps deliver the stream event + fire the provider listener (which
  // schedules the debounce timer) BEFORE the timed pump fires that timer.
  Future<void> settle(WidgetTester tester, AppConnectivityStatus s) async {
    conn.add(s);
    await tester.pump(); // deliver stream event
    await tester.pump(); // provider change → listener → schedule debounce timer
    await tester.pump(const Duration(milliseconds: 450)); // fire debounce
    await tester.pump(); // build frame with the new banner state
  }

  Finder banner() => find.byKey(const Key('summary_offline_banner'));

  testWidgets('no false flash at entry (unresolved → treated online)',
      (tester) async {
    await pump(tester); // stream not yet emitted → online default
    expect(banner(), findsNothing);
    expect(named(AnalyticsEvents.captureSummaryOfflineBannerShown), isEmpty);
  });

  testWidgets('offline → banner appears live + shown event (edge only)',
      (tester) async {
    await pump(tester);
    await settle(tester, AppConnectivityStatus.online);
    expect(banner(), findsNothing);

    await settle(tester, AppConnectivityStatus.offline);
    expect(banner(), findsOneWidget);
    expect(find.textContaining('offline'), findsWidgets);
    expect(named(AnalyticsEvents.captureSummaryOfflineBannerShown), hasLength(1));

    // Extra rebuilds while offline do NOT re-fire the shown event.
    await tester.pump();
    await tester.pump();
    expect(named(AnalyticsEvents.captureSummaryOfflineBannerShown), hasLength(1));
  });

  testWidgets('reconnect → banner hides automatically', (tester) async {
    await pump(tester);
    await settle(tester, AppConnectivityStatus.offline);
    expect(banner(), findsOneWidget);

    await settle(tester, AppConnectivityStatus.online);
    expect(banner(), findsNothing);
  });

  testWidgets('rapid flapping → no flicker, single shown event', (tester) async {
    await pump(tester);
    // Flap in quick succession (each pump ~0ms, well inside the 400ms debounce),
    // so the timer keeps restarting and only the settled state applies.
    conn.add(AppConnectivityStatus.offline);
    await tester.pump();
    conn.add(AppConnectivityStatus.online);
    await tester.pump();
    conn.add(AppConnectivityStatus.offline);
    await tester.pump();
    await tester.pump(); // ensure the final listener fired → debounce (re)scheduled

    // Before the debounce elapses: no banner, no event.
    await tester.pump(const Duration(milliseconds: 100));
    expect(banner(), findsNothing);
    expect(named(AnalyticsEvents.captureSummaryOfflineBannerShown), isEmpty);

    // After it elapses: settled on the final (offline) value → one shown event.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(banner(), findsOneWidget);
    expect(named(AnalyticsEvents.captureSummaryOfflineBannerShown), hasLength(1));
  });

  testWidgets('Upload while offline → blocked (snack + event, no nav)',
      (tester) async {
    await pump(tester);
    await settle(tester, AppConnectivityStatus.offline);

    await tester.tap(find.byKey(const Key('summary_upload')));
    await tester.pump();

    // Did NOT navigate into a guaranteed-to-fail upload.
    expect(find.text('UPLOADING'), findsNothing);
    expect(find.text('Capture summary'), findsOneWidget);
    expect(find.byKey(const Key('summary_offline_snack')), findsOneWidget);
    expect(named(AnalyticsEvents.captureSummaryProceedBlockedOffline),
        hasLength(1));
    expect(named(AnalyticsEvents.captureSummaryProceedToUpload), isEmpty);
  });

  testWidgets('back online → Upload proceeds normally', (tester) async {
    await pump(tester);
    await settle(tester, AppConnectivityStatus.offline);
    await settle(tester, AppConnectivityStatus.online);

    await tester.tap(find.byKey(const Key('summary_upload')));
    await tester.pumpAndSettle();
    expect(find.text('UPLOADING'), findsOneWidget);
    expect(named(AnalyticsEvents.captureSummaryProceedToUpload), hasLength(1));
  });
}
