// OWNER: AND-18
//
// `PreviewHostApi.setRenderedRanges` (ARCH §12.2 "Rendered ranges", D-45; INT-06 glue →
// RenderPreviewServices.renderedRanges). Called on danaview-preview after the glue checked the list
// (sorted, non-overlapping, files inside `<cache>/danaview/editor/renders/`).
//
// - The ranges replace the session's whole set. Each one becomes output frames
//   [frameIndexNearest(startUs), frameIndexNearest(endUs)) of the session's grid (D-35), its file a
//   `file://` URI (AND-16's file contract: frame j at pts P(j), canvas aspect, H.264).
// - The session's AND-16 ContingencyPreviewBackend gets the session's RenderedRangeSwap as its
//   rendered-range hook (installed once) and is rebuilt on the session's current plan, so the next
//   playback (or the one running) plays the ranges. Other backends (the stills fallback below
//   API 29 or without the native shim) keep live preview: the call succeeds and does nothing.
// - While a session has ranges, RenderedRangeBinding polls on danaview-preview and runs the swap's
//   invalidation (RangeTouch rule); when a patch, a transient or a new plan touched a range, the
//   range is dropped until the next call and the backend is rebuilt at once, so playback falls
//   back to the live decks within a frame or two (measured by RenderedRangeSwapTest). The rebuild
//   waits while the session is closed, suspended for an export or shows a source frame.
// - An unknown session answers `internal` (glue convention); the poll ends when the session is
//   disposed or has no range left. Bindings are keyed by session id and hold the session only
//   weakly (the backend they hold refers to its session as host): a binding whose session is gone
//   is removed when its poll notices, and on every call.
// Never logs URIs or plan content.

package com.vecvel.danaview.editor.engine.preview.render

import androidx.annotation.VisibleForTesting
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.pigeon.RenderedRangeMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.preview.PreviewSession
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.preview.fallback.RenderedRange
import java.lang.ref.WeakReference

/** Rendered ranges of preview sessions (file header). */
class RenderedRangeHandler(private val ctx: EngineContext) {
    private class Bound(val session: WeakReference<PreviewSession>, val binding: RenderedRangeBinding)

    /** Bindings by session id; guarded by itself. */
    private val bindings = HashMap<String, Bound>()

    /** Finds open sessions (the process's PreviewSessionManager; tests use their own manager). */
    @VisibleForTesting
    @Volatile
    var sessions: (String) -> PreviewSession? = { ctx.previews.get(it) }

    /** Replaces the rendered ranges of session [sessionId]. */
    fun setRenderedRanges(sessionId: String, ranges: List<RenderedRangeMsg>, done: Completion<Unit>) {
        synchronized(bindings) { prune() }
        val session = sessions(sessionId)
            ?: return done.fail(EngineException(EngineErrorCode.internal, "unknown preview session"))
        val backend = session.backend as? ContingencyPreviewBackend
        if (backend == null || backend.usesStillsFallback) {
            // Live preview only (no range deck on this backend).
            return done.succeed(Unit)
        }
        val handler = ctx.threads.preview.handler ?: return done.fail(EngineException(EngineErrorCode.internal, "preview lane without handler"))
        try {
            val entries = RenderRanges.entries(ranges, FrameGrid.of(session.snapshot.get().plan.canvas.fps))
            val binding = synchronized(bindings) {
                val id = session.sessionId
                val existing = bindings[id]?.takeIf { it.session.get() === session }
                existing?.binding ?: run {
                    bindings.remove(id)?.binding?.stop()
                    val ref = WeakReference(session)
                    lateinit var created: RenderedRangeBinding
                    created = RenderedRangeBinding(
                        backend = backend,
                        snapshot = session.snapshot,
                        handler = handler,
                        ready = { ref.get()?.let { it.isOpen && !it.isSuspended } ?: false },
                        alive = { ref.get()?.let { sessions(id) === it } ?: false },
                        onGone = { forget(id, created) },
                    )
                    bindings[id] = Bound(ref, created)
                    created
                }
            }
            binding.apply(entries)
            done.succeed(Unit)
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t))
        }
    }

    /** The swap of [session], or null (tests). */
    fun swapOf(session: PreviewSession): RenderedRangeSwap? = synchronized(bindings) {
        bindings[session.sessionId]?.takeIf { it.session.get() === session }?.binding?.swap
    }

    /** Bindings held (tests). */
    val bindingCount: Int get() = synchronized(bindings) { bindings.size }

    private fun forget(id: String, binding: RenderedRangeBinding) {
        synchronized(bindings) {
            if (bindings[id]?.binding === binding) bindings.remove(id)
        }
    }

    /** Drops bindings whose session was disposed or collected (caller holds the lock). */
    private fun prune() {
        val it = bindings.entries.iterator()
        while (it.hasNext()) {
            val (id, b) = it.next()
            val s = b.session.get()
            if (s == null || sessions(id) !== s) {
                b.binding.stop()
                it.remove()
            }
        }
    }
}

/** Rendered-range messages → swap entries (pure; JVM-tested). */
object RenderRanges {
    /** A `file://` URI of [uriOrPath] (`file://…` or an absolute path). */
    fun fileUri(uriOrPath: String): String = if (uriOrPath.startsWith("file://")) uriOrPath else "file://$uriOrPath"

    /**
     * The entries of [ranges] on [grid]: frames [nearest(startUs), nearest(endUs)) (D-35); a range
     * that covers no whole frame is left out (it would never play).
     */
    fun entries(ranges: List<RenderedRangeMsg>, grid: FrameGrid): List<RenderedRangeSwap.Entry> = ranges.mapNotNull { r ->
        val first = grid.frameIndexNearest(r.startUs)
        val end = grid.frameIndexNearest(r.endUs)
        if (first < 0 || end <= first) {
            null
        } else {
            RenderedRangeSwap.Entry(RenderedRange(first, end, fileUri(r.uri)), r.startUs, r.endUs, r.hash)
        }
    }.sortedBy { it.range.first }
}
