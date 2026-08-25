// lib/application/capture/ledger/photo_rejection_reason.dart
//
// Why a capture attempt was rejected and excluded from a LevelCaptureLedger's
// accepted list. Grounded on the real pipeline: `overlap` corresponds to the ring
// engine's [RejectAlreadyFilled] decision (segment_capture_decision.dart), `blur`
// to a BlurBand.reject, `motion` to the stability gate being shut.
enum PhotoRejectionReason {
  /// Blur classified into BlurBand.reject (too soft).
  blur,

  /// The stability gate was not open at shutter-fire time (device moving).
  motion,

  /// RingCoverageEngine.evaluateCapture returned RejectAlreadyFilled — the
  /// target segment already holds an accepted photo (overlap enforcement).
  overlap,
}
