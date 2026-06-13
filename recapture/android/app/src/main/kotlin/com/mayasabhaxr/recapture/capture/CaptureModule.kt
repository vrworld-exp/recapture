// android/app/src/main/kotlin/com/mayasabhaxr/recapture/capture/CaptureModule.kt
package com.mayasabhaxr.recapture.capture

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * CaptureModule — Native capture module for ReCapture (Android).
 *
 * STUB IMPLEMENTATION — Phase P0.
 * Real camera (CameraX), sensor (IMU), and blur detection logic is implemented
 * in Phase P3 (Native Camera & Sensor Pipeline). This stub exists to:
 *   1. Establish the MethodChannel registration pattern
 *   2. Prove the Flutter ↔ Kotlin bridge works end-to-end
 *   3. Define the exact response shapes that P3 implementations must match
 *
 * Channel contract (must match lib/platform/method_channels.dart exactly):
 *   Channel name: com.mayasabhaxr.recapture/capture
 *   Methods: startCapture, stopCapture, takePicture, getOrientation
 *
 * P3 TODO: Replace each stub method body with real implementation:
 *   - startCapture  → initialize CameraX session + IMU listener
 *   - stopCapture   → tear down camera session, return real capture summary
 *   - takePicture   → capture photo, run blur/exposure checks, save to disk
 *   - getOrientation → return latest IMU sensor frame (yaw/pitch/roll/gyro/accel)
 */
class CaptureModule(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        /** Must match AppConfig.channelCapture in lib/utils/constants.dart */
        const val CHANNEL_NAME = "com.mayasabhaxr.recapture/capture"

        // Method names — must match constants in lib/platform/method_channels.dart
        private const val METHOD_START_CAPTURE = "startCapture"
        private const val METHOD_STOP_CAPTURE = "stopCapture"
        private const val METHOD_TAKE_PICTURE = "takePicture"
        private const val METHOD_GET_ORIENTATION = "getOrientation"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_START_CAPTURE -> handleStartCapture(result)
            METHOD_STOP_CAPTURE -> handleStopCapture(result)
            METHOD_TAKE_PICTURE -> handleTakePicture(result)
            METHOD_GET_ORIENTATION -> handleGetOrientation(result)
            else -> result.notImplemented()
        }
    }

    /**
     * STUB: Starts a capture session.
     * P3: Initialize CameraX PreviewView + ImageCapture use cases,
     *     start IMU sensor listener (TYPE_ROTATION_VECTOR @ 50-100Hz).
     */
    private fun handleStartCapture(result: MethodChannel.Result) {
        val response = mapOf(
            "status" to "started",
            "sessionId" to "stub-session-${System.currentTimeMillis()}"
        )
        result.success(response)
    }

    /**
     * STUB: Stops the active capture session.
     * P3: Tear down CameraX session, stop IMU listener,
     *     return real accepted photo count for the session.
     */
    private fun handleStopCapture(result: MethodChannel.Result) {
        val response = mapOf(
            "status" to "stopped",
            "totalPhotos" to 0
        )
        result.success(response)
    }

    /**
     * STUB: Captures a single photo.
     * P3: Trigger ImageCapture, run blur detection (Laplacian variance on
     *     downscaled grayscale, width 640) and exposure check (mean luminance),
     *     save to local project folder, return real metadata.
     */
    private fun handleTakePicture(result: MethodChannel.Result) {
        val response = mapOf(
            "filePath" to "/stub/path/to/photo.jpg",
            "timestamp" to System.currentTimeMillis(),
            "blurScore" to 95.0,
            "accepted" to true
        )
        result.success(response)
    }

    /**
     * STUB: Returns the latest device orientation reading.
     * P3: Return real IMU data from TYPE_ROTATION_VECTOR sensor
     *     (yaw/pitch/roll computed from rotation vector + low-pass filter),
     *     plus gyro magnitude and linear acceleration magnitude for the
     *     stability gate.
     */
    private fun handleGetOrientation(result: MethodChannel.Result) {
        val response = mapOf(
            "yaw" to 0.0,
            "pitch" to 0.0,
            "roll" to 0.0,
            "gyroMagnitude" to 0.0,
            "accelMagnitude" to 0.0,
            "timestamp" to System.currentTimeMillis()
        )
        result.success(response)
    }
}
