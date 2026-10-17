@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-11

// Hardware-first video encoder selection (ARCH §14.3, §14.1 "Encoder size and orientation").
// - The device's encoders come from an [EncoderCatalog]: [MediaCodecEncoderCatalog] reads Media3's
//   EncoderUtil (MediaCodecList, the same list DefaultEncoderFactory uses); JVM tests inject lists.
// - [HardwareEncoderSelector.rank] puts hardware-accelerated, non-software-only encoders first and
//   keeps the platform order otherwise. [HardwareEncoderSelector.media3Selector] hands Media3's
//   DefaultEncoderFactory the device's MediaCodecInfos in that order (its own size/bitrate filters
//   and `setEnableFallback(true)` then apply).
// - [HardwareEncoderSelector.choose] predicts what an export will get before it starts: the codec
//   (HEVC falls back to H.264 when no HEVC encoder takes the size: `hevcUnavailable`), the first
//   ranked encoder that takes the size (software → `softwareEncoder`), and whether a portrait size
//   is only taken landscape (the §14.1 retry with rotation metadata: `portraitRetried`). These are
//   the preflight warnings, and the progress warnings from the first sample on.
// - After the export, the encoder that actually ran (ExportResult.videoEncoderName) is looked up
//   with [HardwareEncoderSelector.isHardware] for ExportResult.hardwareEncoder.

package com.vecvel.danaview.editor.engine.export

import android.media.MediaCodecInfo
import android.os.Build
import androidx.annotation.OptIn
import androidx.annotation.RequiresApi
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.EncoderSelector
import androidx.media3.transformer.EncoderUtil
import com.google.common.collect.ImmutableList
import com.vecvel.danaview.editor.engine.pigeon.ExportWarningMsg

/** One video encoder of the device. [supportsSize] answers for a (width, height) frame. */
data class EncoderCandidate(
    val name: String,
    val mimeType: String,
    /** MediaCodecInfo.isHardwareAccelerated (Media3's EncoderUtil heuristic below API 29). */
    val hardware: Boolean,
    /** MediaCodecInfo.isSoftwareOnly (API 29+; name heuristic below). */
    val softwareOnly: Boolean = !hardware,
    val supportsSize: (width: Int, height: Int) -> Boolean = { _, _ -> true },
) {
    /** Whether this encoder counts as hardware for the warnings and ExportResult.hardwareEncoder. */
    val isHardware: Boolean get() = hardware && !softwareOnly
}

/** The device's video encoders per MIME type, in platform order. */
fun interface EncoderCatalog {
    fun encoders(mimeType: String): List<EncoderCandidate>
}

/** [EncoderCatalog] over Media3's EncoderUtil (MediaCodecList REGULAR_CODECS). */
class MediaCodecEncoderCatalog : EncoderCatalog {
    override fun encoders(mimeType: String): List<EncoderCandidate> =
        EncoderUtil.getSupportedEncoders(mimeType).map { info ->
            EncoderCandidate(
                name = info.name,
                mimeType = mimeType,
                hardware = EncoderUtil.isHardwareAccelerated(info, mimeType),
                softwareOnly = softwareOnly(info),
                supportsSize = { w, h -> EncoderUtil.isSizeSupported(info, mimeType, w, h) },
            )
        }

    private fun softwareOnly(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= 29) softwareOnly29(info) else isSoftwareName(info.name)

    @RequiresApi(29)
    private fun softwareOnly29(info: MediaCodecInfo): Boolean = info.isSoftwareOnly

    companion object {
        /** Platform software codec names (below API 29 MediaCodecInfo has no flag). */
        fun isSoftwareName(name: String): Boolean {
            val n = name.lowercase()
            return n.startsWith("omx.google.") || n.startsWith("c2.android.") || n.startsWith("omx.sec.") && n.contains(".sw.") ||
                n.startsWith("c2.google.")
        }
    }
}

/** What an export of given settings will get from the device's encoders (file header). */
data class EncoderChoice(
    /** The codec the settings asked for. */
    val requested: ExportVideoCodec,
    /** The codec that will be written (H.264 when HEVC is unavailable). */
    val codec: ExportVideoCodec,
    /** The first ranked encoder that takes the size (upright, or landscape for a refused portrait). */
    val encoder: EncoderCandidate?,
    /** Portrait output that no encoder takes upright but one takes landscape (§14.1 retry). */
    val portraitRefused: Boolean,
    /** Some encoder takes the size in some orientation. */
    val sizeSupported: Boolean,
) {
    /** An encoder exists for [codec]. */
    val available: Boolean get() = encoder != null

    /** The chosen encoder is hardware accelerated. */
    val hardware: Boolean get() = encoder?.isHardware == true

    /** HEVC was asked for and H.264 will be written. */
    val codecFallback: Boolean get() = codec != requested

    /** Preflight / first progress warnings (codes match ExportStrings.warning on the Dart side). */
    fun warnings(): List<ExportWarningMsg> = buildList {
        if (codecFallback) add(ExportWarnings.hevcUnavailable())
        if (encoder != null && !encoder.isHardware) add(ExportWarnings.softwareEncoder(encoder.name))
        if (portraitRefused) add(ExportWarnings.portraitRetried())
    }
}

/** Hardware-first ranking and prediction over an [EncoderCatalog] (file header). */
class HardwareEncoderSelector(val catalog: EncoderCatalog = MediaCodecEncoderCatalog()) {
    private val cache = HashMap<String, List<EncoderCandidate>>()

    /** The encoders of [mimeType], hardware first (stable). */
    fun ranked(mimeType: String): List<EncoderCandidate> = synchronized(cache) {
        cache.getOrPut(mimeType) { rank(catalog.encoders(mimeType)) }
    }

    /** What an export with [settings] will get (file header). */
    fun choose(settings: EncoderSettings): EncoderChoice {
        val requested = settings.codec
        var codec = requested
        if (requested == ExportVideoCodec.HEVC) {
            val hevc = ranked(ExportVideoCodec.HEVC.mimeType)
            if (hevc.none { takes(it, settings.width, settings.height) || takes(it, settings.height, settings.width) }) {
                codec = ExportVideoCodec.H264
            }
        }
        val list = ranked(codec.mimeType)
        val upright = list.firstOrNull { takes(it, settings.width, settings.height) }
        val rotated = list.firstOrNull { takes(it, settings.height, settings.width) }
        val portraitRefused = settings.isPortrait && upright == null && rotated != null
        val encoder = upright ?: (if (settings.isPortrait) rotated else null) ?: list.firstOrNull()
        return EncoderChoice(requested, codec, encoder, portraitRefused, upright != null || rotated != null)
    }

    /**
     * The largest standard short side (2160, 1440, 1080, 720) at the aspect of [settings] that some
     * encoder of [codec] takes in either orientation, or null when none does.
     */
    fun maxShortSide(settings: EncoderSettings, codec: ExportVideoCodec): Int? {
        val list = ranked(codec.mimeType)
        val long = maxOf(settings.width, settings.height).toDouble()
        val short = settings.shortSide.toDouble()
        for (s in STANDARD_SHORT_SIDES) {
            val l = evenRound(s * long / short)
            val (w, h) = if (settings.isPortrait) s to l else l to s
            if (list.any { takes(it, w, h) || takes(it, h, w) }) return s
        }
        return null
    }

    /** Whether the encoder named [name] is hardware accelerated (null name or unknown: false). */
    fun isHardware(name: String?): Boolean {
        if (name.isNullOrEmpty()) return false
        for (codec in ExportVideoCodec.entries) {
            ranked(codec.mimeType).firstOrNull { it.name == name }?.let { return it.isHardware }
        }
        return false
    }

    /** Media3's EncoderSelector: the device's MediaCodecInfos of a MIME type, hardware first. */
    fun media3Selector(): EncoderSelector = EncoderSelector { mimeType ->
        val infos = EncoderUtil.getSupportedEncoders(mimeType)
        val order = ranked(mimeType).map { it.name }
        ImmutableList.copyOf(
            infos.withIndex().sortedWith(
                compareBy<IndexedValue<MediaCodecInfo>> { order.indexOf(it.value.name).let { i -> if (i < 0) Int.MAX_VALUE else i } }
                    .thenBy { it.index },
            ).map { it.value },
        )
    }

    private fun takes(e: EncoderCandidate, w: Int, h: Int): Boolean = try {
        e.supportsSize(w, h)
    } catch (_: RuntimeException) {
        false
    }

    companion object {
        /** Standard export short sides, largest first (ARCH §14.1 presets). */
        val STANDARD_SHORT_SIDES = intArrayOf(2160, 1440, 1080, 720)

        /** Hardware (and not software-only) encoders first; otherwise the platform order. */
        fun rank(encoders: List<EncoderCandidate>): List<EncoderCandidate> =
            encoders.withIndex().sortedWith(compareBy<IndexedValue<EncoderCandidate>> { if (it.value.isHardware) 0 else 1 }.thenBy { it.index }).map { it.value }

        private fun evenRound(v: Double): Int = (Math.round(v / 2.0) * 2).toInt()
    }
}

/** Export warning codes (ARCH §12.4 ExportWarning; the Dart UI maps them in ExportStrings.warning). */
object ExportWarnings {
    const val SOFTWARE_ENCODER = "softwareEncoder"
    const val HEVC_UNAVAILABLE = "hevcUnavailable"
    const val LAYERS_VS_RESOLUTION = "layersVsResolution"
    const val PORTRAIT_RETRIED = "portraitRetried"
    const val FALLBACK_APPLIED = "fallbackApplied"

    fun softwareEncoder(name: String) = ExportWarningMsg(SOFTWARE_ENCODER, "software video encoder ($name)")

    fun hevcUnavailable() = ExportWarningMsg(HEVC_UNAVAILABLE, "no HEVC encoder takes this size; H.264 is used")

    fun layersVsResolution() = ExportWarningMsg(LAYERS_VS_RESOLUTION, "more layers than the device decodes at once; the export runs in several passes")

    fun portraitRetried() = ExportWarningMsg(PORTRAIT_RETRIED, "portrait size encoded landscape with rotation metadata")

    fun fallbackApplied() = ExportWarningMsg(FALLBACK_APPLIED, "the encoder applied a fallback configuration")

    /** [list] plus [w] unless a warning with its code is already there. */
    fun plus(list: List<ExportWarningMsg>, w: ExportWarningMsg): List<ExportWarningMsg> =
        if (list.any { it.code == w.code }) list else list + w
}
