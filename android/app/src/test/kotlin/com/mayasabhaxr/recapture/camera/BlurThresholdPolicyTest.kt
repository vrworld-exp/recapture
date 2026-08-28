// android/app/src/test/kotlin/com/mayasabhaxr/recapture/camera/BlurThresholdPolicyTest.kt
package com.mayasabhaxr.recapture.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Pure JVM unit tests for the three-band blur policy: boundary precision (40/80 →
 * WARN), configurable + validated thresholds (invalid → defaults, equal → empty
 * WARN), runtime updates, and fail-safe handling of non-finite scores.
 */
class BlurThresholdPolicyTest {

    @Test
    fun classify_boundaryTableWithDefaults() {
        val p = BlurThresholdPolicy() // 40 / 80
        assertEquals(BlurBand.REJECT, p.classify(0.0))
        assertEquals(BlurBand.REJECT, p.classify(39.9))
        assertEquals(BlurBand.WARN, p.classify(40.0))   // inclusive lower
        assertEquals(BlurBand.WARN, p.classify(60.0))
        assertEquals(BlurBand.WARN, p.classify(80.0))   // inclusive upper
        assertEquals(BlurBand.ACCEPT, p.classify(80.1))
        assertEquals(BlurBand.ACCEPT, p.classify(200.0))
    }

    @Test
    fun classify_customThresholdsShiftBands() {
        val p = BlurThresholdPolicy(rejectBelow = 30.0, acceptAbove = 70.0)
        assertEquals(BlurBand.REJECT, p.classify(29.0))
        assertEquals(BlurBand.WARN, p.classify(30.0))
        assertEquals(BlurBand.WARN, p.classify(70.0))
        assertEquals(BlurBand.ACCEPT, p.classify(71.0))
    }

    @Test
    fun config_invalidPairFallsBackToDefaults() {
        // rejectBelow > acceptAbove is nonsensical → both defaults (40/80).
        val p = BlurThresholdPolicy(rejectBelow = 90.0, acceptAbove = 50.0)
        assertEquals(40.0, p.rejectBelow, 0.0)
        assertEquals(80.0, p.acceptAbove, 0.0)
        assertEquals(BlurBand.WARN, p.classify(60.0))
    }

    @Test
    fun config_nonFiniteFallsBackPerField() {
        val p = BlurThresholdPolicy(rejectBelow = Double.NaN, acceptAbove = 70.0)
        assertEquals(40.0, p.rejectBelow, 0.0) // NaN → default
        assertEquals(70.0, p.acceptAbove, 0.0) // valid kept
    }

    @Test
    fun config_equalThresholdsGiveEmptyWarnBand() {
        val p = BlurThresholdPolicy(rejectBelow = 50.0, acceptAbove = 50.0)
        assertEquals(BlurBand.REJECT, p.classify(49.9))
        assertEquals(BlurBand.WARN, p.classify(50.0)) // exactly the cutoff
        assertEquals(BlurBand.ACCEPT, p.classify(50.1))
    }

    @Test
    fun update_appliesToSubsequentClassifications() {
        val p = BlurThresholdPolicy() // 40/80
        assertEquals(BlurBand.WARN, p.classify(60.0))
        p.update(rejectBelow = 65.0, acceptAbove = 90.0)
        assertEquals(65.0, p.rejectBelow, 0.0)
        assertEquals(90.0, p.acceptAbove, 0.0)
        assertEquals(BlurBand.REJECT, p.classify(60.0)) // now below the new reject
    }

    @Test
    fun classify_nonFiniteFailsSafeToReject() {
        val p = BlurThresholdPolicy()
        assertEquals(BlurBand.REJECT, p.classify(Double.NaN))
        assertEquals(BlurBand.REJECT, p.classify(Double.NEGATIVE_INFINITY))
        // Positive infinity must NOT classify ACCEPT (fail safe).
        assertNotEquals(BlurBand.ACCEPT, p.classify(Double.POSITIVE_INFINITY))
        assertEquals(BlurBand.REJECT, p.classify(Double.POSITIVE_INFINITY))
        // Negative finite score → REJECT.
        assertEquals(BlurBand.REJECT, p.classify(-5.0))
    }

    @Test
    fun wire_isLowercase() {
        assertEquals("reject", BlurBand.REJECT.wire)
        assertEquals("warn", BlurBand.WARN.wire)
        assertEquals("accept", BlurBand.ACCEPT.wire)
    }
}
