// OWNER: AND-09
//
// The GL thread rule (ARCH §13.3: only the danaview-gl thread touches GL; Media3's own video-graph
// GL threads run the Media3 effects): names, the current-thread check and per-object confinement.

package com.vecvel.danaview.editor.engine.effects

import com.vecvel.danaview.editor.engine.core.LaneSpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicReference

class GlThreadPolicyTest {
    private fun <T> onThread(name: String, block: () -> T): Result<T> {
        val out = AtomicReference<Result<T>>()
        val t = Thread({ out.set(runCatching(block)) }, name)
        t.start()
        t.join()
        return out.get()
    }

    @Test
    fun onlyTheEngineAndMedia3GlThreadsMayTouchGl() {
        assertEquals("danaview-gl", GlThreadPolicy.ENGINE_GL_THREAD)
        assertEquals(LaneSpec.GL.threadName, GlThreadPolicy.ENGINE_GL_THREAD)
        assertTrue(GlThreadPolicy.isGlThreadName("danaview-gl"))
        assertTrue(GlThreadPolicy.isGlThreadName("Effect:MultipleInputVideoGraph:Thread"))
        assertTrue(GlThreadPolicy.isGlThreadName("Effect:DefaultVideoFrameProcessor:GlThread"))
        for (other in listOf("main", "danaview-preview", "danaview-export", "danaview-io", "danaview-gl-2", "")) {
            assertFalse(other, GlThreadPolicy.isGlThreadName(other))
        }
        assertTrue(onThread("danaview-gl") { GlThreadPolicy.checkCurrent() }.isSuccess)
        val denied = onThread("danaview-preview") { GlThreadPolicy.checkCurrent() }
        assertTrue(denied.exceptionOrNull() is IllegalStateException)
    }

    @Test
    fun objectsStayOnTheirThread() {
        val confinement = onThread("danaview-gl") { GlThreadConfinement() }.getOrThrow()
        assertEquals("danaview-gl", confinement.ownerName)
        // Another thread, even one with the same name, is refused.
        val other = onThread("danaview-gl") { confinement.check() }
        assertTrue(other.exceptionOrNull() is IllegalStateException)
        assertTrue(onThread("worker") { GlThreadConfinement() }.exceptionOrNull() is IllegalStateException)
    }
}
