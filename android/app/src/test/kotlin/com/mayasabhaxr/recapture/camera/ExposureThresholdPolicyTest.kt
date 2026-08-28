// android/app/src/test/kotlin/com/mayasabhaxr/recapture/camera/ExposureThresholdPolicyTest.kt
package com.mayasabhaxr.recapture.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure JVM unit tests for the dark/ok/bright exposure policy: boundary precision
 * (40/220 → OK), configurable + validated thresholds (invalid/equal → defaults,
 * since dark/bright must be strictly separated), runtime updates, and the
 * non-finite → null ("unknown", never OK) guard.
 */
class ExposureThresholdPolicyTest {

    @Test
    fun classify_boundaryTableWithDefaults() {
        val p = ExposureThresholdPolicy() // 40 / 220
        assertEquals(ExposureBand.DARK, p.classify(0.0))     // all-black
        assertEquals(ExposureBand.DARK, p.classify(39.9))
        assertEquals(ExposureBand.OK, p.classify(40.0))      // boundary → OK
        assertEquals(ExposureBand.OK, p.classify(128.0))
        assertEquals(ExposureBand.OK, p.classify(220.0))     // boundary → OK
        assertEquals(ExposureBand.BRIGHT, p.classify(220.1))
        assertEquals(ExposureBand.BRIGHT, p.classify(255.0)) // all-white
    }

    @Test
    fun classify_customThresholdsShiftBands() {
        val p = ExposureThresholdPolicy(darkBelow = 50.0, brightAbove = 200.0)
        assertEquals(ExposureBand.DARK, p.classify(49.9))
        assertEquals(ExposureBand.OK, p.classify(50.0))
        assertEquals(ExposureBand.OK, p.classify(200.0))
        assertEquals(ExposureBand.BRIGHT, p.classify(200.1))
    }

    @Test
    fun config_invalidPairFallsBackToDefaults() {
        // darkBelow >= brightAbove is nonsensical → both defaults (40/220).
        val p = ExposureThresholdPolicy(darkBelow = 230.0, brightAbove = 50.0)
        assertEquals(40.0, p.darkBelow, 0.0)
        assertEquals(220.0, p.brightAbove, 0.0)
        assertEquals(ExposureBand.OK, p.classify(128.0))
    }

    @Test
    fun config_equalThresholdsFallBackToDefaults() {
        // Unlike the blur policy, equality leaves no OK band → rejected, both defaults.
        val p = ExposureThresholdPolicy(darkBelow = 100.0, brightAbove = 100.0)
        assertEquals(40.0, p.darkBelow, 0.0)
        assertEquals(220.0, p.brightAbove, 0.0)
    }

    @Test
    fun config_nonFiniteFallsBackPerField() {
        val p = ExposureThresholdPolicy(darkBelow = Double.NaN, brightAbove = 200.0)
        assertEquals(40.0, p.darkBelow, 0.0)  // NaN → default
        assertEquals(200.0, p.brightAbove, 0.0) // valid kept
    }

    @Test
    fun update_appliesToSubsequentClassifications() {
        val p = ExposureThresholdPolicy() // 40/220
        assertEquals(ExposureBand.DARK, p.classify(30.0))
        p.update(darkBelow = 20.0, brightAbove = 220.0)
        assertEquals(20.0, p.darkBelow, 0.0)
        assertEquals(ExposureBand.OK, p.classify(30.0)) // now above the new dark cutoff
    }

    @Test
    fun classify_nonFiniteIsUnknownNeverOk() {
        val p = ExposureThresholdPolicy()
        assertNull(p.classify(Double.NaN))
        assertNull(p.classify(Double.POSITIVE_INFINITY))
        assertNull(p.classify(Double.NEGATIVE_INFINITY))
    }

    @Test
    fun wire_isLowercase() {
        assertEquals("dark", ExposureBand.DARK.wire)
        assertEquals("ok", ExposureBand.OK.wire)
        assertEquals("bright", ExposureBand.BRIGHT.wire)
    }
}
