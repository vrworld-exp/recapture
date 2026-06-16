// android/app/src/main/kotlin/com/mayasabhaxr/recapture/permissions/PermissionManager.kt
package com.mayasabhaxr.recapture.permissions

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of the `com.mayasabhaxr.recapture/permissions` MethodChannel.
 *
 * Responsibilities (see the task contract):
 *   - map a logical permission key → concrete permission(s) for the running API
 *     level (delegated to [PermissionMapper]);
 *   - `check` reports status WITHOUT prompting;
 *   - `request` triggers the OS dialog and completes the [MethodChannel.Result]
 *     asynchronously, exactly once, when `onRequestPermissionsResult` fires —
 *     keyed by a stable request code;
 *   - distinguish never-asked from permanently-denied via a persisted
 *     "has been requested" flag combined with `shouldShowRequestPermissionRationale`;
 *   - require a foreground Activity; survive Activity-null and teardown without
 *     crashing or leaking the pending result.
 *
 * Status strings returned to Dart — MUST match the AppPermissionStatus mapping in
 * lib/platform/permissions_service.dart:
 *   "granted" | "denied" | "permanentlyDenied" | "restricted"
 */
class PermissionManager(private val appContext: Context) {

    /**
     * The current foreground Activity. Set by the host (MainActivity) when the
     * engine is configured and cleared when the Activity is finishing. Requests
     * require a non-null value; reads degrade gracefully when null.
     */
    var activity: Activity? = null

    private val prefs =
        appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** In-flight requests keyed by request code. At most one per logical key. */
    private val pending = mutableMapOf<Int, PendingRequest>()

    private class PendingRequest(
        val result: MethodChannel.Result,
        var replied: Boolean = false,
    )

    companion object {
        /** Must match AppConfig.channelPermissions in lib/utils/constants.dart. */
        const val CHANNEL_NAME = "com.mayasabhaxr.recapture/permissions"

        private const val PREFS = "mayasabhaxr.permissions"
        private const val KEY_REQUESTED_PREFIX = "requested_"

        // Normalized status strings (mirror the Dart enum mapping).
        private const val GRANTED = "granted"
        private const val DENIED = "denied"
        private const val PERMANENTLY_DENIED = "permanentlyDenied"
        private const val RESTRICTED = "restricted"

        // Stable, distinct request codes per logical permission.
        private val REQUEST_CODES = mapOf(
            "camera" to 7001,
            "storage" to 7002,
            "activityRecognition" to 7003,
            "motion" to 7004,
        )

        // Severity ordering for aggregating multiple concrete permissions into a
        // single status — the worst wins.
        private val RANK = mapOf(
            GRANTED to 0,
            DENIED to 1,
            RESTRICTED to 2,
            PERMANENTLY_DENIED to 3,
        )
    }

    // ── check (never prompts) ────────────────────────────────────────────────

    fun check(logical: String): String {
        val concrete = PermissionMapper.concretePermissions(logical, Build.VERSION.SDK_INT)
        // No concrete permission applies at this API level (raw-IMU "motion", or
        // activityRecognition below API 29) → auto-granted, no dialog.
        if (concrete.isEmpty()) return GRANTED
        if (concrete.all { isGranted(it) }) return GRANTED
        return aggregateUnprompted(concrete)
    }

    // ── request (prompts; resolves on callback) ──────────────────────────────

    fun request(logical: String, result: MethodChannel.Result) {
        val concrete = PermissionMapper.concretePermissions(logical, Build.VERSION.SDK_INT)
        if (concrete.isEmpty()) {
            result.success(GRANTED)
            return
        }
        if (concrete.all { isGranted(it) }) {
            // Already granted — no need to prompt.
            result.success(GRANTED)
            return
        }

        val act = activity
        if (act == null) {
            // Backgrounded / no Activity attached: fail gracefully (Dart maps this
            // to denied and re-checks on resume) rather than crashing.
            result.error("NO_ACTIVITY", "Permission request requires a foreground Activity.", null)
            return
        }

        val code = REQUEST_CODES[logical]
        if (code == null) {
            result.error("UNKNOWN_PERMISSION", "Unknown permission key: $logical", null)
            return
        }

        // Concurrency guard: one in-flight request per logical permission.
        if (pending.containsKey(code)) {
            result.error("ALREADY_IN_FLIGHT", "A request for '$logical' is already in progress.", null)
            return
        }

        pending[code] = PendingRequest(result)
        // Persist "has been requested" BEFORE prompting so a subsequent
        // shouldShowRationale==false can be read as permanently-denied rather
        // than never-asked.
        concrete.forEach { markRequested(it) }
        ActivityCompat.requestPermissions(act, concrete.toTypedArray(), code)
    }

    /**
     * OS callback. Returns true when the request code belonged to this manager
     * (so the host can avoid double-dispatching). Completes the stored result
     * exactly once with the aggregated status.
     */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        val req = pending.remove(requestCode) ?: return false
        val status = aggregateAfterResult(permissions, grantResults)
        reply(req) { it.success(status) }
        return true
    }

    /**
     * Host Activity is being destroyed for real (not a configuration change).
     * Resolve any in-flight requests with an error so the Dart futures complete
     * instead of hanging, and drop references to avoid leaks. The Dart side
     * re-checks permission state on resume.
     */
    fun onActivityDestroyed() {
        activity = null
        val inFlight = pending.values.toList()
        pending.clear()
        inFlight.forEach { req ->
            reply(req) { it.error("ACTIVITY_DESTROYED", "Activity destroyed before the permission result.", null) }
        }
    }

    // ── open app settings (don't-ask-again recovery path) ────────────────────

    /**
     * Launches THIS app's details settings page — the only recovery path once a
     * permission is permanently denied (the OS won't re-show its dialog).
     *
     * Returns whether the screen was launched; it does NOT report or await the
     * user's choice. The resulting permission change is observed by the Dart
     * resume re-check (Screen 4A), not by polling here.
     *
     * Launch failures (no Activity, unresolvable intent, any exception) return
     * false without crashing — the Dart layer owns the user-facing fallback.
     * Safe to call repeatedly (Dart debounces; this just launches the intent).
     */
    fun openAppSettings(): Boolean {
        // Prefer launching from the foreground Activity. Backgrounded (no
        // Activity) → false; Dart re-checks on resume / shows its fallback.
        val act = activity ?: return false
        return try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", appContext.packageName, null)
            }
            // No resolveActivity() pre-check: on API 30+ package-visibility can
            // make it return null even when launchable. Attempt + catch instead.
            act.startActivity(intent)
            true
        } catch (_: Exception) {
            // ActivityNotFoundException (unresolvable) or any other failure.
            false
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private fun isGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(appContext, permission) == PackageManager.PERMISSION_GRANTED

    /** Status for a not-fully-granted set WITHOUT prompting. */
    private fun aggregateUnprompted(concrete: List<String>): String {
        val act = activity
        var worst = GRANTED
        for (p in concrete) {
            if (isGranted(p)) continue
            val state = when {
                // With an Activity we can read the rationale flag: requested-before
                // AND no-rationale ⇒ "don't ask again" (permanently denied).
                act != null && wasRequested(p) &&
                    !ActivityCompat.shouldShowRequestPermissionRationale(act, p) -> PERMANENTLY_DENIED
                // No Activity to consult: fall back on the persisted flag alone.
                act == null && wasRequested(p) -> PERMANENTLY_DENIED
                else -> DENIED // never-asked, or re-promptable denial
            }
            worst = worse(worst, state)
        }
        return worst
    }

    /** Aggregate the OS grant results of a single request into one status. */
    private fun aggregateAfterResult(permissions: Array<out String>, grantResults: IntArray): String {
        if (permissions.isEmpty() || grantResults.isEmpty()) {
            // Request was cancelled / interrupted: treat as a (re-promptable) denial.
            return DENIED
        }
        val act = activity
        var worst = GRANTED
        for (i in permissions.indices) {
            val granted = i < grantResults.size && grantResults[i] == PackageManager.PERMISSION_GRANTED
            if (granted) continue
            val p = permissions[i]
            // requested-before is guaranteed true here (we marked it before the
            // request), so no-rationale now means "don't ask again".
            val state = if (act != null && !ActivityCompat.shouldShowRequestPermissionRationale(act, p)) {
                PERMANENTLY_DENIED
            } else {
                DENIED
            }
            worst = worse(worst, state)
        }
        return worst
    }

    private fun worse(a: String, b: String): String =
        if ((RANK[b] ?: 0) >= (RANK[a] ?: 0)) b else a

    private fun reply(req: PendingRequest, block: (MethodChannel.Result) -> Unit) {
        if (req.replied) return
        req.replied = true
        try {
            block(req.result)
        } catch (_: Exception) {
            // Channel/engine already gone (e.g. teardown). Nothing to deliver to.
        }
    }

    private fun keyFor(permission: String) = KEY_REQUESTED_PREFIX + permission
    private fun wasRequested(permission: String) = prefs.getBoolean(keyFor(permission), false)
    private fun markRequested(permission: String) =
        prefs.edit().putBoolean(keyFor(permission), true).apply()
}
