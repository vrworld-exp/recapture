// android/app/src/test/kotlin/com/mayasabhaxr/recapture/sensors/StabilityGateTest.kt
package com.mayasabhaxr.recapture.sensors

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM unit tests for the stability gate: unit conversion, config validation,
 * the gravity-removal fallback, and the dt-aware dwell state machine (steady →
 * stable, motion spike resets, AND of both sensors, most-recent-of-each, rate
 * independence, gap reset, strict boundary). No device / Robolectric.
 */
class StabilityGateTest {

    private val ms = 1_000_000L // ns per millisecond

    // ── units + config ────────────────────────────────────────────────────────

    @Test
    fun gToMs2_convertsExplicitly() {
        assertEquals(1.4715, StabilityMath.gToMs2(0.15), 1e-9)
    }

    @Test
    fun config_defaultsAndConversion() {
        val c = StabilityConfig.DEFAULT
        assertEquals(0.8, c.gyroThreshRadS, 0.0)
        assertEquals(0.15 * 9.81, c.accelThreshMs2, 1e-9)
        assertEquals(250L * ms, c.dwellNs)
    }

    @Test
    fun config_buildValidatesAndFallsBack() {
        // Invalid (non-positive / negative) → defaults; valid → applied + converted.
        val bad = StabilityConfig.build(gyroThreshRadS = -1.0, accelThreshG = 0.0, dwellMs = -5)
        assertEquals(0.8, bad.gyroThreshRadS, 0.0)
        assertEquals(0.15 * 9.81, bad.accelThreshMs2, 1e-9)
        assertEquals(250L * ms, bad.dwellNs)

        val good = StabilityConfig.build(gyroThreshRadS = 0.5, accelThreshG = 0.2, dwellMs = 400)
        assertEquals(0.5, good.gyroThreshRadS, 0.0)
        assertEquals(0.2 * 9.81, good.accelThreshMs2, 1e-9)
        assertEquals(400L * ms, good.dwellNs)
    }

    // ── gravity-removal fallback ──────────────────────────────────────────────

    @Test
    fun gravity_firstSampleIsZeroThenSubtractsGravity() {
        val g = GravityEstimator()
        // First sample assumed pure gravity → linear ≈ 0.
        assertEquals(0.0, g.linearMagnitude(0.0, 0.0, 9.81, 0L), 1e-9)
        // Held at rest (same gravity) → linear stays ≈ 0.
        var mag = 0.0
        var t = 0L
        repeat(20) { t += 20 * ms; mag = g.linearMagnitude(0.0, 0.0, 9.81, t) }
        assertTrue("linear ≈ 0 at rest, was $mag", mag < 0.05)
    }

    @Test
    fun gravity_detectsTransientMotionAboveGravity() {
        val g = GravityEstimator()
        g.linearMagnitude(0.0, 0.0, 9.81, 0L) // settle
        repeat(5) { g.linearMagnitude(0.0, 0.0, 9.81, (it + 1) * 20L * ms) }
        // A sudden lateral 5 m/s² jolt should show up as nonzero linear accel.
        val mag = g.linearMagnitude(5.0, 0.0, 9.81, 200 * ms)
        assertTrue("motion detected, was $mag", mag > 3.0)
    }

    // ── dwell state machine ───────────────────────────────────────────────────

    private fun steadyGyro() = 0.1   // < 0.8
    private fun steadyAccel() = 0.5  // m/s², < 1.47

    @Test
    fun gate_becomesStableAfterDwellNotBefore() {
        val gate = StabilityGate()
        // Prime both streams steady at t=0; condition starts now.
        assertNull(gate.onGyro(steadyGyro(), 0L))
        assertNull(gate.onLinearAccel(steadyAccel(), 0L))
        // Still within the 250ms dwell.
        assertNull(gate.onGyro(steadyGyro(), 200 * ms))
        // Crossing 250ms → STABLE.
        val t = gate.onLinearAccel(steadyAccel(), 260 * ms)
        assertTrue(t != null && t.stable)
        assertEquals(260 * ms, t!!.timestampNs)
        // No re-emit while it stays stable.
        assertNull(gate.onGyro(steadyGyro(), 300 * ms))
    }

    @Test
    fun gate_motionSpikeResetsDwell() {
        val gate = StabilityGate()
        gate.onGyro(steadyGyro(), 0L)
        gate.onLinearAccel(steadyAccel(), 0L)
        gate.onGyro(steadyGyro(), 200 * ms)
        // Spike at 220ms breaks the condition — no transition (wasn't stable yet).
        assertNull(gate.onGyro(2.0, 220 * ms)) // gyro > 0.8
        // Back to steady: dwell restarts from here; not yet stable at +200ms.
        gate.onGyro(steadyGyro(), 240 * ms)
        assertNull(gate.onLinearAccel(steadyAccel(), 440 * ms))
        // Fresh 250ms from 240ms → stable at ~490ms.
        val t = gate.onGyro(steadyGyro(), 500 * ms)
        assertTrue(t != null && t.stable)
    }

    @Test
    fun gate_requiresBothSensorsBelowThreshold() {
        // Rotational motion only (gyro high, accel low) → never stable.
        val g1 = StabilityGate()
        g1.onLinearAccel(steadyAccel(), 0L)
        g1.onGyro(1.5, 0L)
        assertNull(g1.onGyro(1.5, 300 * ms))

        // Translational motion only (accel high, gyro low) → never stable.
        val g2 = StabilityGate()
        g2.onGyro(steadyGyro(), 0L)
        g2.onLinearAccel(5.0, 0L)
        assertNull(g2.onLinearAccel(5.0, 300 * ms))
    }

    @Test
    fun gate_evaluatesMostRecentOfEachIndependently() {
        val gate = StabilityGate()
        // Only gyro so far — cannot be stable without an accel value.
        assertNull(gate.onGyro(steadyGyro(), 0L))
        assertNull(gate.onGyro(steadyGyro(), 300 * ms))
        // Accel arrives steady; dwell starts now (most-recent gyro still steady).
        assertNull(gate.onLinearAccel(steadyAccel(), 300 * ms))
        val t = gate.onLinearAccel(steadyAccel(), 560 * ms)
        assertTrue(t != null && t.stable)
    }

    @Test
    fun gate_dwellIsRateIndependent() {
        // Same wall-equivalent dwell regardless of cadence: stable just after 250ms
        // whether sampled every 10ms (fast) or sparsely (slow).
        val fast = StabilityGate()
        fast.onGyro(steadyGyro(), 0L); fast.onLinearAccel(steadyAccel(), 0L)
        var fastStable = false
        var t = 0L
        repeat(30) { // 300ms @ 10ms steps; stable fires whenever the dwell crosses
            t += 10 * ms
            if (fast.onGyro(steadyGyro(), t)?.stable == true) fastStable = true
            if (fast.onLinearAccel(steadyAccel(), t)?.stable == true) fastStable = true
        }
        assertTrue("fast cadence stable by ~250ms", fastStable)

        val slow = StabilityGate()
        slow.onGyro(steadyGyro(), 0L); slow.onLinearAccel(steadyAccel(), 0L)
        // One sample at 50ms then 300ms (> 250ms) → stable, same as fast.
        slow.onGyro(steadyGyro(), 50 * ms)
        val st = slow.onLinearAccel(steadyAccel(), 300 * ms)
        assertTrue("slow cadence stable past 250ms", st != null && st.stable)
    }

    @Test
    fun gate_leavingStableEmitsUnstable() {
        val gate = StabilityGate()
        gate.onGyro(steadyGyro(), 0L); gate.onLinearAccel(steadyAccel(), 0L)
        assertTrue(gate.onGyro(steadyGyro(), 300 * ms)!!.stable)
        val t = gate.onGyro(2.0, 320 * ms) // motion → leave stable
        assertTrue(t != null && !t.stable)
        assertEquals(2.0, t!!.gyroMag, 1e-9)
    }

    @Test
    fun gate_largeGapResetsAndDropsStable() {
        val gate = StabilityGate(StabilityConfig.build(null, null, null).copy(gapResetNs = 200 * ms))
        gate.onGyro(steadyGyro(), 0L); gate.onLinearAccel(steadyAccel(), 0L)
        // Keep sample continuity within the 200ms gap while the dwell accumulates.
        gate.onGyro(steadyGyro(), 200 * ms)
        assertTrue(gate.onGyro(steadyGyro(), 300 * ms)!!.stable)
        // A 1s gap (> 200ms) while still "steady" → drop to unstable (no false carry).
        val t = gate.onGyro(steadyGyro(), 1300 * ms)
        assertTrue("gap drops stable", t != null && !t.stable)
        // Must re-accumulate a fresh dwell before stable again (steps within the
        // 200ms gap window so continuity holds).
        assertNull(gate.onLinearAccel(steadyAccel(), 1300 * ms))
        assertNull(gate.onGyro(steadyGyro(), 1500 * ms))
        assertTrue(gate.onGyro(steadyGyro(), 1560 * ms)!!.stable)
    }

    @Test
    fun gate_strictBoundaryIsNotStable() {
        val gate = StabilityGate() // gyro thresh 0.8, accel thresh 1.4715
        // Exactly at the gyro threshold → strict < fails → never stable.
        gate.onLinearAccel(steadyAccel(), 0L)
        gate.onGyro(0.8, 0L)
        assertNull(gate.onGyro(0.8, 300 * ms))
    }

    @Test
    fun gate_resetClearsState() {
        val gate = StabilityGate()
        gate.onGyro(steadyGyro(), 0L); gate.onLinearAccel(steadyAccel(), 0L)
        assertTrue(gate.onGyro(steadyGyro(), 300 * ms)!!.stable)
        gate.reset()
        // After reset, needs both sensors again + a fresh dwell.
        assertNull(gate.onGyro(steadyGyro(), 400 * ms))
        assertNull(gate.onLinearAccel(steadyAccel(), 400 * ms))
        assertTrue(gate.onGyro(steadyGyro(), 700 * ms)!!.stable)
    }
}
