// OWNER: ENG-06
//
// Regression tests for the frozen Android build configuration and the AND-01 outcomes ENG-06
// recorded (docs/editor/spikes/AND-01.md §6; ARCH §5, §13.3):
//
// - frame_grid.json carries AND-01's measured androidSeekMsRounding = "floor" (V-N18: Media3 shows
//   the first frame with pts >= the seek position), and with it an exact seek to floor(P(k) / 1000)
//   ms lands on frame k for every shared vector, while ceil would not (ported from the spike's
//   GridTimeTest / SeekDiagnosticsTest reasoning);
// - the pinned Media3 1.11.1 artifacts the Android lane needs are on the module's classpath
//   (reflection only, so no Media3 opt-in is involved).

package com.vecvel.danaview.editor.engine.buildconfig

import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.JvmFixtures
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BuildConfigTest {
    private fun frameGrid(): JSONObject =
        JSONObject(JvmFixtures.file(FixtureTree.CORE, "vectors/frame_grid.json").readText())

    /** P(k) = round(k * 1e6 / fps) (ARCH §5), for k >= 0. */
    private fun platformTimeOfFrame(k: Long, fps: Int): Long = Math.floorDiv(2 * k * 1_000_000L + fps, 2L * fps)

    @Test
    fun frameGridRecordsTheMeasuredSeekRounding() {
        assertEquals("floor", frameGrid().getString("androidSeekMsRounding"))
    }

    @Test
    fun floorRoundedSeekLandsOnEveryVectorFrame() {
        val rates = frameGrid().getJSONArray("rates")
        var checked = 0
        var ceilMisses = 0
        for (i in 0 until rates.length()) {
            val rate = rates.getJSONObject(i)
            val fps = rate.getInt("fps")
            val frames = rate.getJSONArray("frames")
            for (j in 0 until frames.length()) {
                val f = frames.getJSONObject(j)
                val k = f.getLong("k")
                val p = f.getLong("platformTime")
                assertEquals("P fps=$fps k=$k", platformTimeOfFrame(k, fps), p)
                // Media3 (AND-01 V-N18): a seek to position x shows the first frame with pts >= x.
                val floorUs = Math.floorDiv(p, 1000L) * 1000L
                assertTrue("floor seek fps=$fps k=$k lands at or before P(k)", floorUs <= p)
                if (k > 0) {
                    assertTrue("floor seek fps=$fps k=$k stays after P(k-1)", floorUs > platformTimeOfFrame(k - 1, fps))
                    // AND-16's stuck-deck watchdog alternates ms - 1 and ms (ExoPlayer ignores a re-seek to
                    // the same ms); ms - 1 must land on the same rule frame (ARCH §5, §13.3).
                    assertTrue(
                        "watchdog seek (ms - 1) fps=$fps k=$k stays after P(k-1)",
                        floorUs - 1000L > platformTimeOfFrame(k - 1, fps),
                    )
                }
                val ceilUs = Math.floorDiv(p + 999L, 1000L) * 1000L
                if (ceilUs > p) ceilMisses++ // ceil would show frame k + 1 here
                checked++
            }
        }
        assertTrue("too few vectors: $checked", checked > 60)
        assertTrue("ceil rounding must be distinguishable on the shared vectors", ceilMisses > 0)
    }

    @Test
    fun pinnedMedia3ArtifactsAreOnTheClasspath() {
        val version = Class.forName("androidx.media3.common.MediaLibraryInfo").getField("VERSION").get(null)
        assertEquals("Media3 is pinned (R1); upgrading means rerunning AND-01", "1.11.1", version)
        val classes = listOf(
            "androidx.media3.exoplayer.ExoPlayer", // media3-exoplayer: AND-16 slot decks, AND-10
            "androidx.media3.effect.DefaultVideoFrameProcessor", // media3-effect: AND-09
            "androidx.media3.transformer.Transformer", // media3-transformer: AND-11 export (GO)
            "androidx.media3.muxer.Mp4Muxer", // media3-muxer: AND-07, AND-11
            "androidx.media3.inspector.MediaExtractorCompat", // media3-inspector: rule-frame PTS (V-N16), AND-02/04
            "androidx.media3.inspector.frame.FrameExtractor", // media3-inspector-frame: AND-03/06/17
        )
        // Resolve without running static initializers (they need a real Android runtime).
        val loader = javaClass.classLoader
        for (name in classes) Class.forName(name, false, loader)
    }
}
