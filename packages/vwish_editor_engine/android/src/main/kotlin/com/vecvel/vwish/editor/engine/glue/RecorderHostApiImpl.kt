// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// `RecorderHostApi` glue (ARCH §12.4, §12.6, §15). permission, start, stop and cancel run on
// vwish-io; requestPermission and openSettings on main (they need the activity). Levels and
// interruptions travel as events keyed by the recording id.

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.EngineThreads
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.pigeon.MicPermissionMsg
import com.vecvel.vwish.editor.engine.pigeon.RecordedAssetMsg
import com.vecvel.vwish.editor.engine.pigeon.RecorderHostApi

/** `RecorderHostApi` handlers. [paths] gives the installed roots (output path checks). */
class RecorderHostApiImpl(
    private val threads: EngineThreads,
    private val port: RecorderPort,
    private val paths: () -> Paths?,
    private val dispatch: GlueDispatcher = GlueDispatcher(threads.main),
) : RecorderHostApi {
    override fun permission(callback: (Result<MicPermissionMsg>) -> Unit) =
        dispatch.async(threads.io, callback) { done -> port.permission(done) }

    override fun requestPermission(callback: (Result<MicPermissionMsg>) -> Unit) =
        dispatch.async(threads.main, callback) { done -> port.requestPermission(done) }

    override fun openSettings(callback: (Result<Unit>) -> Unit) =
        dispatch.async(threads.main, callback) { done -> port.openSettings(done) }

    override fun start(outputPath: String, callback: (Result<String>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.output("outputPath", outputPath, paths()) }) { done ->
            port.start(outputPath, done)
        }

    override fun stop(recordingId: String, callback: (Result<RecordedAssetMsg>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.id("recordingId", recordingId) }) { done -> port.stop(recordingId, done) }

    override fun cancel(recordingId: String, callback: (Result<Unit>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.id("recordingId", recordingId) }) { done -> port.cancel(recordingId, done) }
}
