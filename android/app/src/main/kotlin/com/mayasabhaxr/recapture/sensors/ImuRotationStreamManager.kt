// android/app/src/main/kotlin/com/mayasabhaxr/recapture/sensors/ImuRotationStreamManager.kt
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
 * Streams device orientation from `TYPE_ROTATION_VECTOR` to Flutter over an
 * [EventChannel] at a configurable 50–100 Hz. Produces the stream only — no
 * pose/frame fusion (that task joins these samples to frames), no camera work, no
 * other sensors.
 *
 * ## Clock domain (the correctness crux)
 * `SensorEvent.timestamp` is nanoseconds on **CLOCK_BOOTTIME**
 * (`elapsedRealtimeNanos`; advances during deep sleep). CameraX image timestamps
 * in this app are treated as **CLOCK_MONOTONIC** (`System.nanoTime`) — the
 * `captureTimestampNs` the capture task records per frame. If the two streams sat
 * on different clocks, frame↔pose alignment would be silently wrong. So every
 * emitted `timestampNs` is **converted into the camera's monotonic domain** by
 * adding a measured offset `(System.nanoTime() − elapsedRealtimeNanos())`, sampled
 * once per (re)registration. During an active foreground capture there is no deep
 * sleep, so the offset is stable for the session and the conversion is exact.
 * See docs/camera/imu-rotation-stream.md.
 *
 * ## Threading
 * Sensor callbacks are delivered on a dedicated [HandlerThread] (never the main
 * thread, even at 100 Hz). Each sample is marshalled to the platform main thread
 * before the [EventChannel.EventSink] is touched — the sink contract requires it.
 *
 * ## Lifecycle
 * Registered on stream-listen (and on foreground if still listening); unregistered
 * on cancel, explicit teardown, and background — no listener leak, no battery
 * drain. The [HandlerThread] is quit on [dispose]. Registration is guarded against
 * double-register and register-after-dispose.
 *
 * ## Availability
 * If the device lacks `TYPE_ROTATION_VECTOR`, the stream reports an error
 * (`SENSOR_UNAVAILABLE`) rather than producing a silent empty stream. Sensor
 * accuracy/status rides along on every sample so consumers can weight or ignore
 * low-accuracy (uncalibrated-magnetometer) yaw.
 *
 * ## Smoothed orientation (parallel channel)
 * A second EventChannel (`imu_orientation`, [orientationHandler]) emits the
 * low-pass-**filtered** orientation — yaw/pitch/roll + smoothed quaternion — for a
 * UI capture guide, via [OrientationFilter]. Both channels share this one sensor
 * registration (the IMU task owns the sensor); the listener is registered when
 * EITHER channel is subscribed and dropped only when both are gone. The raw stream
 * stays untouched for the pose/frame-fusion task; smoothing never alters it.
 */
class ImuRotationStreamManager(
    appContext: Context,
) : EventChannel.StreamHandler, SensorEventListener {

    companion object {
        // Must match AppConfig.channelImuRotation on the Dart side.
        const val CHANNEL_NAME = "com.mayasabhaxr.recapture/imu_rotation"

        // Must match AppConfig.channelImuOrientation on the Dart side.
        const val ORIENTATION_CHANNEL_NAME = "com.mayasabhaxr.recapture/imu_orientation"

        private const val ERR_UNAVAILABLE = "SENSOR_UNAVAILABLE"
    }

    private val sensorManager: SensorManager? =
        appContext.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val rotationSensor: Sensor? =
        sensorManager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Dedicated thread for high-rate sensor callbacks (off the main thread). */
    private var sensorThread: HandlerThread? = null
    private var sensorHandler: Handler? = null

    /** Raw rotation-vector sink (this class is the raw channel's StreamHandler). */
    private var rawSink: EventChannel.EventSink? = null

    /** Smoothed-orientation sink (the [orientationHandler]'s StreamHandler). */
    private var orientationSink: EventChannel.EventSink? = null

    /** Low-pass filter for the smoothed channel (quaternion-domain, dt-aware). */
    private val filter = OrientationFilter()

    /** True between onListen and onCancel on the RAW channel. */
    @Volatile
    private var rawListening = false

    /** True between onListen and onCancel on the ORIENTATION channel. */
    @Volatile
    private var orientationListening = false

    /** True while the host Activity is backgrounded (no streaming while away). */
    @Volatile
    private var paused = false

    /** True while [rotationSensor] is registered with the [SensorManager]. */
    @Volatile
    private var registered = false

    /** Requested rate, clamped to 50..100 Hz on listen. */
    @Volatile
    private var rateHz = ImuRotationMath.DEFAULT_RATE_HZ

    /** `monotonic − boot` offset (ns), re-measured at each registration. */
    @Volatile
    private var monotonicMinusBootNs = 0L

    /** Latest reported sensor accuracy (stamped onto every emitted sample). */
    @Volatile
    private var accuracy = SensorManager.SENSOR_STATUS_UNRELIABLE

    @Volatile
    private var disposed = false

    // ── raw channel: EventChannel.StreamHandler (platform main thread) ────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        rawSink = events
        rateHz = ImuRotationMath.clampRateHz(rateArg(arguments))
        rawListening = true
        if (reportUnavailable(events)) return
        if (!paused) register()
    }

    override fun onCancel(arguments: Any?) {
        rawListening = false
        rawSink = null
        maybeUnregister()
    }

    // ── orientation channel: smoothed yaw/pitch/roll (parallel StreamHandler) ──

    /** StreamHandler for the parallel smoothed-orientation channel. */
    val orientationHandler: EventChannel.StreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) =
            onOrientationListen(arguments, events)

        override fun onCancel(arguments: Any?) = onOrientationCancel()
    }

    private fun onOrientationListen(arguments: Any?, events: EventChannel.EventSink?) {
        orientationSink = events
        // Either channel may set the rate; whichever (re)subscribes applies it on
        // the next registration. The orientation channel also tunes τ.
        rateHz = ImuRotationMath.clampRateHz(rateArg(arguments))
        applyTau(arguments)
        orientationListening = true
        // A fresh subscription starts the filter clean (also re-init on resume in
        // register()), so it never blends from a stale orientation.
        filter.reset()
        if (reportUnavailable(events)) return
        if (!paused) register()
    }

    private fun onOrientationCancel() {
        orientationListening = false
        orientationSink = null
        maybeUnregister()
    }

    /** Reports the absent sensor on [events]; returns true if it is unavailable. */
    private fun reportUnavailable(events: EventChannel.EventSink?): Boolean {
        if (rotationSensor != null) return false
        // Report unavailable rather than a silent empty stream. The listener stays
        // "subscribed" so a re-listen after onCancel re-reports honestly.
        events?.error(ERR_UNAVAILABLE, "TYPE_ROTATION_VECTOR sensor not available.", null)
        return true
    }

    private fun rateArg(arguments: Any?): Int? {
        val map = arguments as? Map<*, *> ?: return null
        return (map["rateHz"] as? Number)?.toInt()
    }

    /** Reads an optional `tauMs` (smoothing time constant) into the filter. */
    private fun applyTau(arguments: Any?) {
        val map = arguments as? Map<*, *> ?: return
        val tauMs = (map["tauMs"] as? Number)?.toDouble() ?: return
        filter.tauNs = tauMs * 1_000_000.0
    }

    // ── host lifecycle (wired from MainActivity) ──────────────────────────────

    /** App backgrounded: drop the listener so it never drains battery while away. */
    fun onHostPause() {
        paused = true
        unregister()
    }

    /** App foregrounded: re-register only if either stream is still subscribed. */
    fun onHostResume() {
        paused = false
        if ((rawListening || orientationListening) && rotationSensor != null) register()
    }

    fun dispose() {
        disposed = true
        rawListening = false
        orientationListening = false
        unregister()
        sensorThread?.quitSafely()
        sensorThread = null
        sensorHandler = null
        rawSink = null
        orientationSink = null
    }

    // ── registration (guarded against double-register / post-dispose) ─────────

    @Synchronized
    private fun register() {
        if (disposed || registered) return
        val sensor = rotationSensor ?: return
        val manager = sensorManager ?: return
        ensureSensorThread()
        // Sample the boot→monotonic offset at registration; during a foreground
        // capture there is no deep sleep, so it stays valid for the session.
        monotonicMinusBootNs = System.nanoTime() - SystemClock.elapsedRealtimeNanos()
        // A new sensor session ⇒ the smoothing filter starts fresh.
        filter.reset()
        registered = manager.registerListener(
            this,
            sensor,
            ImuRotationMath.samplingPeriodUs(rateHz),
            sensorHandler,
        )
    }

    /** Unregisters only when neither channel is subscribed any more. */
    @Synchronized
    private fun maybeUnregister() {
        if (rawListening || orientationListening) return
        unregister()
    }

    @Synchronized
    private fun unregister() {
        if (!registered) return
        sensorManager?.unregisterListener(this)
        registered = false
    }

    private fun ensureSensorThread() {
        if (sensorThread?.isAlive == true && sensorHandler != null) return
        val thread = HandlerThread("imu-rotation").also { it.start() }
        sensorThread = thread
        sensorHandler = Handler(thread.looper)
    }

    // ── SensorEventListener (delivered on the dedicated sensor thread) ─────────

    override fun onSensorChanged(event: SensorEvent) {
        if (disposed || event.sensor.type != Sensor.TYPE_ROTATION_VECTOR) return
        // Compact, allocation-light payload: a fresh Float64-friendly DoubleArray
        // for the quaternion (encoded as Float64List on the wire) + two scalars.
        val q = ImuRotationMath.quaternion(event.values)
        val ts = ImuRotationMath.toMonotonicNs(event.timestamp, monotonicMinusBootNs)
        val acc = accuracy

        // Raw stream (untouched by smoothing). The EventSink MUST be touched on the
        // platform main thread only.
        if (rawSink != null) {
            val rawPayload = mapOf("q" to q, "accuracy" to acc, "timestampNs" to ts)
            mainHandler.post { if (!disposed) rawSink?.success(rawPayload) }
        }

        // Smoothed orientation stream. The filter runs HERE, on the sensor thread
        // (cheap quaternion ops); only the emit is marshalled to main. Timestamp +
        // clock domain are preserved unchanged from the source sample.
        if (orientationSink != null) {
            val s = filter.filter(q, ts)
            val orientationPayload = mapOf(
                "yaw" to s.yaw,
                "pitch" to s.pitch,
                "roll" to s.roll,
                "q" to doubleArrayOf(s.qx, s.qy, s.qz, s.qw),
                "timestampNs" to s.timestampNs,
            )
            mainHandler.post { if (!disposed) orientationSink?.success(orientationPayload) }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        if (sensor?.type == Sensor.TYPE_ROTATION_VECTOR) this.accuracy = accuracy
    }
}
