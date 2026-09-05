// lib/application/rep/rep_capabilities_web.dart
//
// Browser rep capabilities. Both false, for two DIFFERENT reasons — worth
// keeping distinct, because only one of them could ever change.
//
// CAPTURE is false because a browser HAS NO CAPTURE PIPELINE. Not "no camera":
// `getUserMedia` exists. What does not exist is the rest of it — the exposure
// and stability channels, the IMU rotation feed, the permission channels, the
// background upload session. The 6-photo ring is built on all of them
// (lib/platform/*_channel.dart), and every one is a `MethodChannel` with no web
// implementation. This is a platform limit, not a decision, and it is the ONE
// genuine functional difference between the targets.
//
// SCAN is false for the same reason it is false on `_io`: no decoder package,
// and the OS camera plus note J's activation link already covers it. In
// principle `getUserMedia` plus a decoder would work here — so this is the half
// that could change one day, which is exactly why it is not merged with the
// line above.
//
// A rep on a laptop can activate a code, author the whole menu as image-only
// dishes or from finished captures, and publish. They cannot photograph a dish.
// The screen says so; it does not offer a button that fails.
const bool kCanScanQrCode = false;
const bool kCanCaptureDish = false;

Future<String?> scanQrCode() =>
    throw UnsupportedError('No camera scanner in the browser build.');
