// android/app/src/test/kotlin/com/mayasabhaxr/recapture/storage/CaptureStorageTest.kt
package com.mayasabhaxr.recapture.storage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * File-backed JVM tests for the storage manager (a real temp dir stands in for the
 * app-scoped base). Covers structure + idempotent creation, traversal rejection,
 * collision-free concurrent allocation + resume seeding, enumeration/accounting,
 * incomplete-job detection, and guarded/complete deletion. No Android runtime.
 */
class CaptureStorageTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun storage(clock: () -> Long = { 1000L }) =
        CaptureStorage(File(tmp.root, StorageSegments.ROOT_DIR), clock)

    /** Allocates a frame path AND writes it (the burst task's write the manager doesn't do). */
    private fun CaptureStorage.writeFrame(p: String, j: String, level: String, id: String?) {
        val fp = newFramePath(p, j, level, id)
        File(fp.framePath).writeText("x")
    }

    @Test
    fun levelDir_buildsTheHierarchyUnderRoot_idempotently() {
        val s = storage()
        val dir = s.levelDir("proj1", "job1", "0")
        val expected = File(tmp.root, "recapture/proj1/job1/images/0")
        assertEquals(expected.canonicalPath, dir.canonicalPath)
        assertTrue(dir.isDirectory)
        // Second call is a no-op (no error), same dir.
        assertEquals(dir.canonicalPath, s.levelDir("proj1", "job1", "0").canonicalPath)
        // Int level canonicalizes to the same "0" dir.
        assertEquals(dir.canonicalPath, s.levelDir("proj1", "job1", 0).canonicalPath)
    }

    @Test
    fun craftedIds_areRejected_andCannotEscapeBase() {
        val s = storage()
        assertThrows(IllegalArgumentException::class.java) { s.levelDir("../../evil", "job1", "0") }
        assertThrows(IllegalArgumentException::class.java) { s.levelDir("proj1", "..", "0") }
        assertThrows(IllegalArgumentException::class.java) { s.levelDir("proj1", "job1", "a/b") }
        // Nothing was written outside the base.
        assertFalse(File(tmp.root, "evil").exists())
    }

    @Test
    fun newFramePath_pairsSidecarAndAllocatesSequentially() {
        val s = storage()
        val f0 = s.newFramePath("p", "j", "0", "frameA")
        val f1 = s.newFramePath("p", "j", "0", "frameA")
        // Sidecar shares the frame's base name with .json (the EXIF task's pairing).
        assertEquals(f0.framePath.removeSuffix(".jpg") + ".json", f0.sidecarPath)
        assertTrue(f0.framePath.endsWith("000000_frameA.jpg"))
        assertTrue(f1.framePath.endsWith("000001_frameA.jpg")) // seq advanced
        assertFalse(f0.framePath == f1.framePath)
    }

    @Test
    fun newFramePath_isCollisionFreeUnderConcurrentBurst() {
        val s = storage()
        val n = 200
        val pool = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        val done = CountDownLatch(n)
        val paths = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        repeat(n) {
            pool.execute {
                start.await()
                val fp = s.newFramePath("p", "j", "0", null)
                File(fp.framePath).writeText("x") // simulate the burst write
                paths.add(fp.framePath)
                done.countDown()
            }
        }
        start.countDown()
        assertTrue(done.await(20, TimeUnit.SECONDS))
        pool.shutdown()
        // Every allocation was unique and every file actually exists (no collision).
        assertEquals(n, paths.size)
        assertEquals(n, s.listFrames("p", "j", "0").size)
    }

    @Test
    fun counter_seedsPastExistingFramesOnResume() {
        // Simulate an interrupted job: frames already on disk, fresh manager instance.
        val first = storage()
        val dir = first.levelDir("p", "j", "0")
        File(dir, "000000_a.jpg").writeText("x")
        File(dir, "000005_b.jpg").writeText("x") // a gap, max seq = 5

        val resumed = storage() // new instance ⇒ counter unseeded
        val next = resumed.newFramePath("p", "j", "0", "c")
        // Must continue at max+1, never overwrite 000005.
        assertTrue(next.framePath.endsWith("000006_c.jpg"))
    }

    @Test
    fun enumeration_listsFramesLevelsJobsProjects() {
        val s = storage()
        s.writeFrame("p1", "j1", "0", "a")
        s.writeFrame("p1", "j1", "1", "b")
        s.writeFrame("p1", "j2", "0", "c")
        s.writeFrame("p2", "j9", "0", "d")

        assertEquals(listOf("p1", "p2"), s.listProjects())
        assertEquals(listOf("j1", "j2"), s.listJobs("p1"))
        assertEquals(listOf("0", "1"), s.listLevels("p1", "j1"))
        assertEquals(1, s.listFrames("p1", "j1", "0").size)
    }

    @Test
    fun usage_countsFramesAndTotalBytes_perScope() {
        val s = storage()
        val a = s.newFramePath("p", "j", "0", "a")
        File(a.framePath).writeText("AAAA")          // 4 bytes
        File(a.sidecarPath).writeText("{}")          // 2 bytes (not a frame)
        val b = s.newFramePath("p", "j", "1", "b")
        File(b.framePath).writeText("BB")            // 2 bytes

        val job = s.usage("p", "j")
        assertEquals(2, job.frameCount) // two .jpg frames
        assertEquals(8L, job.byteCount) // 4 + 2 + 2 (real on-disk footprint)

        val level0 = s.usage("p", "j", "0")
        assertEquals(1, level0.frameCount)
        assertEquals(6L, level0.byteCount) // 4 + 2

        // Missing scope → zeroes, no crash.
        assertEquals(0, s.usage("nope").frameCount)
    }

    @Test
    fun freeSpace_isPositive() {
        assertTrue(storage().freeSpaceBytes() > 0L)
    }

    @Test
    fun manifest_marksStartCompleteAndDetectsIncomplete() {
        val s = storage()
        // A job started but never completed (app killed mid-burst).
        s.markJobStart("p", "interrupted")
        s.writeFrame("p", "interrupted", "0", "f")
        // A job that completed cleanly.
        s.markJobStart("p", "done")
        s.markJobComplete("p", "done", frameCount = 1)
        // A bare dir with frames but no manifest (older / crashed before start marker).
        s.writeFrame("p", "bare", "0", "g")

        val incomplete = s.listIncompleteJobs().associate { it.jobId to it.reason }
        assertEquals(setOf("interrupted", "bare"), incomplete.keys)
        assertEquals("in_progress", incomplete["interrupted"])
        assertEquals("no_manifest", incomplete["bare"])
        // The completed job is recognized as complete.
        assertTrue(s.readManifest("p", "done")!!.isComplete)
    }

    @Test
    fun delete_isGuardedAgainstActiveJobsAndComplete() {
        val s = storage()
        s.markJobStart("p", "active")
        s.newFramePath("p", "active", "0", "f")

        // Guarded: an active job is not deleted out from under the capture.
        val guarded = s.deleteJob("p", "active")
        assertFalse(guarded.ok)
        assertEquals(CaptureStorage.CODE_ACTIVE_JOB, guarded.code)
        assertTrue(s.jobDir("p", "active").exists())

        // force overrides; the tree is fully removed.
        val forced = s.deleteJob("p", "active", force = true)
        assertTrue(forced.ok)
        assertFalse(s.jobDir("p", "active").exists())
    }

    @Test
    fun deleteProject_removesWholeTree_theP1Hook() {
        val s = storage()
        s.markJobStart("p", "j")
        s.newFramePath("p", "j", "0", "f")
        s.markJobComplete("p", "j")

        val result = s.deleteProject("p")
        assertTrue(result.ok)
        assertTrue(result.filesDeleted >= 1)
        assertFalse(s.projectDir("p").exists())
        // No orphaned recapture subtree for the deleted project.
        assertFalse(s.listProjects().contains("p"))
    }

    @Test
    fun deleteLevel_removesOnlyThatLevel() {
        val s = storage()
        s.newFramePath("p", "j", "0", "a")
        s.newFramePath("p", "j", "1", "b")
        val r = s.deleteLevel("p", "j", "0")
        assertTrue(r.ok)
        assertEquals(listOf("1"), s.listLevels("p", "j"))
    }

    // ── purge hook (project-deletion cleanup) ────────────────────────────────────

    @Test
    fun purgeProject_removesWholeTree_reportsReclaimedBytes() {
        val s = storage()
        val a = s.newFramePath("p", "j", "0", "a")
        File(a.framePath).writeText("AAAA")  // 4 bytes
        File(a.sidecarPath).writeText("{}")  // 2 bytes
        s.markJobStart("p", "j2")
        s.markJobComplete("p", "j2")         // a finalized (inactive) job

        val r = s.purgeProject("p")
        assertEquals(CaptureStorage.STATUS_OK, r.status)
        assertTrue(r.reclaimedBytes >= 6L)   // frame + sidecar (+ manifests)
        assertTrue(r.failed.isEmpty())
        // Whole tree gone — no orphaned subtree for the deleted project.
        assertFalse(s.projectDir("p").exists())
        assertFalse(s.listProjects().contains("p"))
    }

    @Test
    fun purgeProject_missingTree_isNoopSuccess() {
        val s = storage()
        val r = s.purgeProject("neverCaptured")
        assertEquals(CaptureStorage.STATUS_NOOP, r.status)
        assertEquals(0L, r.reclaimedBytes)
        assertTrue(r.failed.isEmpty())
    }

    @Test
    fun purgeProject_isIdempotent() {
        val s = storage()
        s.writeFrame("p", "j", "0", "a")
        assertEquals(CaptureStorage.STATUS_OK, s.purgeProject("p").status)
        // Second purge of the same project: already gone → no-op success, no crash.
        assertEquals(CaptureStorage.STATUS_NOOP, s.purgeProject("p").status)
    }

    @Test
    fun purgeProject_refusesWhileAJobIsActive_thenForceOverrides() {
        val s = storage()
        s.markJobStart("p", "active")
        s.writeFrame("p", "active", "0", "f")

        val refused = s.purgeProject("p")
        assertEquals(CaptureStorage.STATUS_REFUSED, refused.status)
        assertEquals(0L, refused.reclaimedBytes)
        assertTrue(s.projectDir("p").exists()) // in-flight job untouched

        val forced = s.purgeProject("p", force = true)
        assertEquals(CaptureStorage.STATUS_OK, forced.status)
        assertFalse(s.projectDir("p").exists())
    }

    @Test
    fun purgeProject_craftedId_isRejected_andNothingEscapes() {
        val s = storage()
        s.writeFrame("victim", "j", "0", "f")
        assertThrows(IllegalArgumentException::class.java) { s.purgeProject("../victim") }
        assertThrows(IllegalArgumentException::class.java) { s.purgeProject("a/b") }
        // The crafted ids touched nothing — the real project is intact.
        assertTrue(s.projectDir("victim").exists())
    }

    @Test
    fun purgeProject_reportsPartial_whenAFileCannotBeDeleted() {
        val s = storage()
        s.writeFrame("p", "j", "0", "stuck")
        val levelDir = s.levelDir("p", "j", "0")
        val frame = levelDir.listFiles()!!.first { it.isFile }
        // Simulate a locked/in-use file: on POSIX, removing a file needs write
        // permission on its parent dir. If the platform doesn't honor that
        // (e.g. Windows), skip rather than assert a false negative.
        assumeTrue(levelDir.setWritable(false))
        try {
            assumeTrue(!frame.delete()) // confirm the file is genuinely undeletable now
            val r = s.purgeProject("p")
            assertEquals(CaptureStorage.STATUS_PARTIAL, r.status)
            assertTrue(r.failed.contains(frame.absolutePath))
            assertTrue(s.projectDir("p").exists()) // not a silent complete delete
        } finally {
            levelDir.setWritable(true) // let TemporaryFolder clean up
        }
    }

    // ── orphan sweep ─────────────────────────────────────────────────────────────

    @Test
    fun sweepOrphans_purgesUnknownProjects_keepsKnownOnes() {
        val s = storage()
        s.writeFrame("keep", "j", "0", "a")
        s.writeFrame("orphan1", "j", "0", "b")
        s.writeFrame("orphan2", "j", "0", "c")

        val r = s.sweepOrphans(knownProjectIds = listOf("keep"))
        assertEquals(setOf("orphan1", "orphan2"), r.purgedProjects.toSet())
        assertTrue(r.reclaimedBytes > 0L)
        // Known project untouched; orphans gone.
        assertTrue(s.projectDir("keep").exists())
        assertEquals(listOf("keep"), s.listProjects())
    }

    @Test
    fun sweepOrphans_skipsAProjectWithAnActiveJob() {
        val s = storage()
        s.markJobStart("orphanBusy", "active")
        s.writeFrame("orphanBusy", "active", "0", "f")

        val r = s.sweepOrphans(knownProjectIds = emptyList())
        // Active orphan is refused (left for next time), reported as skipped.
        assertTrue(r.skipped.contains("orphanBusy"))
        assertFalse(r.purgedProjects.contains("orphanBusy"))
        assertTrue(s.projectDir("orphanBusy").exists())
    }
}
