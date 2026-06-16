package com.mayasabhaxr.recapture

import com.mayasabhaxr.recapture.permissions.PermissionManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private lateinit var permissionManager: PermissionManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
        super.onDestroy()
    }
}
