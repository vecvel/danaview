// OWNER: AND-11
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-11: process-scoped coordinator, one Transformer per job on vwish-export, progress every
// 250 ms (ctx.events.exportProgress), error mapping, portrait retry, ActiveExportStore records.
// Android has no resumable exports: `ExportHostApi.resume` answers notSupportedOnDevice in the glue.

package com.vecvel.vwish.editor.engine.export

import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.core.succeed
import com.vecvel.vwish.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.vwish.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.vwish.editor.engine.pigeon.ExportJobRecordMsg
import com.vecvel.vwish.editor.engine.pigeon.ExportPreflightMsg

/** Export coordinator (ARCH §12.4, §14.3; AND-11). Called on vwish-export. */
class ExportCoordinator(private val ctx: EngineContext) {
    /** Checks [plan] (UTF-8 JSON) against [settings]; warnings for software encoders etc. */
    fun preflight(plan: ByteArray, settings: EncodeSettingsMsg, done: Completion<ExportPreflightMsg>) {
        done.fail(EngineErrors.notSupported("export"))
    }

    /** Starts an export to [outputPath] (inside the engine roots); completes with the job id. */
    fun start(
        plan: ByteArray,
        settings: EncodeSettingsMsg,
        outputPath: String,
        title: String,
        whenDetached: DetachedHandoffMsg,
        done: Completion<String>,
    ) {
        done.fail(EngineErrors.notSupported("export"))
    }

    /** Cancels [jobId] and deletes its partial output. */
    fun cancel(jobId: String, done: Completion<Unit>) {
        done.fail(EngineErrors.notSupported("export"))
    }

    /** Running jobs plus one-shot records until consumed (D-22, D-39). */
    fun activeJobs(done: Completion<List<ExportJobRecordMsg>>) {
        done.succeed(emptyList())
    }

    /** Marks the one-shot record of [jobId] as seen. */
    fun consumeJobRecord(jobId: String) = Unit
}
