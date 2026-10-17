@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-11

// Engine-level encode settings of one export (ARCH §12.4 EncodeSettings, §14.1, §14.3). Dart's
// CORE-33 has already applied the presets, capability clamps and the auto-bitrate table, so this
// class only turns EncodeSettingsMsg into what Transformer needs:
// - video MIME (H.264 or HEVC; HEVC falls back to H.264 when the device has no HEVC encoder at all,
//   with the `hevcUnavailable` warning, HardwareEncoderSelector.choose);
// - requested VideoEncoderSettings (bitrate, I-frame interval = keyframeIntervalMs / 1000) and
//   AudioEncoderSettings (bitrate);
// - the output size (compositor and encoder size; the plan canvas is the geometry the effects map
//   from, AND-09) and the output frame count on the export grid (frames k with timeOfFrame(k) < durUs).
// Audio is always AAC-LC 48 kHz stereo (ARCH §14.4, D-38): Media3Composition's composition effects
// resample to 48 kHz (SonicAudioProcessor) and mix to stereo, whatever audioSampleRate/audioChannels
// say. MOV is not written on Android (capabilities.movContainer = false): `container = mov` is
// refused with notSupportedOnDevice.

package com.vecvel.danaview.editor.engine.export

import androidx.annotation.OptIn
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.VideoEncoderSettings
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportContainerMsg
import com.vecvel.danaview.editor.engine.pigeon.VideoCodecMsg

/** Video codecs an Android export can write. */
enum class ExportVideoCodec(val mimeType: String) {
    H264(MimeTypes.VIDEO_H264),
    HEVC(MimeTypes.VIDEO_H265),
}

/** Encoder settings of one export (file header). */
data class EncoderSettings(
    val codec: ExportVideoCodec,
    /** Output (compositor and encoder) size; [height] > [width] is a portrait export. */
    val width: Int,
    val height: Int,
    /** Output frame rate (the plan's canvas fps). */
    val fps: Int,
    val videoBitrate: Int,
    val audioBitrate: Int,
    val keyframeIntervalMs: Int,
) {
    init {
        require(width > 0 && height > 0) { "size" }
        require(fps > 0) { "fps" }
    }

    /** `Transformer.Builder.setVideoMimeType`. */
    val videoMimeType: String get() = codec.mimeType

    /** Whether the output is taller than wide (portrait encoding, ARCH §14.1). */
    val isPortrait: Boolean get() = height > width

    /** Short side of the output. */
    val shortSide: Int get() = minOf(width, height)

    /** Requested I-frame interval in seconds. */
    val iFrameIntervalSeconds: Float get() = keyframeIntervalMs / 1000f

    /**
     * Output frames of a [durUs] plan on the export grid: the k ≥ 0 with timeOfFrame(k) =
     * ceil(k·1e6/fps) < durUs, i.e. floor((durUs − 1)·fps/1e6) + 1 (a plan ending on a grid frame
     * time, such as timeOfFrame(61) = 2 033 334 µs at 30 fps, has exactly that many frames).
     */
    fun frameCount(durUs: Long): Long = if (durUs <= 0) 0 else Math.floorDiv((durUs - 1) * fps, FrameGrid.MICROS) + 1

    /** Expected file size of a [durUs] export: (video + audio bps) · seconds / 8 · 1.02 (ARCH §14.1). */
    fun estimatedBytes(durUs: Long): Long = ((videoBitrate.toLong() + audioBitrate) * durUs / 8_000_000.0 * 1.02).toLong()

    /** The same settings with another codec. */
    fun withCodec(other: ExportVideoCodec): EncoderSettings = copy(codec = other)

    /** Requested video encoder settings (bitrate, I-frame interval). */
    fun videoEncoderSettings(): VideoEncoderSettings = VideoEncoderSettings.Builder()
        .setBitrate(videoBitrate)
        .setiFrameIntervalSeconds(iFrameIntervalSeconds)
        .build()

    /** Requested audio encoder settings (bitrate; AAC 48 kHz stereo comes from the composition). */
    fun audioEncoderSettings(): AudioEncoderSettings = AudioEncoderSettings.Builder().setBitrate(audioBitrate).build()

    companion object {
        /** Output sample rate of every export (ARCH §14.4, D-38). */
        const val AUDIO_SAMPLE_RATE = 48_000

        /** Output channels of every export. */
        const val AUDIO_CHANNELS = 2

        /** `MimeTypes.AUDIO_AAC`. */
        const val AUDIO_MIME_TYPE: String = MimeTypes.AUDIO_AAC

        /** Settings from the Pigeon message; throws notSupportedOnDevice for MOV (file header). */
        fun from(msg: EncodeSettingsMsg): EncoderSettings {
            if (msg.container == ExportContainerMsg.MOV) {
                throw EngineException(EngineErrorCode.notSupportedOnDevice, "MOV export is not available on Android")
            }
            return EncoderSettings(
                codec = if (msg.codec == VideoCodecMsg.HEVC) ExportVideoCodec.HEVC else ExportVideoCodec.H264,
                width = msg.width.toInt(),
                height = msg.height.toInt(),
                fps = msg.fps.toInt(),
                videoBitrate = msg.videoBitrate.toInt(),
                audioBitrate = msg.audioBitrate.toInt(),
                keyframeIntervalMs = msg.keyframeIntervalMs.toInt(),
            )
        }
    }
}
