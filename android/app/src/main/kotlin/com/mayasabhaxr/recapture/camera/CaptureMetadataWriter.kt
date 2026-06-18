// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/CaptureMetadataWriter.kt
package com.mayasabhaxr.recapture.camera

import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Per-frame post-capture metadata step: normalizes interop **EXIF** on the JPEG
 * and writes a per-frame JSON **sidecar** ([CaptureMetadata]).
 *
 * Runs entirely on its own single-thread I/O executor — **off the main thread and
 * off the capture cadence** — so a fast burst is never stalled by metadata I/O.
 * The burst task streams frames and enqueues a job per frame; jobs drain in order,
 * possibly slightly behind capture, but every frame is eventually annotated. A
 * failure is reported (never silently dropped).
 *
 * Safety: EXIF is written to a temp copy, validated as a real JPEG, then the temp
 * **atomically replaces** the original — a mid-write failure cannot corrupt the
 * captured JPEG (the original is untouched and the sidecar is still written).
 *
 * Scope is metadata only: no capture triggering, processing, permission, or
 * lifecycle work, and **no pose** (reserved null slot for the sensor/fusion task).
 */
class CaptureMetadataWriter {

    companion object {
        private const val APP_NAME = "MayasabhaXR"
        private const val EXIF_TEMP_SUFFIX = ".exiftmp"
        private const val SIDECAR_TEMP_SUFFIX = ".tmp"
    }

    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile
    private var disposed = false

    /**
     * Notified (on the I/O thread) with a result map per processed frame:
     * `{ type:"metadata", frameId, index, jpegPath, sidecarPath, exifOk, sidecarOk, error? }`.
     * [CameraCaptureManager] forwards this to the capture EventChannel.
     */
    var onResult: ((Map<String, Any?>) -> Unit)? = null

    /** Queues a frame for EXIF + sidecar processing. Returns immediately. */
    fun enqueue(jpeg: File, metadata: CaptureMetadata) {
        if (disposed) return
        try {
            ioExecutor.execute { process(jpeg, metadata) }
        } catch (_: RejectedExecutionException) {
            // Executor shutting down (dispose) — drop quietly.
        }
    }

    /** Lets queued jobs finish, then stops accepting new work. */
    fun dispose() {
        disposed = true
        ioExecutor.shutdown()
    }

    // ── processing (I/O thread) ──────────────────────────────────────────────────

    private fun process(jpeg: File, metadata: CaptureMetadata) {
        var orientationLabel: String? = null
        var exifOk = false
        var error: String? = null

        try {
            orientationLabel = writeExif(jpeg, metadata)
            exifOk = true
        } catch (e: Exception) {
            // JPEG is left intact by writeExif's temp strategy; record the failure.
            error = "exif: ${e.message ?: e.javaClass.simpleName}"
        }

        // The sidecar is always attempted — it is the source of truth for the
        // pipeline, and must exist even if the EXIF normalization failed.
        val sidecar = sidecarFileFor(jpeg)
        var sidecarOk = false
        try {
            writeSidecar(sidecar, metadata, orientationLabel)
            sidecarOk = true
        } catch (e: Exception) {
            val msg = "sidecar: ${e.message ?: e.javaClass.simpleName}"
            error = if (error == null) msg else "$error; $msg"
        }

        onResult?.invoke(
            linkedMapOf(
                "type" to "metadata",
                "frameId" to metadata.frameId,
                "index" to metadata.frameIndex,
                "jpegPath" to jpeg.absolutePath,
                "sidecarPath" to sidecar.absolutePath,
                "exifOk" to exifOk,
                "sidecarOk" to sidecarOk,
                "error" to error,
            ),
        )
    }

    /**
     * Writes normalized interop EXIF safely (temp copy → validate → atomic replace)
     * and returns the human label of the orientation actually applied. Throws on
     * failure WITHOUT touching the original JPEG.
     */
    private fun writeExif(jpeg: File, metadata: CaptureMetadata): String {
        if (!jpeg.exists()) throw IOException("JPEG missing: ${jpeg.path}")
        val temp = File(jpeg.parentFile, jpeg.name + EXIF_TEMP_SUFFIX)
        jpeg.copyTo(temp, overwrite = true)
        try {
            val exif = ExifInterface(temp.absolutePath)

            // Orientation: normalize to the pipeline convention (valid 1..8, else NORMAL).
            val raw = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED)
            val orientation = ExifOrientation.normalize(raw)
            exif.setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())

            // Make / model / software (interop identity).
            exif.setAttribute(ExifInterface.TAG_MAKE, metadata.device.manufacturer)
            exif.setAttribute(ExifInterface.TAG_MODEL, metadata.device.model)
            exif.setAttribute(ExifInterface.TAG_SOFTWARE, software(metadata.device.appVersion))

            // Human/interop datetime (1s) + sub-second. NOT the alignment timestamp.
            val dateTime = MetadataTime.exifDateTime(metadata.wallClockMillis)
            val subSec = MetadataTime.subSec(metadata.wallClockMillis)
            exif.setAttribute(ExifInterface.TAG_DATETIME, dateTime)
            exif.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, dateTime)
            exif.setAttribute(ExifInterface.TAG_DATETIME_DIGITIZED, dateTime)
            exif.setAttribute(ExifInterface.TAG_SUBSEC_TIME, subSec)
            exif.setAttribute(ExifInterface.TAG_SUBSEC_TIME_ORIGINAL, subSec)
            exif.setAttribute(ExifInterface.TAG_SUBSEC_TIME_DIGITIZED, subSec)

            // Intrinsics (only when the device exposed them — never fabricated).
            ExifMath.rational(metadata.intrinsics.focalLengthMm)?.let {
                exif.setAttribute(ExifInterface.TAG_FOCAL_LENGTH, it)
            }
            ExifMath.rational(metadata.intrinsics.fNumber)?.let {
                exif.setAttribute(ExifInterface.TAG_F_NUMBER, it)
            }
            metadata.intrinsics.focalLength35mm?.let {
                exif.setAttribute(ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, it.toString())
            }

            // Privacy: strip any GPS/location the source may carry.
            for (tag in ExifOrientation.GPS_TAGS) exif.setAttribute(tag, null)

            exif.saveAttributes()

            if (!isValidJpeg(temp)) throw IOException("EXIF write produced an invalid JPEG.")
            atomicReplace(temp, jpeg)
            return ExifOrientation.label(orientation)
        } catch (e: Exception) {
            temp.delete()
            throw e
        }
    }

    private fun writeSidecar(sidecar: File, metadata: CaptureMetadata, orientationLabel: String?) {
        val json = MetadataJson.encode(metadata.toSidecarMap(orientationLabel))
        val temp = File(sidecar.parentFile, sidecar.name + SIDECAR_TEMP_SUFFIX)
        temp.writeText(json, Charsets.UTF_8)
        atomicReplace(temp, sidecar)
    }

    // ── helpers ──────────────────────────────────────────────────────────────────

    /** `<frame>.jpg` → `<frame>.json`, alongside the frame. */
    private fun sidecarFileFor(jpeg: File): File =
        File(jpeg.parentFile, jpeg.nameWithoutExtension + ".json")

    private fun software(appVersion: String?): String =
        if (appVersion.isNullOrBlank()) APP_NAME else "$APP_NAME/$appVersion"

    /** Validates [file] still begins with the JPEG SOI marker and re-opens as EXIF. */
    private fun isValidJpeg(file: File): Boolean {
        val header = ByteArray(2)
        FileInputStream(file).use { if (it.read(header) != 2) return false }
        if (!ExifMath.isJpeg(header)) return false
        return try {
            ExifInterface(file.absolutePath)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Replaces [dest] with [temp]; rename is atomic on the same filesystem. */
    private fun atomicReplace(temp: File, dest: File) {
        if (temp.renameTo(dest)) return
        // Fallback (e.g. dest exists on a platform where rename won't overwrite).
        temp.copyTo(dest, overwrite = true)
        temp.delete()
    }
}
