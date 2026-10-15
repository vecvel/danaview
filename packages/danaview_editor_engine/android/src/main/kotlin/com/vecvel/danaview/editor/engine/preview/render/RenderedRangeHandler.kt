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
//   disposed or has no range left.
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
import java.util.WeakHashMap

/** Rendered ranges of preview sessions (file header). */
class RenderedRangeHandler(private val ctx: EngineContext) {
    private val bindings = WeakHashMap<PreviewSession, RenderedRangeBinding>()

    /** Finds open sessions (the process's PreviewSessionManager; tests use their own manager). */
    @VisibleForTesting
    @Volatile
    var sessions: (String) -> PreviewSession? = { ctx.previews.get(it) }

    /** Replaces the rendered ranges of session [sessionId]. */
    fun setRenderedRanges(sessionId: String, ranges: List<RenderedRangeMsg>, done: Completion<Unit>) {
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
                bindings.getOrPut(session) {
                    RenderedRangeBinding(
                        backend = backend,
                        snapshot = session.snapshot,
                        handler = handler,
                        ready = { session.isOpen && !session.isSuspended },
                        alive = { sessions(session.sessionId) === session },
                    )
                }
            }
            binding.apply(entries)
            done.succeed(Unit)
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t))
        }
    }

    /** The swap of [session], or null (tests). */
    fun swapOf(session: PreviewSession): RenderedRangeSwap? = synchronized(bindings) { bindings[session]?.swap }
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
