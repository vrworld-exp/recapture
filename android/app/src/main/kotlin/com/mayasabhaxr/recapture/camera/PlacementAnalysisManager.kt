// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/PlacementAnalysisManager.kt
package com.mayasabhaxr.recapture.camera

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.objects.ObjectDetection
import com.google.mlkit.vision.objects.ObjectDetector
import com.google.mlkit.vision.objects.defaults.ObjectDetectorOptions
import io.flutter.plugin.common.EventChannel

/**
 * Real-time object PLACEMENT detection for the centre-frame guide: per analyzed
 * frame (throttled) it runs ML Kit's on-device object detector (STREAM_MODE, most
 * prominent object, bundled model — no Play Services dependency) and streams the
 * object's NORMALIZED bounding box to Flutter:
 * `{ hasObject, left, top, right, bottom, trackingId, timestampNs, frameIndex }`.
 * Coordinates are normalized 0..1 in the UPRIGHT image frame (rotation applied),
 * the same space as the Dart `PlacementBox` guide, so the Dart evaluator can map
 * box → PlacementStatus without knowing sensor geometry.
 *
 * DETECTION ONLY — the good/offCenter/tooClose/tooFar decision lives in the Dart
 * placement evaluator, mirroring the blur split (native metric, Dart policy).
 *
 * ## Frame sharing + deferred close
 * This manager does NOT own an ImageAnalysis use case (Preview + ImageCapture +
 * ImageAnalysis already saturates the guaranteed CameraX combination). It is a
 * THIRD consumer of [BlurAnalysisManager]'s single analyzer pass, like exposure —
 * but ML Kit processes ASYNCHRONOUSLY from the live `media.Image`, so when a frame
 * is taken ([maybeProcess] returns true) THIS manager assumes ownership of closing
 * the [ImageProxy] (in the task's completion listener; a leaked proxy stalls the
 * analyzer). With STRATEGY_KEEP_ONLY_LATEST the analyzer simply skips frames while
 * one is held — the [MIN_PROCESS_INTERVAL_MS] throttle bounds that stall so the
 * blur/exposure cadence is barely affected.
 *
 * ## Failure = absence, never a crash
 * Detector creation and processing are guarded: an unavailable/failed detector
 * emits a single PLACEMENT_UNAVAILABLE error and stops taking frames — the Dart
 * side degrades the guide to idle (white), never red, never an exception.
 */
class PlacementAnalysisManager : EventChannel.StreamHandler {

    companion object {
        // Must match AppConfig.channelPlacement on the Dart side.
        const val CHANNEL_NAME = "com.mayasabhaxr.recapture/placement"

        /** Floor between detector invocations (~10 Hz) — guidance does not need
         * more, and it bounds how long the shared analyzer is stalled per frame. */
        private const val MIN_PROCESS_INTERVAL_MS = 100L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    @Volatile
    private var disposed = false

    /** True while an ML Kit task holds a frame (set on the analyzer thread,
     * cleared on the task's completion thread). */
    @Volatile
    private var inFlight = false

    /** Detector creation failed → stop taking frames (error emitted once). */
    @Volatile
    private var unavailable = false

    /** Analyzer-thread only. */
    private var lastAttemptAtMs = 0L

    /** Lazy so a broken ML Kit install fails on first use, not at bind. */
    private var detector: ObjectDetector? = null

    /** Whether the analyzer should hand frames over at all (cheap pre-check). */
    val isActive: Boolean
        get() = !disposed && !unavailable && eventSink != null

    // ── EventChannel.StreamHandler (platform main thread) ─────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        disposed = true
        eventSink = null
        runCatching { detector?.close() }
        detector = null
    }

    // ── analyzer thread (called by BlurAnalysisManager.analyze) ───────────────

    /**
     * Offers [image] to the detector. Returns TRUE when this manager takes
     * ownership (it will close the proxy on task completion); FALSE when the
     * frame was skipped (caller closes as usual). Skips while a task is in
     * flight, inside the throttle window, or when the detector is unavailable.
     */
    @OptIn(ExperimentalGetImage::class)
    fun maybeProcess(image: ImageProxy, timestampNs: Long, frameIndex: Long): Boolean {
        if (!isActive || inFlight) return false
        val now = SystemClock.elapsedRealtime()
        if (now - lastAttemptAtMs < MIN_PROCESS_INTERVAL_MS) return false
        val mediaImage = image.image ?: return false
        val det = obtainDetector() ?: return false

        lastAttemptAtMs = now
        inFlight = true
        val rotation = image.imageInfo.rotationDegrees
        // Upright dimensions: ML Kit reports bounding boxes in the ROTATED frame.
        val uprightW = if (rotation % 180 == 0) image.width else image.height
        val uprightH = if (rotation % 180 == 0) image.height else image.width
        return try {
            det.process(InputImage.fromMediaImage(mediaImage, rotation))
                .addOnSuccessListener { objects ->
                    emitResult(objects.firstOrNull(), uprightW, uprightH, timestampNs, frameIndex)
                }
                .addOnFailureListener { /* skipped frame; next one retries */ }
                .addOnCompleteListener {
                    inFlight = false
                    image.close()
                }
            true
        } catch (_: Exception) {
            // Task never started → nothing will close the proxy for us.
            inFlight = false
            false
        }
    }

    /** Creates the STREAM_MODE detector on first use; on failure emits a single
     * PLACEMENT_UNAVAILABLE error and latches [unavailable]. */
    private fun obtainDetector(): ObjectDetector? {
        detector?.let { return it }
        return runCatching {
            ObjectDetection.getClient(
                ObjectDetectorOptions.Builder()
                    .setDetectorMode(ObjectDetectorOptions.STREAM_MODE)
                    .build(), // single most-prominent object; no classification
            )
        }.onSuccess { detector = it }
            .onFailure {
                unavailable = true
                mainHandler.post {
                    if (!disposed) {
                        eventSink?.error(
                            "PLACEMENT_UNAVAILABLE",
                            "On-device object detector could not be created.",
                            null,
                        )
                    }
                }
            }
            .getOrNull()
    }

    private fun emitResult(
        obj: com.google.mlkit.vision.objects.DetectedObject?,
        uprightW: Int,
        uprightH: Int,
        timestampNs: Long,
        frameIndex: Long,
    ) {
        val payload: Map<String, Any?> = if (obj == null || uprightW <= 0 || uprightH <= 0) {
            // Explicit "nothing detected" so the Dart side can settle back to idle.
            mapOf(
                "hasObject" to false,
                "timestampNs" to timestampNs,
                "frameIndex" to frameIndex,
            )
        } else {
            val b = obj.boundingBox
            mapOf(
                "hasObject" to true,
                "left" to (b.left.toDouble() / uprightW).coerceIn(0.0, 1.0),
                "top" to (b.top.toDouble() / uprightH).coerceIn(0.0, 1.0),
                "right" to (b.right.toDouble() / uprightW).coerceIn(0.0, 1.0),
                "bottom" to (b.bottom.toDouble() / uprightH).coerceIn(0.0, 1.0),
                "trackingId" to obj.trackingId,
                "timestampNs" to timestampNs,
                "frameIndex" to frameIndex,
            )
        }
        mainHandler.post { if (!disposed) eventSink?.success(payload) }
    }
}
