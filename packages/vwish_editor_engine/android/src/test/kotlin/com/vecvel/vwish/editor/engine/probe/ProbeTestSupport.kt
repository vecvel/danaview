// OWNER: AND-02
//
// Injected device snapshots for the AND-02 JVM tests (tier table, gate, compatibility rules).

package com.vecvel.vwish.editor.engine.probe

import com.vecvel.vwish.editor.engine.core.CodecEntry
import com.vecvel.vwish.editor.engine.core.CodecInventory
import com.vecvel.vwish.editor.engine.core.DeviceSnapshot
import com.vecvel.vwish.editor.engine.core.GlInfo

object Devices {
    const val GIB = 1024L * 1024L * 1024L

    /** totalMem as phones report it for a [gb] GB device (about 92 % of the marketing size). */
    fun reportedRam(gb: Int): Long = (gb * GIB * 0.92).toLong()

    fun codec(
        mime: String,
        encoder: Boolean,
        hardware: Boolean = true,
        instances: Int = 16,
        uhd: Boolean = true,
        tenBit: Boolean = false,
        name: String = "c2.test.${mime.substringAfter('/')}.${if (encoder) "encoder" else "decoder"}",
    ) = CodecEntry(name, mime, encoder, hardware, instances, supports1080p = true, supports2160p = uhd, tenBit = tenBit)

    /** A typical phone: hardware H.264/HEVC decoders and encoders, AAC/Opus decoders. */
    fun phoneCodecs(instances: Int = 16, hevcEncoder: Boolean = true, tenBitHevc: Boolean = true) = CodecInventory(
        listOfNotNull(
            codec("video/avc", encoder = false, instances = instances),
            codec("video/hevc", encoder = false, instances = instances, tenBit = tenBitHevc),
            codec("video/x-vnd.on2.vp9", encoder = false, instances = instances),
            codec("audio/mp4a-latm", encoder = false),
            codec("audio/opus", encoder = false),
            codec("video/avc", encoder = true),
            if (hevcEncoder) codec("video/hevc", encoder = true) else null,
        ),
    )

    fun snapshot(
        gb: Int = 6,
        api: Int = 35,
        lowRam: Boolean = false,
        gl: GlInfo? = GlInfo(gles3 = true, maxTextureSize = 16384, yuvTarget = true),
        codecs: CodecInventory = phoneCodecs(),
        totalRam: Long = reportedRam(gb),
        microphone: Boolean = true,
    ) = DeviceSnapshot(
        apiLevel = api,
        totalRamBytes = totalRam,
        lowRamDevice = lowRam,
        soc = "test",
        gl = gl,
        codecs = codecs,
        microphone = microphone,
    )
}
