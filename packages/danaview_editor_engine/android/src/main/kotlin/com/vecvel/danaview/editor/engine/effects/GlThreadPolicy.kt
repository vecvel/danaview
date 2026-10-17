// OWNER: AND-09
//
// Which threads may touch GL (ARCH §13.3 "GL effects", §18.1): the engine's own GL work (AND-17's
// LayerCompositorGl / PausedFrameRenderer, AND-16's compositor, the AND-09 tests) runs on the
// `danaview-gl` lane (EngineThreads, LaneSpec.GL). The Media3 effects run inside a Media3 video
// graph, which owns its single GL thread and EGL context: a single-input graph (FrameExtractor,
// single-sequence exports) on "Effect:DefaultVideoFrameProcessor:GlThread", a multi-sequence
// Transformer export on "Effect:MultipleInputVideoGraph:Thread" (MultipleInputVideoGraph replaces
// any executor set on DefaultVideoFrameProcessor.Factory, so that thread cannot be danaview-gl).
// Every GL object of this package is additionally confined to the thread that created it
// ([GlThreadConfinement]); a call from any other thread fails with IllegalStateException.
// Media3 is pinned at 1.11.1; a Media3 upgrade reruns AND-01 and re-checks these names.

package com.vecvel.danaview.editor.engine.effects

import com.vecvel.danaview.editor.engine.core.LaneSpec

/** The GL thread rule (file header). */
object GlThreadPolicy {
    /** The engine's GL lane. */
    val ENGINE_GL_THREAD: String = LaneSpec.GL.threadName

    /** Media3 1.11.1's video-graph GL threads (single-input and multi-input graphs). */
    val MEDIA3_GL_THREADS: Set<String> = setOf(
        "Effect:DefaultVideoFrameProcessor:GlThread",
        "Effect:MultipleInputVideoGraph:Thread",
    )

    /** Whether a thread called [name] may touch GL. */
    fun isGlThreadName(name: String): Boolean = name == ENGINE_GL_THREAD || name in MEDIA3_GL_THREADS

    /** Throws unless the caller runs on a GL thread; returns the current thread. */
    fun checkCurrent(): Thread {
        val t = Thread.currentThread()
        check(isGlThreadName(t.name)) { "GL used on thread '${t.name}'; only $ENGINE_GL_THREAD (or a Media3 video-graph GL thread) may touch GL" }
        return t
    }
}

/** Confines a GL object to the GL thread that created it (file header). */
class GlThreadConfinement {
    private val owner: Thread = GlThreadPolicy.checkCurrent()

    /** The owning thread's name. */
    val ownerName: String get() = owner.name

    /** Throws unless the caller is the owning thread. */
    fun check() {
        val t = Thread.currentThread()
        check(t === owner) { "GL object of thread '${owner.name}' used on '${t.name}'" }
    }
}
