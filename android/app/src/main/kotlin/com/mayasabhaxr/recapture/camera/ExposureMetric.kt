// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/ExposureMetric.kt
package com.mayasabhaxr.recapture.camera

/**
 * Pure, framework-free exposure metric: the **arithmetic mean of the luma (Y)
 * plane** — a frame's average brightness on the 0–255 scale. A frame-quality signal
 * parallel to [BlurMetric]: too dark / too bright warns the capture UI while the
 * user adjusts. It WARNS only; it never rejects a frame and never changes camera
 * exposure (that is the focus/exposure-lock task).
 *
 * Two anchors (see docs/camera/exposure-check.md):
 *  - **The Y plane IS luminance** — for YUV_420_888 the 8-bit Y values are
 *    luminance directly; no YUV→RGB conversion. It is padded, so it MUST be read by
 *    `rowStride`/`pixelStride` (see [BlurMetric.downscaleLuma]).
 *  - **The mean is scale-independent** — averaging does not change with resolution
 *    or subsampling, so this REUSES the blur task's already-downscaled 640px
 *    [BlurMetric.GrayImage] (one downscale, one frame pass for both metrics) and the
 *    40/220 thresholds stay valid regardless of the downscale.
 *
 * Operating on a [BlurMetric.GrayImage] keeps it JVM-unit-testable and guarantees a
 * single shared traversal with the blur metric.
 *
 * Known limitation: the MEAN can read OK on a high-contrast scene that clips in both
 * the shadows and the highlights (the bright and dark regions average to mid-grey).
 * Histogram/clipping analysis is a possible future refinement, out of scope here.
 */
object ExposureMetric {

    /**
     * Mean luminance of [gray] in `[0, 255]`. Returns `NaN` for an empty image
     * (no pixels) so the caller can emit an explicit "unknown" rather than silently
     * classifying a non-existent frame as OK — see [ExposureThresholdPolicy.classify].
     */
    fun meanLuminance(gray: BlurMetric.GrayImage): Double {
        val pixels = gray.pixels
        if (pixels.isEmpty()) return Double.NaN
        var sum = 0L
        for (b in pixels) sum += (b.toInt() and 0xFF)
        return sum.toDouble() / pixels.size
    }
}
