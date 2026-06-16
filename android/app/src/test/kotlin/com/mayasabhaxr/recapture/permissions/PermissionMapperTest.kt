// android/app/src/test/kotlin/com/mayasabhaxr/recapture/permissions/PermissionMapperTest.kt
package com.mayasabhaxr.recapture.permissions

import android.Manifest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM unit tests for the logical → concrete permission mapping across API
 * levels. No device/Robolectric: the test exercises [PermissionMapper] with the
 * API level supplied as a parameter, asserting against compile-time-inlined
 * `Manifest.permission.*` constants.
 */
class PermissionMapperTest {

    private val allLevels = intArrayOf(24, 28, 29, 30, 32, 33, 34)

    @Test
    fun camera_isCameraOnEveryApiLevel() {
        for (sdk in allLevels) {
            assertEquals(
                "camera @ API $sdk",
                listOf(Manifest.permission.CAMERA),
                PermissionMapper.concretePermissions("camera", sdk),
            )
        }
    }

    @Test
    fun storage_legacyReadUpToApi32() {
        for (sdk in intArrayOf(24, 28, 29, 30, 32)) {
            assertEquals(
                "storage @ API $sdk",
                listOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                PermissionMapper.concretePermissions("storage", sdk),
            )
        }
    }

    @Test
    fun storage_granularMediaOnApi33Plus() {
        val expected = listOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
        )
        assertEquals(expected, PermissionMapper.concretePermissions("storage", 33))
        assertEquals(expected, PermissionMapper.concretePermissions("storage", 34))
    }

    @Test
    fun storage_neverRequestsWriteOnApi29Plus() {
        for (sdk in intArrayOf(29, 30, 32, 33, 34)) {
            assertTrue(
                "WRITE must not be requested @ API $sdk",
                PermissionMapper.concretePermissions("storage", sdk)
                    .none { it == Manifest.permission.WRITE_EXTERNAL_STORAGE },
            )
        }
    }

    @Test
    fun storage_neverRequestsLegacyReadOnApi33Plus() {
        for (sdk in intArrayOf(33, 34)) {
            assertTrue(
                "legacy READ_EXTERNAL_STORAGE must not be requested @ API $sdk",
                PermissionMapper.concretePermissions("storage", sdk)
                    .none { it == Manifest.permission.READ_EXTERNAL_STORAGE },
            )
        }
    }

    @Test
    fun activityRecognition_runtimeOnApi29Plus_autoGrantedBelow() {
        assertEquals(emptyList<String>(), PermissionMapper.concretePermissions("activityRecognition", 24))
        assertEquals(emptyList<String>(), PermissionMapper.concretePermissions("activityRecognition", 28))
        assertEquals(
            listOf(Manifest.permission.ACTIVITY_RECOGNITION),
            PermissionMapper.concretePermissions("activityRecognition", 29),
        )
        assertEquals(
            listOf(Manifest.permission.ACTIVITY_RECOGNITION),
            PermissionMapper.concretePermissions("activityRecognition", 33),
        )
    }

    @Test
    fun motion_rawImuNeedsNoPermissionOnAnyApiLevel() {
        for (sdk in allLevels) {
            assertEquals(
                "motion @ API $sdk",
                emptyList<String>(),
                PermissionMapper.concretePermissions("motion", sdk),
            )
        }
    }

    @Test
    fun unknownKey_mapsToEmpty() {
        assertEquals(emptyList<String>(), PermissionMapper.concretePermissions("bogus", 33))
    }
}
