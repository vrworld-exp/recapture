package com.mayasabhaxr.recapture

import com.mayasabhaxr.recapture.camera.BlurAnalysisManager
import com.mayasabhaxr.recapture.camera.CameraCaptureManager
import com.mayasabhaxr.recapture.camera.CameraControlsManager
import com.mayasabhaxr.recapture.camera.CameraPreviewManager
import com.mayasabhaxr.recapture.permissions.PermissionManager
import com.mayasabhaxr.recapture.sensors.ImuRotationStreamManager
import com.mayasabhaxr.recapture.sensors.StabilityStreamManager
import com.mayasabhaxr.recapture.storage.CaptureStorage
import com.mayasabhaxr.recapture.upload.UploadForegroundService
import com.mayasabhaxr.recapture.upload.UploadResumeWorker
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Sentinel distinguishing an unhandled storage method from a legitimate null result. */
private val NotImplemented = Any()

class MainActivity : FlutterActivity() {

    private lateinit var permissionManager: PermissionManager
    private var cameraPreviewManager: CameraPreviewManager? = null
    private var cameraCaptureManager: CameraCaptureManager? = null
    private var blurAnalysisManager: BlurAnalysisManager? = null
    private var imuRotationManager: ImuRotationStreamManager? = null
    private var stabilityManager: StabilityStreamManager? = null

    /** App-scoped capture storage backbone + a dedicated thread for its blocking I/O. */
    private var captureStorage: CaptureStorage? = null
    private var storageExecutor: ExecutorService? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Native camera-preview channel (Architecture Decision A: external
        // texture). The manager owns the CameraX lifecycle; see CameraPreviewManager.
        val cameraChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CameraPreviewManager.CHANNEL_NAME,
        )
        val cameraManager = CameraPreviewManager(
            appContext = applicationContext,
            textureRegistry = flutterEngine.renderer,
            channel = cameraChannel,
        )
        cameraPreviewManager = cameraManager

        // Focus/exposure lock controls layered on the same bound session. The
        // preview manager hands it the current Camera on every bind/unbind (a
        // rebind resets locks to auto — see CameraControlsManager).
        val cameraControls = CameraControlsManager(applicationContext)

        // Still-capture (single / burst / auto). Owns the ImageCapture use case
        // bound into the SAME session by the preview manager (no separate rebind).
        val cameraCapture = CameraCaptureManager(applicationContext, cameraControls)
        cameraCaptureManager = cameraCapture
        // The preview manager pulls the capture use case at each bind so a staged
        // resolution-policy change is realized on the rebind (CameraCaptureManager
        // owns the ImageCapture + its ResolutionSelector/jpegQuality).
        cameraManager.captureUseCaseProvider = { cameraCapture.useCaseForBind() }
        // Keep Preview's aspect ratio equal to the capture policy's (no FOV mismatch).
        cameraCapture.onAspectRatioChanged = { aspectRatio ->
            cameraManager.captureAspectRatio = aspectRatio
        }
        cameraManager.onCameraChanged = { camera ->
            cameraControls.updateCamera(camera)
            if (camera != null) cameraCapture.onCameraBound(camera) else cameraCapture.onCameraUnbound()
        }

        // Real-time blur detection (variance of Laplacian @ 640px). Owns an
        // ImageAnalysis use case bound into the SAME session (with graceful fallback
        // if the device can't support the 3-use-case combination — see bindUseCases).
        val blurAnalysis = BlurAnalysisManager()
        blurAnalysisManager = blurAnalysis
        cameraManager.analysisUseCaseProvider = { blurAnalysis.useCaseForBind() }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CameraCaptureManager.EVENTS_CHANNEL_NAME,
        ).setStreamHandler(cameraCapture)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BlurAnalysisManager.CHANNEL_NAME,
        ).setStreamHandler(blurAnalysis)

        // Parallel exposure channel (mean-luminance dark/ok/bright warn). Shares the
        // blur analyzer's single downscaled-luma frame pass (see BlurAnalysisManager).
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BlurAnalysisManager.EXPOSURE_CHANNEL_NAME,
        ).setStreamHandler(blurAnalysis.exposureHandler)

        // IMU rotation-vector stream (device orientation @ 50–100Hz). Emits
        // camera-clock-aligned timestamps for the later pose/frame-fusion task;
        // see ImuRotationStreamManager (clock domain + threading + lifecycle).
        val imuRotation = ImuRotationStreamManager(applicationContext)
        imuRotationManager = imuRotation
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ImuRotationStreamManager.CHANNEL_NAME,
        ).setStreamHandler(imuRotation)
        // Parallel smoothed-orientation channel (low-pass yaw/pitch/roll for the
        // capture guide); shares the same sensor registration (see the manager).
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ImuRotationStreamManager.ORIENTATION_CHANNEL_NAME,
        ).setStreamHandler(imuRotation.orientationHandler)

        // Stability gate (gyro + linear-accel; debounced STABLE state + auto-capture
        // trigger). Owns its own raw sensors, distinct from the rotation-vector stream.
        val stability = StabilityStreamManager(applicationContext)
        stabilityManager = stability
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            StabilityStreamManager.CHANNEL_NAME,
        ).setStreamHandler(stability)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CameraCaptureManager.CHANNEL_NAME,
        ).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "captureSingle" -> cameraCapture.captureSingle(result)
                "startBurst" -> cameraCapture.startBurst(
                    call.argument<Int>("count") ?: 0,
                    (call.argument<Number>("intervalMs"))?.toLong(),
                    result,
                )
                "startAutoCapture" -> cameraCapture.startAutoCapture(
                    (call.argument<Number>("intervalMs"))?.toLong(),
                    result,
                )
                "stopAutoCapture" -> cameraCapture.stopAutoCapture(result)
                "configureCaptureResolution" -> {
                    @Suppress("UNCHECKED_CAST")
                    val policyArgs = call.arguments as? Map<String, Any?>
                    cameraCapture.configureCaptureResolution(policyArgs, result)
                }
                "getActiveCaptureResolution" -> cameraCapture.getActiveCaptureResolution(result)
                else -> result.notImplemented()
            }
        }

        // App-scoped capture storage hierarchy (/recapture/{project}/{job}/images/{level}).
        // Dart-facing operations: accounting, free space, incomplete-job listing, and the
        // delete hooks (P1 project deletion cleans its capture data). Path allocation +
        // frame writing stay native (the burst task). All I/O runs off the platform thread.
        val storage = CaptureStorage.fromContext(applicationContext)
        captureStorage = storage
        val storageIo = Executors.newSingleThreadExecutor()
        storageExecutor = storageIo
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CaptureStorage.CHANNEL_NAME,
        ).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            // Snapshot args on the platform thread; do the blocking work off it.
            val projectId = call.argument<String>("projectId")
            val jobId = call.argument<String>("jobId")
            val level = call.argument<String>("level")
            val force = call.argument<Boolean>("force") ?: false
            val knownProjectIds = call.argument<List<String>>("knownProjectIds")
            storageIo.execute {
                val reply: Result<Any?> = runCatching {
                    when (call.method) {
                        "freeSpace" -> storage.freeSpaceBytes()
                        "usage" -> storage.usage(projectId!!, jobId, level).let {
                            mapOf("frameCount" to it.frameCount, "byteCount" to it.byteCount)
                        }
                        "listProjects" -> storage.listProjects()
                        "listJobs" -> storage.listJobs(projectId!!)
                        "listIncompleteJobs" -> storage.listIncompleteJobs().map {
                            mapOf("projectId" to it.projectId, "jobId" to it.jobId, "reason" to it.reason)
                        }
                        "deleteLevel" -> storage.deleteLevel(projectId!!, jobId!!, level!!, force).toMap()
                        "deleteJob" -> storage.deleteJob(projectId!!, jobId!!, force).toMap()
                        "deleteProject" -> storage.deleteProject(projectId!!, force).toMap()
                        // Project-deletion cleanup hook (purge a project's local capture
                        // data) + the optional orphan sweep. See CaptureStorage.purgeProject.
                        "purgeProjectCaptureData" -> storage.purgeProject(projectId!!, force).toMap()
                        "sweepOrphanedCaptureData" ->
                            storage.sweepOrphans(knownProjectIds ?: emptyList(), force).toMap()
                        else -> NotImplemented
                    }
                }
                runOnUiThread {
                    reply.fold(
                        onSuccess = { value ->
                            if (value === NotImplemented) result.notImplemented() else result.success(value)
                        },
                        onFailure = { e ->
                            val code = when (e) {
                                is IllegalArgumentException, is NullPointerException -> "INVALID_ARGS"
                                is SecurityException -> "SECURITY"
                                else -> "STORAGE_ERROR"
                            }
                            result.error(code, e.message ?: e.javaClass.simpleName, null)
                        },
                    )
                }
            }
        }

        cameraChannel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "start" -> cameraManager.start(result)
                "stop" -> cameraManager.stop(result)
                "dispose" -> cameraManager.dispose(result)
                "getCameraControlCapabilities" -> cameraControls.getCapabilities(result)
                "setExposureLock" ->
                    cameraControls.setExposureLock(call.argument<Boolean>("locked") ?: false, result)
                "setAutoWhiteBalanceLock" ->
                    cameraControls.setAutoWhiteBalanceLock(call.argument<Boolean>("locked") ?: false, result)
                "setFocusLocked" ->
                    cameraControls.setFocusLocked(call.argument<Boolean>("locked") ?: false, result)
                "setManualFocusDistance" ->
                    cameraControls.setManualFocusDistance(call.argument<Double>("distance") ?: 0.0, result)
                "unlockAll" -> cameraControls.unlockAll(result)
                else -> result.notImplemented()
            }
        }

        // Background-upload foreground-service channel (STUB scaffolding). The
        // upload pipeline (Dart) starts the service when an upload begins (or the
        // app backgrounds during one), pushes progress, and stops it on
        // complete/cancel. The service owns the notification + version matrix; the
        // transport itself is stubbed for the pipeline to plug in. See
        // UploadForegroundService.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UploadForegroundService.CHANNEL_NAME,
        ).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "startUploadService" -> {
                    UploadForegroundService.start(
                        applicationContext,
                        call.argument<Int>("done") ?: 0,
                        call.argument<Int>("total") ?: 0,
                    )
                    result.success(null)
                }
                "updateProgress" -> {
                    UploadForegroundService.update(
                        applicationContext,
                        call.argument<Int>("done") ?: 0,
                        call.argument<Int>("total") ?: 0,
                    )
                    result.success(null)
                }
                "stopUploadService" -> {
                    UploadForegroundService.stop(applicationContext)
                    result.success(null)
                }
                "hasNotificationsPermission" ->
                    result.success(
                        UploadForegroundService.hasPostNotificationsPermission(applicationContext),
                    )
                // Background auto-resume of offline-queued uploads: a unique
                // WorkManager request constrained to NetworkType.CONNECTED. The
                // Dart offline queue handles the foreground; this is the OS-side
                // counterpart for when the app is backgrounded/killed with jobs
                // waiting for connection. See UploadResumeWorker.
                "scheduleNetworkResume" -> {
                    UploadResumeWorker.schedule(applicationContext)
                    result.success(null)
                }
                "cancelNetworkResume" -> {
                    UploadResumeWorker.cancel(applicationContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Native permissions channel. This Activity hosts the channel and
        // forwards the OS permission callback below — see PermissionManager.
        permissionManager = PermissionManager(applicationContext).also { it.activity = this }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PermissionManager.CHANNEL_NAME,
        ).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            val permission = call.argument<String>("permission")
            when (call.method) {
                "check" -> {
                    if (permission == null) {
                        result.error("BAD_ARGS", "Missing 'permission' argument.", null)
                    } else {
                        result.success(permissionManager.check(permission))
                    }
                }
                "request" -> {
                    if (permission == null) {
                        result.error("BAD_ARGS", "Missing 'permission' argument.", null)
                    } else {
                        // Completes asynchronously in onRequestPermissionsResult.
                        permissionManager.request(permission, result)
                    }
                }
                "openAppSettings" -> {
                    // Recovery path for permanently-denied permissions. Returns
                    // whether the settings screen launched — never the user's
                    // choice (observed by the Dart resume re-check).
                    result.success(permissionManager.openAppSettings())
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Re-register the rotation-vector listener only if a stream is still
        // subscribed (the manager tracks that); a no-op otherwise.
        imuRotationManager?.onHostResume()
        stabilityManager?.onHostResume()
    }

    override fun onPause() {
        super.onPause()
        // Backgrounded → unregister the sensor listeners (no battery drain/leak).
        imuRotationManager?.onHostPause()
        stabilityManager?.onHostPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        // Resolve our pending MethodChannel result first. Only fall through to
        // super (other plugins) when the request code wasn't ours.
        val handled = ::permissionManager.isInitialized &&
            permissionManager.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (!handled) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun onDestroy() {
        // Only treat a real finish as a teardown — a configuration change keeps
        // the Activity alive (see android:configChanges in the manifest), so
        // in-flight requests must not be cancelled then.
        if (::permissionManager.isInitialized && isFinishing) {
            permissionManager.onActivityDestroyed()
        }
        // Release the camera on a real finish (a config change keeps the Activity
        // alive — see android:configChanges — so do not tear down then).
        if (isFinishing) {
            cameraCaptureManager?.dispose()
            cameraCaptureManager = null
            blurAnalysisManager?.dispose()
            blurAnalysisManager = null
            cameraPreviewManager?.dispose(null)
            cameraPreviewManager = null
            // Unregister the sensor listeners and quit their HandlerThreads.
            imuRotationManager?.dispose()
            imuRotationManager = null
            stabilityManager?.dispose()
            stabilityManager = null
            // Stop accepting storage I/O work (in-flight jobs finish).
            storageExecutor?.shutdown()
            storageExecutor = null
            captureStorage = null
        }
        super.onDestroy()
    }
}
