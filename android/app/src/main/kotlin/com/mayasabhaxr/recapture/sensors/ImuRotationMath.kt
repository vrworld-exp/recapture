// android/app/src/main/kotlin/com/mayasabhaxr/recapture/sensors/ImuRotationMath.kt
package com.mayasabhaxr.recapture.sensors

/**
 * Pure, framework-free helpers for the rotation-vector stream:
 *
 *  - requested-rate clamping + the rate→sampling-period (µs) mapping,
 *  - quaternion extraction from a `SensorEvent`'s `values` (incl. the older
 *    3-value sensor that omits `w`), normalized to a unit quaternion,
 *  - the boot→monotonic clock conversion — the camera-alignment key.
 *
 * Deliberately free of Android *runtime* classes (only plain JDK math) so the
 * sampling-period math, quaternion handling, and clock conversion are
 * JVM-unit-testable without a device/Robolectric — mirroring the capture task's
 * pure `ResolutionMath` / `CaptureMetadata` helpers.
 */
object ImuRotationMath {

    /** Supported streaming window (Hz). The OS treats the rate as best-effort. */
    const val MIN_RATE_HZ = 50
    const val MAX_RATE_HZ = 100
    const val DEFAULT_RATE_HZ = 100

    /** Clamps a requested rate into the supported 50..100 Hz window. */
    fun clampRateHz(requested: Int?): Int =
        (requested ?: DEFAULT_RATE_HZ).coerceIn(MIN_RATE_HZ, MAX_RATE_HZ)

    /**
     * Sampling period (microseconds) to pass to `SensorManager.registerListener`
     * for [rateHz] (clamped): 100 Hz → 10_000 µs, 50 Hz → 20_000 µs. This is a
     * hint; the OS delivers best-effort, so consumers rely on per-sample
     * timestamps, not this cadence.
     */
    fun samplingPeriodUs(rateHz: Int): Int = 1_000_000 / clampRateHz(rateHz)

    /**
     * Builds a normalized unit quaternion `[x, y, z, w]` from a rotation-vector
     * sensor's `values`. Modern sensors supply `w` in `values[3]`; older ones
     * supply only x,y,z, so `w` is derived as `sqrt(1 - (x²+y²+z²))` (clamped ≥ 0).
     * The result is renormalized to absorb tiny numeric drift; a degenerate
     * (zero/non-finite) vector falls back to the identity quaternion `[0,0,0,1]`.
     */
    fun quaternion(values: FloatArray): DoubleArray {
        val x = values.getOrElse(0) { 0f }.toDouble()
        val y = values.getOrElse(1) { 0f }.toDouble()
        val z = values.getOrElse(2) { 0f }.toDouble()
        val w = if (values.size >= 4) {
            values[3].toDouble()
        } else {
            val t = 1.0 - (x * x + y * y + z * z)
            if (t > 0.0) Math.sqrt(t) else 0.0
        }
        return normalize(x, y, z, w)
    }

    private fun normalize(x: Double, y: Double, z: Double, w: Double): DoubleArray {
        val norm = Math.sqrt(x * x + y * y + z * z + w * w)
        if (norm <= 0.0 || !norm.isFinite()) return doubleArrayOf(0.0, 0.0, 0.0, 1.0)
        return doubleArrayOf(x / norm, y / norm, z / norm, w / norm)
    }

    /**
     * Converts a CLOCK_BOOTTIME sensor timestamp (`SensorEvent.timestamp`,
     * `elapsedRealtimeNanos`) into the camera's CLOCK_MONOTONIC domain (the
     * `captureTimestampNs` the capture task records) by adding the measured
     * offset `monotonicMinusBootNs = System.nanoTime() − elapsedRealtimeNanos()`.
     *
     * During an active foreground capture there is no deep sleep, so the offset is
     * stable across the session and the conversion is exact. See the manager for
     * where the offset is sampled, and docs/camera/imu-rotation-stream.md for the
     * full clock-domain rationale.
     */
    fun toMonotonicNs(sensorBootNs: Long, monotonicMinusBootNs: Long): Long =
        sensorBootNs + monotonicMinusBootNs
}
