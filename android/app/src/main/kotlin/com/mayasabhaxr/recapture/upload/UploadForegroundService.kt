// android/app/src/main/kotlin/com/mayasabhaxr/recapture/upload/UploadForegroundService.kt
package com.mayasabhaxr.recapture.upload

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that hosts the photo UPLOAD so it survives backgrounding —
 * Android's background-execution limits would otherwise kill a long transfer that
 * isn't a foreground service.
 *
 * ── STUB ────────────────────────────────────────────────────────────────────
 * The actual upload TRANSPORT is intentionally NOT implemented here. This delivers
 * the real, correct scaffolding — the foreground service, the persistent
 * notification, the notification channel, the version matrix, and the lifecycle —
 * with [runUploadStub] as the single, documented plug-in point the upload-pipeline
 * task replaces with the real transfer + progress. The stub performs NO transfer
 * and starts NO timers: the service simply holds foreground state until Flutter
 * signals stop (on complete/cancel).
 *
 * ── Version matrix (the correctness crux) ────────────────────────────────────
 *   • API 34+ : a `foregroundServiceType` (dataSync) is REQUIRED both in the
 *     manifest AND at startForeground, or the service fails to start. Passed here
 *     via [ServiceCompat.startForeground] (which supplies the type on API 29+ and
 *     ignores it below).
 *   • API 33+ : posting the notification needs the runtime `POST_NOTIFICATIONS`
 *     permission. If it is DENIED the service STILL runs — the system merely
 *     suppresses the notification's DISPLAY. Neither startForeground nor
 *     NotificationManagerCompat.notify throws for a missing permission, so the
 *     upload is never crashed or blocked. See [hasPostNotificationsPermission].
 *   • API 26+ : a notification channel is created (idempotently) before posting.
 *
 * ── Restart policy ───────────────────────────────────────────────────────────
 * [START_NOT_STICKY]: if the process is killed the OS must NOT blindly recreate the
 * service with a null intent. The durable upload queue (pipeline) is the source of
 * truth — it resumes the transfer on the next app launch, which re-starts this
 * service explicitly with fresh state. A null-intent recreation stops cleanly.
 */
class UploadForegroundService : Service() {

    /** True once we have entered the foreground; gates progress updates + stop. */
    private var isForeground = false

    override fun onBind(intent: Intent?): IBinder? = null // not a bound service

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> handleStart(intent)
            ACTION_UPDATE_PROGRESS -> handleUpdate(intent)
            ACTION_STOP -> handleStop()
            // Null-intent recreation (should not occur under START_NOT_STICKY) or an
            // unknown action → stop cleanly rather than run with no state.
            else -> handleStop()
        }
        return START_NOT_STICKY
    }

    private fun handleStart(intent: Intent) {
        ensureChannel(this)
        val done = intent.getIntExtra(EXTRA_DONE, 0)
        val total = intent.getIntExtra(EXTRA_TOTAL, 0)
        // Enter (or re-affirm) the foreground with the current progress notification.
        // Idempotent: a second START just refreshes the notification.
        if (!startForegroundSafely(buildNotification(done, total))) {
            // Foreground start refused (e.g. a version/type mismatch, or a
            // background-start restriction). Don't crash — bail out cleanly.
            handleStop()
            return
        }
        isForeground = true
        runUploadStub()
    }

    private fun handleUpdate(intent: Intent) {
        // No active upload → no-op (an update that races ahead of / after the
        // service does nothing rather than spuriously entering the foreground).
        if (!isForeground) return
        val done = intent.getIntExtra(EXTRA_DONE, 0)
        val total = intent.getIntExtra(EXTRA_TOTAL, 0)
        ensureChannel(this)
        // Update the ONGOING notification in place. Suppressed (never thrown) when
        // POST_NOTIFICATIONS is denied on API 33+.
        NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, buildNotification(done, total))
    }

    private fun handleStop() {
        isForeground = false
        // Remove the notification and drop out of the foreground, then stop — no
        // lingering service or notification.
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * The upload transport PLUG-IN POINT. **STUB — intentionally does nothing.**
     *
     * The upload-pipeline task replaces this with the real transfer: read the
     * durable queue, upload each frame/sidecar, call [update] as items complete,
     * and call [stop] on completion/cancel. The service, notification, channel, and
     * lifecycle around it are already real.
     */
    private fun runUploadStub() {
        // TODO(upload-pipeline): drive the real transfer here and call
        //   update(context, done, total) as progress advances, then stop(context)
        //   on complete/cancel. Until then the service just holds foreground state.
    }

    /**
     * Enters the foreground with [notification], supplying the dataSync
     * foregroundServiceType on API 29+ (required on API 34+). Returns false — and
     * never propagates — if the platform refuses the start, so a version/type
     * mismatch is handled instead of shipping a crash.
     */
    private fun startForegroundSafely(notification: Notification): Boolean = try {
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            },
        )
        true
    } catch (e: Exception) {
        // e.g. ForegroundServiceStartNotAllowedException (API 31+) or a
        // MissingForegroundServiceTypeException (API 34+ misconfig).
        Log.w(TAG, "startForeground refused: ${e.javaClass.simpleName}: ${e.message}")
        false
    }

    private fun buildNotification(done: Int, total: Int): Notification {
        val tapIntent = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Uploading photos…")
            .setSmallIcon(android.R.drawable.stat_sys_upload) // placeholder (stub)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(tapIntent)
        // Structured for the pipeline to UPDATE: determinate "done of total" once
        // totals are known, indeterminate placeholder until then.
        if (total > 0) {
            builder.setContentText("$done of $total")
            builder.setProgress(total, done.coerceIn(0, total), false)
        } else {
            builder.setContentText("Preparing…")
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    companion object {
        private const val TAG = "UploadFgService"

        /** MethodChannel name — must match AppConfig.channelUploadService (Dart). */
        const val CHANNEL_NAME = "com.mayasabhaxr.recapture/upload_service"

        private const val CHANNEL_ID = "upload_progress"
        private const val CHANNEL_TITLE = "Uploads"
        private const val NOTIFICATION_ID = 42_101

        const val ACTION_START = "com.mayasabhaxr.recapture.upload.START"
        const val ACTION_STOP = "com.mayasabhaxr.recapture.upload.STOP"
        const val ACTION_UPDATE_PROGRESS = "com.mayasabhaxr.recapture.upload.UPDATE"
        const val EXTRA_DONE = "done"
        const val EXTRA_TOTAL = "total"

        /** Creates the upload notification channel (API 26+). Idempotent. */
        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val mgr = context.getSystemService(NotificationManager::class.java) ?: return
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return // already created
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_TITLE,
                NotificationManager.IMPORTANCE_LOW, // quiet, ongoing progress
            ).apply {
                description = "Shows progress while your photos upload."
                setShowBadge(false)
            }
            mgr.createNotificationChannel(channel)
        }

        /** Starts (or refreshes) the upload foreground service. */
        fun start(context: Context, done: Int = 0, total: Int = 0) {
            val intent = Intent(context, UploadForegroundService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_DONE, done)
                .putExtra(EXTRA_TOTAL, total)
            // Must be startForegroundService: the service promotes itself to the
            // foreground within onStartCommand.
            ContextCompat.startForegroundService(context, intent)
        }

        /** Updates the ongoing notification's progress. No-op if not running. */
        fun update(context: Context, done: Int, total: Int) {
            val intent = Intent(context, UploadForegroundService::class.java)
                .setAction(ACTION_UPDATE_PROGRESS)
                .putExtra(EXTRA_DONE, done)
                .putExtra(EXTRA_TOTAL, total)
            // Plain startService (the service is already foregrounded); guarded so a
            // background-start restriction never throws to the caller.
            try {
                context.startService(intent)
            } catch (_: Exception) { /* not running / background-start blocked */ }
        }

        /** Stops the service + removes the notification (complete/cancel). */
        fun stop(context: Context) {
            val intent = Intent(context, UploadForegroundService::class.java)
                .setAction(ACTION_STOP)
            try {
                context.startService(intent)
            } catch (_: Exception) { /* already gone — nothing to stop */ }
        }

        /**
         * Whether the notification can currently be DISPLAYED. On API 33+ this is
         * the POST_NOTIFICATIONS grant; below 33 notifications need no runtime
         * permission (always true). The service runs regardless — this only lets
         * the caller optionally surface "notifications are off".
         */
        fun hasPostNotificationsPermission(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
            return ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        }
    }
}
