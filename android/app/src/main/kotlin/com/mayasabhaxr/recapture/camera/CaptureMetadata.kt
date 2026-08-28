// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/CaptureMetadata.kt
package com.mayasabhaxr.recapture.camera

import androidx.exifinterface.media.ExifInterface
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Per-frame capture metadata + the pure (framework-light) helpers that build the
 * JSON sidecar and normalize EXIF.
 *
 * Model: standard interoperable fields go into the JPEG's **EXIF** (written by
 * [CaptureMetadataWriter]); richer/app-specific and high-precision fields go into
 * a per-frame **JSON sidecar** (`<frame>.json`). The defining distinction:
 *
 *  - EXIF `DateTime` is wall-clock at ~1-second resolution, for human/interop use.
 *  - [captureTimestampNs] is the precise **monotonic** sensor timestamp recorded
 *    by the burst task â€” the sensor-alignment key. It lives ONLY in the sidecar,
 *    never as the EXIF datetime. Do not conflate them.
 *
 * The sidecar is the source of truth for app/pipeline metadata. `pose` is a
 * reserved null slot filled later by the sensor/pose-fusion task (not here).
 *
 * Everything in this file is deliberately free of Android *runtime* classes (only
 * compile-time-inlined `ExifInterface` constants and pure JDK `text`/`util`), so
 * the sidecar shape, JSON encoding, and EXIF normalization are JVM-unit-testable.
 */
data class CaptureMetadata(
    val sessionId: String,
    val frameId: String,
    val frameIndex: Int,
    /** Precise monotonic capture timestamp (sensor alignment key). */
    val captureTimestampNs: Long,
    /** Wall-clock epoch millis at capture (human/interop; distinct from the above). */
    val wallClockMillis: Long,
    val device: DeviceDescriptor,
    val resolution: ResolutionMeta,
    val intrinsics: CameraIntrinsics,
    val conditions: CaptureConditions,
) {

    /**
     * Builds the ordered sidecar map. [orientationApplied] is the human label of
     * the EXIF orientation the writer ended up with (it depends on reading the
     * JPEG), so it is supplied by the writer; `pose` is always reserved null.
     * Null intrinsics/condition fields are omitted (never fabricated).
     */
    fun toSidecarMap(orientationApplied: String?): LinkedHashMap<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        map["sessionId"] = sessionId
        map["frameId"] = frameId
        map["frameIndex"] = frameIndex
        map["captureTimestampNs"] = captureTimestampNs
        map["wallClockIso"] = MetadataTime.isoUtc(wallClockMillis)

        map["device"] = device.toMap()
        map["resolution"] = resolution.toMap()
        map["intrinsics"] = intrinsics.toMap()
        map["capture"] = conditions.toMap()

        map["orientationApplied"] = orientationApplied
        // RESERVED â€” filled by the sensor/pose-fusion task using captureTimestampNs
        // as the join key. Never computed here.
        map["pose"] = null
        return map
    }
}

/** Device descriptor for the sidecar. */
data class DeviceDescriptor(
    val manufacturer: String,
    val model: String,
    val osVersion: String,
    val appVersion: String?,
    val cameraId: String?,
) {
    fun toMap(): LinkedHashMap<String, Any?> = linkedMapOf(
        "manufacturer" to manufacturer,
        "model" to model,
        "osVersion" to osVersion,
        "appVersion" to appVersion,
        "cameraId" to cameraId,
    )
}

/** Actual resolution chosen for the session (from the resolution-policy task). */
data class ResolutionMeta(
    val width: Int,
    val height: Int,
    val aspectRatio: String,
    val jpegQuality: Int,
    val fellBack: Boolean,
) {
    fun toMap(): LinkedHashMap<String, Any?> = linkedMapOf(
        "width" to width,
        "height" to height,
        "aspectRatio" to aspectRatio,
        "jpegQuality" to jpegQuality,
        "fellBack" to fellBack,
    )
}

/**
 * Camera intrinsics from `CameraCharacteristics` (valuable for photogrammetry
 * calibration). Every field is nullable: a device that does not expose a value
 * omits it from the sidecar â€” nothing is fabricated.
 */
data class CameraIntrinsics(
    val focalLengthMm: Double?,
    val fNumber: Double?,
    val sensorWidthMm: Double?,
    val sensorHeightMm: Double?,
    val cameraId: String?,
) {
    /** 35mm-equivalent focal length, derived only when both inputs are known. */
    val focalLength35mm: Int? get() = ExifMath.focalLength35mm(focalLengthMm, sensorWidthMm, sensorHeightMm)

    /** Omits null fields (graceful for devices lacking intrinsics). */
    fun toMap(): LinkedHashMap<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        focalLengthMm?.let { map["focalLengthMm"] = it }
        focalLength35mm?.let { map["focalLength35mm"] = it }
        fNumber?.let { map["fNumber"] = it }
        sensorWidthMm?.let { map["sensorWidthMm"] = it }
        sensorHeightMm?.let { map["sensorHeightMm"] = it }
        return map
    }
}

/** Capture conditions (lock state) from the focus/exposure-lock task. */
data class CaptureConditions(
    val afLocked: Boolean,
    val aeLocked: Boolean,
    val awbLocked: Boolean,
    /** Exposure time in ns â€” null (not observed via a CaptureResult here). */
    val exposureTimeNs: Long?,
    /** ISO â€” null (not observed here). */
    val iso: Int?,
    val focusDistanceDiopters: Double?,
) {
    fun toMap(): LinkedHashMap<String, Any?> = linkedMapOf(
        "afLocked" to afLocked,
        "aeLocked" to aeLocked,
        "awbLocked" to awbLocked,
        "exposureTimeNs" to exposureTimeNs,
        "iso" to iso,
        "focusDistanceDiopters" to focusDistanceDiopters,
    )
}

/** Wall-clock formatting (pure JDK; UTC, millisecond precision for interop). */
object MetadataTime {
    /** ISO-8601 UTC, e.g. `2026-06-17T10:00:00.123Z`. */
    fun isoUtc(epochMillis: Long): String = isoFormat().format(Date(epochMillis))

    /** EXIF datetime, e.g. `2026:06:17 10:00:00` (1-second; human/interop). */
    fun exifDateTime(epochMillis: Long): String = exifFormat().format(Date(epochMillis))

    /** Sub-second part (milliseconds, 3 digits) for `TAG_SUBSEC_TIME_*`. */
    fun subSec(epochMillis: Long): String = "%03d".format(epochMillis % 1000L)

    private fun isoFormat() = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        .apply { timeZone = TimeZone.getTimeZone("UTC") }

    private fun exifFormat() = SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US)
        .apply { timeZone = TimeZone.getTimeZone("UTC") }
}

/** EXIF orientation normalization + labelling (pure; constants are inlined). */
object ExifOrientation {
    /** Valid EXIF orientations are 1..8; anything else normalizes to NORMAL (1). */
    fun normalize(raw: Int): Int = if (raw in 1..8) raw else ExifInterface.ORIENTATION_NORMAL

    fun label(orientation: Int): String = when (orientation) {
        ExifInterface.ORIENTATION_NORMAL -> "normal"
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> "flipHorizontal"
        ExifInterface.ORIENTATION_ROTATE_180 -> "rotate180"
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> "flipVertical"
        ExifInterface.ORIENTATION_TRANSPOSE -> "transpose"
        ExifInterface.ORIENTATION_ROTATE_90 -> "rotate90"
        ExifInterface.ORIENTATION_TRANSVERSE -> "transverse"
        ExifInterface.ORIENTATION_ROTATE_270 -> "rotate270"
        else -> "normal"
    }

    /** GPS/location tags stripped by default (no location permission; privacy). */
    val GPS_TAGS: List<String> = listOf(
        ExifInterface.TAG_GPS_LATITUDE,
        ExifInterface.TAG_GPS_LATITUDE_REF,
        ExifInterface.TAG_GPS_LONGITUDE,
        ExifInterface.TAG_GPS_LONGITUDE_REF,
        ExifInterface.TAG_GPS_ALTITUDE,
        ExifInterface.TAG_GPS_ALTITUDE_REF,
        ExifInterface.TAG_GPS_TIMESTAMP,
        ExifInterface.TAG_GPS_DATESTAMP,
        ExifInterface.TAG_GPS_PROCESSING_METHOD,
        ExifInterface.TAG_GPS_SPEED,
        ExifInterface.TAG_GPS_SPEED_REF,
        ExifInterface.TAG_GPS_TRACK,
        ExifInterface.TAG_GPS_TRACK_REF,
        ExifInterface.TAG_GPS_IMG_DIRECTION,
        ExifInterface.TAG_GPS_IMG_DIRECTION_REF,
        ExifInterface.TAG_GPS_DOP,
        ExifInterface.TAG_GPS_STATUS,
    )
}

/** Pure EXIF value math: rational encoding, 35mm-equivalent, JPEG validation. */
object ExifMath {

    /**
     * Encodes a positive value as an EXIF rational string `num/den` (e.g. 4.2 â†’
     * `"420/100"`). Returns null for null/non-finite/non-positive input.
     */
    fun rational(value: Double?, denominator: Int = 100): String? {
        if (value == null || !value.isFinite() || value <= 0.0) return null
        val num = Math.round(value * denominator)
        return "$num/$denominator"
    }

    /**
     * 35mm-equivalent focal length = focal Ã— (43.27 / sensorDiagonalMm), rounded.
     * Derived only when focal length and a real sensor size are known (this is a
     * standard photographic conversion, not a fabricated value). Null otherwise.
     */
    fun focalLength35mm(focalMm: Double?, sensorWmm: Double?, sensorHmm: Double?): Int? {
        if (focalMm == null || sensorWmm == null || sensorHmm == null) return null
        if (focalMm <= 0.0 || sensorWmm <= 0.0 || sensorHmm <= 0.0) return null
        val diagonal = Math.hypot(sensorWmm, sensorHmm)
        if (diagonal <= 0.0) return null
        val fullFrameDiagonal = 43.266615 // hypot(36, 24)
        return Math.round(focalMm * (fullFrameDiagonal / diagonal)).toInt()
    }

    /** True if [bytes] begins with the JPEG SOI marker (0xFFD8). */
    fun isJpeg(bytes: ByteArray): Boolean =
        bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()
}

/**
 * Minimal, dependency-free JSON encoder for the sidecar. Handles String, Boolean,
 * Int/Long, Double/Float (finite; NaN/Inf â†’ null), Map (object), Iterable (array),
 * and null. Keys are coerced to String. Ordered output (relies on [LinkedHashMap])
 * so sidecars are deterministic. Kept pure so it is unit-testable.
 */
object MetadataJson {
    fun encode(value: Any?): String = StringBuilder().also { write(it, value) }.toString()

    private fun write(sb: StringBuilder, value: Any?) {
        when (value) {
            null -> sb.append("null")
            is String -> writeString(sb, value)
            is Boolean -> sb.append(value.toString())
            is Int, is Long, is Short, is Byte -> sb.append(value.toString())
            is Double -> sb.append(if (value.isFinite()) trimNumber(value.toString()) else "null")
            is Float -> sb.append(if (value.isFinite()) trimNumber(value.toString()) else "null")
            is Map<*, *> -> writeObject(sb, value)
            is Iterable<*> -> writeArray(sb, value)
            else -> writeString(sb, value.toString())
        }
    }

    private fun writeObject(sb: StringBuilder, map: Map<*, *>) {
        sb.append('{')
        var first = true
        for ((k, v) in map) {
            if (!first) sb.append(',')
            first = false
            writeString(sb, k.toString())
            sb.append(':')
            write(sb, v)
        }
        sb.append('}')
    }

    private fun writeArray(sb: StringBuilder, items: Iterable<*>) {
        sb.append('[')
        var first = true
        for (item in items) {
            if (!first) sb.append(',')
            first = false
            write(sb, item)
        }
        sb.append(']')
    }

    private fun writeString(sb: StringBuilder, s: String) {
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '' -> sb.append("\\f")
                else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
            }
        }
        sb.append('"')
    }

    /** Drops a trailing `.0` so whole doubles serialize as integers-ish (`4.0`â†’`4`). */
    private fun trimNumber(s: String): String = if (s.endsWith(".0")) s.dropLast(2) else s
}
