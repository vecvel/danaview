// OWNER: AND-11
//
// EncoderSettings mapping and HardwareEncoderSelector with injected codec lists (ARCH §14.1, §14.3):
// hardware first, software flagged (`softwareEncoder`), HEVC → H.264 fallback (`hevcUnavailable`),
// a portrait size only taken landscape (`portraitRetried`), unsupported sizes, maxShortSide, and
// the hardware flag of the encoder that actually ran.

package com.vecvel.danaview.editor.engine.export

import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.pigeon.ExportContainerMsg
import com.vecvel.danaview.editor.engine.pigeon.VideoCodecMsg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class EncoderSelectionTest {
    private fun codes(c: EncoderChoice) = c.warnings().map { it.code }

    @Test
    fun settingsMapFromTheMessage() {
        val s = EncoderSettings.from(Settings.msg(w = 1080, h = 1920, fps = 24, codec = VideoCodecMsg.HEVC, videoBitrate = 8_000_000))
        assertEquals(ExportVideoCodec.HEVC, s.codec)
        assertEquals("video/hevc", s.videoMimeType)
        assertEquals(1080, s.width)
        assertEquals(1920, s.height)
        assertTrue(s.isPortrait)
        assertEquals(1080, s.shortSide)
        assertEquals(2.0f, s.iFrameIntervalSeconds, 0f)
        assertEquals(8_000_000, s.videoBitrate)
        assertEquals(192_000, s.audioBitrate)
        // 2.5 s at 24 fps: frames 0..59; 2.5 s + 1 µs needs frame 60 too.
        assertEquals(60, s.frameCount(2_500_000))
        assertEquals(61, s.frameCount(2_500_001))
        assertEquals(0, s.frameCount(0))
        // (8 Mb/s + 192 kb/s) * 10 s / 8 * 1.02
        assertEquals(10_444_800L, s.estimatedBytes(10_000_000))
        assertEquals("audio/mp4a-latm", EncoderSettings.AUDIO_MIME_TYPE)
        assertEquals(48_000, EncoderSettings.AUDIO_SAMPLE_RATE)
        assertEquals(2, EncoderSettings.AUDIO_CHANNELS)
    }

    @Test
    fun movIsNotWrittenOnAndroid() {
        try {
            EncoderSettings.from(Settings.msg(container = ExportContainerMsg.MOV))
            fail("MOV accepted")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.notSupportedOnDevice, e.code)
        }
    }

    @Test
    fun rankPutsHardwareFirstAndKeepsPlatformOrder() {
        val sel = HardwareEncoderSelector(Codecs.phone)
        assertEquals(listOf("c2.qti.avc.encoder", "c2.android.avc.encoder"), sel.ranked(Codecs.AVC).map { it.name })
        val mixed = listOf(
            Codecs.encoder("sw1", Codecs.AVC, false),
            Codecs.encoder("hw1", Codecs.AVC, true),
            Codecs.encoder("sw2", Codecs.AVC, false),
            Codecs.encoder("hw2", Codecs.AVC, true),
        )
        assertEquals(listOf("hw1", "hw2", "sw1", "sw2"), HardwareEncoderSelector.rank(mixed).map { it.name })
        // A hardware-accelerated codec that is also software-only counts as software.
        val odd = EncoderCandidate("odd", Codecs.AVC, hardware = true, softwareOnly = true)
        assertEquals(listOf("hw1", "odd"), HardwareEncoderSelector.rank(listOf(odd, mixed[1])).map { it.name })
    }

    @Test
    fun hardwareEncoderIsPreferredAndNotFlagged() {
        val c = HardwareEncoderSelector(Codecs.phone).choose(Settings.of(1920, 1080))
        assertEquals("c2.qti.avc.encoder", c.encoder?.name)
        assertTrue(c.hardware)
        assertTrue(c.sizeSupported)
        assertEquals(emptyList<String>(), codes(c))
    }

    @Test
    fun softwareEncoderRaisesTheWarning() {
        val c = HardwareEncoderSelector(Codecs.softwareOnly).choose(Settings.of(1280, 720))
        assertEquals("c2.android.avc.encoder", c.encoder?.name)
        assertFalse(c.hardware)
        assertEquals(listOf(ExportWarnings.SOFTWARE_ENCODER), codes(c))
        assertTrue(c.warnings().single().message.contains("c2.android.avc.encoder"))
    }

    @Test
    fun hardwareThatCannotTakeTheSizeFallsToSoftwareAndIsFlagged() {
        val catalog = Codecs.catalog(
            Codecs.encoder("hw", Codecs.AVC, hardware = true, maxW = 1920, maxH = 1088),
            Codecs.encoder("sw", Codecs.AVC, hardware = false, maxW = 4096, maxH = 2304),
        )
        val c = HardwareEncoderSelector(catalog).choose(Settings.of(3840, 2160))
        assertEquals("sw", c.encoder?.name)
        assertEquals(listOf(ExportWarnings.SOFTWARE_ENCODER), codes(c))
    }

    @Test
    fun hevcWithoutAnyHevcEncoderFallsBackToH264() {
        val catalog = Codecs.catalog(Codecs.encoder("c2.qti.avc.encoder", Codecs.AVC, true))
        val c = HardwareEncoderSelector(catalog).choose(Settings.of(1920, 1080, codec = ExportVideoCodec.HEVC))
        assertEquals(ExportVideoCodec.HEVC, c.requested)
        assertEquals(ExportVideoCodec.H264, c.codec)
        assertTrue(c.codecFallback)
        assertEquals(listOf(ExportWarnings.HEVC_UNAVAILABLE), codes(c))
    }

    @Test
    fun softwareHevcIsUsedButFlagged() {
        val c = HardwareEncoderSelector(Codecs.softwareOnly).choose(Settings.of(1280, 720, codec = ExportVideoCodec.HEVC))
        assertEquals(ExportVideoCodec.HEVC, c.codec)
        assertEquals("c2.android.hevc.encoder", c.encoder?.name)
        assertEquals(listOf(ExportWarnings.SOFTWARE_ENCODER), codes(c))
    }

    @Test
    fun hevcTooLargeForEveryHevcEncoderFallsBackToH264() {
        val c = HardwareEncoderSelector(Codecs.softwareOnly).choose(Settings.of(2048, 1152, codec = ExportVideoCodec.HEVC))
        assertEquals(ExportVideoCodec.H264, c.codec)
        assertEquals(listOf(ExportWarnings.HEVC_UNAVAILABLE, ExportWarnings.SOFTWARE_ENCODER), codes(c))
    }

    @Test
    fun portraitTakenOnlyLandscapePredictsTheRetry() {
        val catalog = Codecs.catalog(Codecs.encoder("hw", Codecs.AVC, hardware = true, maxW = 1920, maxH = 1920, landscapeOnly = true))
        val c = HardwareEncoderSelector(catalog).choose(Settings.of(1080, 1920))
        assertEquals("hw", c.encoder?.name)
        assertTrue(c.portraitRefused)
        assertTrue(c.sizeSupported)
        assertEquals(listOf(ExportWarnings.PORTRAIT_RETRIED), codes(c))
        // Landscape output is not a portrait refusal.
        assertFalse(HardwareEncoderSelector(catalog).choose(Settings.of(1920, 1080)).portraitRefused)
    }

    @Test
    fun unsupportedSizeIsReportedWithTheLargestStandardShortSide() {
        val catalog = Codecs.catalog(Codecs.encoder("hw", Codecs.AVC, hardware = true, maxW = 1920, maxH = 1088))
        val sel = HardwareEncoderSelector(catalog)
        val c = sel.choose(Settings.of(3840, 2160))
        assertFalse(c.sizeSupported)
        assertEquals(1080, sel.maxShortSide(Settings.of(3840, 2160), ExportVideoCodec.H264))
        // Portrait 9:16 at short side 1080 is 1080x1920: taken rotated (1920x1080).
        assertEquals(1080, sel.maxShortSide(Settings.of(2160, 3840), ExportVideoCodec.H264))
        assertEquals(2160, HardwareEncoderSelector(Codecs.phone).maxShortSide(Settings.of(1920, 1080), ExportVideoCodec.H264))
        assertNull(HardwareEncoderSelector(Codecs.catalog()).maxShortSide(Settings.of(), ExportVideoCodec.H264))
    }

    @Test
    fun noEncoderAtAll() {
        val c = HardwareEncoderSelector(Codecs.catalog()).choose(Settings.of())
        assertFalse(c.available)
        assertFalse(c.sizeSupported)
        assertEquals(emptyList<String>(), codes(c))
    }

    @Test
    fun theEncoderThatRanIsLookedUpForTheHardwareFlag() {
        val sel = HardwareEncoderSelector(Codecs.phone)
        assertTrue(sel.isHardware("c2.qti.hevc.encoder"))
        assertFalse(sel.isHardware("c2.android.avc.encoder"))
        assertFalse(sel.isHardware("unknown"))
        assertFalse(sel.isHardware(null))
    }

    @Test
    fun softwareNamesBelowApi29() {
        assertTrue(MediaCodecEncoderCatalog.isSoftwareName("OMX.google.h264.encoder"))
        assertTrue(MediaCodecEncoderCatalog.isSoftwareName("c2.android.avc.encoder"))
        assertFalse(MediaCodecEncoderCatalog.isSoftwareName("OMX.qcom.video.encoder.avc"))
        assertFalse(MediaCodecEncoderCatalog.isSoftwareName("c2.exynos.h264.encoder"))
    }
}
