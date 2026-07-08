// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/BlurAnalysisManager.kt
package com.mayasabhaxr.recapture.camera

import android.os.Handler
import android.os.Looper
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.UseCase
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Real-time blur detection on a CameraX [ImageAnalysis] stream: per frame it
 * extracts the luma (Y) plane, downscales to 640px width, computes the variance of
 * the Laplacian ([BlurMetric]), and streams `{ sharpnessScore, sharp, width,
 * height, timestampNs, frameIndex }` to Flutter for a "too blurry / hold steady"
 * indicator. Provides the METRIC + decision only — the accept/reject policy lives
 * in the capture flow, and no reconstruction is done here.
 *
 * ## Frame source + association
 * The `ImageProxy` is YUV_420_888; plane[0] is the luma, read stride-correctly by
 * [BlurMetric] (no YUV→RGB). `timestampNs` is the image's sensor timestamp — the
 * SAME camera clock as a captured frame's `captureTimestampNs`, so the capture flow
 * can associate the score with the right frame (or record it in the sidecar).
 *
 * ## Backpressure + threading (the classic CameraX pitfalls)
 * `STRATEGY_KEEP_ONLY_LATEST` — slow processing DROPS frames instead of queuing or
 * stalling. The analyzer runs on its own executor (never the main thread); the
 * emit is marshalled to the main thread for the [EventChannel.EventSink]. Every
 * [ImageProxy] is `close()`d in a `finally` (an unclosed proxy stalls the analyzer).
 * When nobody is subscribed, frames are drained cheaply (closed without compute).
 *
 * The [ImageAnalysis] use case is pulled by [CameraPreviewManager] at bind
 * ([useCaseForBind]); if the device can't support Preview+ImageCapture+ImageAnalysis
 * together, the preview manager drops analysis gracefully (preview/capture survive).
 *
 * ## Exposure check (parallel channel, shared frame pass)
 * A second EventChannel (`exposure`, [exposureHandler]) emits a per-frame **mean
 * luminance** + dark/ok/bright band ([ExposureMetric] / [ExposureThresholdPolicy])
 * for a "too dark / too bright" hint. It is a warn-only signal — it never rejects a
 * frame and never changes camera exposure. Critically it SHARES this analyzer's
 * single downscaled-luma pass: each frame is downscaled to 640px ONCE and both the
 * Laplacian variance (blur) and the mean (exposure) are computed from that one
 * buffer — no second traversal. Frames are processed when EITHER channel is
 * subscribed; both carry the SAME `timestampNs`/`frameIndex` for frame association.
 *
 * ## Placement detection (third consumer, deferred close)
 * When a [PlacementAnalysisManager] is attached ([placement]) and subscribed, each
 * frame is ALSO offered to it after the luma metrics. Unlike blur/exposure it works
 * from the live `media.Image` asynchronously (ML Kit), so when it TAKES a frame it
 * assumes ownership of closing the proxy — this analyzer must then skip its own
 * `close()`. Its internal throttle bounds how long frames are held, so the
 * blur/exposure cadence is barely affected. See PlacementAnalysisManager.
 */
class BlurAnalysisManager : EventChannel.StreamHandler {

    companion object {
        // Must match AppConfig.channelBlur on the Dart side.
        const val CHANNEL_NAME = "com.mayasabhaxr.recapture/blur"

        // Must match AppConfig.channelExposure on the Dart side.
        const val EXPOSURE_CHANNEL_NAME = "com.mayasabhaxr.recapture/exposure"
    }

    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var threshold = BlurMetric.DEFAULT_THRESHOLD

    /** Three-band policy (REJECT/WARN/ACCEPT) layered on the sharpness score. */
    private val policy = BlurThresholdPolicy()

    /** Three-band policy (DARK/OK/BRIGHT) layered on the mean luminance. */
    private val exposurePolicy = ExposureThresholdPolicy()

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    /** Sink for the parallel exposure channel (the [exposureHandler]'s). */
    @Volatile
    private var exposureSink: EventChannel.EventSink? = null

    /** Optional third frame consumer (object placement). Set once at engine
     * configuration by MainActivity; it manages its own channel + subscription. */
    @Volatile
    var placement: PlacementAnalysisManager? = null

    @Volatile
    private var disposed = false

    /** Analyzer-thread only (single-threaded executor) — no synchronization needed. */
    private var frameIndex = 0L

    private val imageAnalysis: ImageAnalysis = ImageAnalysis.Builder()
        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
        .build()
        .also { it.setAnalyzer(analysisExecutor, ImageAnalysis.Analyzer(::analyze)) }

    /** The use case the preview manager binds into the shared session. */
    fun useCaseForBind(): UseCase = imageAnalysis

    // ── EventChannel.StreamHandler (platform main thread) ─────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        thresholdArg(arguments)?.let { threshold = it }
        applyBandThresholds(arguments)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun thresholdArg(arguments: Any?): Double? {
        val map = arguments as? Map<*, *> ?: return null
        return (map["blurThreshold"] as? Number)?.toDouble()?.takeIf { it.isFinite() && it >= 0.0 }
    }

    /** Reads optional `rejectBelow`/`acceptAbove` band thresholds (validated). */
    private fun applyBandThresholds(arguments: Any?) {
        val map = arguments as? Map<*, *> ?: return
        policy.update(
            (map["rejectBelow"] as? Number)?.toDouble(),
            (map["acceptAbove"] as? Number)?.toDouble(),
        )
    }

    // ── exposure channel: mean-luminance band (parallel StreamHandler) ─────────

    /**
     * StreamHandler for the parallel exposure channel. Shares this manager's single
     * analyzer/frame pass — subscribing here just turns on the exposure emit; the
     * downscaled luma is reused from the blur pass.
     */
    val exposureHandler: EventChannel.StreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            exposureSink = events
            applyExposureThresholds(arguments)
        }

        override fun onCancel(arguments: Any?) {
            exposureSink = null
        }
    }

    /** Reads optional `darkBelow`/`brightAbove` exposure thresholds (validated). */
    private fun applyExposureThresholds(arguments: Any?) {
        val map = arguments as? Map<*, *> ?: return
        exposurePolicy.update(
            (map["darkBelow"] as? Number)?.toDouble(),
            (map["brightAbove"] as? Number)?.toDouble(),
        )
    }

    fun dispose() {
        disposed = true
        imageAnalysis.clearAnalyzer()
        analysisExecutor.shutdown()
        eventSink = null
        exposureSink = null
    }

    // ── analyzer (dedicated executor) ─────────────────────────────────────────

    private fun analyze(image: ImageProxy) {
        // TRUE when the placement consumer took the frame — it then owns the
        // proxy close (in its task-completion listener); closing here too would
        // release the buffer under ML Kit mid-read.
        var closeDeferred = false
        try {
            val blurSink = eventSink
            val expSink = exposureSink
            val placementConsumer = placement?.takeIf { it.isActive }
            // Nobody listening on ANY channel → drain cheaply (still closed in finally).
            if (disposed || (blurSink == null && expSink == null && placementConsumer == null)) {
                return
            }
            val ts = image.imageInfo.timestamp
            // One frame index per analyzed frame, shared so every channel associates
            // its result with the same frame.
            val idx = frameIndex++

            if (blurSink != null || expSink != null) {
                val plane = image.planes[0]
                val buffer = plane.buffer
                val bytes = ByteArray(buffer.remaining())
                buffer.get(bytes)

                // ONE stride-correct downscale to 640px, shared by both metrics — no
                // second frame pass for exposure.
                val gray = BlurMetric.downscaleLuma(
                    src = bytes,
                    srcWidth = image.width,
                    srcHeight = image.height,
                    rowStride = plane.rowStride,
                    pixelStride = plane.pixelStride,
                )
                if (blurSink != null) emitBlur(gray, ts, idx)
                if (expSink != null) emitExposure(gray, ts, idx)
            }

            // Placement LAST: once it takes the frame the proxy stays open until
            // its async task completes, so the luma copy above must already be done.
            if (placementConsumer != null) {
                closeDeferred = placementConsumer.maybeProcess(image, ts, idx)
            }
        } catch (_: Exception) {
            // A bad frame must never stall the analyzer; skip it (proxy still closed).
        } finally {
            if (!closeDeferred) image.close()
        }
    }

    private fun emitBlur(gray: BlurMetric.GrayImage, ts: Long, idx: Long) {
        val variance = BlurMetric.laplacianVariance(gray)
        val payload = mapOf(
            "sharpnessScore" to variance,
            "sharp" to (variance >= threshold),
            // Three-band policy classification + the active thresholds used.
            "band" to policy.classify(variance).wire,
            "rejectBelow" to policy.rejectBelow,
            "acceptAbove" to policy.acceptAbove,
            "width" to gray.width,
            "height" to gray.height,
            "timestampNs" to ts,
            "frameIndex" to idx,
        )
        mainHandler.post { if (!disposed) eventSink?.success(payload) }
    }

    private fun emitExposure(gray: BlurMetric.GrayImage, ts: Long, idx: Long) {
        val mean = ExposureMetric.meanLuminance(gray)
        // A non-finite mean (empty frame) → explicit "unknown"; never silently OK.
        val band = exposurePolicy.classify(mean)?.wire ?: ExposureThresholdPolicy.WIRE_UNKNOWN
        val payload = mapOf(
            "meanLuminance" to mean,
            "band" to band,
            "darkBelow" to exposurePolicy.darkBelow,
            "brightAbove" to exposurePolicy.brightAbove,
            "width" to gray.width,
            "height" to gray.height,
            "timestampNs" to ts,
            "frameIndex" to idx,
        )
        mainHandler.post { if (!disposed) exposureSink?.success(payload) }
    }
}
