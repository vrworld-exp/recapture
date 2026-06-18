// android/app/src/test/kotlin/com/mayasabhaxr/recapture/camera/ExposureMetricTest.kt
package com.mayasabhaxr.recapture.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM unit tests for the mean-luminance metric: correct averaging on
 * dark/mid/bright buffers, scale-independence (the mean survives downscaling), the
 * single-pass reuse of the blur task's stride-correct [BlurMetric.GrayImage] (so
 * padding never skews the mean), and the empty-frame NaN guard. No device.
 */
class ExposureMetricTest {

    @Test
    fun mean_uniformBuffersMatchTheValue() {
        assertEquals(0.0, ExposureMetric.meanLuminance(BlurMetric.GrayImage(8, 8, ByteArray(64) { 0 })), 1e-9)
        assertEquals(128.0, ExposureMetric.meanLuminance(BlurMetric.GrayImage(8, 8, ByteArray(64) { 128.toByte() })), 1e-9)
        // 255 stored as a signed byte (-1) must read back as 255 (unsigned).
        assertEquals(255.0, ExposureMetric.meanLuminance(BlurMetric.GrayImage(8, 8, ByteArray(64) { 255.toByte() })), 1e-9)
    }

    @Test
    fun mean_mixedValuesAverageCorrectly() {
        // Half black, half white → mean 127.5.
        val px = ByteArray(100) { i -> (if (i < 50) 0 else 255).toByte() }
        assertEquals(127.5, ExposureMetric.meanLuminance(BlurMetric.GrayImage(10, 10, px)), 1e-9)
    }

    @Test
    fun mean_isScaleIndependentAfterDownscale() {
        // Same scene at 1× and 2× (pixel-doubled). After both downscale to 640px the
        // mean must match — proving the 40/220 thresholds hold regardless of source
        // resolution.
        val w = 640
        val h = 8
        fun pattern(x: Int) = (if ((x / 16) % 2 == 0) 200 else 40).toByte()
        val base = ByteArray(w * h) { i -> pattern(i % w) }
        val w2 = 1280
        val doubled = ByteArray(w2 * h) { i -> pattern((i % w2) / 2) }

        val a = ExposureMetric.meanLuminance(
            BlurMetric.downscaleLuma(base, w, h, rowStride = w, pixelStride = 1),
        )
        val b = ExposureMetric.meanLuminance(
            BlurMetric.downscaleLuma(doubled, w2, h, rowStride = w2, pixelStride = 1),
        )
        assertEquals("mean must be resolution-independent", a, b, 1e-6)
        assertTrue("mid pattern averages ~120", a in 100.0..140.0)
    }

    @Test
    fun mean_ignoresRowStridePadding() {
        // 4×2 image with rowStride=8 (padding bytes of 255). Read by stride the mean
        // is over the 8 real pixels; a naive contiguous read would pull the padding.
        val src = byteArrayOf(
            10, 20, 30, 40, /*pad*/ -1, -1, -1, -1,
            50, 60, 70, 80, /*pad*/ -1, -1, -1, -1,
        )
        val gray = BlurMetric.downscaleLuma(src, srcWidth = 4, srcHeight = 2, rowStride = 8, pixelStride = 1, targetWidth = 4)
        // (10+20+30+40+50+60+70+80)/8 = 45 — padding (255) excluded.
        assertEquals(45.0, ExposureMetric.meanLuminance(gray), 1e-9)
    }

    @Test
    fun mean_emptyImageIsNaN() {
        // Defensive: an empty buffer yields NaN so the caller emits "unknown", never
        // a silent OK.
        assertTrue(ExposureMetric.meanLuminance(BlurMetric.GrayImage(0, 0, ByteArray(0))).isNaN())
    }
}
