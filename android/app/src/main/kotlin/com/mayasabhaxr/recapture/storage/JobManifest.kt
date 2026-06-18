// android/app/src/main/kotlin/com/mayasabhaxr/recapture/storage/JobManifest.kt
package com.mayasabhaxr.recapture.storage

import com.mayasabhaxr.recapture.camera.MetadataJson

/**
 * Per-job manifest/marker used to distinguish a COMPLETE job from one INTERRUPTED
 * mid-capture (app killed during a burst). It is written at job start
 * ([Status.IN_PROGRESS]) and finalized at completion ([Status.COMPLETE]); a job dir
 * whose manifest is missing or not [Status.COMPLETE] is "incomplete" and can be
 * resumed or cleaned (see [CaptureStorage.listIncompleteJobs]).
 *
 * Encoded with the shared [MetadataJson] encoder for consistency with the per-frame
 * sidecars; decoded by a small targeted reader over the few, controlled scalar keys
 * (the values are sanitized ids/numbers/one of two status tokens — no arbitrary JSON),
 * so both encode and parse are pure and JVM-unit-testable without a JSON runtime.
 */
data class JobManifest(
    val projectId: String,
    val jobId: String,
    val status: Status,
    val startedAtMs: Long,
    val completedAtMs: Long? = null,
    /** Frames the capture flow reported at completion (informational; null until complete). */
    val frameCount: Int? = null,
) {
    enum class Status(val wire: String) {
        IN_PROGRESS("in_progress"),
        COMPLETE("complete");

        companion object {
            fun fromWire(s: String?): Status? = entries.firstOrNull { it.wire == s }
        }
    }

    val isComplete: Boolean get() = status == Status.COMPLETE

    fun encode(): String {
        val map = LinkedHashMap<String, Any?>()
        map["projectId"] = projectId
        map["jobId"] = jobId
        map["status"] = status.wire
        map["startedAtMs"] = startedAtMs
        map["completedAtMs"] = completedAtMs
        map["frameCount"] = frameCount
        return MetadataJson.encode(map)
    }

    companion object {
        /** Manifest file name; lives in the JOB dir (above the `images/` levels). */
        const val FILE_NAME = "_manifest.json"

        /**
         * Parses a manifest written by [encode]. Tolerant of key order and absent
         * optional fields; returns null only if the required identity/status/start
         * fields are unreadable (then the job is treated as incomplete, never trusted).
         */
        fun parse(text: String): JobManifest? {
            val projectId = stringField(text, "projectId") ?: return null
            val jobId = stringField(text, "jobId") ?: return null
            val status = Status.fromWire(stringField(text, "status")) ?: return null
            val startedAtMs = longField(text, "startedAtMs") ?: return null
            return JobManifest(
                projectId = projectId,
                jobId = jobId,
                status = status,
                startedAtMs = startedAtMs,
                completedAtMs = longField(text, "completedAtMs"),
                frameCount = longField(text, "frameCount")?.toInt(),
            )
        }

        private fun stringField(text: String, key: String): String? =
            Regex("\"$key\"\\s*:\\s*\"([^\"]*)\"").find(text)?.groupValues?.get(1)

        // Number field; explicit `null` (or absent) → null.
        private fun longField(text: String, key: String): Long? =
            Regex("\"$key\"\\s*:\\s*(-?\\d+)").find(text)?.groupValues?.get(1)?.toLongOrNull()
    }
}
