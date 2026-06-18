// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/ExposureThresholdPolicy.kt
package com.mayasabhaxr.recapture.camera

/**
 * Three-band classification of a mean luminance ([ExposureMetric]) into an
 * actionable band: too dark, ok, or too bright. The policy layer on top of the
 * metric — the exposure check computes the mean, this turns it into a band the
 * capture UI surfaces as a "too dark"/"too bright" hint. It does NOT recompute the
 * metric, and BOTH extremes are WARN states (the spec gates/rejects nothing on
 * exposure).
 *
 * The two thresholds (defaults 40 / 220 on the 0–255 luma scale) are configurable
 * and intended to be remote-config-tunable without an app release.
 */
enum class ExposureBand {
    /** Too dark — warn ("too dark", increase light / exposure). */
    DARK,

    /** Well exposed — good. */
    OK,

    /** Too bright — warn ("too bright", reduce light / exposure). */
    BRIGHT;

    /** Lowercase wire form for the channel payload (`dark`/`ok`/`bright`). */
    val wire: String get() = name.lowercase()
}

/**
 * Holds the active (validated) thresholds and classifies a mean luminance against
 * them. Pure (no Android runtime), so it is JVM-unit-testable. Thread-safe for the
 * analyzer: thresholds are `@Volatile`, [update] applies to SUBSEQUENT
 * classifications (past frames are not reclassified).
 */
class ExposureThresholdPolicy(
    darkBelow: Double = DEFAULT_DARK_BELOW,
    brightAbove: Double = DEFAULT_BRIGHT_ABOVE,
) {
    companion object {
        const val DEFAULT_DARK_BELOW = 40.0
        const val DEFAULT_BRIGHT_ABOVE = 220.0

        /** Wire form for a frame whose mean luminance could not be determined. */
        const val WIRE_UNKNOWN = "unknown"

        /**
         * Validates a threshold pair. A non-finite input falls back to the per-field
         * default; a non-separated pair (`darkBelow >= brightAbove`, which would leave
         * no OK band or invert the bands) is nonsensical, so it falls back to BOTH
         * defaults. Unlike the blur policy, equality is NOT allowed — the dark/bright
         * bands must be strictly separated by a non-empty OK band.
         */
        fun validated(darkBelow: Double?, brightAbove: Double?): Pair<Double, Double> {
            val d = darkBelow?.takeIf { it.isFinite() } ?: DEFAULT_DARK_BELOW
            val b = brightAbove?.takeIf { it.isFinite() } ?: DEFAULT_BRIGHT_ABOVE
            return if (d < b) d to b else DEFAULT_DARK_BELOW to DEFAULT_BRIGHT_ABOVE
        }
    }

    @Volatile
    var darkBelow: Double = DEFAULT_DARK_BELOW
        private set

    @Volatile
    var brightAbove: Double = DEFAULT_BRIGHT_ABOVE
        private set

    init {
        update(darkBelow, brightAbove)
    }

    /** Applies validated thresholds; subsequent [classify] calls use the new values. */
    fun update(darkBelow: Double?, brightAbove: Double?) {
        val (d, b) = validated(darkBelow, brightAbove)
        this.darkBelow = d
        this.brightAbove = b
    }

    /**
     * Classifies a mean luminance. Boundaries (per spec, OK owns both edges):
     * `mean < darkBelow` → DARK; `mean > brightAbove` → BRIGHT; otherwise OK — so
     * exactly [darkBelow] (40) and exactly [brightAbove] (220) are OK. A non-finite
     * mean (NaN — e.g. an empty frame) returns `null`: the caller emits an explicit
     * "unknown" rather than silently classifying it OK.
     */
    fun classify(mean: Double): ExposureBand? = when {
        !mean.isFinite() -> null
        mean < darkBelow -> ExposureBand.DARK
        mean > brightAbove -> ExposureBand.BRIGHT
        else -> ExposureBand.OK
    }
}
