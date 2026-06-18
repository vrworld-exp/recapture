// android/app/src/test/kotlin/com/mayasabhaxr/recapture/storage/JobManifestTest.kt
package com.mayasabhaxr.recapture.storage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM tests for the job manifest encode/parse round-trip, status detection, and
 * tolerance of absent optionals / malformed text (→ null ⇒ treated as incomplete).
 */
class JobManifestTest {

    @Test
    fun encodeParse_roundTripsInProgress() {
        val m = JobManifest("proj1", "job1", JobManifest.Status.IN_PROGRESS, startedAtMs = 1000L)
        val parsed = JobManifest.parse(m.encode())!!
        assertEquals("proj1", parsed.projectId)
        assertEquals("job1", parsed.jobId)
        assertEquals(JobManifest.Status.IN_PROGRESS, parsed.status)
        assertEquals(1000L, parsed.startedAtMs)
        assertNull(parsed.completedAtMs)
        assertNull(parsed.frameCount)
        assertFalse(parsed.isComplete)
    }

    @Test
    fun encodeParse_roundTripsComplete() {
        val m = JobManifest("p", "j", JobManifest.Status.COMPLETE, startedAtMs = 1L, completedAtMs = 2L, frameCount = 36)
        val parsed = JobManifest.parse(m.encode())!!
        assertTrue(parsed.isComplete)
        assertEquals(2L, parsed.completedAtMs)
        assertEquals(36, parsed.frameCount)
    }

    @Test
    fun parse_returnsNullOnMissingRequiredFields() {
        assertNull(JobManifest.parse("{}"))
        assertNull(JobManifest.parse("not json at all"))
        // Missing status → null.
        assertNull(JobManifest.parse("""{"projectId":"p","jobId":"j","startedAtMs":1}"""))
        // Unknown status token → null.
        assertNull(JobManifest.parse("""{"projectId":"p","jobId":"j","status":"weird","startedAtMs":1}"""))
    }
}
