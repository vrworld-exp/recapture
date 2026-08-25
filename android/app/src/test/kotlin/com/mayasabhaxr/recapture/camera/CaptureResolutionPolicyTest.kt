// android/app/src/test/kotlin/com/mayasabhaxr/recapture/camera/CaptureResolutionPolicyTest.kt
package com.mayasabhaxr.recapture.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM unit tests for the resolution-policy logic: deterministic
 * closest-supported selection ([ResolutionMath]), long-edge ordering, the
 * [Dimensions] helpers, and [CaptureResolutionPolicy.fromMap] validation/defaults.
 *
 * No device / Robolectric: the selection math and parsing are framework-free (the
 * only Android references are compile-time-inlined `static final` constants), so
 * this exercises the exact logic that drives the on-device CameraX bind.
 */
class CaptureResolutionPolicyTest {

    // ── Dimensions ──────────────────────────────────────────────────────────────

    @Test
    fun dimensions_landscapeNormalisesToWidthGteHeight() {
        assertEquals(Dimensions(4000, 3000), Dimensions.landscape(3000, 4000))
        assertEquals(Dimensions(4000, 3000), Dimensions.landscape(4000, 3000))
    }

    @Test
    fun dimensions_fromLongEdgeDerivesAspect() {
        assertEquals(Dimensions(3000, 2250), Dimensions.fromLongEdge(3000, CaptureAspectRatio.RATIO_4_3))
        // 3000 / (16/9) = 1687.5 → rounds to 1688.
        assertEquals(Dimensions(3000, 1688), Dimensions.fromLongEdge(3000, CaptureAspectRatio.RATIO_16_9))
    }

    // ── ResolutionMath.orderByLongEdge ───────────────────────────────────────────

    private val supported = listOf(
        Dimensions(640, 480),
        Dimensions(1280, 960),
        Dimensions(2048, 1536),
        Dimensions(4032, 3024),
    )

    @Test
    fun orderByLongEdge_putsClosestLongEdgeFirst() {
        val ordered = ResolutionMath.orderByLongEdge(supported, 2000)
        assertEquals(Dimensions(2048, 1536), ordered.first())
    }

    @Test
    fun orderByLongEdge_isStableAcrossInputPermutations() {
        val target = 2500
        val a = ResolutionMath.orderByLongEdge(supported, target)
        val b = ResolutionMath.orderByLongEdge(supported.reversed(), target)
        val c = ResolutionMath.orderByLongEdge(supported.shuffled(), target)
        assertEquals(a, b)
        assertEquals(a, c)
    }

    @Test
    fun orderByLongEdge_tieBreaksTowardLargerLongEdge() {
        // Two candidates equidistant (1000 below / 1000 above 2000) → larger first.
        val candidates = listOf(Dimensions(1000, 750), Dimensions(3000, 2250))
        val ordered = ResolutionMath.orderByLongEdge(candidates, 2000)
        assertEquals(Dimensions(3000, 2250), ordered.first())
    }

    // ── CaptureResolutionPolicy.fromMap ──────────────────────────────────────────

    @Test
    fun fromMap_nullYieldsDefault() {
        val p = CaptureResolutionPolicy.fromMap(null).getOrThrow()
        assertEquals(CaptureResolutionPolicy.DEFAULT, p)
    }

    @Test
    fun fromMap_emptyMapYieldsDefaults() {
        val p = CaptureResolutionPolicy.fromMap(emptyMap()).getOrThrow()
        assertEquals(CaptureAspectRatio.RATIO_4_3, p.aspectRatio)
        assertEquals(FallbackRule.CLOSEST_HIGHER_THEN_LOWER, p.fallbackRule)
        assertEquals(CaptureResolutionPolicy.DEFAULT_JPEG_QUALITY, p.jpegQuality)
        assertEquals(CaptureResolutionPolicy.DEFAULT_LONG_EDGE, p.targetLongEdge)
    }

    @Test
    fun fromMap_parsesLongEdgePolicy() {
        val p = CaptureResolutionPolicy.fromMap(
            mapOf(
                "targetLongEdge" to 3000,
                "aspectRatio" to "4:3",
                "fallbackRule" to "closest-higher-then-lower",
                "jpegQuality" to 90,
            ),
        ).getOrThrow()
        assertEquals(3000, p.targetLongEdge)
        assertNull(p.targetSize)
        assertEquals(Dimensions(3000, 2250), p.resolvedTargetSize)
        assertEquals(90, p.jpegQuality)
    }

    @Test
    fun fromMap_parsesExactSizePolicy() {
        val p = CaptureResolutionPolicy.fromMap(
            mapOf("targetWidth" to 4000, "targetHeight" to 3000, "aspectRatio" to "4:3"),
        ).getOrThrow()
        assertEquals(Dimensions(4000, 3000), p.targetSize)
        assertNull(p.targetLongEdge)
        assertEquals(Dimensions(4000, 3000), p.resolvedTargetSize)
    }

    @Test
    fun fromMap_exactSizeNormalisesToLandscape() {
        val p = CaptureResolutionPolicy.fromMap(
            mapOf("targetWidth" to 3000, "targetHeight" to 4000),
        ).getOrThrow()
        assertEquals(Dimensions(4000, 3000), p.targetSize)
    }

    @Test
    fun fromMap_clampsJpegQuality() {
        assertEquals(100, CaptureResolutionPolicy.fromMap(mapOf("jpegQuality" to 200)).getOrThrow().jpegQuality)
        assertEquals(1, CaptureResolutionPolicy.fromMap(mapOf("jpegQuality" to 0)).getOrThrow().jpegQuality)
        assertEquals(1, CaptureResolutionPolicy.fromMap(mapOf("jpegQuality" to -5)).getOrThrow().jpegQuality)
    }

    @Test
    fun fromMap_parsesAspectRatioVariants() {
        assertEquals(
            CaptureAspectRatio.RATIO_16_9,
            CaptureResolutionPolicy.fromMap(mapOf("aspectRatio" to "16:9")).getOrThrow().aspectRatio,
        )
        assertEquals(
            CaptureAspectRatio.RATIO_16_9,
            CaptureResolutionPolicy.fromMap(mapOf("aspectRatio" to "16_9")).getOrThrow().aspectRatio,
        )
    }

    @Test
    fun fromMap_parsesFallbackVariants() {
        assertEquals(
            FallbackRule.NONE,
            CaptureResolutionPolicy.fromMap(mapOf("fallbackRule" to "exact")).getOrThrow().fallbackRule,
        )
        assertEquals(
            FallbackRule.CLOSEST_LOWER,
            CaptureResolutionPolicy.fromMap(mapOf("fallbackRule" to "closest-lower")).getOrThrow().fallbackRule,
        )
    }

    @Test
    fun fromMap_rejectsUnknownAspect() {
        assertTrue(CaptureResolutionPolicy.fromMap(mapOf("aspectRatio" to "1:1")).isFailure)
    }

    @Test
    fun fromMap_rejectsUnknownFallback() {
        assertTrue(CaptureResolutionPolicy.fromMap(mapOf("fallbackRule" to "magic")).isFailure)
    }

    @Test
    fun fromMap_rejectsPartialExactSize() {
        assertTrue(CaptureResolutionPolicy.fromMap(mapOf("targetWidth" to 4000)).isFailure)
        assertTrue(CaptureResolutionPolicy.fromMap(mapOf("targetHeight" to 3000)).isFailure)
    }

    @Test
    fun fromMap_rejectsNonPositiveDimensions() {
        assertTrue(CaptureResolutionPolicy.fromMap(mapOf("targetWidth" to 0, "targetHeight" to 3000)).isFailure)
        assertTrue(CaptureResolutionPolicy.fromMap(mapOf("targetWidth" to 4000, "targetHeight" to -1)).isFailure)
    }

    @Test
    fun fromMap_rejectsNonPositiveLongEdge() {
        assertTrue(CaptureResolutionPolicy.fromMap(mapOf("targetLongEdge" to 0)).isFailure)
        assertTrue(CaptureResolutionPolicy.fromMap(mapOf("targetLongEdge" to -100)).isFailure)
    }

    // ── fellBack reporting ───────────────────────────────────────────────────────

    @Test
    fun fellBack_falseWhenActualMatchesTarget() {
        val p = CaptureResolutionPolicy.fromMap(mapOf("targetWidth" to 4000, "targetHeight" to 3000)).getOrThrow()
        assertFalse(p.fellBack(Dimensions(4000, 3000)))
    }

    @Test
    fun fellBack_trueWhenActualDiverges() {
        val p = CaptureResolutionPolicy.fromMap(mapOf("targetWidth" to 4000, "targetHeight" to 3000)).getOrThrow()
        assertTrue(p.fellBack(Dimensions(4032, 3024)))
    }

    @Test
    fun defaultPolicy_resolvesToSaneTarget() {
        val p = CaptureResolutionPolicy.DEFAULT
        assertNotNull(p.resolvedTargetSize)
        assertEquals(CaptureResolutionPolicy.DEFAULT_LONG_EDGE, p.resolvedTargetSize.longEdge)
    }
}
