// OWNER: HOM-04A
//
// JVM tests of the pure thumbnail helpers (thumbnails/ThumbnailSupport.kt): request validation,
// source parsing, media kinds, box geometry (the HOM-04 rules), sample sizes, the "MediaStore
// thumbnail too small" check and the encoder format actually written.

package com.vecvel.danaview.library.thumbnails

import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.pigeon.ThumbnailFormatMsg
import com.vecvel.danaview.library.pigeon.ThumbnailModeMsg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ThumbnailSupportTest {
    private val fill = ThumbnailModeMsg.FILL
    private val fit = ThumbnailModeMsg.FIT

    private fun failureOf(block: () -> Unit): ThumbnailFailure {
        try {
            block()
        } catch (f: ThumbnailFailure) {
            return f
        }
        fail("no failure")
        throw AssertionError()
    }

    @Test
    fun validationRejectsBadRequests() {
        assertNull(ThumbnailRequests.validate("r", 384, 384, 0.8, "/cache/t.webp"))
        assertEquals(LibraryErrorCode.invalidArgument, ThumbnailRequests.validate("", 384, 384, 0.8, "/c/t")!!.code)
        assertEquals(LibraryErrorCode.invalidArgument, ThumbnailRequests.validate("r", 0, 384, 0.8, "/c/t")!!.code)
        assertEquals(LibraryErrorCode.invalidArgument, ThumbnailRequests.validate("r", 384, 4097, 0.8, "/c/t")!!.code)
        assertEquals(LibraryErrorCode.invalidArgument, ThumbnailRequests.validate("r", 384, 384, 1.5, "/c/t")!!.code)
        assertEquals(LibraryErrorCode.invalidArgument, ThumbnailRequests.validate("r", 384, 384, Double.NaN, "/c/t")!!.code)
        assertEquals(LibraryErrorCode.invalidArgument, ThumbnailRequests.validate("r", 384, 384, 0.8, "cache/t")!!.code)
        assertNull(ThumbnailRequests.validate("r", 4096, 1, 0.0, "/t"))
    }

    @Test
    fun sourcesParse() {
        assertEquals(ThumbnailSource.MediaStoreItem(42), ThumbnailSource.parse("ms:42"))
        assertEquals(ThumbnailSource.LocalFile("/data/a b.jpg"), ThumbnailSource.parse("/data/a b.jpg"))
        assertEquals(ThumbnailSource.LocalFile("/data/a b.jpg"), ThumbnailSource.parse("file:///data/a%20b.jpg"))
        assertEquals(ThumbnailSource.LocalFile("/data/a+b.jpg"), ThumbnailSource.parse("file:///data/a+b.jpg"))
        assertEquals(ThumbnailSource.Content("content://x/1"), ThumbnailSource.parse("content://x/1"))
        assertEquals(LibraryErrorCode.notSupportedOnDevice, failureOf { ThumbnailSource.parse("ph:ABC/L0/001") }.code)
        assertEquals(LibraryErrorCode.invalidArgument, failureOf { ThumbnailSource.parse("ms:abc") }.code)
        assertEquals(LibraryErrorCode.invalidArgument, failureOf { ThumbnailSource.parse("ms:-1") }.code)
        assertEquals(LibraryErrorCode.invalidArgument, failureOf { ThumbnailSource.parse("relative/x.jpg") }.code)
        assertEquals(LibraryErrorCode.invalidArgument, failureOf { ThumbnailSource.parse("https://example.com/x.jpg") }.code)
    }

    @Test
    fun mediaKinds() {
        assertEquals(MediaKind.PDF, ThumbnailTypes.kind("application/pdf", "x.bin"))
        assertEquals(MediaKind.VIDEO, ThumbnailTypes.kind("video/mp4", null))
        assertEquals(MediaKind.IMAGE, ThumbnailTypes.kind("image/heic", null))
        assertEquals(MediaKind.VIDEO, ThumbnailTypes.kind(null, "/a/b/Clip.MOV"))
        assertEquals(MediaKind.IMAGE, ThumbnailTypes.kind(null, "IMG_1.JPG"))
        assertEquals(MediaKind.PDF, ThumbnailTypes.kind("application/octet-stream", "doc.pdf"))
        assertEquals(MediaKind.OTHER, ThumbnailTypes.kind(null, "notes.txt"))
        assertEquals(MediaKind.OTHER, ThumbnailTypes.kind(null, "noext"))
        assertTrue(ThumbnailTypes.looksLikePdf("%PDF-1.7\n".toByteArray()))
        assertTrue(ThumbnailTypes.looksLikePdf("\u0000junk%PDF-1.4".toByteArray()))
        assertFalse(ThumbnailTypes.looksLikePdf("%PD".toByteArray()))
        assertFalse(ThumbnailTypes.looksLikePdf("GIF89a".toByteArray()))
    }

    @Test
    fun fillIsTheBoxAndCropsTheCentre() {
        val box = PxSize(384, 384)
        assertEquals(box, ThumbnailGeometry.outputSize(PxSize(4000, 3000), box, fill))
        assertEquals(PxRect(500, 0, 3000, 3000), ThumbnailGeometry.cropRect(PxSize(4000, 3000), box, fill))
        assertEquals(PxRect(0, 500, 3000, 3000), ThumbnailGeometry.cropRect(PxSize(3000, 4000), box, fill))
        // A source smaller than the box is still cropped to the box's aspect (upscaled on draw).
        assertEquals(PxRect(8, 0, 48, 48), ThumbnailGeometry.cropRect(PxSize(64, 48), box, fill))
    }

    @Test
    fun fitKeepsTheAspectAndNeverUpscales() {
        val box = PxSize(1280, 1280)
        assertEquals(PxSize(1280, 960), ThumbnailGeometry.outputSize(PxSize(4000, 3000), box, fit))
        assertEquals(PxSize(720, 1280), ThumbnailGeometry.outputSize(PxSize(1080, 1920), box, fit))
        assertEquals(PxSize(64, 48), ThumbnailGeometry.outputSize(PxSize(64, 48), box, fit))
        assertEquals(PxSize(1280, 1), ThumbnailGeometry.outputSize(PxSize(100000, 10), box, fit))
        assertEquals(PxRect(0, 0, 4000, 3000), ThumbnailGeometry.cropRect(PxSize(4000, 3000), box, fit))
    }

    @Test
    fun requestSizeCoversTheBoxForFill() {
        val box = PxSize(384, 384)
        assertEquals(PxSize(512, 384), ThumbnailGeometry.requestSize(PxSize(4000, 3000), box, fill))
        assertEquals(PxSize(683, 683), ThumbnailGeometry.requestSize(null, box, fill))
        assertEquals(box, ThumbnailGeometry.requestSize(PxSize(4000, 3000), box, fit))
        assertEquals(4096, ThumbnailGeometry.requestSize(PxSize(100000, 10), box, fill).width)
    }

    @Test
    fun sampleSizeKeepsAtLeastTheWantedSize() {
        assertEquals(4, ThumbnailGeometry.sampleSize(PxSize(4000, 3000), PxSize(512, 384)))
        assertEquals(1, ThumbnailGeometry.sampleSize(PxSize(400, 300), PxSize(512, 384)))
        assertEquals(2, ThumbnailGeometry.sampleSize(PxSize(1024, 768), PxSize(512, 384)))
        assertEquals(1, ThumbnailGeometry.sampleSize(PxSize(0, 0), PxSize(512, 384)))
    }

    @Test
    fun tooSmallAsksForTheOriginalOnlyWhenItHelps() {
        val want = PxSize(1280, 1280)
        assertTrue(ThumbnailGeometry.tooSmall(PxSize(512, 384), want, fit, PxSize(4000, 3000)))
        assertFalse(ThumbnailGeometry.tooSmall(PxSize(512, 384), want, fit, PxSize(512, 384)))
        assertTrue(ThumbnailGeometry.tooSmall(PxSize(512, 384), want, fit, null))
        assertFalse(ThumbnailGeometry.tooSmall(PxSize(1280, 960), want, fit, PxSize(4000, 3000)))
        assertFalse(ThumbnailGeometry.tooSmall(PxSize(512, 384), PxSize(384, 384), fill, PxSize(4000, 3000)))
        assertTrue(ThumbnailGeometry.tooSmall(PxSize(512, 200), PxSize(384, 384), fill, PxSize(4000, 1500)))
    }

    @Test
    fun rotationSwapsQuarterTurns() {
        assertEquals(PxSize(3000, 4000), ThumbnailGeometry.rotated(PxSize(4000, 3000), 90))
        assertEquals(PxSize(3000, 4000), ThumbnailGeometry.rotated(PxSize(4000, 3000), 270))
        assertEquals(PxSize(4000, 3000), ThumbnailGeometry.rotated(PxSize(4000, 3000), 180))
        assertEquals(PxSize(3000, 4000), ThumbnailGeometry.rotated(PxSize(4000, 3000), -90))
    }

    @Test
    fun encoderFormats() {
        assertEquals(ThumbnailFormatMsg.WEBP, ThumbnailEncoding.effectiveFormat(ThumbnailFormatMsg.WEBP))
        assertEquals(ThumbnailFormatMsg.JPEG, ThumbnailEncoding.effectiveFormat(ThumbnailFormatMsg.HEIC))
        assertEquals(ThumbnailFormatMsg.PNG, ThumbnailEncoding.effectiveFormat(ThumbnailFormatMsg.PNG))
        assertEquals(99, ThumbnailEncoding.quality100(1.0, ThumbnailFormatMsg.WEBP))
        assertEquals(100, ThumbnailEncoding.quality100(1.0, ThumbnailFormatMsg.JPEG))
        assertEquals(80, ThumbnailEncoding.quality100(0.8, ThumbnailFormatMsg.WEBP))
        assertTrue(ThumbnailEncoding.keepsAlpha(ThumbnailFormatMsg.PNG))
        assertFalse(ThumbnailEncoding.keepsAlpha(ThumbnailFormatMsg.WEBP))
    }
}
