@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-02
//
// Compatibility verdicts with injected codecs and tone-mapping facts (ARCH §15, AND-01 V-N5).

package com.vecvel.danaview.editor.engine.probe

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.ColorInfo
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import com.vecvel.danaview.editor.engine.core.CodecInventory
import com.vecvel.danaview.editor.engine.core.ToneMappingSupport
import com.vecvel.danaview.editor.engine.media.Compatibility
import com.vecvel.danaview.editor.engine.media.TrackFormats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompatibilityRulesTest {
    private val h264 = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H264).setWidth(1280).setHeight(720).build()
    private val vp9 = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_VP9).setWidth(640).setHeight(360).build()
    private val aac = Format.Builder().setSampleMimeType(MimeTypes.AUDIO_AAC).setChannelCount(2).setSampleRate(48000).build()
    private val ac3 = Format.Builder().setSampleMimeType(MimeTypes.AUDIO_AC3).setChannelCount(6).setSampleRate(48000).build()
    private val hlg = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H265).setWidth(1280).setHeight(720)
        .setColorInfo(ColorInfo.Builder().setColorTransfer(C.COLOR_TRANSFER_HLG).setLumaBitdepth(10).build()).build()

    private val api29NoYuv = ToneMappingSupport(glYuvTarget = false, apiLevel = 29)
    private val api29Yuv = ToneMappingSupport(glYuvTarget = true, apiLevel = 29)
    private val api31 = ToneMappingSupport(glYuvTarget = false, apiLevel = 31)

    @Test
    fun sdrVideoWithADecoderIsEditable() {
        val verdict = Compatibility.decide(TrackFormats(listOf(h264), listOf(aac)), Devices.phoneCodecs(), api29NoYuv)
        assertTrue(verdict.editable)
    }

    @Test
    fun webmIsEditableWhenItsDecodersExist() {
        val opus = Format.Builder().setSampleMimeType(MimeTypes.AUDIO_OPUS).build()
        assertTrue(Compatibility.decide(TrackFormats(listOf(vp9), listOf(opus)), Devices.phoneCodecs(), api29NoYuv).editable)
        val noVp9 = CodecInventory(listOf(Devices.codec("video/avc", encoder = false)))
        val refused = Compatibility.decide(TrackFormats(listOf(vp9), listOf(opus)), noVp9, api29NoYuv)
        assertFalse(refused.editable)
        assertEquals("codec_unsupported", refused.code)
    }

    @Test
    fun hdrNeedsAToneMap() {
        // OpenGL tone map: GL_EXT_YUV_target + a 10-bit decoder.
        assertTrue(Compatibility.decide(TrackFormats(listOf(hlg), emptyList()), Devices.phoneCodecs(), api29Yuv).editable)
        // MediaCodec tone map on API 31+.
        assertTrue(Compatibility.decide(TrackFormats(listOf(hlg), emptyList()), Devices.phoneCodecs(), api31).editable)
        // Neither: refused with hdr_unsupported.
        val refused = Compatibility.decide(TrackFormats(listOf(hlg), emptyList()), Devices.phoneCodecs(), api29NoYuv)
        assertFalse(refused.editable)
        assertEquals("hdr_unsupported", refused.code)
    }

    @Test
    fun hdrWithoutATenBitDecoderIsCodecUnsupported() {
        // The emulator case of AND-01: no HEVC Main10 decoder.
        val verdict = Compatibility.decide(TrackFormats(listOf(hlg), emptyList()), Devices.phoneCodecs(tenBitHevc = false), api31)
        assertFalse(verdict.editable)
        assertEquals("codec_unsupported", verdict.code)
    }

    @Test
    fun protectedContentIsRefused() {
        val verdict = Compatibility.decide(TrackFormats(listOf(h264), listOf(aac), protected = true), Devices.phoneCodecs(), api31)
        assertFalse(verdict.editable)
        assertEquals("protected_content", verdict.code)
    }

    @Test
    fun audioFileWithoutADecoderIsRefusedButAVideoKeepsItsPicture() {
        val audioOnly = Compatibility.decide(TrackFormats(emptyList(), listOf(ac3)), Devices.phoneCodecs(), api31)
        assertFalse(audioOnly.editable)
        assertEquals("codec_unsupported", audioOnly.code)
        assertTrue(Compatibility.decide(TrackFormats(listOf(h264), listOf(ac3)), Devices.phoneCodecs(), api31).editable)
    }

    @Test
    fun rawPcmNeedsNoDecoder() {
        val pcm = Format.Builder().setSampleMimeType(MimeTypes.AUDIO_RAW).setPcmEncoding(C.ENCODING_PCM_16BIT).build()
        assertTrue(Compatibility.decide(TrackFormats(emptyList(), listOf(pcm)), CodecInventory(emptyList()), api31).editable)
    }

    @Test
    fun noTracksIsRefused() {
        val verdict = Compatibility.decide(TrackFormats(emptyList(), emptyList()), Devices.phoneCodecs(), api31)
        assertFalse(verdict.editable)
        assertEquals("codec_unsupported", verdict.code)
    }
}
