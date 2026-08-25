// android/app/src/test/kotlin/com/mayasabhaxr/recapture/camera/BlurMetricTest.kt
package com.mayasabhaxr.recapture.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM unit tests for the blur metric: stride-correct Y-plane downscale,
 * aspect handling / no-upscale, the Laplacian variance (uniform vs textured), and
 * resolution-independence of the 640px-normalized score + the threshold decision.
 * No device / Robolectric.
 */
class BlurMetricTest {

    // ── stride-correct luma extraction ────────────────────────────────────────

    @Test
    fun downscale_readsPaddedYPlaneByStride() {
        // 4×2 image stored with rowStride=8 (4 bytes of padding per row), pixelStride=1.
        // Reading it as a contiguous 4×2 buffer would pull the padding as pixels.
        val src = byteArrayOf(
            10, 20, 30, 40, /*pad*/ 99, 99, 99, 99,
            50, 60, 70, 80, /*pad*/ 99, 99, 99, 99,
        )
        val gray = BlurMetric.downscaleLuma(src, srcWidth = 4, srcHeight = 2, rowStride = 8, pixelStride = 1, targetWidth = 4)
        assertEquals(4, gray.width)
        assertEquals(2, gray.height)
        // No upscale at targetWidth==srcWidth → exact pixels, no padding leaked in.
        assertEquals(listOf(10, 20, 30, 40, 50, 60, 70, 80), gray.pixels.map { it.toInt() and 0xFF })
    }

    @Test
    fun downscale_respectsPixelStride() {
        // pixelStride=2: every other byte is the real luma sample.
        val src = byteArrayOf(10, 0, 20, 0, 30, 0, 40, 0)
        val gray = BlurMetric.downscaleLuma(src, srcWidth = 4, srcHeight = 1, rowStride = 8, pixelStride = 2, targetWidth = 4)
        assertEquals(listOf(10, 20, 30, 40), gray.pixels.map { it.toInt() and 0xFF })
    }

    @Test
    fun downscale_toWidth640PreservesAspect() {
        val gray = BlurMetric.downscaleLuma(ByteArray(1280 * 720), 1280, 720, 1280, 1, targetWidth = 640)
        assertEquals(640, gray.width)
        assertEquals(360, gray.height) // 720 × 640/1280
    }

    @Test
    fun downscale_doesNotUpscaleSmallSources() {
        val gray = BlurMetric.downscaleLuma(ByteArray(320 * 240), 320, 240, 320, 1, targetWidth = 640)
        assertEquals(320, gray.width) // not upscaled to 640 (would inflate the metric)
        assertEquals(240, gray.height)
    }

    // ── Laplacian variance ────────────────────────────────────────────────────

    @Test
    fun variance_uniformImageIsZero() {
        val gray = BlurMetric.GrayImage(10, 10, ByteArray(100) { 128.toByte() })
        assertEquals(0.0, BlurMetric.laplacianVariance(gray), 1e-9)
    }

    @Test
    fun variance_texturedImageIsHigh() {
        // 1px checkerboard = maximal high-frequency content → large variance.
        val w = 16
        val h = 16
        val px = ByteArray(w * h) { i ->
            val x = i % w
            val y = i / w
            (if ((x + y) % 2 == 0) 255 else 0).toByte()
        }
        val variance = BlurMetric.laplacianVariance(BlurMetric.GrayImage(w, h, px))
        assertTrue("checkerboard variance should be large, was $variance", variance > 10_000.0)
    }

    @Test
    fun variance_sharpEdgeBeatsBlurredEdge() {
        // A hard step edge vs the same edge blurred over a few columns: sharp wins.
        val w = 32
        val h = 8
        val sharp = ByteArray(w * h) { i -> (if ((i % w) < w / 2) 0 else 255).toByte() }
        val blurred = ByteArray(w * h) { i ->
            val x = i % w
            // Linear ramp across the middle 8 columns (a soft edge).
            val v = when {
                x < w / 2 - 4 -> 0
                x > w / 2 + 4 -> 255
                else -> ((x - (w / 2 - 4)) * 255 / 8)
            }
            v.toByte()
        }
        val vs = BlurMetric.laplacianVariance(BlurMetric.GrayImage(w, h, sharp))
        val vb = BlurMetric.laplacianVariance(BlurMetric.GrayImage(w, h, blurred))
        assertTrue("sharp ($vs) should exceed blurred ($vb)", vs > vb)
    }

    // ── resolution independence (the 640px normalization payoff) ──────────────

    @Test
    fun analyze_resolutionIndependentAfterDownscale() {
        // Same scene at 1× (640) and 2× (1280, pixel-doubled). After both downscale
        // to 640, the score must match — proving the threshold is resolution-stable.
        val w = 640
        val h = 8
        fun pattern(x: Int) = (if ((x / 16) % 2 == 0) 200 else 40).toByte()
        val base = ByteArray(w * h) { i -> pattern(i % w) }

        val w2 = 1280
        val doubled = ByteArray(w2 * h) { i ->
            val x = i % w2
            pattern(x / 2) // each source column duplicated
        }

        val a = BlurMetric.analyze(base, w, h, rowStride = w, pixelStride = 1)
        val b = BlurMetric.analyze(doubled, w2, h, rowStride = w2, pixelStride = 1)
        assertEquals(640, a.width)
        assertEquals(640, b.width)
        assertEquals("score must be resolution-independent", a.sharpnessScore, b.sharpnessScore, 1e-6)
    }

    // ── threshold decision ────────────────────────────────────────────────────

    @Test
    fun analyze_decisionAgainstThreshold() {
        val w = 16
        val h = 16
        val textured = ByteArray(w * h) { i ->
            (if (((i % w) + (i / w)) % 2 == 0) 255 else 0).toByte()
        }
        val sharp = BlurMetric.analyze(textured, w, h, w, 1, threshold = 100.0)
        assertTrue(sharp.sharp)

        val uniform = ByteArray(w * h) { 128.toByte() }
        val blurry = BlurMetric.analyze(uniform, w, h, w, 1, threshold = 100.0)
        assertFalse(blurry.sharp)
        assertEquals(0.0, blurry.sharpnessScore, 1e-9)
    }

    @Test
    fun analyze_thresholdIsInclusive() {
        // sharp = variance >= threshold. With threshold 0 and a uniform (variance 0)
        // image, the decision is inclusively sharp.
        val gray = ByteArray(9 * 9) { 50.toByte() }
        assertTrue(BlurMetric.analyze(gray, 9, 9, 9, 1, threshold = 0.0).sharp)
    }
}
