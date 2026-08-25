// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/BlurThresholdPolicy.kt
package com.mayasabhaxr.recapture.camera

/**
 * Three-band classification of a sharpness score (the variance-of-Laplacian from
 * [BlurMetric]) into an actionable band. The policy layer on top of the metric:
 * the blur-detection task computes the score, this turns it into a band the
 * capture flow + UI act on. It does NOT recompute the metric.
 *
 * The two thresholds (defaults 40 / 80) are content- and device-sensitive magic
 * numbers — configurable and intended to be remote-config-tunable without an app
 * release. The WARN band is an intentional buffer that avoids a hard sharp/blurry
 * flip at a single cutoff.
 */
enum class BlurBand {
    /** Too blurry — don't use the frame (discard / "hold steady" hint). */
    REJECT,

    /** Borderline — usable but flagged; the capture flow decides (accept-with-caution / prompt). */
    WARN,

    /** Sharp enough — use the frame. */
    ACCEPT;

    /** Lowercase wire form for the channel payload (`reject`/`warn`/`accept`). */
    val wire: String get() = name.lowercase()
}

/**
 * Holds the active (validated) thresholds and classifies scores against them.
 * Pure (no Android runtime), so it is JVM-unit-testable. Thread-safe for the
 * analyzer: thresholds are `@Volatile`, [update] applies to SUBSEQUENT
 * classifications (past frames are not reclassified).
 */
class BlurThresholdPolicy(
    rejectBelow: Double = DEFAULT_REJECT_BELOW,
    acceptAbove: Double = DEFAULT_ACCEPT_ABOVE,
) {
    companion object {
        const val DEFAULT_REJECT_BELOW = 40.0
        const val DEFAULT_ACCEPT_ABOVE = 80.0

        /**
         * Validates a threshold pair. A non-finite input falls back to the per-field
         * default; an INVERTED pair (`rejectBelow > acceptAbove`) is nonsensical, so
         * it falls back to BOTH defaults. `rejectBelow == acceptAbove` is allowed —
         * the WARN band is then empty (binary reject/accept).
         */
        fun validated(rejectBelow: Double?, acceptAbove: Double?): Pair<Double, Double> {
            val r = rejectBelow?.takeIf { it.isFinite() } ?: DEFAULT_REJECT_BELOW
            val a = acceptAbove?.takeIf { it.isFinite() } ?: DEFAULT_ACCEPT_ABOVE
            return if (r <= a) r to a else DEFAULT_REJECT_BELOW to DEFAULT_ACCEPT_ABOVE
        }
    }

    @Volatile
    var rejectBelow: Double = DEFAULT_REJECT_BELOW
        private set

    @Volatile
    var acceptAbove: Double = DEFAULT_ACCEPT_ABOVE
        private set

    init {
        update(rejectBelow, acceptAbove)
    }

    /** Applies validated thresholds; subsequent [classify] calls use the new values. */
    fun update(rejectBelow: Double?, acceptAbove: Double?) {
        val (r, a) = validated(rejectBelow, acceptAbove)
        this.rejectBelow = r
        this.acceptAbove = a
    }

    /**
     * Classifies a sharpness score. Boundaries (inclusive band ownership):
     * `score < rejectBelow` → REJECT; `score > acceptAbove` → ACCEPT; otherwise
     * WARN — so exactly [rejectBelow] and exactly [acceptAbove] are WARN. A
     * non-finite score (NaN/Inf) fails safe to REJECT — never ACCEPT.
     */
    fun classify(score: Double): BlurBand = when {
        !score.isFinite() -> BlurBand.REJECT
        score < rejectBelow -> BlurBand.REJECT
        score > acceptAbove -> BlurBand.ACCEPT
        else -> BlurBand.WARN
    }
}
