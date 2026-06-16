// android/app/src/main/kotlin/com/mayasabhaxr/recapture/permissions/PermissionMapper.kt
package com.mayasabhaxr.recapture.permissions

import android.Manifest
import android.os.Build

/**
 * Maps a logical permission key to the concrete Android permission(s) that must
 * actually be requested on the running API level.
 *
 * This is the correctness crux of the native permissions channel and is kept as
 * a PURE function of (logical key, sdkInt) so it can be unit-tested on the plain
 * JVM (no device / Robolectric) — see PermissionMapperTest. Every reference here
 * is a compile-time constant (`Manifest.permission.*` strings, `VERSION_CODES`
 * ints), which the compiler inlines, so no Android methods are invoked at test
 * time.
 *
 * An EMPTY result means "no runtime permission applies at this API level" and the
 * caller must treat the logical permission as auto-granted with no dialog.
 *
 * Logical keys (must match [AndroidPermissionKeys] on the Dart side):
 *   - "camera"              → CAMERA (runtime since API 23; app minSdk is 24).
 *   - "storage"             → legacy READ ≤32; granular READ_MEDIA_* on 33+.
 *                             WRITE is never runtime-requested (manifest-gated to
 *                             ≤28; a no-op under scoped storage on 29+).
 *   - "activityRecognition" → ACTIVITY_RECOGNITION on 29+; auto-granted below.
 *                             (Implemented for completeness; the app's "Motion"
 *                             gate uses raw IMU instead — see "motion".)
 *   - "motion"              → raw IMU (accelerometer/gyroscope/rotation-vector);
 *                             needs no Android permission → always empty.
 */
object PermissionMapper {

    fun concretePermissions(logical: String, sdkInt: Int): List<String> = when (logical) {
        "camera" -> listOf(Manifest.permission.CAMERA)

        "storage" -> when {
            // API 33+ : granular media. Request only the types the app uses
            // (images + video). READ_EXTERNAL_STORAGE has no effect here.
            sdkInt >= Build.VERSION_CODES.TIRAMISU -> listOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO,
            )
            // API ≤32 : legacy read. On ≤28 this grants the STORAGE group,
            // which also covers WRITE_EXTERNAL_STORAGE — so WRITE is never
            // requested on its own.
            else -> listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

        "activityRecognition" -> when {
            sdkInt >= Build.VERSION_CODES.Q -> listOf(Manifest.permission.ACTIVITY_RECOGNITION)
            else -> emptyList() // not a runtime permission below API 29
        }

        // Raw IMU needs no Android permission — always granted, no dialog.
        "motion" -> emptyList()

        else -> emptyList()
    }
}
