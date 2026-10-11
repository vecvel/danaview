// OWNER: AND-09
//
// GPU time of a block of GL work through GL_EXT_disjoint_timer_query (GL_TIME_ELAPSED_EXT on the
// ES 3 query entry points), for the "a gated frame costs one clear" check and QA-04's 1080p
// compose budget (ARCH §13.4). Where the extension is missing (the SwiftShader emulator exposes
// none) [measureNs] returns null and callers fall back to glFinish-bounded wall time, reported as
// such. Confined to the GL thread.

package com.vecvel.danaview.editor.engine.effects

import android.opengl.GLES20
import android.opengl.GLES30

/** GPU timer queries (file header). */
object GlTimerQuery {
    private const val GL_TIME_ELAPSED_EXT = 0x88BF
    private const val GL_GPU_DISJOINT_EXT = 0x8FBB

    /** GPU nanoseconds of [block], or null without timer queries (or after a disjoint event). */
    fun measureNs(caps: GlCaps, block: () -> Unit): Long? {
        GlThreadPolicy.checkCurrent()
        if (!caps.timerQuery || !caps.isEs3) {
            block()
            return null
        }
        val ids = IntArray(1)
        GLES30.glGenQueries(1, ids, 0)
        try {
            val disjoint = IntArray(1)
            GLES20.glGetIntegerv(GL_GPU_DISJOINT_EXT, disjoint, 0)
            GLES30.glBeginQuery(GL_TIME_ELAPSED_EXT, ids[0])
            block()
            GLES30.glEndQuery(GL_TIME_ELAPSED_EXT)
            val ready = IntArray(1)
            var spins = 0
            while (ready[0] == 0 && spins++ < 10_000) GLES30.glGetQueryObjectuiv(ids[0], GLES30.GL_QUERY_RESULT_AVAILABLE, ready, 0)
            val result = IntArray(1)
            GLES30.glGetQueryObjectuiv(ids[0], GLES30.GL_QUERY_RESULT, result, 0)
            GLES20.glGetIntegerv(GL_GPU_DISJOINT_EXT, disjoint, 0)
            return if (disjoint[0] != 0 || ready[0] == 0) null else result[0].toLong() and 0xFFFFFFFFL
        } finally {
            GLES30.glDeleteQueries(1, ids, 0)
        }
    }

    /** Wall nanoseconds of [block] bounded by glFinish before and after (emulator fallback). */
    fun finishedWallNs(block: () -> Unit): Long {
        GlThreadPolicy.checkCurrent()
        GLES20.glFinish()
        val t0 = System.nanoTime()
        block()
        GLES20.glFinish()
        return System.nanoTime() - t0
    }
}
