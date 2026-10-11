@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-08

// Audio stream selection for AUDIO items (ARCH §11.2 AudioSeg.stream): stream n is the n-th audio
// track of the source in container order (the probe's order). Transformer's ExoPlayerAssetLoader
// selects one audio track with its default DefaultTrackSelector, which always picks stream 0, so
// Media3Composition tags every AUDIO item whose stream is not 0 ([AudioStreamTag]) and the exporter
// installs [AudioStreamAssetLoaderFactory] on the Transformer (`setAssetLoaderFactory`): untagged
// items go to the base factory unchanged; tagged items get an ExoPlayerAssetLoader with the same
// decoder factory, clock and media source factory whose track selector picks the n-th audio group
// ([AudioStreamTrackSelector]). A stream index past the source's audio tracks fails the export
// (never another stream's audio). Every exporter of a Media3Composition (AND-11, AND-18, AND-19)
// must use this factory whenever `Built.selectsAudioStreams` is true.

package com.vecvel.vwish.editor.engine.composition

import android.content.Context
import android.os.Looper
import android.util.Pair
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.util.Clock
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.trackselection.MappingTrackSelector
import androidx.media3.exoplayer.trackselection.TrackSelector
import androidx.media3.transformer.AssetLoader
import androidx.media3.transformer.Codec
import androidx.media3.transformer.DefaultAssetLoaderFactory
import androidx.media3.transformer.DefaultDecoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExoPlayerAssetLoader

/** The MediaItem tag of an AUDIO item that plays audio stream [stream] (> 0) of its source. */
data class AudioStreamTag(val stream: Int)

/** The audio stream an item's MediaItem asks for (0 when untagged). */
fun MediaItem.audioStream(): Int = (localConfiguration?.tag as? AudioStreamTag)?.stream ?: 0

/**
 * A DefaultTrackSelector (with Transformer's own parameters: highest supported bitrate, no
 * device channel-count constraint) whose audio choice is the [stream]-th audio track group.
 */
class AudioStreamTrackSelector(context: Context, private val stream: Int) :
    DefaultTrackSelector(
        context,
        Parameters.Builder()
            .setForceHighestSupportedBitrate(true)
            .setConstrainAudioChannelCountToDeviceCapabilities(false)
            .build(),
    ) {
    override fun selectAudioTrack(
        mappedTrackInfo: MappingTrackSelector.MappedTrackInfo,
        rendererFormatSupports: Array<Array<IntArray>>,
        rendererMixedMimeTypeAdaptationSupports: IntArray,
        params: Parameters,
    ): Pair<ExoTrackSelection.Definition, Int>? {
        for (renderer in 0 until mappedTrackInfo.rendererCount) {
            if (mappedTrackInfo.getRendererType(renderer) != C.TRACK_TYPE_AUDIO) continue
            val groups = mappedTrackInfo.getTrackGroups(renderer)
            check(stream < groups.length) { "audio stream $stream of ${groups.length}" }
            return Pair(ExoTrackSelection.Definition(groups[stream], 0), renderer)
        }
        return null
    }
}

/** Routes AUDIO items tagged with a stream > 0 to a stream-selecting loader (file header). */
class AudioStreamAssetLoaderFactory(
    context: Context,
    private val decoderFactory: Codec.DecoderFactory = DefaultDecoderFactory.Builder(context.applicationContext).build(),
    private val clock: Clock = Clock.DEFAULT,
    /** The media source factory of tagged items (null: Transformer's own default). */
    private val mediaSourceFactory: MediaSource.Factory? = null,
    /** Everything untagged (default: Transformer's DefaultAssetLoaderFactory with [decoderFactory]). */
    private val base: AssetLoader.Factory = DefaultAssetLoaderFactory(context.applicationContext, decoderFactory, clock, null),
) : AssetLoader.Factory {
    private val context = context.applicationContext

    override fun createAssetLoader(
        editedMediaItem: EditedMediaItem,
        looper: Looper,
        listener: AssetLoader.Listener,
        compositionSettings: AssetLoader.CompositionSettings,
    ): AssetLoader {
        val stream = editedMediaItem.mediaItem.audioStream()
        if (stream == 0) return base.createAssetLoader(editedMediaItem, looper, listener, compositionSettings)
        val selector = TrackSelector.Factory { ctx -> AudioStreamTrackSelector(ctx, stream) }
        return ExoPlayerAssetLoader.Factory(context, decoderFactory, clock, mediaSourceFactory, selector, null, null)
            .createAssetLoader(editedMediaItem, looper, listener, compositionSettings)
    }
}
