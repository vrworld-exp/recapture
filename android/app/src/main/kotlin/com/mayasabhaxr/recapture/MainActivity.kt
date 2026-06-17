package com.mayasabhaxr.recapture

import com.mayasabhaxr.recapture.camera.CameraCaptureManager
import com.mayasabhaxr.recapture.camera.CameraControlsManager
import com.mayasabhaxr.recapture.camera.CameraPreviewManager
import com.mayasabhaxr.recapture.permissions.PermissionManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private lateinit var permissionManager: PermissionManager
    private var cameraPreviewManager: CameraPreviewManager? = null
    private var cameraCaptureManager: CameraCaptureManager? = null

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
        cameraManager.captureUseCase = cameraCapture.imageCapture
        cameraManager.onCameraChanged = { camera ->
            cameraControls.updateCamera(camera)
            if (camera != null) cameraCapture.onCameraBound(camera) else cameraCapture.onCameraUnbound()
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CameraCaptureManager.EVENTS_CHANNEL_NAME,
        ).setStreamHandler(cameraCapture)

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
                else -> result.notImplemented()
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
            cameraPreviewManager?.dispose(null)
            cameraPreviewManager = null
        }
        super.onDestroy()
    }
}
