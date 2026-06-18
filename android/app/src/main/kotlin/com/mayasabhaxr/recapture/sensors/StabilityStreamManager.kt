// android/app/src/main/kotlin/com/mayasabhaxr/recapture/sensors/StabilityStreamManager.kt
package com.mayasabhaxr.recapture.sensors

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel

/**
 * Stability gate: streams a debounced STABLE/UNSTABLE state (and a "stable"
 * trigger for the auto-capture flow) over an [EventChannel]. Consumes raw
 * `TYPE_GYROSCOPE` + `TYPE_LINEAR_ACCELERATION` (NOT the rotation-vector stream);
 * does not capture, smooth orientation, or do pose fusion.
 *
 * ## The gate
 * gyro magnitude < `gyroThresh` (default 0.8 rad/s) AND gravity-removed
 * linear-accel magnitude < `accelThresh` (default 0.15 g ≈ 1.47 m/s²), held
 * continuously for `dwellMs` (default 250). The two sensors arrive independently,
 * so the AND is evaluated on the most-recent value of EACH ([StabilityGate]); the
 * dwell is dt-aware (from sensor timestamps), reset on any break or gap.
 *
 * ## Linear acceleration (the 0.15 g check)
 * Uses `TYPE_LINEAR_ACCELERATION` (gravity already removed). Raw accelerometer
 * magnitude (~1 g at rest) is NEVER used for the threshold — it would never pass.
 * On devices lacking the linear-accel sensor, falls back to `TYPE_ACCELEROMETER`
 * with a [GravityEstimator] low-pass gravity removal (documented, approximate).
 *
 * ## Clock / threading / lifecycle
 * Sensor timestamps are converted to the camera-aligned CLOCK_MONOTONIC domain
 * (via [ImuRotationMath.toMonotonicNs], consistent with the IMU task) for emitted
 * timestamps; the dwell uses deltas, so the domain is immaterial to it. Sensor
 * callbacks run on a dedicated [HandlerThread]; transitions are marshalled to the
 * main thread for the [EventChannel.EventSink]. Registered on listen, unregistered
 * on cancel/background; the dwell is reset on (re)registration so a stale condition
 * never carries across a pause.
 *
 * ## Availability
 * If the gyroscope or any usable accelerometer is absent, reports an error
 * (`STABILITY_UNAVAILABLE`) rather than silently never triggering.
 */
class StabilityStreamManager(
    appContext: Context,
) : EventChannel.StreamHandler, SensorEventListener {

    companion object {
        // Must match AppConfig.channelStability on the Dart side.
        const val CHANNEL_NAME = "com.mayasabhaxr.recapture/stability"

        private const val ERR_UNAVAILABLE = "STABILITY_UNAVAILABLE"
    }

    private val sensorManager: SensorManager? =
        appContext.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val gyroSensor: Sensor? = sensorManager?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val linearAccelSensor: Sensor? =
        sensorManager?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
    private val rawAccelSensor: Sensor? =
        sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

    /** True when we must derive linear accel from the raw accelerometer + gravity. */
    private val usesGravityFallback: Boolean = linearAccelSensor == null && rawAccelSensor != null

    /** The accelerometer we actually register (real linear, else raw for fallback). */
    private val accelSensor: Sensor? = linearAccelSensor ?: rawAccelSensor

    private val mainHandler = Handler(Looper.getMainLooper())

    private var sensorThread: HandlerThread? = null
    private var sensorHandler: Handler? = null

    private var eventSink: EventChannel.EventSink? = null

    private val gate = StabilityGate()
    private val gravity = GravityEstimator()

    @Volatile
    private var listening = false

    @Volatile
    private var paused = false

    @Volatile
    private var registered = false

    @Volatile
    private var monotonicMinusBootNs = 0L

    @Volatile
    private var disposed = false

    // ── EventChannel.StreamHandler (platform main thread) ─────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        gate.config = configFrom(arguments)
        listening = true
        val missing = missingSensors()
        if (missing != null) {
            events?.error(ERR_UNAVAILABLE, missing, null)
            return
        }
        if (!paused) register()
    }

    override fun onCancel(arguments: Any?) {
        listening = false
        unregister()
        eventSink = null
    }

    private fun configFrom(arguments: Any?): StabilityConfig {
        val map = arguments as? Map<*, *> ?: return StabilityConfig.DEFAULT
        return StabilityConfig.build(
            gyroThreshRadS = (map["gyroThresh"] as? Number)?.toDouble(),
            accelThreshG = (map["accelThresh"] as? Number)?.toDouble(),
            dwellMs = (map["dwellMs"] as? Number)?.toLong(),
        )
    }

    /** Returns a message naming the missing required sensor, or null if all present. */
    private fun missingSensors(): String? {
        val missing = buildList {
            if (gyroSensor == null) add("gyroscope")
            if (accelSensor == null) add("accelerometer/linear-acceleration")
        }
        return if (missing.isEmpty()) null else "Stability sensors unavailable: ${missing.joinToString()}"
    }

    // ── host lifecycle (wired from MainActivity) ──────────────────────────────

    fun onHostPause() {
        paused = true
        unregister()
    }

    fun onHostResume() {
        paused = false
        if (listening && missingSensors() == null) register()
    }

    fun dispose() {
        disposed = true
        listening = false
        unregister()
        sensorThread?.quitSafely()
        sensorThread = null
        sensorHandler = null
        eventSink = null
    }

    // ── registration ──────────────────────────────────────────────────────────

    @Synchronized
    private fun register() {
        if (disposed || registered) return
        val manager = sensorManager ?: return
        val gyro = gyroSensor ?: return
        val accel = accelSensor ?: return
        ensureSensorThread()
        monotonicMinusBootNs = System.nanoTime() - SystemClock.elapsedRealtimeNanos()
        // Fresh sensor session ⇒ reset the dwell + gravity estimate (no stale carry).
        gate.reset()
        gravity.reset()
        val g = manager.registerListener(this, gyro, SensorManager.SENSOR_DELAY_GAME, sensorHandler)
        val a = manager.registerListener(this, accel, SensorManager.SENSOR_DELAY_GAME, sensorHandler)
        registered = g && a
    }

    @Synchronized
    private fun unregister() {
        if (!registered) return
        sensorManager?.unregisterListener(this)
        registered = false
    }

    private fun ensureSensorThread() {
        if (sensorThread?.isAlive == true && sensorHandler != null) return
        val thread = HandlerThread("stability-gate").also { it.start() }
        sensorThread = thread
        sensorHandler = Handler(thread.looper)
    }

    // ── SensorEventListener (dedicated sensor thread) ─────────────────────────

    override fun onSensorChanged(event: SensorEvent) {
        if (disposed) return
        val ts = ImuRotationMath.toMonotonicNs(event.timestamp, monotonicMinusBootNs)
        val transition = when (event.sensor.type) {
            Sensor.TYPE_GYROSCOPE -> {
                val mag = StabilityMath.magnitude(
                    event.values[0].toDouble(),
                    event.values[1].toDouble(),
                    event.values[2].toDouble(),
                )
                gate.onGyro(mag, ts)
            }

            Sensor.TYPE_LINEAR_ACCELERATION -> {
                val mag = StabilityMath.magnitude(
                    event.values[0].toDouble(),
                    event.values[1].toDouble(),
                    event.values[2].toDouble(),
                )
                gate.onLinearAccel(mag, ts)
            }

            Sensor.TYPE_ACCELEROMETER -> {
                // Fallback path: remove gravity to approximate linear acceleration.
                val mag = gravity.linearMagnitude(
                    event.values[0].toDouble(),
                    event.values[1].toDouble(),
                    event.values[2].toDouble(),
                    ts,
                )
                gate.onLinearAccel(mag, ts)
            }

            else -> null
        }
        transition?.let { emit(it) }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // Stability uses magnitudes only; sensor accuracy is not part of the gate.
    }

    // ── emit (transitions only; sink touched on the main thread) ──────────────

    private fun emit(t: StabilityTransition) {
        val state = mapOf(
            "type" to "state",
            "stable" to t.stable,
            "gyroMag" to t.gyroMag,
            "linAccelMag" to t.linAccelMag,
            "timestampNs" to t.timestampNs,
        )
        // On entering STABLE, also emit the auto-capture trigger.
        val trigger = if (t.stable) {
            mapOf("type" to "trigger", "event" to "stable", "timestampNs" to t.timestampNs)
        } else {
            null
        }
        mainHandler.post {
            if (disposed) return@post
            eventSink?.success(state)
            if (trigger != null) eventSink?.success(trigger)
        }
    }
}
