// android/app/src/test/kotlin/com/mayasabhaxr/recapture/camera/CaptureMetadataTest.kt
package com.mayasabhaxr.recapture.camera

import androidx.exifinterface.media.ExifInterface
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM unit tests for the capture-metadata logic: the JSON encoder, the
 * sidecar map shape (precise-ts vs wall-clock distinction, omitted intrinsics,
 * reserved pose), EXIF orientation/GPS/rational/35mm helpers, and time formatting.
 *
 * No device / Robolectric: the only Android references are compile-time-inlined
 * `ExifInterface` constants; everything else is pure JDK.
 */
class CaptureMetadataTest {

    // ── MetadataJson ─────────────────────────────────────────────────────────────

    @Test
    fun json_encodesPrimitives() {
        assertEquals("null", MetadataJson.encode(null))
        assertEquals("true", MetadataJson.encode(true))
        assertEquals("42", MetadataJson.encode(42))
        assertEquals("123456789012345", MetadataJson.encode(123456789012345L))
    }

    @Test
    fun json_trimsWholeDoublesButKeepsFractions() {
        assertEquals("4", MetadataJson.encode(4.0))
        assertEquals("4.2", MetadataJson.encode(4.2))
    }

    @Test
    fun json_nonFiniteBecomesNull() {
        assertEquals("null", MetadataJson.encode(Double.NaN))
        assertEquals("null", MetadataJson.encode(Double.POSITIVE_INFINITY))
    }

    @Test
    fun json_escapesStrings() {
        assertEquals(""""a\"b\\c\n"""", MetadataJson.encode("a\"b\\c\n"))
    }

    @Test
    fun json_encodesOrderedObjectAndArray() {
        val map = linkedMapOf<String, Any?>("a" to 1, "b" to listOf(1, 2), "c" to null)
        assertEquals("""{"a":1,"b":[1,2],"c":null}""", MetadataJson.encode(map))
    }

    // ── sidecar map ──────────────────────────────────────────────────────────────

    private fun sampleMetadata(
        intrinsics: CameraIntrinsics = CameraIntrinsics(4.2, 1.8, 6.4, 4.8, "0"),
    ) = CaptureMetadata(
        sessionId = "cap_1",
        frameId = "cap_1_00000",
        frameIndex = 0,
        captureTimestampNs = 123456789012345L,
        wallClockMillis = 0L,
        device = DeviceDescriptor("Google", "Pixel 7", "Android 14 (API 34)", "1.0.0", "0"),
        resolution = ResolutionMeta(4000, 3000, "4:3", 90, false),
        intrinsics = intrinsics,
        conditions = CaptureConditions(
            afLocked = true,
            aeLocked = true,
            awbLocked = false,
            exposureTimeNs = null,
            iso = null,
            focusDistanceDiopters = null,
        ),
    )

    @Test
    fun sidecar_hasPreciseTimestampAndDistinctWallClock() {
        val map = sampleMetadata().toSidecarMap("normal")
        assertEquals(123456789012345L, map["captureTimestampNs"])
        assertEquals("1970-01-01T00:00:00.000Z", map["wallClockIso"])
        // The alignment key and the human wall-clock are distinct representations.
        assertTrue(map["captureTimestampNs"].toString() != map["wallClockIso"].toString())
    }

    @Test
    fun sidecar_reservesPoseAsNull() {
        val map = sampleMetadata().toSidecarMap("normal")
        assertTrue(map.containsKey("pose"))
        assertNull(map["pose"])
    }

    @Test
    fun sidecar_recordsOrientationApplied() {
        assertEquals("rotate90", sampleMetadata().toSidecarMap("rotate90")["orientationApplied"])
    }

    @Test
    fun sidecar_intrinsicsDeriveFocalLength35mm() {
        @Suppress("UNCHECKED_CAST")
        val intr = sampleMetadata().toSidecarMap("normal")["intrinsics"] as Map<String, Any?>
        assertEquals(4.2, intr["focalLengthMm"])
        // hypot(6.4,4.8)=8.0 → 4.2 * (43.266615/8.0) ≈ 22.7 → 23
        assertEquals(23, intr["focalLength35mm"])
    }

    @Test
    fun sidecar_omitsUnknownIntrinsics() {
        val map = sampleMetadata(CameraIntrinsics(null, null, null, null, null)).toSidecarMap("normal")
        @Suppress("UNCHECKED_CAST")
        val intr = map["intrinsics"] as Map<String, Any?>
        assertTrue("intrinsics should be empty when device exposes none", intr.isEmpty())
    }

    @Test
    fun sidecar_keepsExplicitNullCaptureSettings() {
        @Suppress("UNCHECKED_CAST")
        val capture = sampleMetadata().toSidecarMap("normal")["capture"] as Map<String, Any?>
        assertEquals(true, capture["afLocked"])
        assertTrue(capture.containsKey("exposureTimeNs"))
        assertNull(capture["exposureTimeNs"])
        assertNull(capture["iso"])
    }

    @Test
    fun sidecar_encodesToValidJson() {
        val json = MetadataJson.encode(sampleMetadata().toSidecarMap("normal"))
        assertTrue(json.contains("\"captureTimestampNs\":123456789012345"))
        assertTrue(json.contains("\"wallClockIso\":\"1970-01-01T00:00:00.000Z\""))
        assertTrue(json.contains("\"pose\":null"))
        assertTrue(json.startsWith("{") && json.endsWith("}"))
    }

    // ── ExifOrientation ──────────────────────────────────────────────────────────

    @Test
    fun orientation_normalizesInvalidToNormal() {
        assertEquals(ExifInterface.ORIENTATION_NORMAL, ExifOrientation.normalize(0))
        assertEquals(ExifInterface.ORIENTATION_NORMAL, ExifOrientation.normalize(9))
        assertEquals(ExifInterface.ORIENTATION_NORMAL, ExifOrientation.normalize(-1))
    }

    @Test
    fun orientation_passesThroughValid() {
        for (o in 1..8) assertEquals(o, ExifOrientation.normalize(o))
    }

    @Test
    fun orientation_labels() {
        assertEquals("normal", ExifOrientation.label(ExifInterface.ORIENTATION_NORMAL))
        assertEquals("rotate90", ExifOrientation.label(ExifInterface.ORIENTATION_ROTATE_90))
        assertEquals("rotate270", ExifOrientation.label(ExifInterface.ORIENTATION_ROTATE_270))
    }

    @Test
    fun gpsTags_coverLatLong() {
        assertTrue(ExifOrientation.GPS_TAGS.isNotEmpty())
        assertTrue(ExifOrientation.GPS_TAGS.contains(ExifInterface.TAG_GPS_LATITUDE))
        assertTrue(ExifOrientation.GPS_TAGS.contains(ExifInterface.TAG_GPS_LONGITUDE))
    }

    // ── ExifMath ─────────────────────────────────────────────────────────────────

    @Test
    fun rational_encodesPositive() {
        assertEquals("420/100", ExifMath.rational(4.2))
        assertEquals("180/100", ExifMath.rational(1.8))
    }

    @Test
    fun rational_rejectsInvalid() {
        assertNull(ExifMath.rational(null))
        assertNull(ExifMath.rational(0.0))
        assertNull(ExifMath.rational(-1.0))
        assertNull(ExifMath.rational(Double.NaN))
    }

    @Test
    fun focalLength35mm_derivedWhenKnown() {
        assertEquals(23, ExifMath.focalLength35mm(4.2, 6.4, 4.8))
    }

    @Test
    fun focalLength35mm_nullWhenAnyInputMissing() {
        assertNull(ExifMath.focalLength35mm(null, 6.4, 4.8))
        assertNull(ExifMath.focalLength35mm(4.2, null, 4.8))
        assertNull(ExifMath.focalLength35mm(4.2, 6.4, null))
        assertNull(ExifMath.focalLength35mm(4.2, 0.0, 4.8))
    }

    @Test
    fun isJpeg_detectsSoiMarker() {
        assertTrue(ExifMath.isJpeg(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x00)))
        assertFalse(ExifMath.isJpeg(byteArrayOf(0x00, 0x01)))
        assertFalse(ExifMath.isJpeg(byteArrayOf(0xFF.toByte())))
    }

    // ── MetadataTime ─────────────────────────────────────────────────────────────

    @Test
    fun time_isoUtcFormat() {
        assertEquals("1970-01-01T00:00:00.000Z", MetadataTime.isoUtc(0L))
    }

    @Test
    fun time_exifDateTimeFormat() {
        assertEquals("1970:01:01 00:00:00", MetadataTime.exifDateTime(0L))
    }

    @Test
    fun time_subSec() {
        assertEquals("234", MetadataTime.subSec(1234L))
        assertEquals("000", MetadataTime.subSec(1000L))
    }
}
