@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-08

// Layer gating (ARCH §13.3 "Compositing"): DefaultVideoCompositor only blends (input 0 on top,
// straight alpha, AND-01 V-N1/V-N4); input ids are sequence indices and pts are composition times
// within −1…+500 µs of P(k). Media3 renders sequence gaps opaque, and edge frames of an item can
// belong to its neighbour, so a layer sequence is shown (alphaScale 1) only when one of its layers
// (or layer pieces) covers `timeOfFrame(k)` with `k = frameIndexNearest(pts)` of the OUTPUT rate
// (D-35); the clock band is never shown; the background always is.

package com.vecvel.vwish.editor.engine.composition

import androidx.annotation.OptIn
import androidx.media3.common.OverlaySettings
import androidx.media3.common.VideoCompositorSettings
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.StaticOverlaySettings
import com.vecvel.vwish.editor.engine.plan.FrameGrid

/** The pure gating decision of a [CompositionSpec] (JVM-testable). */
class LayerGating(private val spec: CompositionSpec) {
    private val grid = FrameGrid.of(spec.outputFps)
    private val byIndex: Array<SequenceSpec?> = arrayOfNulls<SequenceSpec>(spec.sequences.size).also { a ->
        for (s in spec.sequences) a[s.index] = s
    }

    /** Whether compositor input [inputId] is shown at composition time [ptsUs]. */
    fun isVisible(inputId: Int, ptsUs: Long): Boolean {
        val s = byIndex.getOrNull(inputId) ?: return true
        return when (s.kind) {
            SequenceKind.CLOCK_BAND -> false
            SequenceKind.LAYERS -> s.activeAt(grid.frameTimeOf(ptsUs)) != null
            SequenceKind.BACKGROUND, SequenceKind.AUDIO -> true
        }
    }

    /** The layer (or piece) of input [inputId] active at [ptsUs], or null. */
    fun activeAt(inputId: Int, ptsUs: Long): ActiveRange? {
        val s = byIndex.getOrNull(inputId) ?: return null
        return if (s.kind == SequenceKind.LAYERS) s.activeAt(grid.frameTimeOf(ptsUs)) else null
    }
}

/** Media3 compositor settings applying [LayerGating]; the output is [outputWidth] × [outputHeight]. */
class LayerGatingCompositorSettings(
    spec: CompositionSpec,
    private val outputWidth: Int = spec.canvasW,
    private val outputHeight: Int = spec.canvasH,
) : VideoCompositorSettings {
    /** The gating decision. */
    val gating = LayerGating(spec)

    override fun getOutputSize(inputSizes: List<Size>): Size = Size(outputWidth, outputHeight)

    override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings =
        if (gating.isVisible(inputId, presentationTimeUs)) SHOWN else HIDDEN

    private companion object {
        val SHOWN: OverlaySettings = StaticOverlaySettings.Builder().build()
        val HIDDEN: OverlaySettings = StaticOverlaySettings.Builder().setAlphaScale(0f).build()
    }
}
