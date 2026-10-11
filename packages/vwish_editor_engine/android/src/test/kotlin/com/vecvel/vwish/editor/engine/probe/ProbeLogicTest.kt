// OWNER: AND-02
//
// Pure probe logic: container sniffing (on the ENG-05 fixture bytes), frame-rate/VFR measurement
// (on the vfr_720p manifest PTS), codec names, bit depth, thermal mapping and GL version parsing.

package com.vecvel.vwish.editor.engine.probe

import androidx.media3.common.C
import androidx.media3.common.ColorInfo
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import com.vecvel.vwish.editor.engine.core.GlInfo
import com.vecvel.vwish.editor.engine.core.ThermalLevels
import com.vecvel.vwish.editor.engine.harness.FixtureTree
import com.vecvel.vwish.editor.engine.harness.JvmFixtures
import com.vecvel.vwish.editor.engine.media.CodecNames
import com.vecvel.vwish.editor.engine.media.FrameRateFacts
import com.vecvel.vwish.editor.engine.media.SniffedContainer
import com.vecvel.vwish.editor.engine.media.VideoFormats
import com.vecvel.vwish.editor.engine.pigeon.ColorTransferMsg
import com.vecvel.vwish.editor.engine.pigeon.ThermalLevelMsg
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ProbeLogicTest {
    private fun media(name: String): File = JvmFixtures.file(FixtureTree.ENGINE, "media/$name")

    private fun head(name: String): ByteArray = media(name).inputStream().use { input ->
        val buffer = ByteArray(64)
        val n = input.read(buffer)
        buffer.copyOf(maxOf(0, n))
    }

    @Test
    fun sniffsEveryFixtureContainer() {
        val expected = mapOf(
            "frame_counter_1080p30.mp4" to SniffedContainer.MP4,
            "clap_flash_av.mp4" to SniffedContainer.MP4,
            "hlg_10bit_720p.mov" to SniffedContainer.MOV,
            "rotated_90.mov" to SniffedContainer.MOV,
            "sample_h264_aac.mkv" to SniffedContainer.MATROSKA,
            "sample_vp9_opus.webm" to SniffedContainer.WEBM,
            "speech_10s.m4a" to SniffedContainer.M4A,
            "surround_5_1.m4a" to SniffedContainer.M4A,
            "tone_1khz.wav" to SniffedContainer.WAV,
            "still_4k.jpg" to SniffedContainer.JPEG,
            "alpha.png" to SniffedContainer.PNG,
        )
        for ((name, container) in expected) {
            assertEquals(name, container, SniffedContainer.sniff(head(name), name.substringAfterLast('.')))
        }
        // Content URIs have no extension; their MIME type is the hint.
        assertEquals(SniffedContainer.MATROSKA, SniffedContainer.sniff(head("sample_h264_aac.mkv"), "video/x-matroska"))
        assertEquals(SniffedContainer.MOV, SniffedContainer.sniff(head("rotated_90.mov"), "video/quicktime"))
        assertEquals("matroska", SniffedContainer.MATROSKA.wireName)
        assertTrue(SniffedContainer.JPEG.isImage)
        assertFalse(SniffedContainer.WEBM.isImage)
    }

    @Test
    fun sniffFallsBackToTheHint() {
        assertEquals(SniffedContainer.MP3, SniffedContainer.sniff(ByteArray(0), "audio/mpeg"))
        assertEquals(SniffedContainer.UNKNOWN, SniffedContainer.sniff(ByteArray(0), null))
        assertEquals(SniffedContainer.WEBM, SniffedContainer.fromHint("webm"))
    }

    @Test
    fun constantFrameRateInDecodeOrder() {
        // 30 fps with B-frame decode order (I P B B ...).
        val pts = longArrayOf(0, 100_000, 33_333, 66_667, 200_000, 133_333, 166_667, 233_333)
        val facts = FrameRateFacts.measure(pts)
        assertFalse(facts.variableFrameRate)
        assertEquals(30.0, facts.averageFps!!, 0.01)
        assertEquals(30L, facts.nominalFrameRate)
    }

    @Test
    fun ntscRatesRoundToTheProjectRate() {
        val pts = LongArray(60) { (it * 1_001_000_000L / 30_000L) }
        val facts = FrameRateFacts.measure(pts)
        assertEquals(29.97, facts.averageFps!!, 0.01)
        assertEquals(30L, facts.nominalFrameRate)
        assertFalse(facts.variableFrameRate)
    }

    @Test
    fun vfrFixtureIsVariable() {
        val manifest = JSONObject(media("manifest.json").readText())
        val video = manifest.getJSONObject("files").getJSONObject("vfr_720p.mp4").getJSONObject("video")
        val ticks = video.getJSONArray("ptsTicks")
        val timescale = video.getLong("ptsTimescale")
        val pts = LongArray(ticks.length()) { ticks.getLong(it) * 1_000_000L / timescale }
        val facts = FrameRateFacts.measure(pts)
        assertTrue(facts.variableFrameRate)
        assertTrue(facts.averageFps!! in 20.0..30.0)
    }

    @Test
    fun tooFewSamplesUseTheContainerRate() {
        assertEquals(25.0, FrameRateFacts.measure(longArrayOf(0), 25f).averageFps!!, 0.0)
        assertNull(FrameRateFacts.measure(LongArray(0)).averageFps)
        assertNull(FrameRateFacts.measure(LongArray(0)).nominalFrameRate)
    }

    @Test
    fun codecNamesMatchIos() {
        assertEquals("h264", CodecNames.of(MimeTypes.VIDEO_H264))
        assertEquals("hevc", CodecNames.of(MimeTypes.VIDEO_H265))
        assertEquals("vp9", CodecNames.of(MimeTypes.VIDEO_VP9))
        assertEquals("aac", CodecNames.of(MimeTypes.AUDIO_AAC))
        assertEquals("opus", CodecNames.of(MimeTypes.AUDIO_OPUS))
        assertEquals("pcm_s16le", CodecNames.of(MimeTypes.AUDIO_RAW, C.ENCODING_PCM_16BIT))
        assertEquals("pcm_f32le", CodecNames.of(MimeTypes.AUDIO_RAW, C.ENCODING_PCM_FLOAT))
        assertNull(CodecNames.of(null))
    }

    @Test
    fun bitDepthAndTransfer() {
        val hlg = Format.Builder()
            .setSampleMimeType(MimeTypes.VIDEO_H265)
            .setColorInfo(ColorInfo.Builder().setColorTransfer(C.COLOR_TRANSFER_HLG).setLumaBitdepth(10).build())
            .build()
        assertEquals(10, VideoFormats.bitDepth(hlg))
        assertEquals(ColorTransferMsg.HLG, VideoFormats.transfer(hlg))
        val main10 = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H265).setCodecs("hvc1.2.4.L93.B0").build()
        assertEquals(10, VideoFormats.bitDepth(main10))
        val vp9p2 = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_VP9).setCodecs("vp09.02.10.10").build()
        assertEquals(10, VideoFormats.bitDepth(vp9p2))
        val pq = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H265)
            .setColorInfo(ColorInfo.Builder().setColorTransfer(C.COLOR_TRANSFER_ST2084).build()).build()
        assertEquals(ColorTransferMsg.PQ, VideoFormats.transfer(pq))
        assertEquals(10, VideoFormats.bitDepth(pq))
        val sdr = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H264).setCodecs("avc1.640028").build()
        assertEquals(8, VideoFormats.bitDepth(sdr))
        assertEquals(ColorTransferMsg.SDR, VideoFormats.transfer(sdr))
    }

    @Test
    fun thermalMappingMatchesAi06() {
        assertEquals(ThermalLevelMsg.NOMINAL, ThermalLevels.map(0))
        assertEquals(ThermalLevelMsg.NOMINAL, ThermalLevels.map(1))
        assertEquals(ThermalLevelMsg.FAIR, ThermalLevels.map(2))
        assertEquals(ThermalLevelMsg.SERIOUS, ThermalLevels.map(3))
        assertEquals(ThermalLevelMsg.CRITICAL, ThermalLevels.map(4))
        assertEquals(ThermalLevelMsg.CRITICAL, ThermalLevels.map(5))
        assertEquals(ThermalLevelMsg.CRITICAL, ThermalLevels.map(6))
        assertNull(ThermalLevels.map(-1))
    }

    @Test
    fun glesVersionParsing() {
        assertEquals(3, GlInfo.parseGlesMajor("OpenGL ES 3.2 (ANGLE 2.1)"))
        assertEquals(2, GlInfo.parseGlesMajor("OpenGL ES 2.0 build 1.2"))
        assertEquals(0, GlInfo.parseGlesMajor(null))
    }
}
