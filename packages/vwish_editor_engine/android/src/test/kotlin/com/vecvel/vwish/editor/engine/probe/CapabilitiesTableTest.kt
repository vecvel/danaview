// OWNER: AND-02
//
// The editor gate (ARCH §3.2) and the tier table (ARCH §12.5, D-40, AND-01 V-N25) with injected
// device snapshots.

package com.vecvel.vwish.editor.engine.probe

import com.vecvel.vwish.editor.engine.core.Capabilities
import com.vecvel.vwish.editor.engine.core.CodecInventory
import com.vecvel.vwish.editor.engine.core.GlInfo
import com.vecvel.vwish.editor.engine.core.Tiers
import com.vecvel.vwish.editor.engine.pigeon.BackgroundExportKindMsg
import com.vecvel.vwish.editor.engine.pigeon.DeviceTierMsg
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CapabilitiesTableTest {
    // ---- gate ----

    @Test
    fun api28IsTooOld() {
        val caps = Capabilities.compute(Devices.snapshot(api = 28, gl = null))
        assertFalse(caps.supported)
        assertEquals("android_too_old", caps.unsupportedReason)
        assertEquals(0L, caps.maxVisualSequences)
        assertTrue(caps.planVersions.isEmpty())
    }

    @Test
    fun noGles3ContextIsGles3Missing() {
        assertEquals("gles3_missing", Capabilities.gate(Devices.snapshot(gl = GlInfo.NONE)))
        assertEquals("gles3_missing", Capabilities.gate(Devices.snapshot(gl = GlInfo(gles3 = false, maxTextureSize = 4096, yuvTarget = false))))
        assertEquals("gles3_missing", Capabilities.gate(Devices.snapshot(gl = null)))
        val caps = Capabilities.compute(Devices.snapshot(gl = GlInfo.NONE))
        assertFalse(caps.supported)
        assertEquals("gles3_missing", caps.unsupportedReason)
    }

    @Test
    fun lessThanTwoGigabytesIsInsufficientMemory() {
        // A 1.5 GB device reports about 1.38 GiB.
        val caps = Capabilities.compute(Devices.snapshot(totalRam = (1.38 * Devices.GIB).toLong()))
        assertFalse(caps.supported)
        assertEquals("insufficient_memory", caps.unsupportedReason)
        // 1 GB Go device.
        assertEquals("insufficient_memory", Capabilities.gate(Devices.snapshot(gb = 1, lowRam = true)))
    }

    @Test
    fun gateOrderIsApiThenGlesThenMemory() {
        assertEquals("android_too_old", Capabilities.gate(Devices.snapshot(api = 28, gl = GlInfo.NONE, gb = 1)))
        assertEquals("gles3_missing", Capabilities.gate(Devices.snapshot(api = 29, gl = GlInfo.NONE, gb = 1)))
        assertEquals("insufficient_memory", Capabilities.gate(Devices.snapshot(api = 29, gb = 1)))
        assertNull(Capabilities.gate(Devices.snapshot(api = 29, gb = 2)))
    }

    @Test
    fun twoGigabyteDeviceAtApi29IsSupportedOnTheMinimalTier() {
        val caps = Capabilities.compute(Devices.snapshot(api = 29, gb = 2))
        assertTrue(caps.supported)
        assertNull(caps.unsupportedReason)
        assertEquals(DeviceTierMsg.MINIMAL, caps.tier)
    }

    // ---- tiers ----

    @Test
    fun nominalRamRoundsReportedMemoryUp() {
        assertEquals(1.5, Tiers.nominalRamGb((1.38 * Devices.GIB).toLong()), 0.0)
        assertEquals(2.0, Tiers.nominalRamGb((1.85 * Devices.GIB).toLong()), 0.0)
        assertEquals(3.0, Tiers.nominalRamGb((2.75 * Devices.GIB).toLong()), 0.0)
        assertEquals(4.0, Tiers.nominalRamGb((3.7 * Devices.GIB).toLong()), 0.0)
        // The Windows lane's emulator AVDs: 4013928 kB MemTotal.
        assertEquals(4.0, Tiers.nominalRamGb(4_013_928L * 1024L), 0.0)
        assertEquals(6.0, Tiers.nominalRamGb((5.5 * Devices.GIB).toLong()), 0.0)
        assertEquals(6.0, Tiers.nominalRamGb((4.6 * Devices.GIB).toLong()), 0.0)
        assertEquals(8.0, Tiers.nominalRamGb((7.4 * Devices.GIB).toLong()), 0.0)
        assertEquals(12.0, Tiers.nominalRamGb((11.2 * Devices.GIB).toLong()), 0.0)
        assertEquals(40.0, Tiers.nominalRamGb((39.5 * Devices.GIB).toLong()), 0.0)
        assertEquals(0.0, Tiers.nominalRamGb(0), 0.0)
    }

    @Test
    fun tierTable() {
        assertEquals(DeviceTierMsg.MINIMAL, Devices.snapshot(gb = 2).tier)
        assertEquals(DeviceTierMsg.LOW, Devices.snapshot(gb = 3).tier)
        assertEquals(DeviceTierMsg.LOW, Devices.snapshot(gb = 4).tier)
        assertEquals(DeviceTierMsg.MID, Devices.snapshot(gb = 6).tier)
        assertEquals(DeviceTierMsg.HIGH, Devices.snapshot(gb = 8).tier)
        assertEquals(DeviceTierMsg.HIGH, Devices.snapshot(gb = 12).tier)
        // Android Go devices are minimal whatever their RAM (D-40).
        assertEquals(DeviceTierMsg.MINIMAL, Devices.snapshot(gb = 4, lowRam = true).tier)
    }

    @Test
    fun minimalTier() {
        val caps = Capabilities.compute(Devices.snapshot(gb = 2))
        assertEquals(DeviceTierMsg.MINIMAL, caps.tier)
        assertTrue(caps.lowMemoryDevice)
        assertTrue(caps.proxiesRecommended)
        assertTrue(caps.h264Encode)
        assertFalse("minimal exports H.264 only", caps.hevcEncode)
        assertFalse(caps.hardwareHevc)
        assertEquals(1920L, caps.maxExportWidth)
        assertEquals(1080L, caps.maxExportHeight)
        assertEquals(mapOf(720L to 30L, 1080L to 30L), caps.maxFpsByHeight)
        assertEquals(2L, caps.maxConcurrentVideoLayers)
        assertEquals(2L, caps.maxVisualSequences)
        assertEquals(640L, caps.maxPreviewLongSide)
    }

    @Test
    fun lowTier() {
        val caps = Capabilities.compute(Devices.snapshot(gb = 4))
        assertEquals(DeviceTierMsg.LOW, caps.tier)
        assertFalse(caps.lowMemoryDevice)
        assertFalse(caps.proxiesRecommended)
        assertTrue(caps.hevcEncode)
        assertEquals(1920L to 1080L, caps.maxExportWidth to caps.maxExportHeight)
        assertEquals(mapOf(720L to 60L, 1080L to 30L), caps.maxFpsByHeight)
        assertEquals(3L, caps.maxConcurrentVideoLayers)
        assertEquals(3L, caps.maxVisualSequences)
        assertEquals(960L, caps.maxPreviewLongSide)
    }

    @Test
    fun midTier() {
        val caps = Capabilities.compute(Devices.snapshot(gb = 6))
        assertEquals(DeviceTierMsg.MID, caps.tier)
        assertEquals(2560L to 1440L, caps.maxExportWidth to caps.maxExportHeight)
        assertEquals(mapOf(1080L to 60L, 1440L to 30L), caps.maxFpsByHeight)
        assertEquals(4L, caps.maxConcurrentVideoLayers)
        assertEquals(4L, caps.maxVisualSequences)
        assertEquals(1280L, caps.maxPreviewLongSide)
    }

    @Test
    fun highTier() {
        val caps = Capabilities.compute(Devices.snapshot(gb = 8))
        assertEquals(DeviceTierMsg.HIGH, caps.tier)
        assertEquals(3840L to 2160L, caps.maxExportWidth to caps.maxExportHeight)
        assertEquals(mapOf(1440L to 60L, 2160L to 60L), caps.maxFpsByHeight)
        assertEquals(6L, caps.maxConcurrentVideoLayers)
        assertEquals(6L, caps.maxVisualSequences)
        assertEquals(1920L, caps.maxPreviewLongSide)
    }

    @Test
    fun codecInstancesCapLayersAndSequences() {
        // 8 instances: layers min(6, 7) = 6, sequences min(6, (8 - 2) / 2 = 3) = 3 (AND-01 V-N25).
        val eight = Capabilities.compute(Devices.snapshot(gb = 8, codecs = Devices.phoneCodecs(instances = 8)))
        assertEquals(6L, eight.maxConcurrentVideoLayers)
        assertEquals(3L, eight.maxVisualSequences)
        // 4 instances: layers 3, sequences 1.
        val four = Capabilities.compute(Devices.snapshot(gb = 8, codecs = Devices.phoneCodecs(instances = 4)))
        assertEquals(3L, four.maxConcurrentVideoLayers)
        assertEquals(1L, four.maxVisualSequences)
        // Never below 1.
        val two = Capabilities.compute(Devices.snapshot(gb = 8, codecs = Devices.phoneCodecs(instances = 2)))
        assertEquals(1L, two.maxConcurrentVideoLayers)
        assertEquals(1L, two.maxVisualSequences)
        // The emulator's goldfish decoder reports 32: no cap below the table.
        val many = Capabilities.compute(Devices.snapshot(gb = 4, codecs = Devices.phoneCodecs(instances = 32)))
        assertEquals(3L, many.maxConcurrentVideoLayers)
        assertEquals(3L, many.maxVisualSequences)
        // Unknown (0) does not cap.
        val unknown = Capabilities.compute(Devices.snapshot(gb = 6, codecs = Devices.phoneCodecs(instances = 0)))
        assertEquals(4L, unknown.maxConcurrentVideoLayers)
        assertEquals(4L, unknown.maxVisualSequences)
    }

    @Test
    fun softwareHevcEncoderIsNotOffered() {
        val codecs = CodecInventory(
            listOf(
                Devices.codec("video/avc", encoder = false),
                Devices.codec("video/avc", encoder = true, hardware = false),
                Devices.codec("video/hevc", encoder = true, hardware = false),
            ),
        )
        val caps = Capabilities.compute(Devices.snapshot(gb = 8, codecs = codecs))
        assertTrue(caps.h264Encode)
        assertFalse(caps.hardwareH264)
        assertFalse(caps.hevcEncode)
        assertFalse(caps.hardwareHevc)
    }

    @Test
    fun exportSizeFollowsTheH264Encoder() {
        val no4k = CodecInventory(
            listOf(Devices.codec("video/avc", encoder = false), Devices.codec("video/avc", encoder = true, uhd = false)),
        )
        val caps = Capabilities.compute(Devices.snapshot(gb = 8, codecs = no4k))
        assertEquals(2560L to 1440L, caps.maxExportWidth to caps.maxExportHeight)
        assertEquals(mapOf(1440L to 60L), caps.maxFpsByHeight)
        val only720 = CodecInventory(
            listOf(
                Devices.codec("video/avc", encoder = false),
                Devices.codec("video/avc", encoder = true, uhd = false).copy(supports1080p = false),
            ),
        )
        val small = Capabilities.compute(Devices.snapshot(gb = 4, codecs = only720))
        assertEquals(1280L to 720L, small.maxExportWidth to small.maxExportHeight)
        assertEquals(mapOf(720L to 60L), small.maxFpsByHeight)
    }

    @Test
    fun noHardwareDecoderRecommendsProxies() {
        val codecs = CodecInventory(
            listOf(Devices.codec("video/avc", encoder = false, hardware = false), Devices.codec("video/avc", encoder = true)),
        )
        assertTrue(Capabilities.compute(Devices.snapshot(gb = 8, codecs = codecs)).proxiesRecommended)
    }

    @Test
    fun fixedAndroidValues() {
        val caps = Capabilities.compute(Devices.snapshot(gb = 6, gl = GlInfo(gles3 = true, maxTextureSize = 8192, yuvTarget = false)))
        assertTrue(caps.supported)
        assertEquals(8192L, caps.maxTextureSize)
        assertFalse(caps.movContainer)
        assertEquals(BackgroundExportKindMsg.FOREGROUND_SERVICE, caps.backgroundKind)
        assertTrue(caps.backgroundGpu)
        assertTrue(caps.voiceRecording)
        assertTrue(caps.holdFrame)
        assertTrue("AND-01 V-N15", caps.fpsUpconversion)
        assertTrue(caps.externalDrop)
        assertEquals(0.1, caps.minSpeed, 0.0)
        assertEquals(10.0, caps.maxSpeed, 0.0)
        assertEquals(4.0, caps.maxAudioSpeed, 0.0)
        assertEquals(65L, caps.maxLutSize)
        assertEquals(listOf(1L), caps.planVersions)
        assertFalse(Capabilities.compute(Devices.snapshot(microphone = false)).voiceRecording)
    }
}
