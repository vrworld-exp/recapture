// android/app/src/test/kotlin/com/mayasabhaxr/recapture/sensors/ImuRotationMathTest.kt
package com.mayasabhaxr.recapture.sensors

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM unit tests for the rotation-vector stream's framework-free logic:
 * rate clamping + sampling period, quaternion extraction (4-value, older
 * 3-value, degenerate), and the boot→monotonic clock conversion (the
 * camera-alignment key). No device / Robolectric.
 */
class ImuRotationMathTest {

    // ── rate / sampling period ────────────────────────────────────────────────

    @Test
    fun clampRateHz_clampsToWindowAndDefaults() {
        assertEquals(100, ImuRotationMath.clampRateHz(null))
        assertEquals(50, ImuRotationMath.clampRateHz(30))
        assertEquals(100, ImuRotationMath.clampRateHz(200))
        assertEquals(75, ImuRotationMath.clampRateHz(75))
        assertEquals(50, ImuRotationMath.clampRateHz(50))
        assertEquals(100, ImuRotationMath.clampRateHz(100))
    }

    @Test
    fun samplingPeriodUs_mapsRateToMicroseconds() {
        assertEquals(10_000, ImuRotationMath.samplingPeriodUs(100))
        assertEquals(20_000, ImuRotationMath.samplingPeriodUs(50))
        // Out-of-window rates clamp first.
        assertEquals(20_000, ImuRotationMath.samplingPeriodUs(10))
        assertEquals(10_000, ImuRotationMath.samplingPeriodUs(500))
    }

    // ── quaternion extraction ─────────────────────────────────────────────────

    @Test
    fun quaternion_passesThroughNormalizedFourValue() {
        // Identity rotation: w = 1.
        val q = ImuRotationMath.quaternion(floatArrayOf(0f, 0f, 0f, 1f))
        assertQuat(doubleArrayOf(0.0, 0.0, 0.0, 1.0), q)
    }

    @Test
    fun quaternion_normalizesNonUnitInput() {
        // A 90° rotation about X stored unnormalized; expect unit length out.
        val s = Math.sin(Math.PI / 4)
        val c = Math.cos(Math.PI / 4)
        val q = ImuRotationMath.quaternion(floatArrayOf((s * 2).toFloat(), 0f, 0f, (c * 2).toFloat()))
        assertEquals(1.0, norm(q), 1e-6)
        assertQuat(doubleArrayOf(s, 0.0, 0.0, c), q)
    }

    @Test
    fun quaternion_computesWForOlderThreeValueSensor() {
        // 60° about X → sin30 = 0.5, w = cos30 ≈ 0.8660. Sensor omits w.
        val x = Math.sin(Math.toRadians(30.0)) // 0.5
        val q = ImuRotationMath.quaternion(floatArrayOf(x.toFloat(), 0f, 0f))
        val expectedW = Math.sqrt(1.0 - x * x)
        assertQuat(doubleArrayOf(x, 0.0, 0.0, expectedW), q)
        assertEquals(1.0, norm(q), 1e-6)
    }

    @Test
    fun quaternion_degenerateFallsBackToIdentity() {
        val q = ImuRotationMath.quaternion(floatArrayOf(0f, 0f, 0f, 0f))
        assertQuat(doubleArrayOf(0.0, 0.0, 0.0, 1.0), q)
    }

    @Test
    fun quaternion_emptyValuesIsIdentity() {
        // Defensive: a malformed empty sample must not throw.
        val q = ImuRotationMath.quaternion(floatArrayOf())
        assertQuat(doubleArrayOf(0.0, 0.0, 0.0, 1.0), q)
    }

    // ── clock conversion ──────────────────────────────────────────────────────

    @Test
    fun toMonotonicNs_appliesOffset() {
        // Boot clock is ahead of monotonic by deep-sleep time → negative offset.
        val bootTs = 5_000_000_000L
        val offset = -1_200_000_000L // monotonic − boot
        assertEquals(3_800_000_000L, ImuRotationMath.toMonotonicNs(bootTs, offset))
    }

    @Test
    fun toMonotonicNs_zeroOffsetIsIdentity() {
        assertEquals(42L, ImuRotationMath.toMonotonicNs(42L, 0L))
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private fun norm(q: DoubleArray): Double =
        Math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3])

    private fun assertQuat(expected: DoubleArray, actual: DoubleArray) {
        assertTrue("expected 4 components, got ${actual.size}", actual.size == 4)
        for (i in 0 until 4) assertEquals(expected[i], actual[i], 1e-6)
    }
}
