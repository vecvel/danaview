// OWNER: AND-18
//
// D-33 placeholders created by INT-06 (ARCH D-45, §12.2-§12.4) for the Android render-preview
// cache, reached from the glue (`glue/ContextPorts.kt`) through [RenderPreviewServices.of]. AND-18
// replaces the bodies and keeps the class names, constructors and method signatures:
// - [RenderPreviewJobService]: a `RenderPreviewJob` registered with AND-05's job registry that
//   exports the range plan through AND-08's mapper at the preview canvas size, project fps on the
//   frame grid, intra-only or short-GOP H.264, video only, to `outputPath` inside `<cache>/renders/`;
//   progress, cancel (deletes the partial file) and failures through the job events.
// - [RenderedRangeHandler]: hands the ranges to the session's playback swap-in (AND-16 backend),
//   which plays them from their files during playback only and drops a range when an applied patch
//   touches it (and every range on `setPlan`) until the next call.
// - [PowerStateMonitor]: charging (`BatteryManager.isCharging` / ACTION_POWER_CONNECTED) and battery
//   saver (`PowerManager.isPowerSaveMode` / ACTION_POWER_SAVE_MODE_CHANGED), emitting
//   `signal(powerStateChanged, powerState)` through EventHub on every change.

package com.vecvel.danaview.editor.engine.preview.render

import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.PowerStateMsg
import com.vecvel.danaview.editor.engine.pigeon.RenderedRangeMsg
import java.util.WeakHashMap

/** The render-preview services of one process [EngineContext] (D-45). */
class RenderPreviewServices private constructor(ctx: EngineContext) {
    /** Render-preview jobs (danaview-jobs). */
    val jobs = RenderPreviewJobService(ctx)

    /** Rendered ranges of preview sessions (danaview-preview). */
    val renderedRanges = RenderedRangeHandler(ctx)

    /** Charging and battery-saver state (main). */
    val power = PowerStateMonitor(ctx)

    companion object {
        private val instances = WeakHashMap<EngineContext, RenderPreviewServices>()

        /** The services of [ctx], created on first use. */
        @Synchronized
        fun of(ctx: EngineContext): RenderPreviewServices = instances.getOrPut(ctx) { RenderPreviewServices(ctx) }
    }
}

/** Placeholder of the render-preview job service (AND-18). */
class RenderPreviewJobService(@Suppress("unused") private val ctx: EngineContext) {
    /** Starts a render of [plan] (UTF-8 JSON range plan) into [outputPath]; completes with the job id. */
    fun start(request: JobRequestMsg, plan: ByteArray, outputPath: String, done: Completion<String>) =
        done.fail(EngineErrors.notSupported("render preview"))
}

/** Placeholder of the rendered-range handler (AND-18). */
class RenderedRangeHandler(@Suppress("unused") private val ctx: EngineContext) {
    /** Replaces the rendered ranges of session [sessionId]. */
    fun setRenderedRanges(sessionId: String, ranges: List<RenderedRangeMsg>, done: Completion<Unit>) =
        done.fail(EngineErrors.notSupported("rendered ranges"))
}

/** Placeholder of the power/idle signal (AND-18). */
class PowerStateMonitor(@Suppress("unused") private val ctx: EngineContext) {
    /** The current charging and battery-saver state. */
    fun powerState(done: Completion<PowerStateMsg>) = done.fail(EngineErrors.notSupported("power state"))
}
