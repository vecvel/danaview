// OWNER: AND-09
//
// A minimal PNG decoder for API-03's goldens and sources (test only): non-interlaced, bit depth 8
// (grey, RGB, RGBA, grey + alpha) or 16 (grey; the sprite glyph maps, big-endian), all five row
// filters. It returns the raw samples with no colour management, gamma or premultiplication, which
// BitmapFactory would not guarantee (and it cannot read 16-bit grey).

package com.vecvel.danaview.editor.engine.effects

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.zip.Inflater

/** A decoded PNG: [channels] samples per pixel, row-major top-down. */
class PngImage(val width: Int, val height: Int, val channels: Int, val bitDepth: Int, val samples: IntArray) {
    /** RGBA8 bytes (grey expanded, alpha 255 when absent). */
    fun toRgba8(): ByteArray {
        require(bitDepth == 8) { "8-bit only" }
        val out = ByteArray(width * height * 4)
        for (i in 0 until width * height) {
            val s = i * channels
            when (channels) {
                1 -> { val v = samples[s].toByte(); out[i * 4] = v; out[i * 4 + 1] = v; out[i * 4 + 2] = v; out[i * 4 + 3] = -1 }
                2 -> { val v = samples[s].toByte(); out[i * 4] = v; out[i * 4 + 1] = v; out[i * 4 + 2] = v; out[i * 4 + 3] = samples[s + 1].toByte() }
                3 -> { out[i * 4] = samples[s].toByte(); out[i * 4 + 1] = samples[s + 1].toByte(); out[i * 4 + 2] = samples[s + 2].toByte(); out[i * 4 + 3] = -1 }
                else -> for (c in 0 until 4) out[i * 4 + c] = samples[s + c].toByte()
            }
        }
        return out
    }
}

/** The decoder (file header). */
object PngDecoder {
    fun decode(bytes: ByteArray): PngImage {
        val sig = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)
        require(bytes.size > 8 && (0 until 8).all { bytes[it] == sig[it] }) { "not a PNG" }
        val bb = ByteBuffer.wrap(bytes)
        var pos = 8
        var w = 0
        var h = 0
        var depth = 0
        var type = 0
        val idat = ByteArrayOutputStream()
        while (pos + 8 <= bytes.size) {
            val len = bb.getInt(pos)
            val name = String(bytes, pos + 4, 4, Charsets.US_ASCII)
            val data = pos + 8
            when (name) {
                "IHDR" -> {
                    w = bb.getInt(data)
                    h = bb.getInt(data + 4)
                    depth = bytes[data + 8].toInt() and 0xFF
                    type = bytes[data + 9].toInt() and 0xFF
                    require(bytes[data + 12].toInt() == 0) { "interlaced PNG" }
                }
                "IDAT" -> idat.write(bytes, data, len)
                "IEND" -> break
            }
            pos = data + len + 4
        }
        val channels = when (type) {
            0 -> 1
            2 -> 3
            4 -> 2
            6 -> 4
            else -> error("PNG colour type $type")
        }
        require(depth == 8 || (depth == 16 && type == 0)) { "PNG depth $depth type $type" }
        val bpp = channels * depth / 8
        val stride = w * bpp
        val raw = ByteArray(h * (stride + 1))
        val inf = Inflater()
        inf.setInput(idat.toByteArray())
        var n = 0
        while (n < raw.size) {
            val got = inf.inflate(raw, n, raw.size - n)
            require(got > 0 || !inf.needsInput()) { "PNG data truncated" }
            if (got == 0 && inf.finished()) break
            n += got
        }
        inf.end()
        val img = ByteArray(h * stride)
        for (y in 0 until h) {
            val f = raw[y * (stride + 1)].toInt()
            val src = y * (stride + 1) + 1
            val dst = y * stride
            for (x in 0 until stride) {
                val v = raw[src + x].toInt() and 0xFF
                val a = if (x >= bpp) img[dst + x - bpp].toInt() and 0xFF else 0
                val b = if (y > 0) img[dst - stride + x].toInt() and 0xFF else 0
                val c = if (x >= bpp && y > 0) img[dst - stride + x - bpp].toInt() and 0xFF else 0
                val out = when (f) {
                    0 -> v
                    1 -> v + a
                    2 -> v + b
                    3 -> v + (a + b) / 2
                    4 -> {
                        val p = a + b - c
                        val pa = kotlin.math.abs(p - a)
                        val pb = kotlin.math.abs(p - b)
                        val pc = kotlin.math.abs(p - c)
                        v + if (pa <= pb && pa <= pc) a else if (pb <= pc) b else c
                    }
                    else -> error("PNG filter $f")
                }
                img[dst + x] = out.toByte()
            }
        }
        val samples = if (depth == 8) {
            IntArray(img.size) { img[it].toInt() and 0xFF }
        } else {
            IntArray(img.size / 2) { ((img[it * 2].toInt() and 0xFF) shl 8) or (img[it * 2 + 1].toInt() and 0xFF) }
        }
        return PngImage(w, h, channels, depth, samples)
    }
}
