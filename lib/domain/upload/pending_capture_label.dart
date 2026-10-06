// lib/domain/upload/pending_capture_label.dart
//
// Pure Dart — NO Flutter / IO. WHICH label a capture waiting on the phone shows
// on its project card, and which actions go with it (offline capture, Step
// C1/C4). One decision, made here and unit-tested; the widget that draws it
// (presentation/widgets/pending_capture_card_parts.dart) maps each kind to copy,
// colour tokens and buttons and decides nothing.
//
//   kind               label                                   actions
//   savedOffline       Saved on phone · Not uploaded           Upload now (disabled offline)
//   waitingWifi        Waiting for Wi-Fi                       Upload now (→ mobile-data confirm)
//   queued             Waiting to upload                       Upload now
//   waitingConnection  Waiting for connection                  Upload now (re-probe)
//   uploading          Uploading {pct}%                        Pause
//   paused             Paused                                  Resume
//   failed             Upload failed · {short reason}          Retry
//   planLimit          Plan limit reached — upgrade to upload  Retry
//   projectMissing     This project no longer exists           Delete · Upload as new project
//   filesMissing       Capture files are missing on this phone Delete
//   needsLogin         Log in again to upload                  Log in
import 'auto_upload_policy.dart';
import 'pending_capture.dart';

enum PendingLabelKind {
  savedOffline,
  waitingWifi,
  queued,
  waitingConnection,
  uploading,
  paused,
  failed,
  planLimit,
  projectMissing,
  filesMissing,
  needsLogin,
}

/// The actions a card can offer for a pending capture.
enum PendingCardAction { uploadNow, pause, resume, retry, delete, uploadAsNew, logIn }

/// Failure codes the label distinguishes. Mirrors `PendingFailureCodes`
/// (application layer) — kept as literals so the domain imports nothing above
/// it; `pending_capture_label_test.dart` pins the two together.
const String kFailureFilesMissing = 'FILES_MISSING';
const String kFailureProjectNotFound = 'PROJECT_NOT_FOUND';
const String kFailurePlanLimit = 'PLAN_LIMIT';
const String kFailureWaitingWifi = 'WAITING_WIFI';

/// The label for [capture]. Returns null for an [PendingCaptureState.uploaded]
/// record — the card shows the normal server status from then on.
PendingLabelKind? pendingLabelFor(
  PendingCapture capture, {
  required UploadNetwork network,
  required AutoUploadSettings settings,
  required bool isActive,
  required bool needsLogin,
}) {
  if (capture.state == PendingCaptureState.uploaded) return null;

  if (capture.state == PendingCaptureState.failed) {
    return switch (capture.lastErrorCode) {
      kFailureFilesMissing => PendingLabelKind.filesMissing,
      kFailureProjectNotFound => PendingLabelKind.projectMissing,
      kFailurePlanLimit => PendingLabelKind.planLimit,
      _ => PendingLabelKind.failed,
    };
  }
  if (needsLogin) return PendingLabelKind.needsLogin;
  if (capture.userPaused) return PendingLabelKind.paused;

  if (isActive) {
    if (capture.lastErrorCode == kFailureWaitingWifi) {
      return PendingLabelKind.waitingWifi;
    }
    return network == UploadNetwork.none
        ? PendingLabelKind.waitingConnection
        : PendingLabelKind.uploading;
  }

  if (network == UploadNetwork.none) {
    return capture.state == PendingCaptureState.savedLocal
        ? PendingLabelKind.savedOffline
        : PendingLabelKind.waitingConnection;
  }
  if (isWaitingForWifi(capture, network, settings)) {
    return PendingLabelKind.waitingWifi;
  }
  return capture.state == PendingCaptureState.waitingNetwork &&
          capture.lastErrorCode != null
      ? PendingLabelKind.waitingConnection // a failed reach → backing off
      : PendingLabelKind.queued;
}

/// The actions for [kind], primary first.
List<PendingCardAction> pendingActionsFor(PendingLabelKind kind) =>
    switch (kind) {
      PendingLabelKind.savedOffline ||
      PendingLabelKind.waitingWifi ||
      PendingLabelKind.queued ||
      PendingLabelKind.waitingConnection =>
        const [PendingCardAction.uploadNow],
      PendingLabelKind.uploading => const [PendingCardAction.pause],
      PendingLabelKind.paused => const [PendingCardAction.resume],
      PendingLabelKind.failed ||
      PendingLabelKind.planLimit =>
        const [PendingCardAction.retry],
      PendingLabelKind.projectMissing => const [
          PendingCardAction.delete,
          PendingCardAction.uploadAsNew,
        ],
      PendingLabelKind.filesMissing => const [PendingCardAction.delete],
      PendingLabelKind.needsLogin => const [PendingCardAction.logIn],
    };
