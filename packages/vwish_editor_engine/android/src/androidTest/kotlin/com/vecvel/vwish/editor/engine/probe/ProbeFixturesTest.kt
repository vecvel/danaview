@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-02
//
// Probe fields against the ENG-05 manifest on the device/emulator, for every fixture (including
// the MKV and WebM), through a file path and through a content:// URI (the engine's FileProvider).

package com.vecvel.vwish.editor.engine.probe

import android.util.Log
import androidx.annotation.OptIn
import androidx.core.content.FileProvider
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.vwish.editor.engine.core.CodecInventory
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.GlInfo
import com.vecvel.vwish.editor.engine.core.ToneMappingSupport
import com.vecvel.vwish.editor.engine.harness.FixtureTree
import com.vecvel.vwish.editor.engine.harness.TestFixtures
import com.vecvel.vwish.editor.engine.media.Probe
import com.vecvel.vwish.editor.engine.pigeon.ColorTransferMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaKindMsg
import com.vecvel.vwish.editor.engine.pigeon.ProbeMsg
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ProbeFixturesTest {
    companion object {
        private const val TAG = "VwishProbeTest"
        private lateinit var codecs: CodecInventory
        private lateinit var toneMapping: ToneMappingSupport
        private lateinit var files: JSONObject

        @BeforeClass
        @JvmStatic
        fun setUp() {
            codecs = CodecInventory.load()
            toneMapping = ToneMappingSupport(GlInfo.probe().yuvTarget, android.os.Build.VERSION.SDK_INT)
            files = JSONObject(TestFixtures.readText(FixtureTree.ENGINE, "media/manifest.json")).getJSONObject("files")
        }
    }

    private fun probe(name: String): ProbeMsg {
        val file = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")
        val started = System.nanoTime()
        val result = Probe.probe(TestFixtures.targetContext, file.absolutePath, codecs, toneMapping)
        Log.i(TAG, "$name probed in ${(System.nanoTime() - started) / 1_000_000} ms: kind=${result.kind} editable=${result.editable} issues=${result.issues}")
        return result
    }

    private fun JSONObject.optObject(key: String): JSONObject? = if (isNull(key)) null else optJSONObject(key)

    /** Checks the generic manifest fields of an audio/video fixture. */
    private fun checkAv(name: String, probe: ProbeMsg) {
        val entry = files.getJSONObject(name)
        val video = entry.optObject("video")
        val audio = entry.optObject("audio")
        val durationUs = (entry.getDouble("durationSeconds") * 1_000_000).toLong()
        assertTrue("$name duration ${probe.durationUs} vs $durationUs", abs(probe.durationUs - durationUs) <= 60_000)
        assertEquals("$name hasVideo", video != null, probe.hasVideo)
        assertEquals("$name hasAudio", audio != null, probe.hasAudio)
        assertEquals("$name kind", if (video != null) MediaKindMsg.VIDEO else MediaKindMsg.AUDIO, probe.kind)
        assertEquals("$name audioStreams", if (audio != null) 1L else 0L, probe.audioStreams)
        if (video != null) {
            val width = if (video.has("displayWidth")) video.getLong("displayWidth") else video.getLong("width")
            val height = if (video.has("displayHeight")) video.getLong("displayHeight") else video.getLong("height")
            assertEquals("$name width", width, probe.width)
            assertEquals("$name height", height, probe.height)
            assertEquals("$name rotation", video.getLong("rotationDegrees"), probe.rotation)
            val codec = when (val c = video.getString("codec")) {
                "h264", "hevc", "vp9" -> c
                else -> fail("unexpected codec $c")
            }
            assertEquals("$name videoCodec", codec, probe.videoCodec)
            val vfr = video.optBoolean("variableFrameRate", false)
            assertEquals("$name VFR", vfr, probe.variableFrameRate)
            if (!vfr && !video.isNull("fps")) {
                assertEquals("$name nominalFrameRate", video.getLong("fps"), probe.nominalFrameRate)
                assertEquals("$name nominalFps", video.getDouble("fps"), probe.nominalFps!!, 0.05)
            }
            if (vfr) assertTrue(probe.issues.contains("variable_frame_rate"))
        } else {
            assertNull(probe.width)
            assertNull(probe.videoCodec)
        }
        if (audio != null) {
            assertEquals("$name audioCodec", when (val c = audio.getString("codec")) {
                "aac", "opus", "pcm_s16le" -> c
                else -> fail("unexpected audio codec $c")
            }, probe.audioCodec)
            assertEquals("$name channels", audio.getLong("channels"), probe.channels)
            assertEquals("$name sampleRate", audio.getLong("sampleRate"), probe.sampleRate)
        }
        assertEquals("$name sizeBytes", entry.getLong("bytes"), probe.sizeBytes)
    }

    @Test
    fun frameCounters() {
        for (name in listOf(
            "frame_counter_1080p30.mp4", "frame_counter_720p24.mp4", "frame_counter_720p25.mp4",
            "frame_counter_720p48.mp4", "frame_counter_720p60.mp4",
        )) {
            val probe = probe(name)
            checkAv(name, probe)
            assertEquals("mp4", probe.container)
            assertEquals(ColorTransferMsg.SDR, probe.transfer)
            assertEquals(8L, probe.bitDepth)
            assertTrue("$name editable", probe.editable)
            assertTrue(probe.issues.isEmpty())
        }
    }

    @Test
    fun clapAndToneUnderVideo() {
        for (name in listOf("clap_flash_av.mp4", "tone_under_video.mp4")) {
            val probe = probe(name)
            checkAv(name, probe)
            assertTrue(probe.editable)
        }
    }

    @Test
    fun rotatedSourceReportsDisplaySize() {
        val probe = probe("rotated_90.mov")
        checkAv("rotated_90.mov", probe)
        assertEquals("mov", probe.container)
        assertEquals(90L, probe.rotation)
        assertEquals(720L to 1280L, probe.width to probe.height)
    }

    @Test
    fun vfrIsDetected() {
        val probe = probe("vfr_720p.mp4")
        checkAv("vfr_720p.mp4", probe)
        assertTrue(probe.variableFrameRate)
        assertTrue(probe.editable)
    }

    @Test
    fun hlgIsHdrTenBit() {
        val probe = probe("hlg_10bit_720p.mov")
        checkAv("hlg_10bit_720p.mov", probe)
        assertEquals(ColorTransferMsg.HLG, probe.transfer)
        assertEquals(10L, probe.bitDepth)
        assertTrue(probe.issues.containsAll(listOf("hdr", "high_bit_depth")))
        // Editable exactly when this device has a 10-bit HEVC decoder and a tone map (AND-01 V-N5).
        val tenBit = codecs.hasTenBitDecoder("video/hevc")
        val toneMap = toneMapping.glYuvTarget || toneMapping.apiLevel >= 31
        Log.i(TAG, "HLG: 10-bit HEVC decoder=$tenBit GL_EXT_YUV_target=${toneMapping.glYuvTarget} api=${toneMapping.apiLevel}")
        assertEquals(tenBit && toneMap, probe.editable)
        if (!tenBit) assertTrue(probe.issues.contains("codec_unsupported"))
    }

    @Test
    fun matroskaAndWebmAreEditableWithDecoders() {
        val mkv = probe("sample_h264_aac.mkv")
        checkAv("sample_h264_aac.mkv", mkv)
        assertEquals("matroska", mkv.container)
        assertEquals(25L, mkv.nominalFrameRate)
        assertTrue("MKV is editable on Android (ARCH §15)", mkv.editable)
        val webm = probe("sample_vp9_opus.webm")
        checkAv("sample_vp9_opus.webm", webm)
        assertEquals("webm", webm.container)
        assertEquals(25L, webm.nominalFrameRate)
        assertEquals(codecs.hasDecoder(androidx.media3.common.Format.Builder().setSampleMimeType("video/x-vnd.on2.vp9").setWidth(640).setHeight(360).build()), webm.editable)
        assertTrue("the emulator has VP9 and Opus decoders", webm.editable)
    }

    @Test
    fun audioFiles() {
        for (name in listOf("speech_10s.m4a", "surround_5_1.m4a", "tone_1khz.wav", "tone_440hz.wav", "stereo_440l_880r.wav")) {
            val probe = probe(name)
            checkAv(name, probe)
            assertTrue(probe.editable)
        }
        assertEquals("m4a", probe("speech_10s.m4a").container)
        assertEquals("wav", probe("tone_1khz.wav").container)
        assertEquals(6L, probe("surround_5_1.m4a").channels)
    }

    @Test
    fun images() {
        val jpeg = probe("still_4k.jpg")
        assertEquals(MediaKindMsg.IMAGE, jpeg.kind)
        assertEquals(3840L to 2160L, jpeg.width to jpeg.height)
        assertEquals("jpeg", jpeg.container)
        assertTrue(jpeg.editable)
        val png = probe("alpha.png")
        assertEquals(MediaKindMsg.IMAGE, png.kind)
        assertEquals(512L to 512L, png.width to png.height)
        assertEquals("png", png.container)
    }

    @Test
    fun contentUriIsProbedReadOnly() {
        val source = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/sample_h264_aac.mkv")
        val work = File(TestFixtures.targetContext.cacheDir, "vwish/editor/work/probe-test").apply { mkdirs() }
        val copy = File(work, "sample.mkv")
        source.copyTo(copy, overwrite = true)
        val before = copy.lastModified()
        val uri = FileProvider.getUriForFile(
            TestFixtures.targetContext, TestFixtures.targetContext.packageName + EngineContext.FILE_PROVIDER_SUFFIX, copy,
        )
        val probe = Probe.probe(TestFixtures.targetContext, uri.toString(), codecs, toneMapping)
        checkAv("sample_h264_aac.mkv", probe)
        assertEquals("matroska", probe.container)
        assertEquals(before, copy.lastModified())
        copy.delete()
    }

    @Test
    fun missingFileIsMediaOffline() {
        val missing = File(TestFixtures.targetContext.cacheDir, "vwish_test_fixtures/missing.mp4")
        try {
            Probe.probe(TestFixtures.targetContext, missing.absolutePath, codecs, toneMapping)
            fail("expected mediaOffline")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.mediaOffline, e.code)
            assertFalse(e.message.orEmpty().contains("/"))
        }
    }
}
