// OWNER: AND-18
//
// The render-preview services of one process EngineContext (ARCH D-45, §12.2-§12.4), reached from
// the glue (`glue/ContextPorts.kt`, INT-06) through [RenderPreviewServices.of]. INT-06 created the
// class names, constructors and method signatures as D-33 placeholders; AND-18 implements them:
// - [RenderPreviewJobService] (RenderPreviewJobService.kt): `renderPreview` jobs registered with
//   AND-05's job registry (danaview-jobs).
// - [RenderedRangeHandler] (RenderedRangeHandler.kt): `setRenderedRanges`, played by AND-16's
//   backend through RenderedRangeSwap during playback only (danaview-preview).
// - [PowerStateMonitor] (PowerStateMonitor.kt): `powerState` and the `powerStateChanged` signal
//   (main).
// Creating the services (first use in a process, roots installed) sweeps stale render part files
// on danaview-io (RenderPreviewJobService.sweep).

package com.vecvel.danaview.editor.engine.preview.render

import com.vecvel.danaview.editor.engine.core.EngineContext
import java.util.WeakHashMap
import java.util.concurrent.RejectedExecutionException

/** The render-preview services of one process [EngineContext] (D-45). */
class RenderPreviewServices private constructor(ctx: EngineContext) {
    /** Render-preview jobs (danaview-jobs). */
    val jobs = RenderPreviewJobService(ctx)

    /** Rendered ranges of preview sessions (danaview-preview). */
    val renderedRanges = RenderedRangeHandler(ctx)

    /** Charging and battery-saver state (main). */
    val power = PowerStateMonitor(ctx)

    init {
        // The first use in a process (the editor opening a session, asking the power state or
        // starting a render) removes part files a killed process left in the renders directory.
        ctx.pathsOrNull?.let { paths ->
            try {
                ctx.threads.io.execute { jobs.sweep(paths) }
            } catch (e: RejectedExecutionException) {
                // Shutting down.
            }
        }
    }

    companion object {
        private val instances = WeakHashMap<EngineContext, RenderPreviewServices>()

        /** The services of [ctx], created on first use. */
        @Synchronized
        fun of(ctx: EngineContext): RenderPreviewServices = instances.getOrPut(ctx) { RenderPreviewServices(ctx) }
    }
}
