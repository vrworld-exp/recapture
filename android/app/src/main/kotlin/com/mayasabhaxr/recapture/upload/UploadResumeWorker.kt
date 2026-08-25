// android/app/src/main/kotlin/com/mayasabhaxr/recapture/upload/UploadResumeWorker.kt
package com.mayasabhaxr.recapture.upload

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * WorkManager-backed BACKGROUND auto-resume for offline-queued uploads: a
 * one-time work request constrained to [NetworkType.CONNECTED], so the OS runs
 * it only when connectivity is actually available — even if the app process was
 * killed while jobs were waiting for connection.
 *
 * ── Division of labour (no double-run) ───────────────────────────────────────
 * The Dart [OfflineUploadQueue] monitors connectivity and drives resume while
 * the app is in the FOREGROUND. This worker is the BACKGROUND counterpart: the
 * pipeline schedules it (via the upload_service MethodChannel →
 * [UploadForegroundServiceClient.scheduleNetworkResume]) when the app leaves the
 * foreground with queued jobs, and CANCELS it when the queue drains or the user
 * cancels. Unique work + REPLACE means at most ONE resume request is ever
 * pending — re-scheduling refreshes rather than stacks.
 *
 * ── STUB ─────────────────────────────────────────────────────────────────────
 * Like [UploadForegroundService.runUploadStub], the actual resume TRANSPORT is
 * intentionally NOT implemented here — the scaffolding (constraint, uniqueness,
 * backoff, scheduling API) is real; [runResumeStub] is the single, documented
 * plug-in point the upload-pipeline task replaces (read the durable queue,
 * start [UploadForegroundService] with the real transfer, resume from the
 * persisted offset/ETags). Until then the worker simply succeeds so WorkManager
 * never retries a no-op forever.
 */
class UploadResumeWorker(
    context: Context,
    params: WorkerParameters,
) : Worker(context, params) {

    override fun doWork(): Result {
        // Reaching here means the CONNECTED constraint is satisfied — the OS
        // says a network is available (still only a hint; the real transfer is
        // the reachability truth, and its failure re-queues + backs off).
        return runResumeStub()
    }

    /**
     * The background-resume PLUG-IN POINT. **STUB — intentionally does nothing.**
     *
     * The upload-pipeline task replaces this with: read the durable upload queue
     * (offline-queued jobs only — NEVER user-paused ones), start the upload
     * foreground service, and run the transfer from the persisted resume state.
     * Return [Result.retry] on a transient failure so WorkManager's exponential
     * backoff re-attempts under the same network constraint.
     */
    private fun runResumeStub(): Result {
        Log.d(TAG, "connectivity available — resume stub invoked (no transport yet)")
        return Result.success()
    }

    companion object {
        private const val TAG = "UploadResumeWorker"

        /** Unique work name — one pending resume request at most. */
        const val WORK_NAME = "upload_network_resume"

        /**
         * Schedules (or refreshes) the network-constrained resume request.
         * Runs when the OS reports connectivity; retries with exponential
         * backoff if the worker asks for it.
         */
        fun schedule(context: Context) {
            val request = OneTimeWorkRequestBuilder<UploadResumeWorker>()
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build(),
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.REPLACE, request)
        }

        /** Cancels any pending resume request (queue drained / user cancelled). */
        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }
    }
}
