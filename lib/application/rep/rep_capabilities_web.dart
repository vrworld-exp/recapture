// lib/application/rep/rep_capabilities_web.dart
//
// Browser rep capabilities.
//
// SCAN is TRUE. It used to be false for want of a decoder, and the note here
// said this was "the half that could change one day" — this is that day.
// `mobile_scanner` ships a first-party web implementation
// (`MobileScannerWeb`), so the browser gets the same scanner screen the phone
// does, from the same Dart call site. It needs a secure origin: `localhost` and
// any https:// deployment qualify, and a plain-http origin lands in the
// scanner's own "cannot open a scanner" state with manual entry one tap away.
//
// CAPTURE is TRUE, and it is NOT the same pipeline as the phone's — read
// web_dish_capture.dart before assuming parity of mechanism. The browser has
// `getUserMedia` and nothing else: no exposure channel, no blur channel, no IMU
// rotation feed, no background upload session. Every one of those is a
// `MethodChannel` with no web implementation, and the 6-photo RING is built on
// the IMU specifically — it fills by yaw segment as the rep walks around the
// dish.
//
// A LAPTOP HAS NO GYROSCOPE, so the ring cannot be ported; it can only be
// replaced. The web flow therefore takes the same six photos under manual
// control, hands them to the same upload and the same 3D generation, and says
// plainly on screen that the guidance is not there. The OUTPUT is at parity —
// a rep on a laptop can produce a real AR dish — while the guided experience
// remains a phone feature, which is the honest version of that claim.
const bool kCanScanQrCode = true;
const bool kCanCaptureDish = true;
