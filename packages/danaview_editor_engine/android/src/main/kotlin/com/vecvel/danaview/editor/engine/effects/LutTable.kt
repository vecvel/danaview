// OWNER: AND-09
//
// `.vlut` tables (ARCH §10.2, D-07; CORE-21 writes them): little-endian 'VLUT', u16 version = 1,
// u16 N (2–65), then N³ × RGB float16, red fastest, domain [0, 1]. Engines upload the table as a
// tiled 2D texture: N tiles of N × N (red across, green down) in a ⌈√N⌉-column grid (≤ 585 × 520
// for N = 65), sampled bilinearly inside the two nearest blue slices and mixed linearly between
// them, which is the trilinear lookup of ARCH §11.6 "LUT". Decoding and the tiled layout are pure
// (JVM-tested, with [lookupTiled] mirroring dv_look.glsl's dvLut); [LutTexture] uploads on the GL
// thread as RGBA16F on ES 3 (the float16 values unchanged) or RGBA8 on ES 2.

package com.vecvel.danaview.editor.engine.effects

import android.opengl.GLES20
import android.opengl.GLES30
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** A decoded LUT: [size]³ entries of float16 RGB, red fastest (file header). */
class LutTable(val size: Int, private val halves: ShortArray) {
    init {
        require(size in MIN_SIZE..MAX_SIZE) { "LUT size $size" }
        require(halves.size == size * size * size * 3) { "LUT data length" }
    }

    /** Entry ([r], [g], [b]) channel [ch] as a float. */
    fun value(r: Int, g: Int, b: Int, ch: Int): Float = Half.toFloat(halves[((b * size + g) * size + r) * 3 + ch])

    /** Raw float16 bits of entry ([r], [g], [b]) channel [ch]. */
    fun half(r: Int, g: Int, b: Int, ch: Int): Short = halves[((b * size + g) * size + r) * 3 + ch]

    /** Tiles per row of the tiled texture: ⌈√N⌉. */
    val tilesPerRow: Int get() = tilesPerRow(size)

    /** Tiled texture width. */
    val textureWidth: Int get() = tilesPerRow * size

    /** Tiled texture height. */
    val textureHeight: Int get() = ceil(size.toDouble() / tilesPerRow).toInt() * size

    /** Texel (x, y) of entry (r, g, b) in the tiled texture (y = row index as uploaded). */
    fun texelOf(r: Int, g: Int, b: Int): Pair<Int, Int> = Pair((b % tilesPerRow) * size + r, (b / tilesPerRow) * size + g)

    /**
     * The tiled RGBA texel data, row 0 first, as float16 RGBA (4 shorts per texel, alpha = 1.0).
     */
    fun tiledHalfRgba(): ShortArray {
        val w = textureWidth
        val out = ShortArray(w * textureHeight * 4)
        for (b in 0 until size) for (g in 0 until size) for (r in 0 until size) {
            val (x, y) = texelOf(r, g, b)
            val o = (y * w + x) * 4
            out[o] = half(r, g, b, 0)
            out[o + 1] = half(r, g, b, 1)
            out[o + 2] = half(r, g, b, 2)
            out[o + 3] = Half.ONE
        }
        return out
    }

    /** The tiled RGBA8 texel data, row 0 first. */
    fun tiledRgba8(): ByteArray {
        val w = textureWidth
        val out = ByteArray(w * textureHeight * 4)
        for (b in 0 until size) for (g in 0 until size) for (r in 0 until size) {
            val (x, y) = texelOf(r, g, b)
            val o = (y * w + x) * 4
            for (ch in 0 until 3) out[o + ch] = toByte(value(r, g, b, ch)).toByte()
            out[o + 3] = 0xFF.toByte()
        }
        return out
    }

    /**
     * The trilinear lookup exactly as dv_look.glsl's dvLut does it on the tiled layout (bilinear in
     * the slices `z0 = min(floor(z), N − 2)` and `z0 + 1`, then linear), on clamped input.
     */
    fun lookupTiled(r: Double, g: Double, b: Double): DoubleArray {
        val n1 = size - 1.0
        val x = r.coerceIn(0.0, 1.0) * n1
        val y = g.coerceIn(0.0, 1.0) * n1
        val z = b.coerceIn(0.0, 1.0) * n1
        val z0 = min(floor(z), n1 - 1).toInt()
        val fz = z - z0
        val s0 = sliceBilinear(z0, x, y)
        val s1 = sliceBilinear(z0 + 1, x, y)
        return DoubleArray(3) { s0[it] * (1 - fz) + s1[it] * fz }
    }

    private fun sliceBilinear(slice: Int, x: Double, y: Double): DoubleArray {
        val x0 = floor(x).toInt().coerceIn(0, size - 1)
        val y0 = floor(y).toInt().coerceIn(0, size - 1)
        val x1 = min(x0 + 1, size - 1)
        val y1 = min(y0 + 1, size - 1)
        val fx = x - x0
        val fy = y - y0
        return DoubleArray(3) { ch ->
            val c00 = value(x0, y0, slice, ch)
            val c10 = value(x1, y0, slice, ch)
            val c01 = value(x0, y1, slice, ch)
            val c11 = value(x1, y1, slice, ch)
            (c00 * (1 - fx) + c10 * fx) * (1 - fy) + (c01 * (1 - fx) + c11 * fx) * fy
        }
    }

    companion object {
        /** Smallest N. */
        const val MIN_SIZE = 2

        /** Largest N (ARCH §10.2). */
        const val MAX_SIZE = 65

        private const val HEADER = 8

        /** ⌈√N⌉. */
        fun tilesPerRow(n: Int): Int {
            var c = sqrt(n.toDouble()).toInt()
            while (c * c < n) c++
            return c
        }

        /** Decodes `.vlut` v1 bytes; throws IllegalArgumentException on a bad file. */
        fun decode(bytes: ByteArray): LutTable {
            require(bytes.size >= HEADER) { "vlut: truncated header" }
            require(bytes[0] == 'V'.code.toByte() && bytes[1] == 'L'.code.toByte() && bytes[2] == 'U'.code.toByte() && bytes[3] == 'T'.code.toByte()) { "vlut: bad magic" }
            val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val version = bb.getShort(4).toInt() and 0xFFFF
            require(version == 1) { "vlut: unsupported version $version" }
            val n = bb.getShort(6).toInt() and 0xFFFF
            require(n in MIN_SIZE..MAX_SIZE) { "vlut: bad size $n" }
            val count = n * n * n * 3
            require(bytes.size == HEADER + count * 2) { "vlut: expected ${HEADER + count * 2} bytes, got ${bytes.size}" }
            val halves = ShortArray(count)
            bb.position(HEADER)
            bb.asShortBuffer().get(halves)
            return LutTable(n, halves)
        }

        /** A table from `N³ × 3` floats, red fastest (inline vector LUTs, generated tables). */
        fun fromFloats(n: Int, rgb: DoubleArray): LutTable {
            require(rgb.size == n * n * n * 3) { "LUT data length" }
            return LutTable(n, ShortArray(rgb.size) { Half.fromFloat(rgb[it].toFloat()) })
        }

        /** `round(clamp(v, 0, 1)·255)`. */
        fun toByte(v: Float): Int = (v.coerceIn(0f, 1f) * 255f).roundToInt()
    }
}

/** IEEE 754 binary16 conversions. */
object Half {
    /** 1.0. */
    const val ONE: Short = 0x3C00

    /** The float of half [bits]. */
    fun toFloat(bits: Short): Float {
        val h = bits.toInt() and 0xFFFF
        val sign = (h ushr 15) and 1
        val exp = (h ushr 10) and 0x1F
        val mant = h and 0x3FF
        val v = when (exp) {
            0 -> mant / 1024f * 6.1035156e-5f // subnormal: mant · 2^-24
            0x1F -> if (mant == 0) Float.POSITIVE_INFINITY else Float.NaN
            else -> java.lang.Float.intBitsToFloat(((exp - 15 + 127) shl 23) or (mant shl 13))
        }
        return if (sign == 1) -v else v
    }

    /** Half bits of [f], round to nearest even (overflow → ±65504 clamp, NaN → 0x7E00). */
    fun fromFloat(f: Float): Short {
        if (f.isNaN()) return 0x7E00
        val bits = java.lang.Float.floatToIntBits(f)
        val sign = (bits ushr 16) and 0x8000
        val abs = kotlin.math.abs(f)
        if (abs >= 65520f) return (sign or 0x7BFF).toShort()
        if (abs < 6.1035156e-5f) {
            // Subnormal half: round(abs / 2^-24).
            val m = Math.rint((abs / 5.9604645e-8f).toDouble()).toInt()
            return (sign or m).toShort()
        }
        val e = ((bits ushr 23) and 0xFF) - 127 + 15
        val m = bits and 0x7FFFFF
        var half = (e shl 10) or (m ushr 13)
        val rest = m and 0x1FFF
        if (rest > 0x1000 || (rest == 0x1000 && (half and 1) == 1)) half++
        return (sign or half).toShort()
    }
}

/** A LUT uploaded as the tiled texture (file header); GL-thread confined. */
class LutTexture private constructor(val texture: Int, val table: LutTable, val isHalfFloat: Boolean, private val confinement: GlThreadConfinement) {
    private var released = false

    /** `[N, tiles per row, texture width, texture height]` for dv_look's uLutInfo. */
    val info: FloatArray get() = floatArrayOf(table.size.toFloat(), table.tilesPerRow.toFloat(), table.textureWidth.toFloat(), table.textureHeight.toFloat())

    /** Deletes the texture. */
    fun release() {
        confinement.check()
        if (released) return
        released = true
        GlResources.deleteTexture(texture)
    }

    companion object {
        /** Uploads [table]: RGBA16F when [halfFloat] (ES 3), else RGBA8. */
        fun upload(table: LutTable, halfFloat: Boolean): LutTexture {
            val confinement = GlThreadConfinement()
            val w = table.textureWidth
            val h = table.textureHeight
            val id = if (halfFloat) {
                val data = table.tiledHalfRgba()
                val buf = ByteBuffer.allocateDirect(data.size * 2).order(ByteOrder.nativeOrder())
                buf.asShortBuffer().put(data)
                GlResources.createTexture(w, h, GLES30.GL_RGBA16F, GLES20.GL_RGBA, GLES30.GL_HALF_FLOAT, buf, GLES20.GL_LINEAR)
            } else {
                val data = table.tiledRgba8()
                val buf = ByteBuffer.allocateDirect(data.size).order(ByteOrder.nativeOrder())
                buf.put(data).position(0)
                GlResources.createTexture(w, h, GLES20.GL_RGBA, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf, GLES20.GL_LINEAR)
            }
            return LutTexture(id, table, halfFloat, confinement)
        }
    }
}
