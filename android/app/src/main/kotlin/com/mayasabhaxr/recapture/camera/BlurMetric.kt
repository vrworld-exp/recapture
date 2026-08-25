// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/BlurMetric.kt
package com.mayasabhaxr.recapture.camera

import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Pure, framework-free blur metric: variance of the Laplacian on a grayscale image
 * downscaled to a fixed 640px width. Higher variance = sharper; lower = blurrier.
 *
 * Two correctness anchors (see docs/camera/blur-detection.md):
 *  - **Grayscale is the luma (Y) plane** — for YUV_420_888 the Y plane IS
 *    grayscale (no YUV→RGB conversion), but it is padded, so it MUST be read by
 *    `rowStride`/`pixelStride`, never as a contiguous `width×height` buffer.
 *  - **Downscale to 640px width first** — the raw Laplacian variance scales with
 *    resolution; normalizing every frame to one width makes a single threshold
 *    valid across source resolutions/devices. Aspect ratio is preserved.
 *
 * Free of Android runtime classes (operates on a `ByteArray` luma plane + strides),
 * so the stride handling, downscale, and variance are JVM-unit-testable — mirroring
 * the sensor tasks' pure helpers.
 */
object BlurMetric {

    /** Normalization width; the threshold is tuned at this scale. */
    const val DEFAULT_TARGET_WIDTH = 640

    /**
     * Default sharp/blurry cutoff at 640px width. The ABSOLUTE value is
     * content-sensitive (low-texture/dark scenes score low even in focus), so it is
     * a tunable default, not a universal constant. See the doc.
     */
    const val DEFAULT_THRESHOLD = 100.0

    /** An 8-bit contiguous grayscale image (luma 0..255 stored as signed bytes). */
    class GrayImage(val width: Int, val height: Int, val pixels: ByteArray)

    /** Sharpness score + decision for one frame (frame association added by caller). */
    data class BlurAnalysis(
        val sharpnessScore: Double,
        val sharp: Boolean,
        val width: Int,
        val height: Int,
    )

    /**
     * Stride-correct nearest-neighbour downscale of a YUV **Y (luma) plane** to
     * [targetWidth] (aspect preserved). Reads the source by [rowStride]/[pixelStride]
     * (padding-safe) — center-sampling each destination pixel. Sources at or below
     * [targetWidth] are NOT upscaled (kept at source width, so the metric is never
     * inflated by interpolation).
     */
    fun downscaleLuma(
        src: ByteArray,
        srcWidth: Int,
        srcHeight: Int,
        rowStride: Int,
        pixelStride: Int,
        targetWidth: Int = DEFAULT_TARGET_WIDTH,
    ): GrayImage {
        require(srcWidth > 0 && srcHeight > 0) { "Source dimensions must be positive." }
        val outW = if (srcWidth <= targetWidth) srcWidth else targetWidth
        val outH = max(1, (srcHeight.toDouble() * outW / srcWidth).roundToInt())
        val out = ByteArray(outW * outH)
        for (oy in 0 until outH) {
            // Center-sample: map the destination pixel centre back to the source.
            val sy = (((oy + 0.5) * srcHeight / outH).toInt()).coerceIn(0, srcHeight - 1)
            val rowBase = sy * rowStride
            val outBase = oy * outW
            for (ox in 0 until outW) {
                val sx = (((ox + 0.5) * srcWidth / outW).toInt()).coerceIn(0, srcWidth - 1)
                val idx = rowBase + sx * pixelStride
                out[outBase + ox] = if (idx in src.indices) src[idx] else 0
            }
        }
        return GrayImage(outW, outH, out)
    }

    /**
     * Variance of a 3×3 4-connected Laplacian (`[[0,1,0],[1,-4,1],[0,1,0]]`) over
     * the interior of [gray]. Returns 0 for images too small to have an interior
     * (a uniform image also yields ~0 → classified blurry, as expected).
     */
    fun laplacianVariance(gray: GrayImage): Double {
        val w = gray.width
        val h = gray.height
        if (w < 3 || h < 3) return 0.0
        val p = gray.pixels
        var sum = 0.0
        var sumSq = 0.0
        var n = 0L
        for (y in 1 until h - 1) {
            val row = y * w
            for (x in 1 until w - 1) {
                val i = row + x
                val center = p[i].toInt() and 0xFF
                val up = p[i - w].toInt() and 0xFF
                val down = p[i + w].toInt() and 0xFF
                val left = p[i - 1].toInt() and 0xFF
                val right = p[i + 1].toInt() and 0xFF
                val lap = (up + down + left + right - 4 * center).toDouble()
                sum += lap
                sumSq += lap * lap
                n++
            }
        }
        if (n == 0L) return 0.0
        val mean = sum / n
        return (sumSq / n) - (mean * mean)
    }

    /**
     * Full pipeline from a strided Y plane → sharpness score + sharp/blurry decision
     * (`sharp = variance >= threshold`), computed at [targetWidth].
     */
    fun analyze(
        src: ByteArray,
        srcWidth: Int,
        srcHeight: Int,
        rowStride: Int,
        pixelStride: Int,
        threshold: Double = DEFAULT_THRESHOLD,
        targetWidth: Int = DEFAULT_TARGET_WIDTH,
    ): BlurAnalysis {
        val gray = downscaleLuma(src, srcWidth, srcHeight, rowStride, pixelStride, targetWidth)
        val variance = laplacianVariance(gray)
        return BlurAnalysis(
            sharpnessScore = variance,
            sharp = variance >= threshold,
            width = gray.width,
            height = gray.height,
        )
    }
}
