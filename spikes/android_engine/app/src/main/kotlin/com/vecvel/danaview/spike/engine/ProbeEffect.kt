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
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.math.abs
import kotlin.math.max

/**
 * Pattern of the generated media (tool/gen_media.sh): 32x18 cells, rows 0-5 barcode (16 columns:
 * col 0 white, col 15 black, cols 1..14 the 14-bit frame number MSB first), rows 6-11 mid grey,
 * rows 12-17 left green / right blue.
 */
object Barcode {
    sealed interface Reading
    data class Value(val n: Int) : Reading
    data object Background : Reading
    data class Unknown(val samples: List<Int>) : Reading

    fun columnX(rect: FloatArray, c: Int): Int = (rect[0] + rect[2] * (2 * c + 1) / 32f).toInt()
    fun barcodeY(rect: FloatArray): Int = (rect[1] + rect[3] * 3f / 18f).toInt()
    fun greyY(rect: FloatArray): Int = (rect[1] + rect[3] * 9f / 18f).toInt()
    fun markerY(rect: FloatArray): Int = (rect[1] + rect[3] * 15f / 18f).toInt()

    private fun ch(p: Int, s: Int) = ((p shr s) and 0xff) / 255f
    fun r(p: Int) = ch(p, 16)
    fun g(p: Int) = ch(p, 8)
    fun b(p: Int) = ch(p, 0)
    private fun bright(p: Int) = max(r(p), max(g(p), b(p)))

    fun near(p: Int, rgb: FloatArray, tol: Float = 0.08f) =
        abs(r(p) - rgb[0]) <= tol && abs(g(p) - rgb[1]) <= tol && abs(b(p) - rgb[2]) <= tol

    /** Decodes 16 column samples (0xRRGGBB). */
    fun decode(samples: List<Int>, bg: FloatArray): Reading {
        if (samples.all { near(it, bg) }) return Background
        if (bright(samples[0]) < 0.6f || bright(samples[15]) > 0.4f) return Unknown(samples)
        var n = 0
        for (c in 1..14) n = (n shl 1) or (if (bright(samples[c]) > 0.5f) 1 else 0)
        return Value(n)
    }
}

/** A canvas region probed on every composited frame. */
data class ProbeRegion(val name: String, val rect: FloatArray)

data class RegionReading(val reading: Barcode.Reading, val grey: Int, val markerLeft: Int, val markerRight: Int)

data class ProbeFrame(
    val ptsUs: Long,
    val wallNs: Long,
    val regions: Map<String, RegionReading>,
    /** Full RGBA frame (row 0 = top), only for frames selected by [ProbeEffect.captureFull]. */
    val full: ByteArray? = null,
)

/**
 * Composition-level effect (Composition.Builder.setEffects) that passes the composited frame
 * through and reads a few pixel rows back to decode the barcodes of each region. Runs in both
 * CompositionPlayer and Transformer, so playback, seeks and export are checked on one code path.
 */
class ProbeEffect(
    private val canvasW: Int,
    private val canvasH: Int,
    private val bg: FloatArray,
    @Volatile var regions: List<ProbeRegion>,
) : GlEffect {
    val frames = ConcurrentLinkedQueue<ProbeFrame>()
    @Volatile var enabled = true
    @Volatile var captureFull: (Long) -> Boolean = { false }

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram = ProbeProgram(this)

    fun clear() = frames.clear()

    private class ProbeProgram(private val e: ProbeEffect) :
        BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1) {
        private val program = GlProgram(COPY_VERTEX, COPY_FRAGMENT).also {
            it.setBufferAttribute(
                "aFramePosition",
                GlUtil.getNormalizedCoordinateBounds(),
                GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
            )
        }
        private val row: ByteBuffer = ByteBuffer.allocateDirect(e.canvasW * 4).order(ByteOrder.nativeOrder())

        override fun configure(inputWidth: Int, inputHeight: Int): Size = Size(inputWidth, inputHeight)

        override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
            program.use()
            program.setSamplerTexIdUniform("uTex", inputTexId, 0)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            if (!e.enabled) return
            val readings = HashMap<String, RegionReading>()
            for (r in e.regions) {
                val cols = readRow(Barcode.barcodeY(r.rect))
                val samples = (0 until 16).map { cols(Barcode.columnX(r.rect, it)) }
                val greyRow = readRow(Barcode.greyY(r.rect))
                val grey = greyRow((r.rect[0] + r.rect[2] / 2).toInt())
                val markerRow = readRow(Barcode.markerY(r.rect))
                readings[r.name] = RegionReading(
                    Barcode.decode(samples, e.bg),
                    grey,
                    markerRow((r.rect[0] + r.rect[2] * 0.25f).toInt()),
                    markerRow((r.rect[0] + r.rect[2] * 0.75f).toInt()),
                )
            }
            val full = if (e.captureFull(presentationTimeUs)) readFull() else null
            e.frames.add(ProbeFrame(presentationTimeUs, System.nanoTime(), readings, full))
        }

        /** Reads canvas row [y] (y down); returns a lookup x -> 0xRRGGBB. */
        private fun readRow(y: Int): (Int) -> Int {
            val glY = (e.canvasH - 1 - y).coerceIn(0, e.canvasH - 1)
            row.clear()
            GLES20.glReadPixels(0, glY, e.canvasW, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, row)
            val copy = ByteArray(e.canvasW * 4)
            row.get(copy)
            return { x ->
                val i = x.coerceIn(0, e.canvasW - 1) * 4
                ((copy[i].toInt() and 0xff) shl 16) or ((copy[i + 1].toInt() and 0xff) shl 8) or (copy[i + 2].toInt() and 0xff)
            }
        }

        private fun readFull(): ByteArray {
            val buf = ByteBuffer.allocateDirect(e.canvasW * e.canvasH * 4).order(ByteOrder.nativeOrder())
            GLES20.glReadPixels(0, 0, e.canvasW, e.canvasH, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
            val out = ByteArray(e.canvasW * e.canvasH * 4)
            val stride = e.canvasW * 4
            for (y in 0 until e.canvasH) { // flip to row 0 = top
                buf.position((e.canvasH - 1 - y) * stride)
                buf.get(out, y * stride, stride)
            }
            return out
        }

        override fun release() {
            super.release()
            program.delete()
        }
    }

    companion object {
        const val COPY_VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTex;
void main() {
  gl_Position = aFramePosition;
  vTex = (aFramePosition.xy + 1.0) * 0.5;
}
"""
        const val COPY_FRAGMENT = """
precision mediump float;
uniform sampler2D uTex;
varying vec2 vTex;
void main() { gl_FragColor = texture2D(uTex, vTex); }
"""
    }
}
