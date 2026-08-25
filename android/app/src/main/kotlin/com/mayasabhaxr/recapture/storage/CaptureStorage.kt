// android/app/src/main/kotlin/com/mayasabhaxr/recapture/storage/CaptureStorage.kt
package com.mayasabhaxr.recapture.storage

import android.content.Context
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Filesystem backbone for the capture storage hierarchy
 * `<appBase>/recapture/<projectId>/<jobId>/images/<level>/`. Resolves the base,
 * creates the nested structure on demand, allocates collision-free frame (+ sidecar)
 * paths under concurrent burst writes, enumerates + accounts for size/space, marks +
 * detects incomplete jobs, and deletes levels/jobs/projects (guarded against active
 * jobs). It is the storage layer ONLY — it captures nothing, writes no metadata
 * CONTENT (the burst/EXIF tasks do), and does no processing/upload.
 *
 * ## App-scoped storage (no permission) — reconciles with P2
 * The base is **app-scoped** (`getExternalFilesDir(null)`, falling back to `filesDir`),
 * so capture output needs NO `READ/WRITE_EXTERNAL_STORAGE`. Capture is therefore
 * decoupled from the storage permission (which, if used at all, is for importing user
 * media). The `/recapture` tree is rooted under that base — never at filesystem root
 * or shared/public storage.
 *
 * ## Security (no traversal)
 * Every `projectId`/`jobId`/`level`/`frameId` is sanitized by [StorageSegments]
 * (strict allowlist) before it touches a path, and each resolved dir/file is
 * re-asserted to stay under [root] via [StorageSegments.assertWithin] — a crafted
 * `../../etc` is rejected, not written.
 *
 * ## Concurrency
 * Directory creation is `mkdirs` (idempotent, race-tolerant). Frame path allocation
 * uses a per-level [AtomicLong] sequence seeded past any existing frames (so a resumed
 * job never reuses an index), making concurrent `newFramePath` calls collision-free.
 *
 * ## Threading
 * All methods perform blocking file I/O and MUST be called off the main thread. They
 * are synchronous (the native burst task already runs on its capture executor); the
 * MethodChannel layer dispatches to [io] for Dart-initiated calls.
 */
class CaptureStorage internal constructor(
    /** The `<appBase>/recapture` root. Injected directly so the manager is JVM-testable. */
    val root: File,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    companion object {
        const val CHANNEL_NAME = "com.mayasabhaxr.recapture/capture_storage"

        // Delete-result codes surfaced to Dart.
        const val CODE_OK = "ok"
        const val CODE_ACTIVE_JOB = "active_job"
        const val CODE_NOT_FOUND = "not_found"
        const val CODE_IO_ERROR = "io_error"

        // Purge-result statuses surfaced to Dart (the project-deletion cleanup hook):
        //   ok      → the whole tree was removed
        //   partial → some files were locked/in-use and survived (see failed paths)
        //   refused → a capture job for the project is active (nothing deleted)
        //   noop    → nothing to purge (never captured / already gone) — idempotent
        const val STATUS_OK = "ok"
        const val STATUS_PARTIAL = "partial"
        const val STATUS_REFUSED = "refused"
        const val STATUS_NOOP = "noop"

        /**
         * Resolves the app-scoped base and roots `/recapture` under it. Prefers
         * external app-scoped storage (larger capacity for capture data); falls back to
         * internal `filesDir` if external is unavailable (e.g. ejected). No permission.
         */
        fun fromContext(context: Context): CaptureStorage {
            val base = context.getExternalFilesDir(null) ?: context.filesDir
            return CaptureStorage(File(base, StorageSegments.ROOT_DIR))
        }
    }

    /** Per-level atomic sequence counters, keyed by the level dir's canonical path. */
    private val sequences = ConcurrentHashMap<String, AtomicLong>()

    /** Jobs currently capturing (guards deletes), keyed by [jobKey]. */
    private val activeJobs: MutableSet<String> = ConcurrentHashMap.newKeySet()

    // ── results ────────────────────────────────────────────────────────────────

    /** A collision-free frame + its sidecar path within a level. */
    data class FramePaths(
        val frameId: String?,
        val sequence: Long,
        val framePath: String,
        val sidecarPath: String,
    )

    /** Frame count + total bytes on disk for a scope (level/job/project). */
    data class Usage(val frameCount: Int, val byteCount: Long)

    /** An interrupted job and why it is considered incomplete. */
    data class IncompleteJob(val projectId: String, val jobId: String, val reason: String)

    /** Outcome of a delete (code is one of the `CODE_*` constants). */
    data class DeleteResult(val ok: Boolean, val code: String, val filesDeleted: Int, val bytesFreed: Long) {
        fun toMap(): Map<String, Any?> =
            mapOf("ok" to ok, "code" to code, "filesDeleted" to filesDeleted, "bytesFreed" to bytesFreed)
    }

    /**
     * Outcome of purging a project's local capture data ([purgeProject]). [status] is
     * one of the `STATUS_*` constants. [reclaimedBytes] is the on-disk footprint of the
     * files actually deleted (so a `partial` still reports what it freed). [failed] lists
     * the absolute paths that could not be deleted (non-empty only on `partial`) — the
     * caller can retry exactly those rather than re-walking the whole tree.
     */
    data class PurgeResult(val status: String, val reclaimedBytes: Long, val failed: List<String>) {
        fun toMap(): Map<String, Any?> =
            mapOf("status" to status, "reclaimedBytes" to reclaimedBytes, "failed" to failed)
    }

    /**
     * Outcome of an orphan sweep ([sweepOrphans]): the projects whose trees were purged,
     * the total bytes reclaimed, and the projects [skipped] (a job was active, the purge
     * was partial, or the dir name was not a valid project id and was left untouched).
     */
    data class SweepResult(val purgedProjects: List<String>, val reclaimedBytes: Long, val skipped: List<String>) {
        fun toMap(): Map<String, Any?> =
            mapOf("purgedProjects" to purgedProjects, "reclaimedBytes" to reclaimedBytes, "skipped" to skipped)
    }

    // ── path resolution (sanitized + contained) ──────────────────────────────────

    fun projectDir(projectId: String): File =
        resolve(StorageSegments.require(projectId, "projectId"))

    fun jobDir(projectId: String, jobId: String): File =
        resolve(StorageSegments.require(projectId, "projectId"), StorageSegments.require(jobId, "jobId"))

    /**
     * Resolves the level dir, **creating** the nested structure on demand (idempotent).
     * Throws [IllegalArgumentException] for an invalid segment and [IOException] if the
     * directory cannot be created.
     */
    @Throws(IOException::class)
    fun levelDir(projectId: String, jobId: String, level: String): File {
        val dir = resolve(
            StorageSegments.require(projectId, "projectId"),
            StorageSegments.require(jobId, "jobId"),
            StorageSegments.IMAGES_DIR,
            StorageSegments.require(level, "level"),
        )
        ensureDir(dir)
        return dir
    }

    /** [levelDir] overload that canonicalizes an int level (`0`,`1`,…) consistently. */
    @Throws(IOException::class)
    fun levelDir(projectId: String, jobId: String, level: Int): File =
        levelDir(projectId, jobId, StorageSegments.level(level))

    /** Resolves a child of [root] from already-or-about-to-be-validated segments. */
    private fun resolve(vararg segments: String): File {
        var f = root
        for (s in segments) f = File(f, s)
        StorageSegments.assertWithin(root, f)
        return f
    }

    // ── frame allocation (collision-free, concurrency-safe) ──────────────────────

    /**
     * Allocates a unique frame + sidecar path in `(projectId, jobId, level)`, creating
     * the level dir if needed. Safe under concurrent burst writes: the per-level
     * sequence is atomic and seeded past existing files, so two parallel calls never
     * collide and a resumed job never overwrites earlier frames. The sidecar shares the
     * frame's base name with a `.json` extension (the EXIF task's pairing).
     */
    @Throws(IOException::class)
    fun newFramePath(projectId: String, jobId: String, level: String, frameId: String? = null): FramePaths {
        val dir = levelDir(projectId, jobId, level)
        val seq = counterFor(dir).getAndIncrement()
        val names = StorageSegments.frameNames(seq, frameId)
        val frame = File(dir, names.frame)
        StorageSegments.assertWithin(root, frame)
        return FramePaths(
            frameId = frameId,
            sequence = seq,
            framePath = frame.absolutePath,
            sidecarPath = File(dir, names.sidecar).absolutePath,
        )
    }

    /** Per-level counter, seeded once from existing frame files (resume-safe). */
    private fun counterFor(levelDir: File): AtomicLong =
        sequences.computeIfAbsent(levelDir.canonicalPath) {
            val maxSeq = levelDir.listFiles()
                ?.filter { it.isFile && StorageSegments.isFrame(it.name) }
                ?.mapNotNull { StorageSegments.sequenceOf(it.name) }
                ?.maxOrNull()
            AtomicLong((maxSeq?.plus(1)) ?: 0L)
        }

    // ── enumeration ───────────────────────────────────────────────────────────────

    /** Frame files in a level (sorted by name = capture order); empty if none. */
    fun listFrames(projectId: String, jobId: String, level: String): List<File> {
        val dir = resolve(
            StorageSegments.require(projectId, "projectId"),
            StorageSegments.require(jobId, "jobId"),
            StorageSegments.IMAGES_DIR,
            StorageSegments.require(level, "level"),
        )
        return dir.listFiles()?.asSequence()
            ?.filter { it.isFile && StorageSegments.isFrame(it.name) }
            ?.sortedBy { it.name }
            ?.toList()
            ?: emptyList()
    }

    fun listLevels(projectId: String, jobId: String): List<String> =
        childDirNames(File(jobDir(projectId, jobId), StorageSegments.IMAGES_DIR))

    fun listJobs(projectId: String): List<String> = childDirNames(projectDir(projectId))

    fun listProjects(): List<String> = childDirNames(root)

    private fun childDirNames(dir: File): List<String> =
        dir.listFiles()?.filter { it.isDirectory }?.map { it.name }?.sorted() ?: emptyList()

    // ── accounting + free space ────────────────────────────────────────────────────

    /**
     * Frame count + total bytes under a scope: a project (jobId/level null), a job
     * (level null), or a single level. Walks lazily ([File.walkTopDown]) so a job with
     * thousands of frames is streamed, not loaded into memory. `byteCount` is the real
     * on-disk footprint (frames + sidecars + manifest); `frameCount` counts only `.jpg`.
     */
    fun usage(projectId: String, jobId: String? = null, level: String? = null): Usage {
        val scope = when {
            level != null && jobId != null -> resolve(
                StorageSegments.require(projectId, "projectId"),
                StorageSegments.require(jobId, "jobId"),
                StorageSegments.IMAGES_DIR,
                StorageSegments.require(level, "level"),
            )
            jobId != null -> jobDir(projectId, jobId)
            else -> projectDir(projectId)
        }
        if (!scope.exists()) return Usage(0, 0L)
        var frames = 0
        var bytes = 0L
        for (f in scope.walkTopDown()) {
            if (!f.isFile) continue
            bytes += f.length()
            if (StorageSegments.isFrame(f.name)) frames++
        }
        return Usage(frames, bytes)
    }

    /**
     * Usable bytes on the storage volume holding the capture tree — the capture flow
     * checks this before/during a burst to stop gracefully before filling storage.
     * Walks up to the nearest existing ancestor (the root may not exist yet).
     */
    fun freeSpaceBytes(): Long {
        var dir: File? = root
        while (dir != null && !dir.exists()) dir = dir.parentFile
        return dir?.usableSpace ?: 0L
    }

    // ── job manifest (incomplete-job detection) ──────────────────────────────────

    /** Marks a job as started (writes an IN_PROGRESS manifest; flags it active). */
    @Throws(IOException::class)
    fun markJobStart(projectId: String, jobId: String) {
        val pid = StorageSegments.require(projectId, "projectId")
        val jid = StorageSegments.require(jobId, "jobId")
        val dir = jobDir(pid, jid)
        ensureDir(dir)
        writeManifest(
            dir,
            JobManifest(pid, jid, JobManifest.Status.IN_PROGRESS, startedAtMs = clock()),
        )
        activeJobs.add(jobKey(pid, jid))
    }

    /** Finalizes a job (writes a COMPLETE manifest; clears active). Idempotent. */
    @Throws(IOException::class)
    fun markJobComplete(projectId: String, jobId: String, frameCount: Int? = null) {
        val pid = StorageSegments.require(projectId, "projectId")
        val jid = StorageSegments.require(jobId, "jobId")
        val dir = jobDir(pid, jid)
        if (!dir.exists()) return
        val started = readManifest(dir)?.startedAtMs ?: clock()
        writeManifest(
            dir,
            JobManifest(pid, jid, JobManifest.Status.COMPLETE, started, completedAtMs = clock(), frameCount = frameCount),
        )
        activeJobs.remove(jobKey(pid, jid))
    }

    /**
     * Lists jobs interrupted mid-capture: a job dir whose manifest is missing
     * (`no_manifest`) or not COMPLETE (`in_progress`). An empty job dir with neither
     * frames nor a manifest is ignored (nothing to resume/clean).
     */
    fun listIncompleteJobs(): List<IncompleteJob> {
        val out = ArrayList<IncompleteJob>()
        for (project in listProjects()) {
            val projectDir = File(root, project)
            for (jobDir in projectDir.listFiles()?.filter { it.isDirectory } ?: emptyList()) {
                val manifest = readManifest(jobDir)
                when {
                    manifest == null -> {
                        // No manifest: incomplete only if it actually holds capture data.
                        if (hasAnyFrame(jobDir)) out.add(IncompleteJob(project, jobDir.name, "no_manifest"))
                    }
                    !manifest.isComplete -> out.add(IncompleteJob(project, jobDir.name, manifest.status.wire))
                }
            }
        }
        return out
    }

    fun readManifest(projectId: String, jobId: String): JobManifest? =
        readManifest(jobDir(projectId, jobId))

    private fun writeManifest(jobDir: File, manifest: JobManifest) {
        val file = File(jobDir, JobManifest.FILE_NAME)
        val temp = File(jobDir, JobManifest.FILE_NAME + ".tmp")
        temp.writeText(manifest.encode(), Charsets.UTF_8)
        if (!temp.renameTo(file)) {
            temp.copyTo(file, overwrite = true)
            temp.delete()
        }
    }

    private fun readManifest(jobDir: File): JobManifest? {
        val file = File(jobDir, JobManifest.FILE_NAME)
        if (!file.isFile) return null
        return runCatching { JobManifest.parse(file.readText(Charsets.UTF_8)) }.getOrNull()
    }

    private fun hasAnyFrame(jobDir: File): Boolean =
        jobDir.walkTopDown().any { it.isFile && StorageSegments.isFrame(it.name) }

    // ── deletion (guarded against active jobs; complete) ─────────────────────────

    @Throws(IOException::class)
    fun deleteLevel(projectId: String, jobId: String, level: String, force: Boolean = false): DeleteResult {
        val pid = StorageSegments.require(projectId, "projectId")
        val jid = StorageSegments.require(jobId, "jobId")
        if (!force && isActive(pid, jid)) return guarded()
        val dir = resolve(pid, jid, StorageSegments.IMAGES_DIR, StorageSegments.require(level, "level"))
        return deleteTree(dir)
    }

    @Throws(IOException::class)
    fun deleteJob(projectId: String, jobId: String, force: Boolean = false): DeleteResult {
        val pid = StorageSegments.require(projectId, "projectId")
        val jid = StorageSegments.require(jobId, "jobId")
        if (!force && isActive(pid, jid)) return guarded()
        val result = deleteTree(jobDir(pid, jid))
        if (result.ok) {
            activeJobs.remove(jobKey(pid, jid))
            sequences.keys.removeAll { it.contains(File.separator + jid + File.separator) }
        }
        return result
    }

    /**
     * Deletes a project's entire capture tree. Refuses (unless [force]) if ANY job in
     * the project is active. This is the hook P1 project-deletion calls to clean a
     * deleted project's capture data (no orphaned `/recapture` subtree).
     */
    @Throws(IOException::class)
    fun deleteProject(projectId: String, force: Boolean = false): DeleteResult {
        val pid = StorageSegments.require(projectId, "projectId")
        if (!force && activeJobs.any { it.startsWith(pid + KEY_SEP) }) return guarded()
        val result = deleteTree(projectDir(pid))
        if (result.ok) {
            activeJobs.removeAll { it.startsWith(pid + KEY_SEP) }
            sequences.keys.removeAll { it.contains(File.separator + pid + File.separator) }
        }
        return result
    }

    /**
     * Purges a project's entire local capture tree (`/recapture/<projectId>/`). This is
     * the project-deletion cleanup hook the client delete flow calls to reclaim space.
     *
     * Reconciled with P1's **soft** delete as **purge-on-delete (Option A)**: the user's
     * delete reclaims the (large, local) capture images immediately, so a later restore
     * recovers the server project record but NOT its local capture data. (Documented in
     * docs/camera/storage-cleanup-on-delete.md.)
     *
     * - **Sanitized / exact-match:** [projectId] goes through [StorageSegments.require],
     *   so a crafted `../otherProject`, separators, or null bytes are rejected — never
     *   traversing out or hitting another project's tree.
     * - **Guarded:** while ANY job in the project is active (between start/complete) the
     *   purge is `refused` and deletes nothing, unless [force]; an in-flight capture is
     *   never deleted out from under itself.
     * - **Idempotent:** a missing tree (never captured / already purged) is a `noop`
     *   success.
     * - **Complete or honest:** removes the whole subtree; if some files are locked/in-use
     *   they survive and are returned as `partial` with their paths (retryable) rather
     *   than a silent partial state.
     *
     * Blocking I/O — call off the main thread (the channel layer dispatches to [io]).
     */
    @Throws(IOException::class)
    fun purgeProject(projectId: String, force: Boolean = false): PurgeResult {
        val pid = StorageSegments.require(projectId, "projectId")
        if (!force && activeJobs.any { it.startsWith(pid + KEY_SEP) }) {
            return PurgeResult(STATUS_REFUSED, 0L, emptyList())
        }
        val dir = projectDir(pid)
        if (!dir.exists()) return PurgeResult(STATUS_NOOP, 0L, emptyList())
        val outcome = purgeTree(dir)
        return if (outcome.failed.isEmpty()) {
            // Fully gone: drop the project's in-memory bookkeeping so a re-created
            // project of the same id starts clean (no stale active flag / seq counter).
            activeJobs.removeAll { it.startsWith(pid + KEY_SEP) }
            sequences.keys.removeAll { it.contains(File.separator + pid + File.separator) }
            PurgeResult(STATUS_OK, outcome.bytesFreed, emptyList())
        } else {
            PurgeResult(STATUS_PARTIAL, outcome.bytesFreed, outcome.failed)
        }
    }

    /**
     * Optional orphan sweep: purges capture trees for projects on disk that are NOT in
     * [knownProjectIds] — data left behind by a project deleted while the app was off (it
     * missed its delete hook). The known set comes from the caller (the app's server/local
     * project list); this manager keeps no project list of its own. Each orphan goes
     * through [purgeProject], so the SAME guards/policy apply: sanitization, active-job
     * refusal, idempotency, and partial reporting. A dir whose name is not a valid project
     * id is left untouched (recorded in [SweepResult.skipped]) — never force-deleted.
     */
    fun sweepOrphans(knownProjectIds: Collection<String>, force: Boolean = false): SweepResult {
        val known = knownProjectIds.toHashSet()
        val purged = ArrayList<String>()
        val skipped = ArrayList<String>()
        var bytes = 0L
        for (project in listProjects()) {
            if (known.contains(project)) continue // still a known project — keep its data
            val result = try {
                purgeProject(project, force)
            } catch (e: IllegalArgumentException) {
                skipped.add(project) // not a valid project id — never touch it
                continue
            }
            when (result.status) {
                STATUS_OK -> { purged.add(project); bytes += result.reclaimedBytes }
                STATUS_PARTIAL -> { purged.add(project); bytes += result.reclaimedBytes; skipped.add(project) }
                STATUS_REFUSED -> skipped.add(project) // a job is active — left for next time
                // STATUS_NOOP: vanished under us — nothing to report
            }
        }
        return SweepResult(purged, bytes, skipped)
    }

    /** A tree delete that records which files survived (locked/in-use). */
    private data class TreeOutcome(val filesDeleted: Int, val bytesFreed: Long, val failed: List<String>)

    /**
     * Deletes [dir] and everything under it bottom-up, so a directory is removed only
     * after its children: empty dirs then delete cleanly, and a child that fails leaves
     * its parent behind (reported via the child path, the retryable unit). Only file
     * failures are collected — a non-empty dir is the expected consequence of a failed
     * child, not a separate failure.
     */
    private fun purgeTree(dir: File): TreeOutcome {
        StorageSegments.assertWithin(root, dir)
        var files = 0
        var bytes = 0L
        val failed = ArrayList<String>()
        for (f in dir.walkBottomUp()) {
            if (f.isFile) {
                val len = f.length()
                if (f.delete()) {
                    files++
                    bytes += len
                } else {
                    failed.add(f.absolutePath)
                }
            } else {
                f.delete() // remove the dir if now empty; ignore if a child survived
            }
        }
        return TreeOutcome(files, bytes, failed)
    }

    private fun deleteTree(dir: File): DeleteResult {
        StorageSegments.assertWithin(root, dir)
        if (!dir.exists()) return DeleteResult(ok = true, code = CODE_NOT_FOUND, filesDeleted = 0, bytesFreed = 0L)
        var files = 0
        var bytes = 0L
        for (f in dir.walkTopDown()) {
            if (f.isFile) {
                files++
                bytes += f.length()
            }
        }
        return if (dir.deleteRecursively()) {
            DeleteResult(ok = true, code = CODE_OK, filesDeleted = files, bytesFreed = bytes)
        } else {
            DeleteResult(ok = false, code = CODE_IO_ERROR, filesDeleted = 0, bytesFreed = 0L)
        }
    }

    private fun guarded() = DeleteResult(ok = false, code = CODE_ACTIVE_JOB, filesDeleted = 0, bytesFreed = 0L)

    // ── helpers ──────────────────────────────────────────────────────────────────

    /** True while a job is between [markJobStart] and [markJobComplete]. */
    fun isActive(projectId: String, jobId: String): Boolean =
        activeJobs.contains(jobKey(projectId, jobId))

    @Throws(IOException::class)
    private fun ensureDir(dir: File) {
        StorageSegments.assertWithin(root, dir)
        if (dir.isDirectory) return // idempotent
        if (!dir.mkdirs() && !dir.isDirectory) { // mkdirs may race: re-check the result
            throw IOException("Could not create directory: ${dir.path}")
        }
    }

    private fun jobKey(projectId: String, jobId: String) = projectId + KEY_SEP + jobId
}

private const val KEY_SEP = " "
