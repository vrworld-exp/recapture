// lib/domain/upload/auto_upload_policy.dart
//
// Pure Dart — NO Flutter / IO. WHEN a capture waiting on the phone may upload.
// The one place this rule lives (offline capture, Step B3):
//
//   | Capture | Wi-Fi | Mobile data                                   |
//   |---------|-------|-----------------------------------------------|
//   | Meshy   | auto  | auto                                          |
//   | Full    | auto  | only if "Upload on mobile data" is ON         |
//
// A tap on "Upload now" overrides the Wi-Fi rule (after a size confirm on
// mobile data for a Full capture), and that yes holds for the rest of that
// capture's upload ([PendingCapture.mobileDataApproved]). No network, no upload.
//
// Product assumption (README "Assumptions"): auto-upload is ON. Making uploads
// manual-only is a change to [canAutoUpload] alone.
import 'pending_capture.dart';

/// The network as the policy sees it. Mirrors `AppNetworkType` without
/// importing the platform layer into the domain.
enum UploadNetwork { unmetered, metered, none }

/// The device-local upload preferences the policy reads.
class AutoUploadSettings {
  const AutoUploadSettings({this.uploadOnMobileData = false});

  /// "Upload on mobile data" — defaults to OFF.
  final bool uploadOnMobileData;
}

/// Whether [capture] may use [network] at all, ignoring who asked.
bool _networkAllowed(
  PendingCapture capture,
  UploadNetwork network,
  AutoUploadSettings settings,
) {
  switch (network) {
    case UploadNetwork.none:
      return false;
    case UploadNetwork.unmetered:
      return true;
    case UploadNetwork.metered:
      return capture.isMeshy ||
          settings.uploadOnMobileData ||
          capture.mobileDataApproved;
  }
}

/// May the app start (or keep running) [capture]'s upload ON ITS OWN?
bool canAutoUpload(
  PendingCapture capture,
  UploadNetwork network,
  AutoUploadSettings settings,
) =>
    _networkAllowed(capture, network, settings);

/// Does an "Upload now" tap on [capture] need the "Use mobile data?" confirm
/// first? True only for a Full capture on mobile data that the setting and an
/// earlier confirm do not already cover.
bool needsMobileDataConfirm(
  PendingCapture capture,
  UploadNetwork network,
  AutoUploadSettings settings,
) =>
    network == UploadNetwork.metered &&
    !_networkAllowed(capture, network, settings);

/// Is [capture] held back ONLY by the Wi-Fi rule — i.e. it would upload on
/// Wi-Fi, there is a network, and that network is mobile data? Drives the
/// "Waiting for Wi-Fi" label.
bool isWaitingForWifi(
  PendingCapture capture,
  UploadNetwork network,
  AutoUploadSettings settings,
) =>
    needsMobileDataConfirm(capture, network, settings);
