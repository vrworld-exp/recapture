// android/app/src/test/kotlin/com/mayasabhaxr/recapture/sensors/OrientationFilterTest.kt
package com.mayasabhaxr.recapture.sensors

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM unit tests for the low-pass orientation filter: the dt-aware blend
 * factor, double-cover-safe nlerp, quaternion→Euler derivation, and the stateful
 * filter's wraparound/gimbal/gap/rate behavior. No device / Robolectric.
 */
class OrientationFilterTest {

    private val ms = 1_000_000L // ns per millisecond

    // ── alpha (dt-aware blend) ────────────────────────────────────────────────

    @Test
    fun alpha_tauZeroIsPassthrough() {
        assertEquals(1.0, OrientationMath.alpha(10.0 * ms, 0.0), 0.0)
    }

    @Test
    fun alpha_nonPositiveDtIsNoUpdate() {
        assertEquals(0.0, OrientationMath.alpha(0.0, 100.0 * ms), 0.0)
        assertEquals(0.0, OrientationMath.alpha(-5.0 * ms, 100.0 * ms), 0.0)
    }

    @Test
    fun alpha_matchesTimeConstantFormula() {
        // dt = τ → α = 1 − e^-1 ≈ 0.6321.
        val tau = 100.0 * ms
        assertEquals(1.0 - Math.exp(-1.0), OrientationMath.alpha(tau, tau), 1e-9)
    }

    @Test
    fun alpha_isRateIndependentWhenComposed() {
        // The retained fraction (1−α) over equal total elapsed time must be the
        // same regardless of how dt is subdivided: two 10ms steps == one 20ms step.
        val tau = 80.0 * ms
        val one20 = 1.0 - OrientationMath.alpha(20.0 * ms, tau)
        val two10 = (1.0 - OrientationMath.alpha(10.0 * ms, tau)) *
            (1.0 - OrientationMath.alpha(10.0 * ms, tau))
        assertEquals(one20, two10, 1e-9)
    }

    // ── nlerp + double-cover ──────────────────────────────────────────────────

    @Test
    fun nlerp_takesShortestPathOnSignFlip() {
        // q and −q are the same rotation. Blending identity with −identity must
        // NOT collapse toward zero/garbage — double-cover flips the sign.
        val a = doubleArrayOf(0.0, 0.0, 0.0, 1.0)
        val b = doubleArrayOf(0.0, 0.0, 0.0, -1.0) // == a as a rotation
        val out = DoubleArray(4)
        OrientationMath.nlerp(a, b, 0.5, out)
        assertUnit(out)
        // Result should be (the short-path) identity, not the degenerate average.
        assertEquals(1.0, Math.abs(out[3]), 1e-9)
    }

    @Test
    fun nlerp_writesUnitQuaternionEvenAliasingInput() {
        val a = doubleArrayOf(0.0, 0.0, 0.7071, 0.7071) // 90° about Z
        val b = doubleArrayOf(0.0, 0.0, 0.0, 1.0)
        OrientationMath.nlerp(a, b, 0.5, a) // out aliases a
        assertUnit(a)
    }

    // ── toEuler ───────────────────────────────────────────────────────────────

    @Test
    fun toEuler_identityIsAllZero() {
        val e = OrientationMath.toEuler(0.0, 0.0, 0.0, 1.0)
        assertEquals(0.0, e[0], 1e-9)
        assertEquals(0.0, e[1], 1e-9)
        assertEquals(0.0, e[2], 1e-9)
    }

    @Test
    fun toEuler_pitchNear90IsStableNoNaN() {
        // ~89° rotation about X drives pitch toward ±π/2 (the gimbal edge): the
        // derivation must stay finite with magnitude ~89° (sign follows the
        // getOrientation convention), no NaN/blowup.
        val half = Math.toRadians(89.0) / 2.0
        val e = OrientationMath.toEuler(Math.sin(half), 0.0, 0.0, Math.cos(half))
        assertTrue(e.all { it.isFinite() })
        assertEquals(Math.toRadians(89.0), Math.abs(e[1]), 1e-3)
    }

    // ── filter: init / smoothing / wraparound / gap / extremes ────────────────

    @Test
    fun filter_firstSampleInitializesToSample() {
        val f = OrientationFilter()
        val q = quatAboutZ(Math.toRadians(30.0))
        val s = f.filter(q, 1000L)
        // No blend: smoothed == sample (yaw matches a 30° Z rotation).
        assertEquals(quatYaw(q), s.yaw, 1e-9)
        assertEquals(1000L, s.timestampNs)
    }

    @Test
    fun filter_reducesJitterTowardSteadyTarget() {
        val f = OrientationFilter(tauNs = 100.0 * ms)
        f.filter(quatAboutZ(0.0), 0L) // init at 0°
        var t = 0L
        // Feed a steady target; the smoothed yaw approaches it monotonically (error
        // shrinks every step) and lags — never overshoots.
        val target = quatAboutZ(Math.toRadians(40.0))
        val targetYaw = quatYaw(target)
        var prevErr = Double.MAX_VALUE
        var last = 0.0
        repeat(50) {
            t += 10 * ms
            val s = f.filter(target, t)
            val err = Math.abs(s.yaw - targetYaw)
            assertTrue("error shrinks (no overshoot/jitter)", err <= prevErr + 1e-9)
            prevErr = err
            last = s.yaw
        }
        // After ~0.5s ≫ τ it should be very close to the target.
        assertEquals(targetYaw, last, Math.toRadians(0.5))
    }

    @Test
    fun filter_yawWraparoundHasNo180Artifact() {
        // Two orientations straddling the ±180° yaw boundary (179° and 181°≡−179°)
        // are only 2° apart. Quaternion-domain smoothing must land NEAR ±180°, not
        // near 0° (the artifact a scalar Euler average would produce).
        val f = OrientationFilter(tauNs = 10.0 * ms) // dt=10ms ⇒ α≈0.632
        f.filter(quatAboutZ(Math.toRadians(179.0)), 0L)
        val s = f.filter(quatAboutZ(Math.toRadians(181.0)), 10 * ms)
        // Yaw magnitude near π (±180°), nowhere near 0.
        assertTrue("smoothed yaw |${Math.toDegrees(s.yaw)}°| near 180",
            Math.abs(Math.abs(s.yaw) - Math.PI) < Math.toRadians(2.0))
    }

    @Test
    fun filter_largeGapReinitializesNoSnapThrough() {
        val f = OrientationFilter(tauNs = 100.0 * ms, gapResetNs = 200 * ms)
        f.filter(quatAboutZ(Math.toRadians(10.0)), 0L)
        // A 1s gap (> 200ms reset) → snap to the new sample, not a blended crawl.
        val sample = quatAboutZ(Math.toRadians(120.0))
        val s = f.filter(sample, 1000 * ms)
        assertEquals(quatYaw(sample), s.yaw, 1e-6)
    }

    @Test
    fun filter_tauZeroIsPassthrough() {
        val f = OrientationFilter(tauNs = 0.0)
        f.filter(quatAboutZ(0.0), 0L)
        val target = quatAboutZ(Math.toRadians(75.0))
        val s = f.filter(target, 10 * ms)
        // α=1 ⇒ smoothed == latest sample, no lag.
        assertEquals(quatYaw(target), s.yaw, 1e-9)
    }

    @Test
    fun filter_hugeTauBarelyMoves() {
        val f = OrientationFilter(tauNs = 10_000.0 * ms) // 10s ⇒ α≈0.001 at 10ms
        f.filter(quatAboutZ(0.0), 0L)
        val s = f.filter(quatAboutZ(Math.toRadians(90.0)), 10 * ms)
        assertTrue("stays near init", Math.abs(s.yaw) < Math.toRadians(1.0))
        assertTrue(s.yaw.isFinite())
    }

    @Test
    fun filter_rateIndependentSmoothing() {
        // Same τ and same total elapsed time, different cadence → comparable result.
        val target = quatAboutZ(Math.toRadians(30.0))

        val fast = OrientationFilter(tauNs = 100.0 * ms)
        fast.filter(quatAboutZ(0.0), 0L)
        var t = 0L
        var fastYaw = 0.0
        repeat(20) { t += 10 * ms; fastYaw = fast.filter(target, t).yaw } // 200ms @100Hz

        val slow = OrientationFilter(tauNs = 100.0 * ms)
        slow.filter(quatAboutZ(0.0), 0L)
        t = 0L
        var slowYaw = 0.0
        repeat(10) { t += 20 * ms; slowYaw = slow.filter(target, t).yaw } // 200ms @50Hz

        assertEquals("rate-independent", fastYaw, slowYaw, Math.toRadians(0.3))
    }

    @Test
    fun filter_normalizedOverLongRun() {
        val f = OrientationFilter(tauNs = 50.0 * ms)
        var t = 0L
        var last = SmoothedOrientation(0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0L)
        repeat(2000) {
            t += 10 * ms
            val yaw = Math.toRadians((it % 360).toDouble())
            last = f.filter(quatAboutZ(yaw), t)
        }
        val norm = Math.sqrt(last.qx * last.qx + last.qy * last.qy + last.qz * last.qz + last.qw * last.qw)
        assertEquals("unit quaternion after long run", 1.0, norm, 1e-9)
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /** Unit quaternion for a rotation of [rad] about the Z axis. */
    private fun quatAboutZ(rad: Double): DoubleArray {
        val h = rad / 2.0
        return doubleArrayOf(0.0, 0.0, Math.sin(h), Math.cos(h))
    }

    private fun quatYaw(q: DoubleArray): Double =
        OrientationMath.toEuler(q[0], q[1], q[2], q[3])[0]

    private fun assertUnit(q: DoubleArray) {
        val norm = Math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3])
        assertEquals(1.0, norm, 1e-9)
    }
}
