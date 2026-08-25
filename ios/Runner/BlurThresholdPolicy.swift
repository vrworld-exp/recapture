import Foundation

/// Three-band classification of a sharpness score (variance of Laplacian from
/// `BlurMetric`) into an actionable band — a Swift port of the Android
/// `BlurThresholdPolicy`, so the wire form and band boundaries match exactly.
enum BlurBand: String {
  /// Too blurry — don't use the frame.
  case reject
  /// Borderline — usable but flagged; the capture flow decides.
  case warn
  /// Sharp enough — use the frame.
  case accept

  /// Lowercase wire form for the channel payload (`reject`/`warn`/`accept`).
  var wire: String { rawValue }
}

/// Holds validated thresholds and classifies scores against them (value type —
/// replaced wholesale on a threshold update, so reads are consistent).
struct BlurThresholdPolicy {

  static let defaultRejectBelow = 40.0
  static let defaultAcceptAbove = 80.0

  let rejectBelow: Double
  let acceptAbove: Double

  /// Builds a validated policy. A non-finite input falls back to the per-field
  /// default; an INVERTED pair (`rejectBelow > acceptAbove`) falls back to BOTH
  /// defaults. `rejectBelow == acceptAbove` is allowed (empty WARN → binary).
  init(rejectBelow: Double? = nil, acceptAbove: Double? = nil) {
    let r = (rejectBelow.map { $0.isFinite } == true) ? rejectBelow! : Self.defaultRejectBelow
    let a = (acceptAbove.map { $0.isFinite } == true) ? acceptAbove! : Self.defaultAcceptAbove
    if r <= a {
      self.rejectBelow = r
      self.acceptAbove = a
    } else {
      self.rejectBelow = Self.defaultRejectBelow
      self.acceptAbove = Self.defaultAcceptAbove
    }
  }

  /// `score < rejectBelow` → reject; `score > acceptAbove` → accept; else warn
  /// (so exactly [rejectBelow] and [acceptAbove] are warn). Non-finite fails safe
  /// to reject — never accept.
  func classify(_ score: Double) -> BlurBand {
    if !score.isFinite { return .reject }
    if score < rejectBelow { return .reject }
    if score > acceptAbove { return .accept }
    return .warn
  }
}
