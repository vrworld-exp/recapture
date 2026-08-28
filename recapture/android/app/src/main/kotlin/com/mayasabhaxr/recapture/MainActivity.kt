// android/app/src/main/kotlin/com/mayasabhaxr/recapture/MainActivity.kt
package com.mayasabhaxr.recapture

import com.mayasabhaxr.recapture.capture.CaptureModule
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register the capture channel — handled by CaptureModule.
        // P3 will add additional channels here (e.g. sensor EventChannel)
        // following the same pattern.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CaptureModule.CHANNEL_NAME
        ).setMethodCallHandler(CaptureModule(applicationContext))
    }
}
