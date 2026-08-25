// android/app/src/main/kotlin/com/mayasabhaxr/recapture/camera/CaptureResolutionPolicy.kt
package com.mayasabhaxr.recapture.camera

import android.util.Size
import android.view.Surface
import androidx.camera.core.AspectRatio
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionFilter
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy

/**
 * Configurable, device-adaptive **resolution + JPEG-quality policy** for the
 * still-capture [androidx.camera.core.ImageCapture] use case.
 *
 * Why this exists: photogrammetry/3D reconstruction needs **known, uniform** input
 * dimensions, but CameraX otherwise picks a per-device default size. This policy
 * expresses the *intent* (a target size or long-edge + an aspect ratio that must
 * match preview/analysis) and turns it into a CameraX [ResolutionSelector] that
 * maps deterministically onto whatever the device actually supports.
 *
 * Bind-time only: a [ResolutionSelector] is consumed when the use case is bound, so
 * a policy change takes effect on the **next bind** (the preview/session task owns
 * the rebind) — never mid-session. Because the selector is fixed for the life of a
 * bound session, every frame in that session shares the same resolution + quality.
 *
 * The exact target is treated as intent, not a guarantee: the [fallbackRule] maps
 * it to the closest supported size **deterministically** (same device → same
 * choice) and clamps to the device's min/max. The caller learns the ACTUAL chosen
 * size — and whether it differed — via [CameraCaptureManager.getActiveCaptureResolution].
 *
 * This class is sizing/encoding policy only: it does not trigger captures, manage
 * permissions, or own the session lifecycle.
 */
data class CaptureResolutionPolicy(
    /** Aspect ratio; MUST match preview/analysis so FOV/crop is consistent. */
    val aspectRatio: CaptureAspectRatio,
    /** How an unsupported target maps to a supported size. */
    val fallbackRule: FallbackRule,
    /** JPEG encode quality, 1..100, constant for the whole session. */
    val jpegQuality: Int,
    /** Exact target (sensor-natural / landscape orientation), or null. */
    val targetSize: Dimensions?,
    /** Target long edge in px (used when [targetSize] is null), or null. */
    val targetLongEdge: Int?,
) {

    /**
     * The concrete bound size this policy resolves to (sensor-natural landscape:
     * width ≥ height), derived from [targetSize] or [targetLongEdge] + [aspectRatio].
     * This is the size handed to CameraX's [ResolutionStrategy] and the reference
     * for the `fellBack` comparison.
     */
    val resolvedTargetSize: Dimensions = run {
        targetSize ?: Dimensions.fromLongEdge(targetLongEdge ?: DEFAULT_LONG_EDGE, aspectRatio)
    }

    /** Builds the bind-time [ResolutionSelector] (aspect + strategy + filter). */
    fun buildResolutionSelector(): ResolutionSelector {
        val bound = Size(resolvedTargetSize.width, resolvedTargetSize.height)
        return ResolutionSelector.Builder()
            .setAspectRatioStrategy(aspectRatio.toStrategy())
            .setResolutionStrategy(ResolutionStrategy(bound, fallbackRule.cameraXRule))
            // Finer, deterministic ordering: prefer the size whose long edge is
            // closest to the intended long edge (stable tie-breaks). The strategy
            // above still clamps to supported sizes; this only orders the candidates.
            .setResolutionFilter(longEdgeFilter(resolvedTargetSize.longEdge))
            .build()
    }

    /** EXIF target rotation — fixed so orientation is consistent across frames. */
    val targetRotation: Int = Surface.ROTATION_0

    /** Did CameraX's actual output diverge from the resolved target? */
    fun fellBack(actual: Dimensions): Boolean = actual != resolvedTargetSize

    companion object {
        const val JPEG_QUALITY_MIN = 1
        const val JPEG_QUALITY_MAX = 100
        const val DEFAULT_JPEG_QUALITY = 90
        const val DEFAULT_LONG_EDGE = 3000

        /** Sensible device-adaptive default when nothing is configured. */
        val DEFAULT = CaptureResolutionPolicy(
            aspectRatio = CaptureAspectRatio.RATIO_4_3,
            fallbackRule = FallbackRule.CLOSEST_HIGHER_THEN_LOWER,
            jpegQuality = DEFAULT_JPEG_QUALITY,
            targetSize = null,
            targetLongEdge = DEFAULT_LONG_EDGE,
        )

        /**
         * Parses + validates a policy map from Flutter. Returns [Result.success]
         * with a fully-resolved policy, or [Result.failure] with a human-readable
         * message for clearly-invalid input (the channel maps this to INVALID_ARGS).
         * Omitted optional fields fall back to [DEFAULT]; quality is clamped, not
         * rejected, so a slightly-out-of-range value still fails safe.
         */
        fun fromMap(map: Map<String, Any?>?): Result<CaptureResolutionPolicy> {
            if (map == null) return Result.success(DEFAULT)

            val aspect = when (val raw = (map["aspectRatio"] as? String)?.lowercase()) {
                null -> DEFAULT.aspectRatio
                else -> CaptureAspectRatio.fromString(raw)
                    ?: return Result.failure(IllegalArgumentException("Unsupported aspectRatio: $raw"))
            }

            val rule = when (val raw = (map["fallbackRule"] as? String)?.lowercase()) {
                null -> DEFAULT.fallbackRule
                else -> FallbackRule.fromString(raw)
                    ?: return Result.failure(IllegalArgumentException("Unsupported fallbackRule: $raw"))
            }

            // Clamp quality (fail safe) rather than reject.
            val quality = ((map["jpegQuality"] as? Number)?.toInt() ?: DEFAULT.jpegQuality)
                .coerceIn(JPEG_QUALITY_MIN, JPEG_QUALITY_MAX)

            val w = (map["targetWidth"] as? Number)?.toInt()
            val h = (map["targetHeight"] as? Number)?.toInt()
            val longEdge = (map["targetLongEdge"] as? Number)?.toInt()

            // Exact size: both dimensions must be present and positive.
            val targetSize: Dimensions?
            when {
                w != null || h != null -> {
                    if (w == null || h == null) {
                        return Result.failure(
                            IllegalArgumentException("targetWidth and targetHeight must be supplied together"),
                        )
                    }
                    if (w <= 0 || h <= 0) {
                        return Result.failure(IllegalArgumentException("Target dimensions must be positive"))
                    }
                    targetSize = Dimensions.landscape(w, h)
                }
                else -> targetSize = null
            }

            if (targetSize == null && longEdge != null && longEdge <= 0) {
                return Result.failure(IllegalArgumentException("targetLongEdge must be positive"))
            }

            // No explicit target at all → fall back to the default long edge.
            val resolvedLongEdge = when {
                targetSize != null -> null
                longEdge != null -> longEdge
                else -> DEFAULT_LONG_EDGE
            }

            return Result.success(
                CaptureResolutionPolicy(
                    aspectRatio = aspect,
                    fallbackRule = rule,
                    jpegQuality = quality,
                    targetSize = targetSize,
                    targetLongEdge = resolvedLongEdge,
                ),
            )
        }

        /**
         * A [ResolutionFilter] that orders the (already aspect-filtered) supported
         * sizes by [ResolutionMath.orderByLongEdge] so the long-edge intent is
         * honoured predictably across devices. Pure ordering lives in
         * [ResolutionMath]; this only bridges [Size] ↔ [Dimensions].
         */
        private fun longEdgeFilter(targetLongEdge: Int): ResolutionFilter =
            ResolutionFilter { supported, _ ->
                val ordered = ResolutionMath.orderByLongEdge(
                    supported.map { Dimensions(it.width, it.height) },
                    targetLongEdge,
                )
                ordered.map { Size(it.width, it.height) }.toMutableList()
            }
    }
}

/** Aspect ratios the pipeline supports; MUST mirror preview/analysis. */
enum class CaptureAspectRatio(val widthUnits: Int, val heightUnits: Int) {
    RATIO_4_3(4, 3),
    RATIO_16_9(16, 9),
    ;

    /** Width:height as a float in landscape orientation (≥ 1). */
    val ratio: Float get() = widthUnits.toFloat() / heightUnits.toFloat()

    /** The CameraX [AspectRatio] constant for preview parity. */
    fun toCameraX(): Int = when (this) {
        RATIO_4_3 -> AspectRatio.RATIO_4_3
        RATIO_16_9 -> AspectRatio.RATIO_16_9
    }

    /** AUTO fallback so a device lacking the exact ratio still binds. */
    fun toStrategy(): AspectRatioStrategy = AspectRatioStrategy(toCameraX(), AspectRatioStrategy.FALLBACK_RULE_AUTO)

    companion object {
        fun fromString(raw: String): CaptureAspectRatio? = when (raw.replace(" ", "")) {
            "4:3", "4_3", "ratio_4_3" -> RATIO_4_3
            "16:9", "16_9", "ratio_16_9" -> RATIO_16_9
            else -> null
        }
    }
}

/** Maps the policy's fallback intent onto a CameraX [ResolutionStrategy] rule. */
enum class FallbackRule(val cameraXRule: Int) {
    /** Exact only; bind fails if the exact size is unsupported. */
    NONE(ResolutionStrategy.FALLBACK_RULE_NONE),
    CLOSEST_HIGHER_THEN_LOWER(ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
    CLOSEST_LOWER(ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER),
    ;

    companion object {
        fun fromString(raw: String): FallbackRule? = when (raw.replace("-", "_")) {
            "none", "exact" -> NONE
            "closest_higher_then_lower" -> CLOSEST_HIGHER_THEN_LOWER
            "closest_lower" -> CLOSEST_LOWER
            else -> null
        }
    }
}

/**
 * Plain width/height pair — deliberately framework-free (no [Size]) so the
 * deterministic selection logic in [ResolutionMath] is unit-testable on the JVM.
 */
data class Dimensions(val width: Int, val height: Int) {
    val longEdge: Int get() = maxOf(width, height)
    val shortEdge: Int get() = minOf(width, height)
    val area: Long get() = width.toLong() * height.toLong()

    companion object {
        /** Normalises to landscape (width ≥ height), the sensor-natural convention. */
        fun landscape(a: Int, b: Int): Dimensions = Dimensions(maxOf(a, b), minOf(a, b))

        /** Derives a landscape size from a long edge + aspect ratio (rounded). */
        fun fromLongEdge(longEdge: Int, aspect: CaptureAspectRatio): Dimensions {
            val w = longEdge
            val h = Math.round(longEdge / aspect.ratio)
            return Dimensions(w, h)
        }
    }
}

/**
 * Pure, deterministic long-edge ordering used by the policy's [ResolutionFilter]
 * (no Android framework deps so it is unit-testable). The on-device closest-size
 * mapping is delegated to CameraX's [ResolutionStrategy] (built from the policy);
 * this filter then orders the surviving candidates so the **long-edge intent** is
 * honoured predictably, with the first element being the chosen output.
 *
 * "Deterministic" here means: given the same candidate list and target, the order
 * is total and stable — same device → same result, regardless of input order.
 */
object ResolutionMath {

    /**
     * Orders [candidates] by closeness of their long edge to [targetLongEdge].
     * Ties (equal distance) break toward the larger long edge, then larger area,
     * then larger width, then larger height — a total order, so the result is fully
     * deterministic regardless of the input order.
     */
    fun orderByLongEdge(candidates: List<Dimensions>, targetLongEdge: Int): List<Dimensions> =
        candidates.sortedWith(
            compareBy<Dimensions> { kotlin.math.abs(it.longEdge - targetLongEdge) }
                .thenByDescending { it.longEdge }
                .thenByDescending { it.area }
                .thenByDescending { it.width }
                .thenByDescending { it.height },
        )
}
