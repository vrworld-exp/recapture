// android/app/src/main/kotlin/com/mayasabhaxr/recapture/sensors/StabilityGate.kt
package com.mayasabhaxr.recapture.sensors

import kotlin.math.sqrt

/**
 * Pure, framework-free core of the stability gate: magnitude/unit helpers, the
 * gravity-removal fallback estimator, the validated threshold config, and the
 * dt-aware dwell state machine.
 *
 * The gate opens (STABLE) when gyroscope magnitude < `gyroThresh` rad/s AND
 * gravity-removed linear-acceleration magnitude < `accelThresh` (default 0.15 g),
 * held CONTINUOUSLY for `dwellMs`. The AND is evaluated on the most-recent value
 * of EACH sensor (the two streams arrive independently); the dwell is measured
 * from sensor timestamps (dt-aware), not a sample count or wall clock.
 *
 * Free of Android runtime classes so it is JVM-unit-testable (mirrors the other
 * sensor tasks' pure `ImuRotationMath` / `OrientationMath`).
 */
object StabilityMath {
    /** Standard gravity (m/s²) used to convert the g threshold to SI. */
    const val GRAVITY_MS2 = 9.81

    /** Euclidean magnitude of a 3-vector. */
    fun magnitude(x: Double, y: Double, z: Double): Double = sqrt(x * x + y * y + z * z)

    /** Converts a g value (e.g. 0.15) to m/s² (0.15 × 9.81 ≈ 1.47). */
    fun gToMs2(g: Double): Double = g * GRAVITY_MS2

    /**
     * Continuous stillness score in [0,1] for a UI meter: 1.0 when perfectly
     * still, falling to 0.0 as EITHER signal reaches its threshold. It is the
     * geometric mean of the two clamped proximity-to-threshold partials, so one
     * signal alone can collapse it — mirroring the gate's AND, and crossing ~0
     * around the same boundary the debounced gate flips. This is an INSTANTANEOUS
     * display signal, NOT the debounced gate decision (that stays in [StabilityGate]).
     *
     * A non-positive threshold ⇒ that partial is 0 (maximum penalty), never a
     * divide-by-zero; a non-finite magnitude ⇒ that partial is 0.
     */
    fun score(gyroMag: Double, linAccelMag: Double, gyroThresh: Double, accelThresh: Double): Double {
        val g = partial(gyroMag, gyroThresh)
        val a = partial(linAccelMag, accelThresh)
        return sqrt(g * a) // geometric mean of two values
    }

    private fun partial(value: Double, threshold: Double): Double {
        if (!value.isFinite() || threshold <= 0.0) return 0.0
        return 1.0 - (value / threshold).coerceIn(0.0, 1.0)
    }
}

/**
 * Gravity-removal fallback for devices lacking `TYPE_LINEAR_ACCELERATION`: a
 * dt-aware low-pass estimates the gravity vector from raw accelerometer samples
 * and subtracts it, yielding an approximate linear acceleration. The first sample
 * is assumed to be pure gravity (linear ≈ 0). The estimate is intentionally slow
 * (large τ) so steady gravity is tracked while motion is rejected. Approximate vs
 * a hardware linear-accel sensor, but correct enough to gate the 0.15 g check.
 */
class GravityEstimator(var tauNs: Double = DEFAULT_GRAVITY_TAU_NS) {
    companion object {
        /** Slow gravity tracker (~0.5 s) — tracks gravity, rejects brief motion. */
        const val DEFAULT_GRAVITY_TAU_NS = 500_000_000.0
    }

    private val gravity = DoubleArray(3)
    private var hasState = false
    private var prevTimestampNs = 0L

    fun reset() {
        hasState = false
    }

    /** Updates the gravity estimate from a raw accel sample; returns |linear accel|. */
    fun linearMagnitude(ax: Double, ay: Double, az: Double, timestampNs: Long): Double {
        if (!hasState) {
            gravity[0] = ax; gravity[1] = ay; gravity[2] = az
            hasState = true
            prevTimestampNs = timestampNs
            return 0.0
        }
        val dt = (timestampNs - prevTimestampNs).toDouble()
        prevTimestampNs = timestampNs
        val a = OrientationMath.alpha(dt, tauNs)
        gravity[0] += a * (ax - gravity[0])
        gravity[1] += a * (ay - gravity[1])
        gravity[2] += a * (az - gravity[2])
        return StabilityMath.magnitude(ax - gravity[0], ay - gravity[1], az - gravity[2])
    }
}

/** Validated stability thresholds. Construct via [build] to apply defaults/clamps. */
data class StabilityConfig(
    val gyroThreshRadS: Double,
    /** Linear-accel threshold in **m/s²** (converted from the g input). */
    val accelThreshMs2: Double,
    val dwellNs: Long,
    val gapResetNs: Long = DEFAULT_GAP_RESET_NS,
) {
    companion object {
        const val DEFAULT_GYRO_THRESH_RAD_S = 0.8
        const val DEFAULT_ACCEL_THRESH_G = 0.15
        const val DEFAULT_DWELL_MS = 250L

        /** Beyond this inter-sample gap, the dwell breaks (pause/dropped samples). */
        const val DEFAULT_GAP_RESET_NS = 500_000_000L

        val DEFAULT = StabilityConfig(
            gyroThreshRadS = DEFAULT_GYRO_THRESH_RAD_S,
            accelThreshMs2 = StabilityMath.gToMs2(DEFAULT_ACCEL_THRESH_G),
            dwellNs = DEFAULT_DWELL_MS * 1_000_000L,
        )

        /**
         * Builds a config from optional inputs, applying defaults for any that are
         * missing/invalid (non-finite or non-positive thresholds, negative dwell).
         * [accelThreshG] is in g and converted to m/s² here (the single, explicit
         * unit conversion — no silent ×9.81 elsewhere).
         */
        fun build(gyroThreshRadS: Double?, accelThreshG: Double?, dwellMs: Long?): StabilityConfig {
            val gyro = gyroThreshRadS?.takeIf { it.isFinite() && it > 0.0 } ?: DEFAULT_GYRO_THRESH_RAD_S
            val accelG = accelThreshG?.takeIf { it.isFinite() && it > 0.0 } ?: DEFAULT_ACCEL_THRESH_G
            val dwell = dwellMs?.takeIf { it >= 0L } ?: DEFAULT_DWELL_MS
            return StabilityConfig(
                gyroThreshRadS = gyro,
                accelThreshMs2 = StabilityMath.gToMs2(accelG),
                dwellNs = dwell * 1_000_000L,
            )
        }
    }
}

/** A debounced stability transition: emitted only when [stable] flips. */
data class StabilityTransition(
    val stable: Boolean,
    val gyroMag: Double,
    val linAccelMag: Double,
    val timestampNs: Long,
)

/**
 * An instantaneous (non-debounced) stability reading: the continuous [score] plus
 * the magnitudes it was computed from. Surfaced throttled for a UI stillness meter,
 * distinct from the debounced [StabilityTransition].
 */
data class StabilityReading(
    val score: Double,
    val gyroMag: Double,
    val linAccelMag: Double,
)

/**
 * dt-aware dwell state machine. Fed the latest gyro / linear-accel magnitude as
 * each (independent) sensor sample arrives; returns a [StabilityTransition] only
 * when the debounced state flips (entered or left STABLE), never per sample.
 *
 * Threshold comparison is strict `<` (a value exactly at the threshold is NOT
 * stable). A break in the condition, or an inter-sample gap beyond
 * [StabilityConfig.gapResetNs] (pause/resume / dropped samples), resets the dwell
 * — so no false STABLE is emitted across a gap.
 *
 * Called on the sensor thread; [reset] may come from the main thread, so both are
 * `@Synchronized` (mirrors [OrientationFilter]).
 */
class StabilityGate(@Volatile var config: StabilityConfig = StabilityConfig.DEFAULT) {

    private var gyroMag = Double.NaN
    private var linAccelMag = Double.NaN
    private var haveGyro = false
    private var haveAccel = false

    /** Sensor timestamp when the combined condition first became true, or null. */
    private var conditionStartTs: Long? = null
    private var stable = false
    private var lastSampleTs: Long? = null

    @Synchronized
    fun reset() {
        gyroMag = Double.NaN
        linAccelMag = Double.NaN
        haveGyro = false
        haveAccel = false
        conditionStartTs = null
        stable = false
        lastSampleTs = null
    }

    @Synchronized
    fun onGyro(magnitude: Double, timestampNs: Long): StabilityTransition? {
        gyroMag = magnitude
        haveGyro = true
        return evaluate(timestampNs)
    }

    @Synchronized
    fun onLinearAccel(magnitude: Double, timestampNs: Long): StabilityTransition? {
        linAccelMag = magnitude
        haveAccel = true
        return evaluate(timestampNs)
    }

    /**
     * The current instantaneous stillness reading from the most-recent magnitude of
     * each sensor, or null until BOTH have reported (so an early, misleading score
     * is never surfaced). Independent of the debounced gate state.
     */
    @Synchronized
    fun currentReading(): StabilityReading? {
        if (!haveGyro || !haveAccel) return null
        return StabilityReading(
            score = StabilityMath.score(
                gyroMag, linAccelMag, config.gyroThreshRadS, config.accelThreshMs2),
            gyroMag = gyroMag,
            linAccelMag = linAccelMag,
        )
    }

    private fun evaluate(ts: Long): StabilityTransition? {
        val last = lastSampleTs
        lastSampleTs = ts
        // A large inter-sample gap breaks dwell continuity (pause / dropped run).
        if (last != null && ts - last > config.gapResetNs) {
            conditionStartTs = null
            if (stable) {
                stable = false
                return transition(false, ts)
            }
        }

        val condition = haveGyro && haveAccel &&
            gyroMag < config.gyroThreshRadS &&
            linAccelMag < config.accelThreshMs2

        if (!condition) {
            conditionStartTs = null
            return if (stable) {
                stable = false
                transition(false, ts)
            } else {
                null
            }
        }

        // Condition holds: accumulate the dwell from the first satisfied timestamp.
        val start = conditionStartTs
        if (start == null) {
            conditionStartTs = ts
            return null
        }
        if (!stable && ts - start >= config.dwellNs) {
            stable = true
            return transition(true, ts)
        }
        return null
    }

    private fun transition(becameStable: Boolean, ts: Long) = StabilityTransition(
        stable = becameStable,
        gyroMag = if (gyroMag.isFinite()) gyroMag else 0.0,
        linAccelMag = if (linAccelMag.isFinite()) linAccelMag else 0.0,
        timestampNs = ts,
    )
}
