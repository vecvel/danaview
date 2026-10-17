// OWNER: ENG-05
//
// JVM unit tests of the Kotlin frame barcode reader (FrameBarcode.kt in src/androidTest is
// added to this source set, see test_fixtures/media/README.md). The fixture tests decode the
// committed PNG frames of frame_counter_1080p30 and, when the dev-only ffmpeg is installed,
// all 240 frames extracted from the video.

package com.vecvel.danaview.editor.engine.support

import java.io.File
import java.util.concurrent.TimeUnit
import javax.imageio.ImageIO
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class FrameBarcodeTest {
    private fun bits(index: Int): String =
        FrameBarcode.cellsFor(index).joinToString("") { if (it) "1" else "0" }

    private fun frame(w: Int, h: Int, v: Int = 90): ByteArray =
        ByteArray(w * h * 4) { v.toByte() }

    @Test
    fun goldenVectorsMatchTheFixtureGenerator() {
        assertEquals("1000000000000000000000000010", bits(0))
        assertEquals("1000000000000000010000011110", bits(1))
        assertEquals("1000000000101000000110100110", bits(160))
        assertEquals("1000000000111011111000001110", bits(239))
        assertEquals("1000010010001101001111000110", bits(0x1234))
        assertEquals("1011111111111111110010010010", bits(0xFFFF))
        assertEquals(105, FrameBarcode.crc8(160))
    }

    @Test
    fun syntheticRoundTripAtSeveralSizes() {
        for ((w, h) in listOf(280 to 158, 640 to 360, 1920 to 1080)) {
            val px = frame(w, h)
            for (i in listOf(0, 1, 159, 160, 239, 479, 4660, 65535)) {
                FrameBarcode.paint(px, w, h, i)
                assertEquals("${w}x$h index $i", i, FrameBarcode.decode(px, w, h))
                assertEquals(i, FrameBarcode.decode(px, w, h, order = FramePixelOrder.BGRA))
            }
        }
    }

    @Test
    fun everyIndexRoundTripsSmall() {
        val w = 280
        val h = 160
        val px = frame(w, h)
        for (i in 0..FrameBarcode.MAX_INDEX step 7) {
            FrameBarcode.paint(px, w, h, i)
            assertEquals(i, FrameBarcode.decode(px, w, h))
        }
    }

    @Test
    fun statuses() {
        val w = 640
        val h = 360
        val flat = frame(w, h, 128)
        assertEquals(FrameBarcodeStatus.NO_SIGNAL, FrameBarcode.read(flat, w, h).status)

        val a = frame(w, h)
        val b = frame(w, h)
        FrameBarcode.paint(a, w, h, 100)
        FrameBarcode.paint(b, w, h, 101)
        val mix = ByteArray(a.size) { (((a[it].toInt() and 0xFF) + (b[it].toInt() and 0xFF)) / 2).toByte() }
        val blended = FrameBarcode.read(mix, w, h)
        assertEquals(FrameBarcodeStatus.BLENDED, blended.status)
        assertNull(blended.index)
        assertFalse(blended.isReadable)

        // Inverted band: calibration cells swapped.
        val inv = a.copyOf()
        for (y in 0 until 36) for (x in 0 until w) {
            val p = (y * w + x) * 4
            for (c in 0 until 3) inv[p + c] = (255 - (inv[p + c].toInt() and 0xFF)).toByte()
        }
        assertEquals(FrameBarcodeStatus.BAD_GUARD, FrameBarcode.read(inv, w, h).status)

        // One flipped data cell: checksum catches it.
        val bad = a.copyOf()
        val x0 = 9 * w / 28
        val x1 = 10 * w / 28
        for (y in 0 until 36) for (x in x0 until x1) {
            val p = (y * w + x) * 4
            val v = (255 - (bad[p].toInt() and 0xFF)).toByte()
            bad[p] = v; bad[p + 1] = v; bad[p + 2] = v
        }
        assertEquals(FrameBarcodeStatus.BAD_CHECKSUM, FrameBarcode.read(bad, w, h).status)
    }

    @Test
    fun regionAndStride() {
        val w = 600
        val h = 600
        val stride = w * 4 + 64
        val px = ByteArray(stride * h)
        val region = FrameBarcodeRegion(0, 210, 600, 180)
        FrameBarcode.paint(px, w, h, 4242, bytesPerRow = stride, region = region)
        assertNull(FrameBarcode.decode(px, w, h, bytesPerRow = stride))
        assertEquals(4242, FrameBarcode.decode(px, w, h, bytesPerRow = stride, region = region))
    }

    // ---- fixture frames ----

    private fun fixturesDir(): File? {
        System.getProperty("danaview.fixtures")?.let { return File(it).takeIf(File::isDirectory) }
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, "test_fixtures/media")
            if (candidate.isDirectory) return candidate
            dir = dir.parentFile
        }
        return null
    }

    private fun decodePng(file: File): Int? {
        val img = ImageIO.read(file) ?: error("cannot decode ${file.name}")
        val w = img.width
        val h = img.height
        val argb = IntArray(w * h)
        img.getRGB(0, 0, w, h, argb, 0, w)
        return FrameBarcode.decodeArgb(argb, w, h)
    }

    @Test
    fun committedPngFramesOfFrameCounter1080p30() {
        val dir = fixturesDir()
        assumeTrue("test_fixtures/media not found", dir != null)
        val frames = File(dir, "frames").listFiles { f -> f.name.startsWith("frame_counter_1080p30_") && f.extension == "png" }
            ?.sortedBy { it.name } ?: emptyList()
        assertTrue("expected the committed sample frames", frames.size >= 10)
        for (f in frames) {
            val expected = f.nameWithoutExtension.substringAfterLast('_').toInt()
            assertEquals(f.name, expected, decodePng(f))
        }
    }

    private fun findFfmpeg(): String? {
        System.getenv("FFMPEG")?.let { if (File(it).canExecute()) return it }
        val dirs = listOf("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin") +
            (System.getenv("PATH") ?: "").split(File.pathSeparator)
        return dirs.map { File(it, "ffmpeg") }.firstOrNull { it.canExecute() }?.path
    }

    @Test
    fun all240FramesOfFrameCounter1080p30FromExtractedPng() {
        val dir = fixturesDir()
        val ffmpeg = findFfmpeg()
        assumeTrue("test_fixtures/media not found", dir != null)
        assumeTrue("ffmpeg (dev-only tool) not installed", ffmpeg != null)
        val out = File.createTempFile("danaview_frames", "").apply { delete(); mkdirs() }
        try {
            val p = ProcessBuilder(
                ffmpeg, "-v", "error", "-y", "-i", File(dir, "frame_counter_1080p30.mp4").path,
                "-fps_mode", "passthrough", "-start_number", "0", File(out, "f_%d.png").path,
            ).redirectErrorStream(true).start()
            assertTrue("ffmpeg timed out", p.waitFor(3, TimeUnit.MINUTES))
            assertEquals(0, p.exitValue())
            val files = out.listFiles()!!.toList()
            assertEquals(240, files.size)
            for (i in 0 until 240) {
                assertEquals("frame $i", i, decodePng(File(out, "f_$i.png")))
            }
        } finally {
            out.deleteRecursively()
        }
    }
}
