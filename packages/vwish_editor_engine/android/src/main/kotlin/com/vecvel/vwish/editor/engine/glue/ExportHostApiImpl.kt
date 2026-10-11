// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// `ExportHostApi` glue (ARCH §12.4, §12.6, §14.3). Everything runs on vwish-export. Android exports
// are not segment-resumable (D-22: the foreground service keeps them running), so `resume` answers
// `notSupportedOnDevice` here without reaching the coordinator.

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.EngineThreads
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.vwish.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.vwish.editor.engine.pigeon.ExportHostApi
import com.vecvel.vwish.editor.engine.pigeon.ExportJobRecordMsg
import com.vecvel.vwish.editor.engine.pigeon.ExportPreflightMsg

/** `ExportHostApi` handlers. [paths] gives the installed roots (output path checks). */
class ExportHostApiImpl(
    private val threads: EngineThreads,
    private val port: ExportPort,
    private val paths: () -> Paths?,
    private val dispatch: GlueDispatcher = GlueDispatcher(threads.main),
) : ExportHostApi {
    override fun preflight(plan: ByteArray, settings: EncodeSettingsMsg, callback: (Result<ExportPreflightMsg>) -> Unit) =
        dispatch.async(threads.export, callback, check = {
            Check.planBytes("plan", plan)
            Check.settings(settings)
        }) { done -> port.preflight(plan, settings, done) }

    override fun start(
        plan: ByteArray,
        settings: EncodeSettingsMsg,
        outputPath: String,
        title: String,
        whenDetached: DetachedHandoffMsg,
        callback: (Result<String>) -> Unit,
    ) = dispatch.async(threads.export, callback, check = {
        Check.planBytes("plan", plan)
        Check.settings(settings)
        Check.output("outputPath", outputPath, paths())
        Check.title("title", title)
    }) { done -> port.start(plan, settings, outputPath, title, whenDetached, done) }

    override fun resume(jobId: String, callback: (Result<String>) -> Unit) =
        dispatch.reply(callback, Result.failure(EngineException(EngineErrorCode.notSupportedOnDevice, "exports are not resumable on Android")))

    override fun cancel(jobId: String, callback: (Result<Unit>) -> Unit) =
        dispatch.async(threads.export, callback, check = { Check.id("jobId", jobId) }) { done -> port.cancel(jobId, done) }

    override fun activeJobs(callback: (Result<List<ExportJobRecordMsg>>) -> Unit) =
        dispatch.async(threads.export, callback) { done -> port.activeJobs(done) }

    override fun consumeJobRecord(jobId: String) =
        dispatch.fireAndForget(threads.export, "consumeJobRecord", check = { Check.id("jobId", jobId) }) {
            port.consumeJobRecord(jobId)
        }
}
