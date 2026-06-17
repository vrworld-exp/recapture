// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/CameraPreviewManager.kt
package com.mayasabhaxr.recapture.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Size
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.core.SurfaceRequest
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import io.flutter.view.TextureRegistry.SurfaceProducer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Native side of the `com.mayasabhaxr.recapture/camera_preview` MethodChannel.
 *
 * Bridges a live CameraX back-camera **preview** into Flutter via an external
 * texture (Architecture Decision A): CameraX renders into a [android.view.Surface]
 * obtained from a Flutter [SurfaceProducer]; Flutter draws `Texture(textureId)`.
 *
 * Scope is PREVIEW only — no ImageAnalysis, still/video capture, or sensor work.
 *
 * The dominant concern here is **surface + camera lifecycle correctness**: bind,
 * release, and survive dispose / background / surface-recreate without leaking the
 * camera or drawing to a dead surface. To decouple from Activity recreation we own
 * a private [LifecycleRegistry] and drive CameraX's `bindToLifecycle` against it —
 * start moves it to RESUMED (camera opens), stop to CREATED (camera closes),
 * dispose to DESTROYED (full teardown). This mirrors the official camera_android
 * plugin's proxy-lifecycle approach and keeps start/stop/dispose authoritative.
 *
 * Threading: `bindToLifecycle` and all registry/producer mutations run on the main
 * thread (CameraX requirement); the camera open itself and surface requests run on
 * CameraX's own / a dedicated executor, so setup never blocks the UI thread.
 *
 * CAMERA permission is assumed granted by the P2 gate; this class NEVER requests it.
 * If it is somehow missing, or no back camera exists, or binding fails, `start`
 * fails gracefully with a coded error and no crash.
 */
class CameraPreviewManager(
    private val appContext: Context,
    private val textureRegistry: TextureRegistry,
    private val channel: MethodChannel,
) : LifecycleOwner {

    companion object {
        const val CHANNEL_NAME = "com.mayasabhaxr.recapture/camera_preview"

        // Error codes surfaced to Dart (CameraPreviewController maps these).
        private const val ERR_PERMISSION = "PERMISSION_DENIED"
        private const val ERR_NO_BACK = "NO_BACK_CAMERA"
        private const val ERR_BIND = "BIND_FAILED"
        private const val ERR_CANCELLED = "CANCELLED"

        // Dart-bound callbacks (native → Flutter) on the same channel.
        private const val CB_PREVIEW_CHANGED = "onPreviewChanged"
        private const val CB_ERROR = "onError"
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Dedicated executor for CameraX surface requests / transformation callbacks. */
    private var cameraExecutor: ExecutorService? = null

    private val lifecycleRegistry = LifecycleRegistry(this).apply {
        currentState = Lifecycle.State.INITIALIZED
    }
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    private var cameraProvider: ProcessCameraProvider? = null
    private var preview: Preview? = null
    private var surfaceProducer: SurfaceProducer? = null
    private var camera: Camera? = null

    /**
     * Notified (on the main thread) with the freshly bound [Camera] on each bind,
     * and with `null` on unbind/teardown. The focus/exposure controls layer
     * ([CameraControlsManager]) listens here so it always targets the current
     * session — and, per the rebind decision, resets to auto on every rebind.
     */
    var onCameraChanged: ((Camera?) -> Unit)? = null

    /**
     * An extra use case (the still-capture [androidx.camera.core.ImageCapture]
     * from [CameraCaptureManager]) bound into the SAME session as Preview. Set
     * once before the first start; Preview + ImageCapture is a CameraX-guaranteed
     * combination, so no fallback is needed for that pair.
     */
    var captureUseCase: UseCase? = null

    /** The `start` result awaiting the first resolved surface request. */
    private var pendingStart: MethodChannel.Result? = null

    /** Bumped on every start so a stale provider future can detect teardown. */
    private var bindGeneration = 0

    private var disposed = false

    private var lastResolution: Size? = null
    private var lastRotationDegrees = 0

    // ── MethodChannel entry points (called on the main thread) ────────────────

    fun start(result: MethodChannel.Result) {
        if (disposed) {
            result.error(ERR_CANCELLED, "Manager disposed.", null)
            return
        }
        // Defensive permission check — we never request here (P2 gate owns it).
        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            result.error(ERR_PERMISSION, "CAMERA permission not granted.", null)
            return
        }

        // Idempotent: a second start while already running just re-reports state.
        if (surfaceProducer != null && preview != null && pendingStart == null) {
            result.success(currentInfoMap())
            return
        }

        // Replace any superseded pending start (rapid start/start churn).
        pendingStart?.let { it.error(ERR_CANCELLED, "Superseded by a newer start().", null) }
        pendingStart = result

        ensureExecutor()
        ensureSurfaceProducer()

        val generation = ++bindGeneration
        val providerFuture = ProcessCameraProvider.getInstance(appContext)
        providerFuture.addListener({
            // Resolves later — bail if torn down or superseded meanwhile.
            if (disposed || generation != bindGeneration) {
                runCatching { providerFuture.get().unbindAll() }
                failStart(ERR_CANCELLED, "Teardown won the race with binding.")
                return@addListener
            }
            try {
                val provider = providerFuture.get()
                cameraProvider = provider
                if (!provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)) {
                    failStart(ERR_NO_BACK, "No back camera available.")
                    return@addListener
                }
                bindPreview(provider)
            } catch (e: Exception) {
                failStart(ERR_BIND, e.message ?: "Failed to bind camera preview.")
            }
        }, ContextCompat.getMainExecutor(appContext))
    }

    fun stop(result: MethodChannel.Result) {
        unbind()
        result.success(null)
    }

    fun dispose(result: MethodChannel.Result?) {
        if (disposed) {
            result?.success(null)
            return
        }
        disposed = true
        bindGeneration++ // invalidate any in-flight provider future
        pendingStart?.let { it.error(ERR_CANCELLED, "Disposed before binding completed.", null) }
        pendingStart = null

        unbind()
        if (lifecycleRegistry.currentState != Lifecycle.State.INITIALIZED) {
            lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        }

        surfaceProducer?.release()
        surfaceProducer = null
        cameraProvider = null
        cameraExecutor?.shutdown()
        cameraExecutor = null
        result?.success(null)
    }

    // ── internals ─────────────────────────────────────────────────────────────

    private fun bindPreview(provider: ProcessCameraProvider) {
        // Rotation for an external texture is reported by the SurfaceRequest's
        // TransformationInfo and applied on the Flutter side, so the use case
        // itself needs no target rotation.
        val useCase = Preview.Builder()
            .build()
            .also { it.setSurfaceProvider(cameraExecutor!!, surfaceProvider) }
        preview = useCase

        // bindToLifecycle must run on the main thread; we are already on it
        // (provider future listener uses the main executor).
        provider.unbindAll()
        // Bind Preview together with the still-capture use case (if registered) so
        // captures run on the same session — never a separate rebind.
        val useCases = listOfNotNull<UseCase>(useCase, captureUseCase).toTypedArray()
        val bound = provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, *useCases)
        // Open the camera by moving our owned lifecycle to RESUMED.
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
        // Hand the fresh CameraControl to the controls layer. A new bind ⇒ a new
        // session, so this is the reset-to-auto point for focus/exposure locks.
        camera = bound
        onCameraChanged?.invoke(bound)
    }

    /** Fulfils CameraX [SurfaceRequest]s with the Flutter texture's surface. */
    private val surfaceProvider = Preview.SurfaceProvider { request: SurfaceRequest ->
        val producer = surfaceProducer
        if (producer == null || disposed) {
            request.willNotProvideSurface()
            return@SurfaceProvider
        }
        val resolution = request.resolution
        // Size the producer to the camera resolution to avoid stretching; the
        // Flutter wrapper applies BoxFit.cover for the FILL_CENTER look.
        producer.setSize(resolution.width, resolution.height)
        lastResolution = resolution

        request.setTransformationInfoListener(cameraExecutor!!) { info ->
            lastRotationDegrees = info.rotationDegrees
            // Resolution + rotation are now known: complete start once, then push
            // subsequent rotation/size changes to Dart so the widget re-orients.
            mainHandler.post {
                if (resolveStart()) return@post
                pushPreviewChanged()
            }
        }

        request.provideSurface(producer.surface, cameraExecutor!!) {
            // Camera finished with this surface (unbind / resolution change). The
            // producer's lifecycle is owned by stop()/dispose(); nothing to do.
        }
    }

    private fun ensureSurfaceProducer() {
        if (surfaceProducer != null) return
        val producer = textureRegistry.createSurfaceProducer()
        producer.setCallback(object : SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                // Surface (re)created after a background/foreground cycle. Re-bind so
                // CameraX issues a fresh SurfaceRequest against the new surface.
                if (disposed) return
                cameraProvider?.let { provider ->
                    bindGeneration++
                    bindPreview(provider)
                }
            }

            override fun onSurfaceCleanup() {
                // Surface destroyed (app backgrounded). Stop driving the camera so we
                // never render to a dead surface; do NOT release the producer — it is
                // reused when onSurfaceAvailable fires on resume.
                lifecycleRegistry.currentState = Lifecycle.State.CREATED
                cameraProvider?.unbindAll()
                clearCamera()
            }
        })
        surfaceProducer = producer
    }

    private fun ensureExecutor() {
        if (cameraExecutor == null || cameraExecutor!!.isShutdown) {
            cameraExecutor = Executors.newSingleThreadExecutor()
        }
    }

    /** Releases the camera but keeps the manager (and producer) reusable. */
    private fun unbind() {
        cameraProvider?.unbindAll()
        preview = null
        clearCamera()
        if (lifecycleRegistry.currentState.isAtLeast(Lifecycle.State.CREATED) &&
            lifecycleRegistry.currentState != Lifecycle.State.DESTROYED
        ) {
            lifecycleRegistry.currentState = Lifecycle.State.CREATED
        }
    }

    private fun clearCamera() {
        if (camera == null) return
        camera = null
        onCameraChanged?.invoke(null)
    }

    /** Completes a pending start() with the now-known preview info. */
    private fun resolveStart(): Boolean {
        val pending = pendingStart ?: return false
        pendingStart = null
        pending.success(currentInfoMap())
        return true
    }

    private fun failStart(code: String, message: String) {
        mainHandler.post {
            val pending = pendingStart
            pendingStart = null
            if (pending != null) {
                pending.error(code, message, null)
            } else if (!disposed) {
                // Failure after start already resolved — notify via the error callback.
                channel.invokeMethod(CB_ERROR, mapOf("code" to code, "message" to message))
            }
        }
    }

    private fun pushPreviewChanged() {
        if (disposed) return
        channel.invokeMethod(CB_PREVIEW_CHANGED, currentInfoMap())
    }

    private fun currentInfoMap(): Map<String, Any> {
        val res = lastResolution
        return mapOf(
            "textureId" to (surfaceProducer?.id() ?: -1L),
            "previewWidth" to (res?.width ?: 0),
            "previewHeight" to (res?.height ?: 0),
            "rotationDegrees" to lastRotationDegrees,
        )
    }
}
