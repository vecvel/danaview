@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import androidx.media3.common.OverlaySettings
import androidx.media3.common.VideoCompositorSettings
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.StaticOverlaySettings
import java.util.concurrent.ConcurrentLinkedQueue

data class OverlayCall(val inputId: Int, val ptsUs: Long, val alpha: Float)

/**
 * ARCH §13.3 "Compositing": output = canvas render size; input 0 (clock band) is never visible;
 * a visual sequence is shown (alphaScale 1) only when one of its layers covers
 * timeOfFrame(frameIndexNearest(pts)), because Media3 renders sequence gaps as opaque black.
 * Inputs above [visualSequences] (background solid) are always shown.
 */
class LayerGatingCompositorSettings(
    private val canvasW: Int,
    private val canvasH: Int,
    private val outputFps: Int,
    private val visualSequences: Int,
    private val store: ParamStore,
    private val recorder: ConcurrentLinkedQueue<OverlayCall>? = null,
) : VideoCompositorSettings {
    override fun getOutputSize(inputSizes: List<Size>): Size = Size(canvasW, canvasH)

    override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings {
        val visible = when {
            inputId == 0 -> false
            inputId <= visualSequences -> store.activeAt(inputId, presentationTimeUs, outputFps) != null
            else -> true
        }
        recorder?.add(OverlayCall(inputId, presentationTimeUs, if (visible) 1f else 0f))
        return if (visible) SHOWN else HIDDEN
    }

    companion object {
        private val SHOWN: OverlaySettings = StaticOverlaySettings.Builder().build()
        private val HIDDEN: OverlaySettings = StaticOverlaySettings.Builder().setAlphaScale(0f).build()
    }
}
