// android/app/src/main/kotlin/com/mayasabhaxr/recapture/sensors/OrientationFilter.kt
package com.mayasabhaxr.recapture.sensors

import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.exp
import kotlin.math.sqrt

/**
 * Pure, framework-free quaternion math for the orientation low-pass filter:
 * the dt-aware blend factor, normalized-lerp with double-cover handling, and the
 * quaternion→Euler (yaw/pitch/roll) derivation.
 *
 * The Euler derivation reproduces Android's `SensorManager.getOrientation`
 * convention exactly (azimuth/pitch/roll in **radians**) from a quaternion-built
 * rotation matrix, so downstream code sees the familiar Android orientation — but
 * computed from the *smoothed* quaternion, never by low-passing Euler scalars.
 *
 * Free of Android runtime classes so it is JVM-unit-testable (mirrors the capture
 * task's pure `ResolutionMath` / `ImuRotationMath`).
 */
object OrientationMath {

    /** Dot product of two quaternions (sign indicates same vs opposite cover). */
    fun dot(a: DoubleArray, b: DoubleArray): Double =
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]

    /**
     * Time-constant blend factor `α = 1 − exp(−dt/τ)`, clamped to [0,1]. Rate is
     * best-effort/variable, so `dt` comes from sample timestamps, not an assumed
     * cadence. Degenerate ends behave sensibly: `τ ≤ 0` → 1 (passthrough, no
     * smoothing); `dt ≤ 0` → 0 (no time elapsed ⇒ no update).
     *
     * [dtNs] and [tauNs] are both in nanoseconds (only their ratio matters).
     */
    fun alpha(dtNs: Double, tauNs: Double): Double {
        if (tauNs <= 0.0) return 1.0
        if (dtNs <= 0.0) return 0.0
        return (1.0 - exp(-dtNs / tauNs)).coerceIn(0.0, 1.0)
    }

    /**
     * Normalized linear interpolation from [a] toward [b] by [t], written into
     * [out] (which may alias [a]). Handles quaternion double-cover: if `dot(a,b)`
     * is negative, [b] is blended with a flipped sign so the result takes the
     * SHORTEST path (no jerk on a `q`/`−q` sign flip). The double-cover flip keeps
     * the blend within ≤90°, so the lerp is never antipodal/degenerate; a defensive
     * guard falls back to the sign-corrected [b] if the norm still collapses.
     *
     * nlerp (not slerp) is used deliberately: at 50–100 Hz the per-sample step is
     * small, where nlerp ≈ slerp at a fraction of the cost.
     */
    fun nlerp(a: DoubleArray, b: DoubleArray, t: Double, out: DoubleArray) {
        val s = if (dot(a, b) < 0.0) -1.0 else 1.0
        val u = 1.0 - t
        val x = u * a[0] + t * s * b[0]
        val y = u * a[1] + t * s * b[1]
        val z = u * a[2] + t * s * b[2]
        val w = u * a[3] + t * s * b[3]
        val norm = sqrt(x * x + y * y + z * z + w * w)
        if (norm <= 1e-12 || !norm.isFinite()) {
            // Degenerate (shouldn't happen post double-cover): snap to b̂.
            normalizeInto(s * b[0], s * b[1], s * b[2], s * b[3], out)
            return
        }
        out[0] = x / norm
        out[1] = y / norm
        out[2] = z / norm
        out[3] = w / norm
    }

    /** Writes a normalized `[x,y,z,w]` into [out] (identity if degenerate). */
    fun normalizeInto(x: Double, y: Double, z: Double, w: Double, out: DoubleArray) {
        val norm = sqrt(x * x + y * y + z * z + w * w)
        if (norm <= 1e-12 || !norm.isFinite()) {
            out[0] = 0.0; out[1] = 0.0; out[2] = 0.0; out[3] = 1.0
            return
        }
        out[0] = x / norm; out[1] = y / norm; out[2] = z / norm; out[3] = w / norm
    }

    /**
     * Derives `[yaw, pitch, roll]` (radians) from a unit quaternion `[x,y,z,w]`,
     * matching `SensorManager.getOrientation` on a quaternion-built rotation
     * matrix: yaw = atan2(R1,R4), pitch = asin(−R7), roll = atan2(−R6,R8). Pitch is
     * clamped to the valid asin domain. Because the input is the *smoothed*
     * quaternion, this stays stable through yaw wraparound and pitch ±90° (gimbal),
     * where a scalar Euler low-pass would not.
     */
    fun toEuler(x: Double, y: Double, z: Double, w: Double): DoubleArray {
        val r1 = 2.0 * (x * y - z * w)
        val r4 = 1.0 - 2.0 * (x * x + z * z)
        val r6 = 2.0 * (x * z - y * w)
        val r7 = 2.0 * (y * z + x * w)
        val r8 = 1.0 - 2.0 * (x * x + y * y)
        val yaw = atan2(r1, r4)
        val pitch = asin((-r7).coerceIn(-1.0, 1.0))
        val roll = atan2(-r6, r8)
        return doubleArrayOf(yaw, pitch, roll)
    }
}

/** A smoothed orientation sample: the filtered quaternion + derived YPR + ts. */
data class SmoothedOrientation(
    val qx: Double,
    val qy: Double,
    val qz: Double,
    val qw: Double,
    /** Yaw/pitch/roll in radians (SensorManager.getOrientation convention). */
    val yaw: Double,
    val pitch: Double,
    val roll: Double,
    /** UNCHANGED from the source sample (CLOCK_MONOTONIC; downstream join key). */
    val timestampNs: Long,
)

/**
 * Stateful, dt-aware low-pass orientation filter operating in the **quaternion
 * domain** (nlerp toward each new sample), then deriving yaw/pitch/roll from the
 * smoothed quaternion. Consumes the IMU rotation-vector samples; registers no
 * sensors and does no pose/frame fusion.
 *
 * ## Policy
 *  - **First sample / reset:** `smoothedQ = sample` (nothing to blend from).
 *  - **dt-aware blend:** `α = 1 − exp(−dt/τ)` from consecutive sample timestamps —
 *    rate-independent, so smoothing is consistent whether the IMU delivers at 50,
 *    100, or an irregular rate.
 *  - **Double-cover:** the shortest-path sign flip is applied inside the nlerp.
 *  - **Normalize:** the smoothed quaternion is re-normalized every step (no drift).
 *  - **Large gap:** if `dt > gapResetNs` (default 500 ms — dropped samples / a
 *    pause/resume) the filter re-initializes to the new sample rather than snapping
 *    through a long-stale orientation. Non-monotonic `dt < 0` also re-initializes.
 *
 * Not thread-safe by itself; the manager calls [filter] on its sensor thread and
 * [reset]/[setTauNs] from the main thread, so both are `@Synchronized`.
 */
class OrientationFilter(
    tauNs: Double = DEFAULT_TAU_NS,
    private val gapResetNs: Long = DEFAULT_GAP_RESET_NS,
) {
    companion object {
        /** Default time constant: 100 ms — smooth but not laggy for a live guide. */
        const val DEFAULT_TAU_NS = 100_000_000.0

        /** Beyond this inter-sample gap, re-initialize instead of blending. */
        const val DEFAULT_GAP_RESET_NS = 500_000_000L
    }

    /** Smoothing time constant (ns). Always coerced ≥ 0 (`τ = 0` ⇒ passthrough). */
    @Volatile
    var tauNs: Double = tauNs.coerceAtLeast(0.0)
        set(value) {
            field = value.coerceAtLeast(0.0)
        }

    private val smoothedQ = DoubleArray(4)
    private var hasState = false
    private var prevTimestampNs = 0L

    /** Forget state so the next sample re-initializes (subscribe / resume). */
    @Synchronized
    fun reset() {
        hasState = false
    }

    /**
     * Filters one sample. [q] is the source unit quaternion `[x,y,z,w]` (not
     * mutated); [timestampNs] is preserved unchanged on the output.
     */
    @Synchronized
    fun filter(q: DoubleArray, timestampNs: Long): SmoothedOrientation {
        val dt = timestampNs - prevTimestampNs
        if (!hasState || dt < 0L || dt > gapResetNs) {
            // First sample / non-monotonic / large gap → snap to the new sample.
            OrientationMath.normalizeInto(q[0], q[1], q[2], q[3], smoothedQ)
            hasState = true
        } else {
            val a = OrientationMath.alpha(dt.toDouble(), tauNs)
            OrientationMath.nlerp(smoothedQ, q, a, smoothedQ)
        }
        prevTimestampNs = timestampNs

        val e = OrientationMath.toEuler(smoothedQ[0], smoothedQ[1], smoothedQ[2], smoothedQ[3])
        return SmoothedOrientation(
            qx = smoothedQ[0],
            qy = smoothedQ[1],
            qz = smoothedQ[2],
            qw = smoothedQ[3],
            yaw = e[0],
            pitch = e[1],
            roll = e[2],
            timestampNs = timestampNs,
        )
    }
}
