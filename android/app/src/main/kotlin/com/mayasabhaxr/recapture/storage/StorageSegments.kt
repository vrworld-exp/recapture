// android/app/src/main/kotlin/com/mayasabhaxr/recapture/storage/StorageSegments.kt
package com.mayasabhaxr.recapture.storage

import java.io.File

/**
 * Pure, framework-free path-segment sanitization + file naming for the capture
 * storage tree `<base>/recapture/<projectId>/<jobId>/images/<level>/`. This is the
 * **security boundary**: `projectId`/`jobId`/`level`/`frameId` arrive from outside
 * (project/job ids, capture config) and are interpolated into filesystem paths, so a
 * crafted value like `../../etc` MUST NOT be able to escape the app-scoped base.
 *
 * Strategy: a strict allowlist (`[A-Za-z0-9_-]`, 1..[MAX_SEGMENT_LEN] chars). That
 * inherently rejects `.`, `..`, `/`, `\`, null bytes, whitespace, and every other
 * traversal/encoding trick — there is nothing to "strip", an invalid segment is
 * simply rejected. The manager additionally re-asserts containment with
 * [assertWithin] after resolving (defence in depth), so even a future bug in the
 * allowlist cannot write outside the base.
 *
 * Free of Android runtime classes (operates on `String`/`File`), so the sanitization,
 * naming, and containment logic are JVM-unit-testable.
 */
object StorageSegments {

    /** Root dir name under the app-scoped base. */
    const val ROOT_DIR = "recapture"

    /** Fixed segment between `<jobId>` and `<level>`. */
    const val IMAGES_DIR = "images"

    /** Captured-frame extension; the sidecar mirrors the name with [SIDECAR_EXT]. */
    const val FRAME_EXT = "jpg"

    /** Per-frame JSON sidecar extension (matches the EXIF/sidecar task: `<frame>.json`). */
    const val SIDECAR_EXT = "json"

    const val MAX_SEGMENT_LEN = 128

    private val ALLOWED = Regex("^[A-Za-z0-9_-]{1,$MAX_SEGMENT_LEN}$")

    /** A sanitized frame/sidecar name pair within a level dir. */
    data class FrameNames(val frame: String, val sidecar: String)

    /** True iff [segment] is a safe single path segment (allowlist). */
    fun isValid(segment: String?): Boolean = segment != null && ALLOWED.matches(segment)

    /**
     * Returns [segment] if valid, else throws [IllegalArgumentException] with a clear,
     * non-leaking message (the rejected value is not echoed, to avoid log injection).
     * [label] names which id failed (`projectId`/`jobId`/`level`).
     */
    fun require(segment: String?, label: String): String {
        require(isValid(segment)) {
            "Invalid $label: must be 1..$MAX_SEGMENT_LEN of [A-Za-z0-9_-] (no separators, dots, or traversal)."
        }
        return segment!!
    }

    /**
     * Canonicalizes a numeric [level] to a stable decimal segment (`0`, `1`, …) so an
     * int and its string form map to the SAME directory. Negative levels are rejected.
     */
    fun level(level: Int): String {
        require(level >= 0) { "Invalid level: must be >= 0." }
        return level.toString()
    }

    /**
     * Builds the collision-free frame + sidecar names for sequence number [seq] and an
     * optional caller [frameId]. The zero-padded [seq] (allocated atomically per level
     * by the manager) guarantees uniqueness even under concurrent burst writes and
     * regardless of a duplicate/blank/invalid [frameId]; a valid [frameId] is appended
     * for traceability, an invalid one is dropped (never trusted into the filename).
     * The sidecar shares the base name with a `.json` extension — exactly what the
     * EXIF/sidecar task derives (`<frame>.json` alongside the frame).
     */
    fun frameNames(seq: Long, frameId: String?): FrameNames {
        val safeId = frameId?.takeIf { isValid(it) }
        val base = if (safeId != null) "%06d_%s".format(seq, safeId) else "%06d".format(seq)
        return FrameNames(frame = "$base.$FRAME_EXT", sidecar = "$base.$SIDECAR_EXT")
    }

    /** Parses the leading sequence number from a frame file name, or null. */
    fun sequenceOf(fileName: String): Long? =
        Regex("^(\\d+)").find(fileName)?.groupValues?.get(1)?.toLongOrNull()

    /** True iff [name] is a captured frame (`*.jpg`, case-insensitive). */
    fun isFrame(name: String): Boolean = name.endsWith(".$FRAME_EXT", ignoreCase = true)

    /**
     * Asserts [child] resolves inside [base] (canonical-path containment). The last
     * line of defence against traversal — throws [SecurityException] if a resolved
     * path would escape the app-scoped base.
     */
    fun assertWithin(base: File, child: File) {
        val basePath = base.canonicalPath
        val childPath = child.canonicalPath
        if (childPath != basePath && !childPath.startsWith(basePath + File.separator)) {
            throw SecurityException("Resolved path escapes the capture base.")
        }
    }
}
