// OWNER: ENG-08
//
// Engine roots (ARCH §8.1, §20.1: the engine writes only below the Dart roots) and the lane table
// (ARCH §18.1).

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.LaneSpec
import com.vecvel.vwish.editor.engine.core.Paths
import android.os.Process
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PathsAndThreadsTest {
    private val paths = TestRoots.paths

    private fun codeOf(block: () -> Unit): EngineErrorCode? = try {
        block()
        null
    } catch (e: EngineException) {
        e.code
    }

    @Test
    fun rootsAndDirectoriesFollowTheLayout() {
        assertEquals(TestRoots.CACHE, paths.cacheRoot.invariantSeparatorsPath)
        assertEquals(TestRoots.SUPPORT, paths.supportRoot.invariantSeparatorsPath)
        assertEquals(TestRoots.SPEECH, paths.speechRoot.invariantSeparatorsPath)
        assertEquals("${TestRoots.CACHE}/work/picks", paths.workPicks.invariantSeparatorsPath)
        assertEquals("${TestRoots.CACHE}/thumbs", paths.thumbs.invariantSeparatorsPath)
        assertEquals("${TestRoots.SUPPORT}/derived", paths.derived.invariantSeparatorsPath)
    }

    @Test
    fun dartRootsAreValidated() {
        assertEquals(EngineErrorCode.internal, codeOf { Paths.fromDart("relative/cache", TestRoots.SUPPORT) })
        assertEquals(EngineErrorCode.internal, codeOf { Paths.fromDart("", TestRoots.SUPPORT) })
        assertEquals(EngineErrorCode.internal, codeOf { Paths.fromDart("/a/../b", TestRoots.SUPPORT) })
        assertEquals(EngineErrorCode.internal, codeOf { Paths.fromDart("/a/editor", "/a/editor/support") })
        assertEquals(EngineErrorCode.internal, codeOf { Paths.fromDart("/a/editor", "/a/editor") })
        assertNull(codeOf { Paths.fromDart("/a/cache/vwish/editor/", "file:///a/files/vwish/editor") })
        assertEquals(Paths.fromDart("/a/c", "/a/s"), Paths.fromDart("/a/c/", "/a//s"))
    }

    @Test
    fun writablePathsStayInsideTheRoots() {
        assertTrue(paths.isWritable("${TestRoots.CACHE}/work/export-1.mp4"))
        assertTrue(paths.isWritable("${TestRoots.SUPPORT}/projects/p/assets/stills/a.png"))
        assertTrue(paths.isWritable("${TestRoots.SPEECH}/work/job.wav"))
        assertTrue(paths.isWritable("file://${TestRoots.CACHE}/work/x.mp4"))
        assertFalse(paths.isWritable("${TestRoots.CACHE}/../escape.mp4"))
        assertFalse(paths.isWritable("${TestRoots.CACHE}x/sibling.mp4"))
        assertFalse(paths.isWritable("/sdcard/Movies/x.mp4"))
        assertFalse(paths.isWritable("work/x.mp4"))
        assertFalse(paths.isWritable("content://media/external/video/1"))
        assertFalse(paths.isWritable(""))
        assertEquals(EngineErrorCode.permissionDenied, codeOf { paths.requireWritable("/sdcard/x.mp4", "outputPath") })
        assertEquals(EngineErrorCode.internal, codeOf { paths.requireWritable("x.mp4", "outputPath") })
    }

    @Test
    fun pathsNeverPrintThemselves() {
        assertFalse(paths.toString().contains("/data"))
    }

    @Test
    fun lanesHaveTheArchitectureNamesAndPriorities() {
        assertEquals(
            listOf("vwish-preview", "vwish-gl", "vwish-export", "vwish-jobs", "vwish-io"),
            LaneSpec.entries.map { it.threadName },
        )
        assertEquals(Process.THREAD_PRIORITY_DISPLAY, LaneSpec.PREVIEW.priority)
        assertEquals(Process.THREAD_PRIORITY_DISPLAY, LaneSpec.GL.priority)
        assertEquals(Process.THREAD_PRIORITY_BACKGROUND, LaneSpec.JOBS.priority)
        assertEquals(Process.THREAD_PRIORITY_BACKGROUND, LaneSpec.IO.priority)
    }

    @Test
    fun lanesStartLazilyOnceAndShutDown() {
        val fake = FakeThreads()
        val threads = fake.threads
        assertTrue(threads.started().isEmpty())
        assertSame(threads.io, threads.io)
        assertEquals(listOf(LaneSpec.IO), threads.started().map { it.spec })
        threads.jobs
        threads.shutdown()
        assertTrue(threads.started().isEmpty())
        try {
            fake.lane(LaneSpec.IO).execute { }
            fail("a quit lane must reject work")
        } catch (expected: java.util.concurrent.RejectedExecutionException) {
        }
    }
}
