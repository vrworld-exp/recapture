// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/CameraControlsManager.kt
package com.mayasabhaxr.recapture.camera

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.core.Camera
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Manual focus / exposure **lock** controls layered onto the existing CameraX
 * session owned by [CameraPreviewManager]. Operates on that session's bound
 * [Camera] via Camera2 interop ([Camera2CameraControl] / [Camera2CameraInfo]) —
 * it never creates, rebinds, or releases a camera.
 *
 * Capabilities are gated by the device: each control is offered only when the
 * hardware supports it, and defensive calls for unsupported controls no-op.
 *
 * Rebind decision: **reset to auto** (spec default). [updateCamera] is invoked by
 * the preview manager on every bind/unbind; a new (or null) camera drops all
 * tracked lock state, so a session always starts in full auto and the caller
 * re-locks as needed.
 *
 * Threading: capability reads are cheap synchronous characteristic lookups.
 * Applying options goes through [Camera2CameraControl.setCaptureRequestOptions],
 * which dispatches to CameraX's own executor (off the main thread); the returned
 * future's completion resolves the MethodChannel result back on the main thread.
 *
 * Scope is focus/exposure control only — no permission, session lifecycle,
 * capture, or analysis work.
 */
class CameraControlsManager(private val appContext: Context) {

    companion object {
        private const val ERR_NO_CAMERA = "NO_CAMERA"
        private const val ERR_UNSUPPORTED = "UNSUPPORTED"
    }

    private val mainExecutor = ContextCompat.getMainExecutor(appContext)

    private var camera: Camera? = null
    private var camera2Control: Camera2CameraControl? = null

    // Device capabilities for the currently bound camera.
    private var aeLockAvailable = false
    private var awbLockAvailable = false
    private var manualFocusAvailable = false
    private var minFocusDistance = 0f // diopters; max of the focus-distance range

    // Camera intrinsics for the bound camera (read once per bind on the main
    // thread; null if not exposed by the device — never fabricated). Read from the
    // capture-executor thread by the metadata snapshot, so @Volatile for safe
    // publication. Consumed by the metadata task.
    @Volatile private var cameraId: String? = null
    @Volatile private var focalLengthMm: Float? = null
    @Volatile private var fNumber: Float? = null
    @Volatile private var sensorWidthMm: Float? = null
    @Volatile private var sensorHeightMm: Float? = null

    // Tracked lock state (source of truth, rebuilt into CaptureRequestOptions).
    private val lock = Any()
    private var aeLocked = false
    private var awbLocked = false
    private var afHeld = false // AF held via startFocusAndMetering (lockForCapture / setFocusLocked)
    private var manualFocusDistance: Float? = null // non-null ⇒ AF_MODE OFF + this distance

    /**
     * Called by [CameraPreviewManager.onCameraChanged] on the main thread. A new
     * camera (or null) is a fresh session → reset all tracked locks to auto.
     */
    fun updateCamera(camera: Camera?) {
        synchronized(lock) {
            aeLocked = false
            awbLocked = false
            afHeld = false
            manualFocusDistance = null
        }
        this.camera = camera
        if (camera == null) {
            camera2Control = null
            aeLockAvailable = false
            awbLockAvailable = false
            manualFocusAvailable = false
            minFocusDistance = 0f
            clearIntrinsics()
            return
        }
        camera2Control = Camera2CameraControl.from(camera.cameraControl)
        readCapabilities(camera)
    }

    private fun readCapabilities(camera: Camera) {
        val info = Camera2CameraInfo.from(camera.cameraInfo)
        aeLockAvailable =
            info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true
        awbLockAvailable =
            info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true

        val min = info.getCameraCharacteristic(
            CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE,
        ) ?: 0f
        val afModes = info.getCameraCharacteristic(
            CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES,
        ) ?: IntArray(0)
        val supportsAfOff = afModes.contains(CameraMetadata.CONTROL_AF_MODE_OFF)
        // Manual focus needs both a real focus range and the OFF AF mode.
        manualFocusAvailable = min > 0f && supportsAfOff
        minFocusDistance = if (min > 0f) min else 0f

        readIntrinsics(info)
    }

    /**
     * Reads camera intrinsics once per bind for the capture-metadata sidecar.
     * Each field is left null when the device does not expose it (no fabrication).
     */
    private fun readIntrinsics(info: Camera2CameraInfo) {
        cameraId = runCatching { info.cameraId }.getOrNull()
        focalLengthMm = info
            .getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            ?.firstOrNull()
            ?.takeIf { it > 0f }
        fNumber = info
            .getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)
            ?.firstOrNull()
            ?.takeIf { it > 0f }
        val physical = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        sensorWidthMm = physical?.width?.takeIf { it > 0f }
        sensorHeightMm = physical?.height?.takeIf { it > 0f }
    }

    private fun clearIntrinsics() {
        cameraId = null
        focalLengthMm = null
        fNumber = null
        sensorWidthMm = null
        sensorHeightMm = null
    }

    /** Snapshot of the bound camera's intrinsics for the sidecar (nullable fields). */
    fun snapshotIntrinsics(): CameraIntrinsics = CameraIntrinsics(
        focalLengthMm = focalLengthMm?.toDouble(),
        fNumber = fNumber?.toDouble(),
        sensorWidthMm = sensorWidthMm?.toDouble(),
        sensorHeightMm = sensorHeightMm?.toDouble(),
        cameraId = cameraId,
    )

    /** Snapshot of the current lock/capture conditions for the sidecar. */
    fun snapshotConditions(): CaptureConditions = synchronized(lock) {
        CaptureConditions(
            afLocked = afHeld || manualFocusDistance != null,
            aeLocked = aeLocked,
            awbLocked = awbLocked,
            // Not observed here (no CaptureResult callback) — left null, not faked.
            exposureTimeNs = null,
            iso = null,
            focusDistanceDiopters = manualFocusDistance?.toDouble(),
        )
    }

    // ── MethodChannel entry points (called on the main thread) ────────────────

    fun getCapabilities(result: MethodChannel.Result) {
        val caps = mutableMapOf<String, Any?>(
            "aeLock" to (camera2Control != null && aeLockAvailable),
            "awbLock" to (camera2Control != null && awbLockAvailable),
            "manualFocus" to (camera2Control != null && manualFocusAvailable),
        )
        if (camera2Control != null && manualFocusAvailable) {
            caps["focusDistanceRange"] = mapOf(
                "min" to 0.0,
                "max" to minFocusDistance.toDouble(),
            )
        }
        result.success(caps)
    }

    fun setExposureLock(locked: Boolean, result: MethodChannel.Result) {
        if (!ensureSupported(aeLockAvailable, result)) return
        synchronized(lock) { aeLocked = locked }
        applyOptions(result)
    }

    fun setAutoWhiteBalanceLock(locked: Boolean, result: MethodChannel.Result) {
        if (!ensureSupported(awbLockAvailable, result)) return
        synchronized(lock) { awbLocked = locked }
        applyOptions(result)
    }

    /**
     * AF hold: locks the current focus without manual-distance hardware via a
     * non-auto-cancel center [FocusMeteringAction]; unlock resumes auto AF.
     * Unlocking also clears any manual focus distance (full AF unlock).
     */
    fun setFocusLocked(locked: Boolean, result: MethodChannel.Result) {
        val cam = camera
        if (cam == null) {
            result.error(ERR_NO_CAMERA, "No camera bound.", null)
            return
        }
        if (locked) {
            // AF hold and manual distance conflict — drop any manual distance first.
            val hadManual: Boolean
            synchronized(lock) {
                hadManual = manualFocusDistance != null
                manualFocusDistance = null
                afHeld = true
            }
            if (hadManual) applyOptions(null) // clear the AF_MODE OFF override

            val factory = SurfaceOrientedMeteringPointFactory(1f, 1f)
            val point = factory.createPoint(0.5f, 0.5f)
            val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF)
                .disableAutoCancel() // hold — do not revert after the timeout
                .build()
            val future = cam.cameraControl.startFocusAndMetering(action)
            future.addListener({ replySafely(result) }, mainExecutor)
        } else {
            // Resume auto AF: cancel the held metering and drop manual distance.
            val hadManual: Boolean
            synchronized(lock) {
                hadManual = manualFocusDistance != null
                manualFocusDistance = null
                afHeld = false
            }
            val future = cam.cameraControl.cancelFocusAndMetering()
            if (hadManual) {
                // Re-apply options (now without AF_MODE OFF) after cancel completes.
                future.addListener({ applyOptions(result) }, mainExecutor)
            } else {
                future.addListener({ replySafely(result) }, mainExecutor)
            }
        }
    }

    /**
     * Manual focus distance in diopters, clamped to `[0, minFocusDistance]`
     * (0 = infinity). Implies `AF_MODE = OFF`. Capability-gated.
     */
    fun setManualFocusDistance(distance: Double, result: MethodChannel.Result) {
        if (!ensureSupported(manualFocusAvailable, result)) return
        val clamped = distance.toFloat().coerceIn(0f, minFocusDistance)
        synchronized(lock) { manualFocusDistance = clamped }
        applyOptions(result)
    }

    /**
     * Best-effort lock of AE + focus for a capture run (called by
     * [CameraCaptureManager] before a burst/auto-capture). Locks AE if supported
     * and holds AF; unsupported pieces are skipped. Fire-and-forget — no result.
     * Per the rebind decision, a later background rebind resets these to auto.
     */
    fun lockForCapture() {
        if (camera2Control != null && aeLockAvailable) {
            synchronized(lock) {
                aeLocked = true
                manualFocusDistance = null // AF hold (below) and manual distance conflict
            }
            applyOptions(null)
        }
        camera?.let { cam ->
            val factory = SurfaceOrientedMeteringPointFactory(1f, 1f)
            val point = factory.createPoint(0.5f, 0.5f)
            val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF)
                .disableAutoCancel()
                .build()
            cam.cameraControl.startFocusAndMetering(action)
            synchronized(lock) { afHeld = true }
        }
    }

    /** Restore auto AE/AF/AWB and clear all manual options. */
    fun unlockAll(result: MethodChannel.Result) {
        val control = camera2Control
        val cam = camera
        synchronized(lock) {
            aeLocked = false
            awbLocked = false
            afHeld = false
            manualFocusDistance = null
        }
        // Cancel any held AF metering, then drop every interop override.
        cam?.cameraControl?.cancelFocusAndMetering()
        if (control == null) {
            result.success(null)
            return
        }
        control.clearCaptureRequestOptions().addListener({ replySafely(result) }, mainExecutor)
    }

    // ── internals ─────────────────────────────────────────────────────────────

    private fun ensureSupported(available: Boolean, result: MethodChannel.Result): Boolean {
        if (camera2Control == null) {
            result.error(ERR_NO_CAMERA, "No camera bound.", null)
            return false
        }
        if (!available) {
            // Defensive no-op for an unsupported control (UI should have hidden it).
            result.error(ERR_UNSUPPORTED, "Control not supported on this device.", null)
            return false
        }
        return true
    }

    /**
     * Rebuilds the interop options from the tracked state and applies them. Clears
     * first so a removed key (e.g. AF_MODE when leaving manual focus) is dropped,
     * then sets the rebuilt options. Resolves [result] when the set completes.
     */
    private fun applyOptions(result: MethodChannel.Result?) {
        val control = camera2Control
        if (control == null) {
            result?.error(ERR_NO_CAMERA, "No camera bound.", null)
            return
        }
        control.clearCaptureRequestOptions().addListener({
            val opts = buildOptions()
            control.setCaptureRequestOptions(opts).addListener({
                replySafely(result)
            }, mainExecutor)
        }, mainExecutor)
    }

    private fun buildOptions(): CaptureRequestOptions {
        val builder = CaptureRequestOptions.Builder()
        synchronized(lock) {
            if (aeLockAvailable) {
                builder.setCaptureRequestOption(CaptureRequest.CONTROL_AE_LOCK, aeLocked)
            }
            if (awbLockAvailable) {
                builder.setCaptureRequestOption(CaptureRequest.CONTROL_AWB_LOCK, awbLocked)
            }
            manualFocusDistance?.let { d ->
                builder.setCaptureRequestOption(
                    CaptureRequest.CONTROL_AF_MODE,
                    CameraMetadata.CONTROL_AF_MODE_OFF,
                )
                builder.setCaptureRequestOption(CaptureRequest.LENS_FOCUS_DISTANCE, d)
            }
        }
        return builder.build()
    }

    private fun replySafely(result: MethodChannel.Result?) {
        try {
            result?.success(null)
        } catch (_: Exception) {
            // Channel/engine already gone — nothing to deliver.
        }
    }
}
