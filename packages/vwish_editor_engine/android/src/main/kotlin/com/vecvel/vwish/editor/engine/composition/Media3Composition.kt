@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-08

// CompositionSpec → Media3 Transformer `Composition` (ARCH §13.3; AND-01: GO for Transformer
// export). Sequences keep the spec's index order (compositor input id = sequence index, V-N1) and
// are built with `EditedMediaItemSequence.Builder(trackTypes)` (Media3 1.11 track types; the
// deprecated experimentalSetForce{Audio,Video}Track setters are never used). Generated images come
// from [CompositionImages]; per-item video effects from the [EffectChainFactory] (AND-09's GL
// effects). Composition-level audio: SonicAudioProcessor(48 kHz) + ChannelMixingAudioProcessor to
// stereo (mono duplicated, 3–8 channels ITU −3 dB with LFE dropped, the API-03 reference matrix).
// HDR sources are tone-mapped (`setHdrMode`; the caller picks OpenGL where the device has
// GL_EXT_YUV_target and a 10-bit decoder, else MediaCodec or proxies, AND-02 / AND-01 V-N5).
// AUDIO items of audio stream n > 0 carry an AudioStreamTag; the exporter installs
// AudioStreamAssetLoaderFactory when `Built.selectsAudioStreams` (AudioStreamSelection.kt).

package com.vecvel.vwish.editor.engine.composition

import androidx.annotation.OptIn
import androidx.core.net.toUri
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.SpeedParameters
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.GainProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.plan.FrameGrid
import com.vecvel.vwish.editor.engine.plan.ParamSnapshot
import java.util.concurrent.atomic.AtomicReference

/** Builds Transformer compositions from [CompositionSpec]s (file header). */
object Media3Composition {
    /** Composition-level options. */
    data class Options(
        /** `Composition.setHdrMode` value. */
        val hdrMode: Int = Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL,
        /** Compositor output size (defaults to the canvas). */
        val outputWidth: Int? = null,
        val outputHeight: Int? = null,
        /** Composition audio effects: Sonic 48 kHz + stereo channel mixing. */
        val compositionAudio: Boolean = true,
    )

    /** The built composition and the gating settings it uses. */
    class Built(val composition: Composition, val compositorSettings: LayerGatingCompositorSettings, val spec: CompositionSpec) {
        /**
         * Some AUDIO item plays an audio stream other than 0: the exporter must install
         * [AudioStreamAssetLoaderFactory] (AudioStreamSelection.kt), or stream 0 would be exported.
         */
        val selectsAudioStreams: Boolean get() = spec.audioSequences.any { s -> s.items.any { it.kind == ItemKind.AUDIO && it.stream != 0 } }
    }

    /** Output sample rate of the composition audio (ARCH §11.6 Audio). */
    const val OUTPUT_SAMPLE_RATE = 48_000

    /** Builds [spec]; throws `planInvalid` for an empty plan or a `hold` layer (export never holds). */
    fun build(
        spec: CompositionSpec,
        images: CompositionImages,
        effects: EffectChainFactory,
        snapshot: AtomicReference<ParamSnapshot>,
        options: Options = Options(),
    ): Built {
        if (spec.isEmpty) throw EngineErrors.invalidPlan("an empty plan has nothing to compose")
        val sequences = spec.sequences.map { sequence(spec, it, images, effects, snapshot) }
        val settings = LayerGatingCompositorSettings(
            spec,
            options.outputWidth ?: spec.canvasW,
            options.outputHeight ?: spec.canvasH,
        )
        val builder = Composition.Builder(sequences)
            .setVideoCompositorSettings(settings)
            .setHdrMode(options.hdrMode)
        if (options.compositionAudio) builder.setEffects(Effects(compositionAudioProcessors(), emptyList()))
        return Built(builder.build(), settings, spec)
    }

    /** SonicAudioProcessor(48 kHz) + ChannelMixingAudioProcessor(→ stereo) (ARCH §13.3). */
    fun compositionAudioProcessors(): List<AudioProcessor> {
        val sonic = SonicAudioProcessor().apply { setOutputSampleRateHz(OUTPUT_SAMPLE_RATE) }
        val mixing = ChannelMixingAudioProcessor()
        for (channels in 1..8) mixing.putChannelMixingMatrix(stereoDownmix(channels))
        return listOf(sonic, mixing)
    }

    /**
     * The `channels` → 2 matrix of the API-03 reference mixer (`AudioMath.downmixMatrix`): mono
     * duplicated; stereo as is; ITU-R BS.775 for 3 = L R C, 4 = L R Ls Rs, 5 = L R C Ls Rs,
     * 6 = L R C LFE Ls Rs, 7 = L R C LFE Cs Ls Rs, 8 = L R C LFE Ls Rs Lb Rb (centre and surrounds
     * −3 dB, LFE dropped, 7-channel Cs 0.5); other counts keep the first two channels.
     */
    fun stereoDownmix(channels: Int): ChannelMixingMatrix {
        val rows = downmixRows(channels)
        // ChannelMixingMatrix is row-major by input channel: coefficient[in * 2 + out].
        val coefficients = FloatArray(channels * 2)
        for (input in 0 until channels) {
            coefficients[input * 2] = rows[0][input].toFloat()
            coefficients[input * 2 + 1] = rows[1][input].toFloat()
        }
        return ChannelMixingMatrix(channels, 2, coefficients)
    }

    /** `[[L coefficients], [R coefficients]]` (see [stereoDownmix]). */
    fun downmixRows(channels: Int): List<DoubleArray> {
        val k = ITU_MINUS_3_DB
        return when (channels) {
            1 -> listOf(doubleArrayOf(1.0), doubleArrayOf(1.0))
            3 -> listOf(doubleArrayOf(1.0, 0.0, k), doubleArrayOf(0.0, 1.0, k))
            4 -> listOf(doubleArrayOf(1.0, 0.0, k, 0.0), doubleArrayOf(0.0, 1.0, 0.0, k))
            5 -> listOf(doubleArrayOf(1.0, 0.0, k, k, 0.0), doubleArrayOf(0.0, 1.0, k, 0.0, k))
            6 -> listOf(doubleArrayOf(1.0, 0.0, k, 0.0, k, 0.0), doubleArrayOf(0.0, 1.0, k, 0.0, 0.0, k))
            7 -> listOf(doubleArrayOf(1.0, 0.0, k, 0.0, 0.5, k, 0.0), doubleArrayOf(0.0, 1.0, k, 0.0, 0.5, 0.0, k))
            8 -> listOf(doubleArrayOf(1.0, 0.0, k, 0.0, k, 0.0, k, 0.0), doubleArrayOf(0.0, 1.0, k, 0.0, 0.0, k, 0.0, k))
            else -> listOf(DoubleArray(channels) { if (it == 0) 1.0 else 0.0 }, DoubleArray(channels) { if (it == 1) 1.0 else 0.0 })
        }
    }

    /** −3 dB as a linear factor (1/√2). */
    const val ITU_MINUS_3_DB = 0.7071067811865476

    private fun trackTypes(t: TrackTypes): Set<Int> = when (t) {
        TrackTypes.VIDEO -> setOf(C.TRACK_TYPE_VIDEO)
        TrackTypes.AUDIO -> setOf(C.TRACK_TYPE_AUDIO)
        TrackTypes.VIDEO_AND_AUDIO -> setOf(C.TRACK_TYPE_VIDEO, C.TRACK_TYPE_AUDIO)
    }

    private fun sequence(
        spec: CompositionSpec,
        s: SequenceSpec,
        images: CompositionImages,
        effects: EffectChainFactory,
        snapshot: AtomicReference<ParamSnapshot>,
    ): EditedMediaItemSequence {
        val b = EditedMediaItemSequence.Builder(trackTypes(s.trackTypes))
        for (item in s.items) {
            if (item.kind == ItemKind.AUDIO_GAP) {
                b.addGap(item.durationUs)
                continue
            }
            b.addItem(editedItem(spec, s, item, images, effects, snapshot))
        }
        return b.build()
    }

    private fun imageItem(uri: String, durationUs: Long, fps: Int, videoEffects: List<Effect>): EditedMediaItem {
        val mediaItem = MediaItem.Builder()
            .setUri(uri.toUri())
            .setImageDurationMs(FrameGrid.ceilDiv(durationUs, 1000L))
            .build()
        return EditedMediaItem.Builder(mediaItem)
            .setDurationUs(durationUs)
            .setFrameRate(fps)
            .setEffects(Effects(emptyList(), videoEffects))
            .build()
    }

    private fun editedItem(
        spec: CompositionSpec,
        s: SequenceSpec,
        item: ItemSpec,
        images: CompositionImages,
        effects: EffectChainFactory,
        snapshot: AtomicReference<ParamSnapshot>,
    ): EditedMediaItem {
        val fps = spec.outputFps
        fun visualEffects(): List<Effect> {
            val layer = item.layerId?.let { spec.layers[it] }
            return effects.videoEffects(
                ItemEffectContext(
                    spec = spec,
                    sequence = s,
                    item = item,
                    layer = layer,
                    snapshot = snapshot,
                    needsBlur = layer != null && ParamSnapshot.needsBlur(layer),
                    maxScale = layer?.let { ParamSnapshot.maxScale(it) } ?: 1.0,
                ),
            )
        }
        return when (item.kind) {
            ItemKind.CLOCK -> imageItem(images.transparent(CompositionImages.CLOCK_BAND_SIZE, CompositionImages.CLOCK_BAND_SIZE), item.durationUs, fps, emptyList())
            ItemKind.BACKGROUND -> imageItem(images.opaque(spec.bg, spec.canvasW, spec.canvasH), item.durationUs, fps, emptyList())
            ItemKind.GAP, ItemKind.SPRITE -> imageItem(images.transparent(spec.canvasW, spec.canvasH), item.durationUs, fps, visualEffects())
            ItemKind.SOLID -> imageItem(
                images.opaque(WHITE, CompositionImages.SOLID_SOURCE_SIZE, CompositionImages.SOLID_SOURCE_SIZE),
                item.durationUs,
                fps,
                visualEffects(),
            )
            ItemKind.IMAGE -> imageItem(requireNotNull(item.uri), item.durationUs, fps, visualEffects())
            ItemKind.MEDIA -> {
                if (item.hold) throw EngineErrors.invalidPlan("a pending freeze still cannot be composed")
                val sourceDuration = item.sourceDurationUs ?: throw EngineErrors.invalidPlan("media duration unknown")
                val mediaItem = MediaItem.Builder()
                    .setUri(requireNotNull(item.uri).toUri())
                    .setClippingConfiguration(
                        MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionUs(item.clipStartUs)
                            .setEndPositionUs(item.clipEndUs)
                            .build(),
                    )
                    .build()
                val b = EditedMediaItem.Builder(mediaItem)
                    .setDurationUs(sourceDuration)
                    .setRemoveAudio(true)
                    .setEffects(Effects(emptyList(), visualEffects()))
                item.speed?.let { b.setSpeed(SpeedParameters(it, item.keepPitch)) }
                item.frameRate?.let { b.setFrameRate(it) }
                b.build()
            }
            ItemKind.AUDIO -> {
                val sourceDuration = item.sourceDurationUs ?: throw EngineErrors.invalidPlan("audio duration unknown")
                if (item.stream < 0) throw EngineErrors.invalidPlan("negative audio stream")
                val mediaItem = MediaItem.Builder()
                    .setUri(requireNotNull(item.uri).toUri())
                    .setClippingConfiguration(
                        MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionUs(item.clipStartUs)
                            .setEndPositionUs(item.clipEndUs)
                            .build(),
                    )
                    // Stream n > 0 is selected by AudioStreamAssetLoaderFactory (AudioStreamSelection.kt).
                    .apply { if (item.stream != 0) setTag(AudioStreamTag(item.stream)) }
                    .build()
                val processors = ArrayList<AudioProcessor>()
                item.gain?.let { processors += GainProcessor(KeyframedGainProvider.forItem(it, item.startUs)) }
                val b = EditedMediaItem.Builder(mediaItem)
                    .setDurationUs(sourceDuration)
                    .setRemoveVideo(true)
                    .setEffects(Effects(processors, emptyList()))
                item.speed?.let { b.setSpeed(SpeedParameters(it, item.keepPitch)) }
                b.build()
            }
            ItemKind.AUDIO_GAP -> error("audio gaps are sequence gaps")
        }
    }

    private const val WHITE: Int = -1 // 0xFFFFFFFF
}
