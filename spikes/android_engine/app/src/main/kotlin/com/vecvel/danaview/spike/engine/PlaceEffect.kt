@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger

/** One drawFrame call seen by an effect (V-N2, V-N3, V-N17). */
data class EffectCall(val seq: Int, val ptsUs: Long, val active: Boolean, val wallNs: Long)

/** Thread-safe sink for effect calls. */
class EffectRecorder {
    val calls = ConcurrentLinkedQueue<EffectCall>()
    val drawCount = AtomicInteger()
    fun record(c: EffectCall) {
        calls.add(c)
        drawCount.incrementAndGet()
    }
    fun clear() {
        calls.clear()
        drawCount.set(0)
    }
    fun of(seq: Int) = calls.filter { it.seq == seq }
}

/** Shared GLSL for the place pass (spike version of `dv_place.glsl`, ARCH §11.6 reduced). */
object PlaceShaders {
    const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vPos;
void main() {
  gl_Position = aFramePosition;
  vPos = (aFramePosition.xy + 1.0) * 0.5;
}
"""

    // Output is canvas-size, straight alpha (ARCH §13.3 "Compositing"). uRect is in canvas-normalized
    // coordinates with y measured from the top. Input textures follow Media3's convention (texture
    // y = 0 is the bottom of the image) unless uFlipY = 1 (bitmaps uploaded with GLUtils).
    const val FRAGMENT = """
precision highp float;
uniform sampler2D uTex;
uniform vec4 uRect;
uniform vec3 uTint;
uniform float uAlpha;
uniform vec4 uSolid;
uniform float uUseSolid;
uniform float uFlipY;
varying vec2 vPos;
void main() {
  vec2 c = vec2(vPos.x, 1.0 - vPos.y);
  vec2 uv = (c - uRect.xy) / uRect.zw;
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x >= 1.0 || uv.y >= 1.0) {
    gl_FragColor = vec4(0.0);
    return;
  }
  if (uUseSolid > 0.5) {
    gl_FragColor = uSolid;
    return;
  }
  vec2 st = uFlipY > 0.5 ? uv : vec2(uv.x, 1.0 - uv.y);
  vec4 s = texture2D(uTex, st);
  gl_FragColor = vec4(clamp(s.rgb * uTint, 0.0, 1.0), uAlpha);
}
"""

    fun create(): GlProgram = GlProgram(VERTEX, FRAGMENT).also {
        it.setBufferAttribute(
            "aFramePosition",
            GlUtil.getNormalizedCoordinateBounds(),
            GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
        )
    }

    /** Draws [p] (straight alpha) into the focused framebuffer of [canvasW]x[canvasH]. */
    fun draw(program: GlProgram, texId: Int, p: LayerParams, canvasW: Int, canvasH: Int, flipY: Boolean) {
        program.use()
        program.setSamplerTexIdUniform("uTex", texId, 0)
        program.setFloatsUniform(
            "uRect",
            floatArrayOf(p.rect[0] / canvasW, p.rect[1] / canvasH, p.rect[2] / canvasW, p.rect[3] / canvasH),
        )
        program.setFloatsUniform("uTint", p.tint)
        program.setFloatUniform("uAlpha", p.alpha)
        program.setFloatsUniform("uSolid", p.solid ?: floatArrayOf(0f, 0f, 0f, 0f))
        program.setFloatUniform("uUseSolid", if (p.solid != null) 1f else 0f)
        program.setFloatUniform("uFlipY", if (flipY) 1f else 0f)
        program.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GlUtil.checkGlError()
    }
}

/**
 * Last effect of a visual sequence (spike `LayerPlaceEffect`): outputs a canvas-size straight-alpha
 * texture with the active layer placed in its rect, or transparent with an early exit when no layer
 * of the sequence covers the frame (ARCH §13.3 "Early exit"). Parameters are read at draw time from
 * [store], so a param edit is a reference swap.
 */
class PlaceEffect(
    val seq: Int,
    private val store: ParamStore,
    private val canvasW: Int,
    private val canvasH: Int,
    private val outputFps: Int,
    private val recorder: EffectRecorder?,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        PlaceShaderProgram(this)

    private class PlaceShaderProgram(private val e: PlaceEffect) :
        BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1) {
        private val program = PlaceShaders.create()

        override fun configure(inputWidth: Int, inputHeight: Int): Size = Size(e.canvasW, e.canvasH)

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            val p = e.store.activeAt(e.seq, presentationTimeUs, e.outputFps)
            e.recorder?.record(EffectCall(e.seq, presentationTimeUs, p != null, System.nanoTime()))
            GLES20.glClearColor(0f, 0f, 0f, 0f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            if (p == null) return // early exit: gap or gated frame costs one clear
            PlaceShaders.draw(program, inputTexId, p, e.canvasW, e.canvasH, flipY = false)
        }

        override fun release() {
            super.release()
            program.delete()
        }
    }
}
