// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/CameraCaptureManager.kt
package com.mayasabhaxr.recapture.camera

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.camera.core.Camera
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Still-capture (single / burst / auto-capture) on the existing CameraX session.
 *
 * Binds nothing itself: it owns the [ImageCapture] use case which
 * [CameraPreviewManager] binds alongside Preview (same session, no rebind).
 *
 * Design choices (confirmed): `CAPTURE_MODE_MINIMIZE_LATENCY` + JPEG via the
 * in-memory [ImageProxy] path — read the sensor timestamp
 * ([androidx.camera.core.ImageInfo.getTimestamp], nanoseconds, suitable for the
 * later sensor-fusion alignment), write the JPEG bytes to app-scoped session
 * storage, and close the proxy immediately (bounded memory). Bursts auto-lock
 * AE+AF (via [CameraControlsManager.lockForCapture]) and stay locked.
 *
 * Back-pressure: captures are **serialized** — the next `takePicture` is scheduled
 * only after the prior completes, so the device's own drain rate gates the
 * cadence (no unbounded queue, no silent drops). `intervalMs` is a *minimum*
 * spacing; if the device is slower the effective cadence slows and is visible in
 * the per-frame `timestampNs`. Only one capture operation runs at a time;
 * a concurrent request is rejected with `BUSY`.
 *
 * Per-frame failure policy: **report and continue**, marking the gap (the failed
 * index is skipped; an `error` event carries it).
 *
 * Transport: start/stop over the MethodChannel return immediately (single capture
 * returns its frame); frames/completion/errors stream over the [EventChannel].
 * Scope is the capture trigger + execution + frame output only — no sensor/motion
 * trigger criterion, pose association, or reconstruction (a config hook is
 * accepted but the sensor criterion is not implemented here).
 */
class CameraCaptureManager(
    private val appContext: Context,
    private val controls: CameraControlsManager,
    private val metadataWriter: CaptureMetadataWriter = CaptureMetadataWriter(),
) : EventChannel.StreamHandler {

    init {
        // Per-frame EXIF/sidecar results stream over the same capture EventChannel.
        metadataWriter.onResult = { event -> emit(event) }
    }

    companion object {
        // Must match AppConfig.channelCapture / channelCaptureEvents on the Dart side.
        const val CHANNEL_NAME = "com.mayasabhaxr.recapture/capture"
        const val EVENTS_CHANNEL_NAME = "com.mayasabhaxr.recapture/captureEvents"

        private const val ERR_NO_CAMERA = "NO_CAMERA"
        private const val ERR_BUSY = "BUSY"
        private const val ERR_INVALID = "INVALID_ARGS"
        private const val ERR_WRITE = "WRITE_FAILED"
        private const val ERR_CAPTURE = "CAPTURE_FAILED"
    }

    // ── resolution / quality policy (sizing+encoding; see CaptureResolutionPolicy) ─
    //
    // The policy is bind-time: it parameterizes the [ImageCapture] but does not
    // capture. A change is staged into [pendingPolicy] and only realized on the
    // NEXT bind (the preview/session task owns rebinding) — never swapped under a
    // live session, so every frame in a session keeps one resolution + quality.

    /** The policy that will be realized on the next bind. */
    @Volatile
    private var pendingPolicy: CaptureResolutionPolicy = CaptureResolutionPolicy.DEFAULT

    /** The policy actually realized in [currentImageCapture] (the bound one). */
    @Volatile
    private var boundPolicy: CaptureResolutionPolicy = pendingPolicy

    /** True when [pendingPolicy] differs from what [currentImageCapture] encodes. */
    @Volatile
    private var policyDirty = false

    /**
     * The [ImageCapture] handed to [CameraPreviewManager] at bind. Rebuilt only at
     * bind time via [useCaseForBind] when the policy changed, so captures and
     * reporting always reference the instance that is actually bound.
     */
    @Volatile
    private var currentImageCapture: ImageCapture = buildImageCapture(pendingPolicy)

    /** The capture use case to bind. Exposed for the preview manager's wiring. */
    val imageCapture: ImageCapture get() = currentImageCapture

    /**
     * Invoked (main thread) on a successful [configureCaptureResolution] with the
     * CameraX [androidx.camera.core.AspectRatio] constant, so the preview/session
     * task can match its own aspect ratio on the next bind (no FOV mismatch).
     */
    var onAspectRatioChanged: ((Int) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var captureExecutor: ScheduledExecutorService = newExecutor()

    private var eventSink: EventChannel.EventSink? = null

    /** True while the use case is bound (a live session can be captured to). */
    @Volatile
    private var bound = false

    /** The in-progress burst/auto run, or null. Identity is the cancel token. */
    @Volatile
    private var active: Op? = null

    /** Guards an in-flight single capture (separate from [active]). */
    @Volatile
    private var singleInFlight = false

    @Volatile
    private var disposed = false

    private class Op(
        val sessionId: String,
        val dir: File,
        val total: Int?, // null ⇒ auto-capture (until stop)
        val intervalMs: Long,
    ) {
        var index = 0
    }

    // ── policy plumbing ────────────────────────────────────────────────────────

    private fun buildImageCapture(p: CaptureResolutionPolicy): ImageCapture =
        ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            // Resolution + quality are fixed here, at bind, for the whole session.
            .setResolutionSelector(p.buildResolutionSelector())
            .setJpegQuality(p.jpegQuality)
            // Fixed target rotation ⇒ consistent EXIF orientation across frames.
            .setTargetRotation(p.targetRotation)
            .build()

    /**
     * Returns the [ImageCapture] the preview manager should bind. Called on the
     * main thread at bind time: if the policy changed since the last bind it
     * rebuilds the use case here (the only place a policy change is realized), so a
     * mid-session reconfigure never disturbs the live session — it lands on the
     * rebind the session task performs.
     */
    fun useCaseForBind(): ImageCapture {
        if (policyDirty) {
            boundPolicy = pendingPolicy
            currentImageCapture = buildImageCapture(boundPolicy)
            policyDirty = false
        }
        return currentImageCapture
    }

    /**
     * Stages a new resolution/JPEG-quality policy. Validated + clamped; clearly
     * invalid input is rejected with `INVALID_ARGS` and the prior policy stands.
     * Takes effect on the NEXT bind (acknowledged via `appliesOnNextBind`), never
     * mid-session. Reports the (parsed) target so the caller can confirm intent.
     */
    fun configureCaptureResolution(args: Map<String, Any?>?, result: MethodChannel.Result) {
        CaptureResolutionPolicy.fromMap(args).fold(
            onSuccess = { p ->
                pendingPolicy = p
                policyDirty = true
                onAspectRatioChanged?.invoke(p.aspectRatio.toCameraX())
                result.success(
                    mapOf(
                        "accepted" to true,
                        "appliesOnNextBind" to true,
                        "target" to targetMap(p),
                        "jpegQuality" to p.jpegQuality,
                        "aspectRatio" to aspectLabel(p.aspectRatio),
                    ),
                )
            },
            onFailure = { e ->
                result.error(ERR_INVALID, e.message ?: "Invalid resolution policy.", null)
            },
        )
    }

    /**
     * Reports the ACTUAL capture resolution. When bound, reads CameraX's chosen
     * output size from the bound [ImageCapture] and flags whether it diverged from
     * the target (`fellBack`). When not yet bound, returns the resolved target with
     * `bound: false` (no actual size exists until a session binds).
     */
    fun getActiveCaptureResolution(result: MethodChannel.Result) {
        val p = boundPolicy
        val info = if (bound) currentImageCapture.resolutionInfo else null
        val res = info?.resolution
        val actual = if (res != null) Dimensions(res.width, res.height) else null

        val out = mutableMapOf<String, Any?>(
            "jpegQuality" to p.jpegQuality,
            "aspectRatio" to aspectLabel(p.aspectRatio),
            "target" to targetMap(p),
            "bound" to (actual != null),
        )
        if (actual != null) {
            out["width"] = actual.width
            out["height"] = actual.height
            out["fellBack"] = p.fellBack(actual)
        } else {
            // Best-known size before bind: the resolved target (intent), fellBack unknown.
            out["width"] = p.resolvedTargetSize.width
            out["height"] = p.resolvedTargetSize.height
            out["fellBack"] = false
        }
        result.success(out)
    }

    private fun targetMap(p: CaptureResolutionPolicy): Map<String, Any?> = mapOf(
        "width" to p.resolvedTargetSize.width,
        "height" to p.resolvedTargetSize.height,
        "longEdge" to p.resolvedTargetSize.longEdge,
    )

    private fun aspectLabel(a: CaptureAspectRatio): String = when (a) {
        CaptureAspectRatio.RATIO_4_3 -> "4:3"
        CaptureAspectRatio.RATIO_16_9 -> "16:9"
    }

    // ── session wiring (called on the main thread by the preview manager) ─────

    fun onCameraBound(@Suppress("UNUSED_PARAMETER") camera: Camera) {
        bound = true
    }

    fun onCameraUnbound() {
        bound = false
        // A backgrounded/torn-down session must not be captured to: stop the loop
        // and finalize whatever ran so Flutter sees a clean completion.
        active?.let { finalize(it, emitCompleted = true) }
    }

    // ── EventChannel.StreamHandler ────────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ── MethodChannel entry points (called on the main thread) ────────────────

    fun captureSingle(result: MethodChannel.Result) {
        if (!ensureReady(result)) return
        singleInFlight = true
        val sessionId = newSessionId()
        val dir = sessionDir(sessionId)
        imageCapture.takePicture(
            captureExecutor,
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    val ts = image.imageInfo.timestamp
                    val width = image.width
                    val height = image.height
                    val bytes = image.jpegBytes()
                    image.close()
                    singleInFlight = false
                    try {
                        val frame = writeFrame(dir, sessionId, 0, ts, bytes)
                        replyMain {
                            result.success(
                                mapOf(
                                    "id" to frame.id,
                                    "path" to frame.path,
                                    "timestampNs" to ts,
                                ),
                            )
                        }
                        // Off-thread EXIF + sidecar; the single result already returned.
                        enqueueMetadata(frame, sessionId, 0, ts, width, height)
                    } catch (e: IOException) {
                        replyMain { result.error(ERR_WRITE, e.message ?: "Write failed.", null) }
                    }
                }

                override fun onError(exc: ImageCaptureException) {
                    singleInFlight = false
                    replyMain { result.error(ERR_CAPTURE, exc.message ?: "Capture failed.", null) }
                }
            },
        )
    }

    fun startBurst(count: Int, intervalMs: Long?, result: MethodChannel.Result) {
        if (count < 1) {
            result.error(ERR_INVALID, "Burst count must be >= 1.", null)
            return
        }
        beginLoop(total = count, intervalMs = intervalMs, result = result)
    }

    fun startAutoCapture(intervalMs: Long?, result: MethodChannel.Result) {
        beginLoop(total = null, intervalMs = intervalMs, result = result)
    }

    fun stopAutoCapture(result: MethodChannel.Result) {
        active?.let { finalize(it, emitCompleted = true) }
        result.success(null)
    }

    fun dispose() {
        disposed = true
        active = null
        bound = false
        captureExecutor.shutdownNow()
        // Let any queued metadata jobs finish (they don't touch the camera).
        metadataWriter.dispose()
    }

    // ── loop driver ───────────────────────────────────────────────────────────

    private fun beginLoop(total: Int?, intervalMs: Long?, result: MethodChannel.Result) {
        if (!ensureReady(result)) return
        if (active != null) {
            result.error(ERR_BUSY, "A capture operation is already running.", null)
            return
        }
        // Auto-lock AE+AF for frame consistency; stays locked (caller unlocks).
        controls.lockForCapture()

        val sessionId = newSessionId()
        val op = Op(
            sessionId = sessionId,
            dir = sessionDir(sessionId),
            total = total,
            intervalMs = (intervalMs ?: 0L).coerceAtLeast(0L),
        )
        active = op
        result.success(mapOf("sessionId" to sessionId))
        captureExecutor.execute { captureNext(op) }
    }

    /** Captures the next frame of [op] (runs on the capture executor). */
    private fun captureNext(op: Op) {
        if (!isRunning(op)) return
        if (op.total != null && op.index >= op.total) {
            finalize(op, emitCompleted = true)
            return
        }
        val startedAt = System.currentTimeMillis()
        imageCapture.takePicture(
            captureExecutor,
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    val ts = image.imageInfo.timestamp
                    val width = image.width
                    val height = image.height
                    val bytes = image.jpegBytes()
                    image.close()
                    // Cancelled (stopped / unbound) while in-flight → drop this frame.
                    if (!isRunning(op)) return
                    val index = op.index
                    try {
                        val frame = writeFrame(op.dir, op.sessionId, index, ts, bytes)
                        emit(
                            mapOf(
                                "type" to "frame",
                                "id" to frame.id,
                                "path" to frame.path,
                                "timestampNs" to ts,
                                "index" to index,
                                "total" to op.total,
                            ),
                        )
                        // Off-thread EXIF + sidecar; never blocks the burst cadence.
                        enqueueMetadata(frame, op.sessionId, index, ts, width, height)
                    } catch (e: IOException) {
                        // Report and continue, marking the gap (index still advances).
                        emit(mapOf("type" to "error", "index" to index, "message" to (e.message ?: "Write failed.")))
                    }
                    op.index = index + 1
                    scheduleNext(op, startedAt)
                }

                override fun onError(exc: ImageCaptureException) {
                    if (!isRunning(op)) return
                    val index = op.index
                    emit(mapOf("type" to "error", "index" to index, "message" to (exc.message ?: "Capture failed.")))
                    op.index = index + 1
                    scheduleNext(op, startedAt)
                }
            },
        )
    }

    private fun scheduleNext(op: Op, startedAt: Long) {
        if (!isRunning(op)) return
        if (op.total != null && op.index >= op.total) {
            finalize(op, emitCompleted = true)
            return
        }
        // intervalMs is a MINIMUM spacing; if the capture already took longer, fire
        // immediately (effective cadence slows — visible via the frame timestamps).
        val elapsed = System.currentTimeMillis() - startedAt
        val delay = (op.intervalMs - elapsed).coerceAtLeast(0L)
        try {
            captureExecutor.schedule({ captureNext(op) }, delay, TimeUnit.MILLISECONDS)
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            // Executor shut down (dispose) between checks — stop quietly.
        }
    }

    /** Ends [op] if it is the active one; optionally emits the completion event. */
    private fun finalize(op: Op, emitCompleted: Boolean) {
        if (active !== op) return
        active = null
        if (emitCompleted) {
            emit(mapOf("type" to "completed", "count" to op.index, "sessionId" to op.sessionId))
        }
    }

    private fun isRunning(op: Op): Boolean = !disposed && bound && active === op

    // ── output ─────────────────────────────────────────────────────────────────

    private data class Frame(val id: String, val path: String)

    @Throws(IOException::class)
    private fun writeFrame(dir: File, sessionId: String, index: Int, timestampNs: Long, bytes: ByteArray): Frame {
        if (!dir.exists() && !dir.mkdirs()) {
            throw IOException("Could not create session directory: ${dir.path}")
        }
        val id = "%s_%05d".format(sessionId, index)
        // Timestamp encoded in the filename so the frame carries it on disk too.
        val file = File(dir, "%s_%d.jpg".format(id, timestampNs))
        FileOutputStream(file).use { it.write(bytes) }
        return Frame(id = id, path = file.absolutePath)
    }

    private fun sessionDir(sessionId: String): File {
        val base = appContext.getExternalFilesDir(null) ?: appContext.filesDir
        return File(File(base, "captures"), sessionId)
    }

    private fun newSessionId(): String = "cap_${System.currentTimeMillis()}"

    // ── metadata (per-frame post-capture, off-thread) ────────────────────────────

    /** App version string for the device descriptor / EXIF software tag. */
    private val appVersion: String? by lazy {
        runCatching {
            @Suppress("DEPRECATION")
            appContext.packageManager.getPackageInfo(appContext.packageName, 0).versionName
        }.getOrNull()
    }

    /**
     * Snapshots the precise timestamp, actual resolution, device, intrinsics, and
     * capture conditions for [frame] and hands them to [metadataWriter] for
     * off-thread EXIF + sidecar writing. Cheap snapshot work only; the heavy I/O is
     * the writer's, so the capture cadence is never stalled.
     */
    private fun enqueueMetadata(
        frame: Frame,
        sessionId: String,
        index: Int,
        timestampNs: Long,
        width: Int,
        height: Int,
    ) {
        val policy = boundPolicy
        val actual = Dimensions.landscape(width, height)
        val intrinsics = controls.snapshotIntrinsics()
        val metadata = CaptureMetadata(
            sessionId = sessionId,
            frameId = frame.id,
            frameIndex = index,
            captureTimestampNs = timestampNs,
            wallClockMillis = System.currentTimeMillis(),
            device = DeviceDescriptor(
                manufacturer = Build.MANUFACTURER ?: "",
                model = Build.MODEL ?: "",
                osVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                appVersion = appVersion,
                cameraId = intrinsics.cameraId,
            ),
            resolution = ResolutionMeta(
                width = width,
                height = height,
                aspectRatio = aspectLabel(policy.aspectRatio),
                jpegQuality = policy.jpegQuality,
                fellBack = policy.fellBack(actual),
            ),
            intrinsics = intrinsics,
            conditions = controls.snapshotConditions(),
        )
        metadataWriter.enqueue(File(frame.path), metadata)
    }

    private fun ImageProxy.jpegBytes(): ByteArray {
        val buffer = planes[0].buffer
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        return bytes
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /** Validates a live session + no in-flight single; replies error if not. */
    private fun ensureReady(result: MethodChannel.Result): Boolean {
        if (disposed || !bound) {
            result.error(ERR_NO_CAMERA, "No bound camera session.", null)
            return false
        }
        if (singleInFlight) {
            result.error(ERR_BUSY, "A single capture is already in flight.", null)
            return false
        }
        return true
    }

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(event) }
    }

    private fun replyMain(block: () -> Unit) {
        mainHandler.post {
            try {
                block()
            } catch (_: Exception) {
                // Channel/engine gone — nothing to deliver.
            }
        }
    }

    private fun newExecutor(): ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor()
}
