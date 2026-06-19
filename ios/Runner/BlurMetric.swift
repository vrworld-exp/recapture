import Foundation

/// Pure, framework-free blur metric: variance of the Laplacian on a grayscale
/// image downscaled to a fixed 640px width — a line-for-line Swift port of the
/// Android `BlurMetric` (Kotlin), so iOS scores are numerically comparable and
/// share the same threshold/policy. Higher variance = sharper; lower = blurrier.
///
/// Two correctness anchors (mirroring Android, see docs/camera/blur-detection.md):
///  - **Grayscale is the luma (Y) plane** — for the camera's YUV biplanar frames
///    plane 0 IS grayscale (no YUV→RGB), but it is padded, so it MUST be read by
///    `rowStride`/`pixelStride`, never as a contiguous `width×height` buffer.
///  - **Downscale to 640px width first** — the raw Laplacian variance scales with
///    resolution; normalizing every frame to one width makes a single threshold
///    valid across source resolutions/devices. Aspect ratio is preserved.
///
/// No Flutter/AVFoundation imports — operates on a `[UInt8]` luma plane + strides,
/// so the stride handling, downscale, and variance are independently unit-testable.
enum BlurMetric {

  /// Normalization width; the threshold is tuned at this scale.
  static let defaultTargetWidth = 640

  /// Default sharp/blurry cutoff at 640px width. The ABSOLUTE value is
  /// content-sensitive (low-texture/dark scenes score low even in focus), so it is
  /// a tunable default, not a universal constant.
  static let defaultThreshold = 100.0

  /// An 8-bit contiguous grayscale image (luma 0..255).
  struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]
  }

  /// Stride-correct nearest-neighbour downscale of a YUV **Y (luma) plane** to
  /// [targetWidth] (aspect preserved). Reads the source by [rowStride]/[pixelStride]
  /// (padding-safe), center-sampling each destination pixel. Sources at or below
  /// [targetWidth] are NOT upscaled (so the metric is never inflated by interpolation).
  static func downscaleLuma(
    _ src: [UInt8],
    srcWidth: Int,
    srcHeight: Int,
    rowStride: Int,
    pixelStride: Int,
    targetWidth: Int = defaultTargetWidth
  ) -> GrayImage {
    precondition(srcWidth > 0 && srcHeight > 0, "Source dimensions must be positive.")
    let outW = srcWidth <= targetWidth ? srcWidth : targetWidth
    let outH = max(1, Int((Double(srcHeight) * Double(outW) / Double(srcWidth)).rounded()))
    var out = [UInt8](repeating: 0, count: outW * outH)
    for oy in 0..<outH {
      // Center-sample: map the destination pixel centre back to the source.
      let sy = min(max(Int((Double(oy) + 0.5) * Double(srcHeight) / Double(outH)), 0), srcHeight - 1)
      let rowBase = sy * rowStride
      let outBase = oy * outW
      for ox in 0..<outW {
        let sx = min(max(Int((Double(ox) + 0.5) * Double(srcWidth) / Double(outW)), 0), srcWidth - 1)
        let idx = rowBase + sx * pixelStride
        out[outBase + ox] = idx >= 0 && idx < src.count ? src[idx] : 0
      }
    }
    return GrayImage(width: outW, height: outH, pixels: out)
  }

  /// Variance of a 3×3 4-connected Laplacian (`[[0,1,0],[1,-4,1],[0,1,0]]`) over
  /// the interior of [gray]. Returns 0 for images too small to have an interior
  /// (a uniform image also yields ~0 → classified blurry, as expected).
  static func laplacianVariance(_ gray: GrayImage) -> Double {
    let w = gray.width
    let h = gray.height
    if w < 3 || h < 3 { return 0.0 }
    let p = gray.pixels
    var sum = 0.0
    var sumSq = 0.0
    var n = 0
    for y in 1..<(h - 1) {
      let row = y * w
      for x in 1..<(w - 1) {
        let i = row + x
        let center = Int(p[i])
        let up = Int(p[i - w])
        let down = Int(p[i + w])
        let left = Int(p[i - 1])
        let right = Int(p[i + 1])
        let lap = Double(up + down + left + right - 4 * center)
        sum += lap
        sumSq += lap * lap
        n += 1
      }
    }
    if n == 0 { return 0.0 }
    let mean = sum / Double(n)
    return (sumSq / Double(n)) - (mean * mean)
  }
}
