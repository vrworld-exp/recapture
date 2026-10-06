// test/upload/pending_capture_label_test.dart
//
// Offline capture, Stage C: the card label decision (every row of the C1
// table + C4), the C2 limits rule, and the 360 dp card / web rendering.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/offline_capture_capability.dart';
import 'package:recapture/application/upload/pending_captures_notifier.dart';
import 'package:recapture/application/upload/pending_upload_coordinator.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/domain/upload/auto_upload_policy.dart';
import 'package:recapture/domain/upload/offline_capture_limits.dart';
import 'package:recapture/domain/upload/pending_capture.dart';
import 'package:recapture/domain/upload/pending_capture_label.dart';
import 'package:recapture/presentation/screens/projects/pending_captures_ui.dart';
import 'package:recapture/presentation/widgets/pending_capture_card_parts.dart';
import 'package:recapture/presentation/widgets/project_card.dart';

PendingCapture cap({
  String mode = 'full',
  PendingCaptureState state = PendingCaptureState.savedLocal,
  String? code,
  bool paused = false,
  String projectId = 'p1',
}) {
  final at = DateTime.utc(2026, 10, 1);
  return PendingCapture(
    localId: 'l',
    projectId: projectId,
    ownerUserId: 'u',
    projectName: 'A rather long project name for a narrow phone card',
    objectSize: 'medium',
    captureMode: mode,
    flowVariant: 'with_bottom',
    frameCount: 48,
    byteCount: 200 * 1024 * 1024,
    state: state,
    capturedAt: at,
    updatedAt: at,
    bundleRelPath: 'b',
    perLevelCounts: const {'EYE': 48},
    lastErrorCode: code,
    userPaused: paused,
  );
}

PendingLabelKind? label(
  PendingCapture c, {
  UploadNetwork net = UploadNetwork.unmetered,
  bool active = false,
  bool login = false,
}) =>
    pendingLabelFor(c,
        network: net,
        settings: const AutoUploadSettings(),
        isActive: active,
        needsLogin: login);

void main() {
  group('pendingLabelFor — the C1 table', () {
    test('saved, offline → Saved on phone · Not uploaded', () {
      expect(label(cap(), net: UploadNetwork.none),
          PendingLabelKind.savedOffline);
    });
    test('saved, online on mobile data, Full → Waiting for Wi-Fi', () {
      expect(label(cap(), net: UploadNetwork.metered),
          PendingLabelKind.waitingWifi);
    });
    test('waitingNetwork, offline → Waiting for connection', () {
      expect(
          label(cap(state: PendingCaptureState.waitingNetwork),
              net: UploadNetwork.none),
          PendingLabelKind.waitingConnection);
    });
    test('the active upload → Uploading', () {
      expect(label(cap(state: PendingCaptureState.uploading), active: true),
          PendingLabelKind.uploading);
    });
    test('an active Full upload parked by the Wi-Fi rule → Waiting for Wi-Fi',
        () {
      expect(
          label(
              cap(
                  state: PendingCaptureState.waitingNetwork,
                  code: kFailureWaitingWifi),
              net: UploadNetwork.metered,
              active: true),
          PendingLabelKind.waitingWifi);
    });
    test('user-paused → Paused (wins over the network)', () {
      expect(label(cap(paused: true), net: UploadNetwork.none),
          PendingLabelKind.paused);
    });
    test('failed → Upload failed, with its specific variants', () {
      PendingLabelKind? f(String? c) =>
          label(cap(state: PendingCaptureState.failed, code: c));
      expect(f('server'), PendingLabelKind.failed);
      expect(f(kFailurePlanLimit), PendingLabelKind.planLimit);
      expect(f(kFailureProjectNotFound), PendingLabelKind.projectMissing);
      expect(f(kFailureFilesMissing), PendingLabelKind.filesMissing);
    });
    test('uploaded → no label (the server status shows)', () {
      expect(label(cap(state: PendingCaptureState.uploaded)), isNull);
    });
    test('C4: an auth stop → Log in again to upload', () {
      expect(label(cap(state: PendingCaptureState.waitingNetwork), login: true),
          PendingLabelKind.needsLogin);
    });
  });

  test('actions per label', () {
    expect(pendingActionsFor(PendingLabelKind.savedOffline),
        [PendingCardAction.uploadNow]);
    expect(pendingActionsFor(PendingLabelKind.uploading),
        [PendingCardAction.pause]);
    expect(pendingActionsFor(PendingLabelKind.paused),
        [PendingCardAction.resume]);
    expect(pendingActionsFor(PendingLabelKind.failed),
        [PendingCardAction.retry]);
    expect(pendingActionsFor(PendingLabelKind.projectMissing),
        [PendingCardAction.delete, PendingCardAction.uploadAsNew]);
    // Files gone: Delete only — a retry could never succeed.
    expect(pendingActionsFor(PendingLabelKind.filesMissing),
        [PendingCardAction.delete]);
  });

  test('the domain failure literals match the coordinator codes', () {
    expect(kFailureFilesMissing, PendingFailureCodes.filesMissing);
    expect(kFailureProjectNotFound, PendingFailureCodes.projectNotFound);
    expect(kFailurePlanLimit, PendingFailureCodes.planLimit);
    expect(kFailureWaitingWifi, PendingFailureCodes.waitingForWifi);
  });

  group('offlineCaptureBlock — C2', () {
    test('online never blocks', () {
      expect(
          offlineCaptureBlock(
              online: true, pendingCount: 99, modeId: 'full', freeBytes: 1),
          isNull);
    });
    test('the 6th offline capture is blocked', () {
      expect(
          offlineCaptureBlock(
              online: false,
              pendingCount: kMaxPendingCapturesPerUser,
              modeId: 'meshy',
              freeBytes: null),
          OfflineCaptureBlock.tooManyPending);
      expect(
          offlineCaptureBlock(
              online: false,
              pendingCount: kMaxPendingCapturesPerUser - 1,
              modeId: 'meshy',
              freeBytes: null),
          isNull);
    });
    test('low storage blocks; 1.5 × the per-mode estimate is enough', () {
      final need = requiredFreeBytesFor('full');
      expect(need, (350 * 1024 * 1024 * 1.5).ceil());
      expect(
          offlineCaptureBlock(
              online: false, pendingCount: 0, modeId: 'full', freeBytes: need - 1),
          OfflineCaptureBlock.lowStorage);
      expect(
          offlineCaptureBlock(
              online: false, pendingCount: 0, modeId: 'full', freeBytes: need),
          isNull);
    });
    test('an unknown free-space answer never blocks', () {
      expect(
          offlineCaptureBlock(
              online: false, pendingCount: 0, modeId: 'full', freeBytes: null),
          isNull);
    });
  });

  test('a waiting capture whose project the list lost still gets a row', () {
    final merged = mergeProjectsWithPending(
      [
        Project(
            id: 'srv',
            name: 'S',
            status: ProjectStatus.completed,
            updatedAt: DateTime.utc(2026)),
      ],
      [cap(projectId: 'pending_9')],
    );
    expect(merged.map((p) => p.id), ['pending_9', 'srv']);
  });

  testWidgets('pending card at 360 dp: wraps, never overflows', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final kind in PendingLabelKind.values) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProjectCard(
              project: Project(
                id: 'p1',
                name: 'A rather long project name for a narrow phone card',
                status: ProjectStatus.draft,
                updatedAt: DateTime.utc(2026),
              ),
              onResume: (_) {},
              onView: (_) {},
              onRetry: (_) {},
              onMore: (_) {},
              pendingPill: PendingCardPill(kind: kind, percent: 42),
              pendingActions: PendingCardActions(
                kind: kind,
                percent: 42,
                reason: 'Server problem',
                onAction: (_) {},
              ),
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull, reason: 'overflow for $kind');
      expect(find.byKey(const Key('pending_sentence')), findsOneWidget);
    }
  });

  testWidgets('web (no capability): no pending strip', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        offlineCaptureCapabilityProvider.overrideWithValue(false),
        currentUserIdProvider.overrideWithValue('u'),
      ],
      child: const MaterialApp(home: Scaffold(body: PendingCapturesStrip())),
    ));
    expect(find.byKey(const Key('pending_strip')), findsNothing);
  });
}
