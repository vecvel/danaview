// OWNER: AND-11
//
// JVM checks of the audio-to-video-end rule (owner decision 2026-10-15, ARCH §14.3): the export
// grid's video end, the composition's audio tail (Media3Composition.audioTailUs: only when the
// spec has an audio track) and AudioEndTrimmingMuxer (audio units at or after the video end are
// not written; video and timestamps untouched). The end-to-end measurement from written MP4s is
// the instrumented ExportAvDurationTest.

package com.vecvel.danaview.editor.engine.export

import androidx.media3.common.Format
import androidx.media3.common.Metadata
import androidx.media3.common.MimeTypes
import androidx.media3.muxer.BufferInfo
import androidx.media3.muxer.Muxer
import com.google.common.collect.ImmutableList
import com.vecvel.danaview.editor.engine.composition.CompositionSpec
import com.vecvel.danaview.editor.engine.composition.Media3Composition
import com.vecvel.danaview.editor.engine.composition.SequenceKind
import com.vecvel.danaview.editor.engine.composition.SequenceSpec
import com.vecvel.danaview.editor.engine.composition.TrackTypes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

class AudioEndTrimTest {
    private class RecordingMuxer : Muxer {
        val formats = ArrayList<Format>()
        val written = ArrayList<Pair<Int, Long>>()
        var closed = false

        override fun addTrack(format: Format): Int {
            formats += format
            return formats.size - 1
        }

        override fun writeSampleData(trackId: Int, data: ByteBuffer, bufferInfo: BufferInfo) {
            written += trackId to bufferInfo.presentationTimeUs
        }

        override fun addMetadataEntry(metadataEntry: Metadata.Entry) {}

        override fun close() {
            closed = true
        }
    }

    private val video = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H264).setWidth(1280).setHeight(720).build()
    private val audio = Format.Builder().setSampleMimeType(MimeTypes.AUDIO_AAC).setSampleRate(48_000).setChannelCount(2).build()
    private val unitUs = 1024L * 1_000_000L / 48_000L

    @Test
    fun audioUnitsAtOrAfterTheVideoEndAreDroppedVideoIsKept() {
        val base = RecordingMuxer()
        val m = AudioEndTrimmingMuxer(base, endUs = 2_000_000)
        val v = m.addTrack(video)
        val a = m.addTrack(audio)
        // Priming unit at -33 333 us (edit list), then units every 21 333 us up to 2.25 s.
        var t = -33_333L
        while (t < 2_250_000) {
            m.writeSampleData(a, ByteBuffer.allocate(4), BufferInfo(t, 4, 0))
            t += unitUs
        }
        for (k in 0 until 60) m.writeSampleData(v, ByteBuffer.allocate(4), BufferInfo(k * 33_333L, 4, 0))
        m.writeSampleData(v, ByteBuffer.allocate(4), BufferInfo(2_100_000, 4, 0)) // video is never trimmed
        m.close()
        assertTrue(base.closed)
        val kept = base.written.filter { it.first == a }.map { it.second }
        assertEquals(-33_333L, kept.first())
        assertTrue("every kept unit starts before the end", kept.all { it < 2_000_000 })
        val end = kept.last() + unitUs
        assertTrue("audio end $end within [2 000 000, 2 000 000 + one unit)", end >= 2_000_000 && end < 2_000_000 + unitUs)
        assertEquals("timestamps unchanged", (0 until kept.size).map { -33_333L + it * unitUs }, kept)
        assertEquals(61, base.written.count { it.first == v })
    }

    @Test
    fun factoryDelegatesAndOnlyWrapsWhenAnEndIsSet() {
        val inner = object : Muxer.Factory {
            override fun create(path: String): Muxer = RecordingMuxer()

            override fun getSupportedSampleMimeTypes(trackType: Int): ImmutableList<String> = ImmutableList.of(MimeTypes.AUDIO_AAC)

            override fun supportsWritingNegativeTimestampsInEditList(): Boolean = true
        }
        val f = AudioEndTrimmingMuxer.Factory(inner, 1_000_000)
        assertEquals(ImmutableList.of(MimeTypes.AUDIO_AAC), f.getSupportedSampleMimeTypes(1))
        assertTrue(f.supportsWritingNegativeTimestampsInEditList())
        assertTrue(f.create("x") is AudioEndTrimmingMuxer)
        val plain = TransformerExport.muxerFactory(TransformerExport.Config(settings = Settings.of(), selector = HardwareEncoderSelector(Codecs.phone)))
        assertTrue(plain !is AudioEndTrimmingMuxer.Factory)
        val trimmed = TransformerExport.muxerFactory(TransformerExport.Config(settings = Settings.of(), selector = HardwareEncoderSelector(Codecs.phone), audioEndUs = 5))
        assertTrue(trimmed is AudioEndTrimmingMuxer.Factory)
    }

    @Test
    fun videoEndIsTheExportGridTimeOfTheFrameCount() {
        assertEquals(2_000_000L, ExportCoordinator.videoEndUs(2_000_000, Settings.of(fps = 30)))
        assertEquals(2_033_333L, ExportCoordinator.videoEndUs(2_033_333, Settings.of(fps = 30)))
        // A plan ending at timeOfFrame(61) = ceil(61e6/30) = 2 033 334 us has 61 frames, not 62.
        assertEquals(61L, Settings.of(fps = 30).frameCount(2_033_334))
        assertEquals(2_033_333L, ExportCoordinator.videoEndUs(2_033_334, Settings.of(fps = 30)))
        // 2.5 s of a 30 fps grid exported at 24 fps: 60 frames, ending at 2.5 s.
        assertEquals(2_500_000L, ExportCoordinator.videoEndUs(2_500_000, Settings.of(fps = 24)))
        // A plan end inside an output frame extends to that frame's end.
        assertEquals(2_016_667L, ExportCoordinator.videoEndUs(2_000_001, Settings.of(fps = 60)))
        assertEquals(0L, ExportCoordinator.videoEndUs(0, Settings.of()))
    }

    private fun spec(vararg types: TrackTypes) = CompositionSpec(
        canvasW = 1280, canvasH = 720, outputFps = 30, gridFps = 30, durUs = 2_000_000, bg = 0,
        sequences = types.mapIndexed { i, t -> SequenceSpec(i, if (t == TrackTypes.AUDIO) SequenceKind.AUDIO else SequenceKind.LAYERS, t, emptyList()) },
        layers = emptyMap(),
    )

    @Test
    fun theAudioTailIsAddedOnlyWithAnAudioTrackAndWhenAsked() {
        val withAudio = spec(TrackTypes.VIDEO_AND_AUDIO, TrackTypes.VIDEO)
        val videoOnly = spec(TrackTypes.VIDEO, TrackTypes.VIDEO)
        val audioLanes = spec(TrackTypes.VIDEO, TrackTypes.AUDIO)
        assertNull(Media3Composition.audioTailUs(withAudio, Media3Composition.Options()))
        assertEquals(2_250_000L, Media3Composition.audioTailUs(withAudio, Media3Composition.Options(audioThroughUs = 2_250_000)))
        assertEquals(2_250_000L, Media3Composition.audioTailUs(audioLanes, Media3Composition.Options(audioThroughUs = 2_250_000)))
        assertNull("intermediates and render previews are video only", Media3Composition.audioTailUs(videoOnly, Media3Composition.Options(audioThroughUs = 2_250_000)))
        assertSame(null, Media3Composition.audioTailUs(withAudio, Media3Composition.Options(audioThroughUs = 0)))
    }
}
