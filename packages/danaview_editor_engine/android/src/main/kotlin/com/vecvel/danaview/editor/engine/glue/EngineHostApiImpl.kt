// OWNER: ENG-08 (frozen by ENG-06, D-42; amended by INT-07: the localized export notification texts
// of `initialize`, validated and handed to the port)
//
// `EngineHostApi` glue (ARCH §12.1, §12.6). Threads: initialize, capabilities, compatibility,
// probe and freeBytes on danaview-io; trimCaches fans out to the cache owners' lanes.

package com.vecvel.danaview.editor.engine.glue

import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.pigeon.CapabilitiesMsg
import com.vecvel.danaview.editor.engine.pigeon.CompatibilityMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineConfigMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineHostApi
import com.vecvel.danaview.editor.engine.pigeon.ProbeMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg

/** `EngineHostApi` handlers. */
class EngineHostApiImpl(
    private val threads: EngineThreads,
    private val port: EngineRootPort,
    private val dispatch: GlueDispatcher = GlueDispatcher(threads.main),
) : EngineHostApi {
    override fun initialize(config: EngineConfigMsg, callback: (Result<Unit>) -> Unit) {
        lateinit var paths: Paths
        dispatch.async(threads.io, callback, check = {
            paths = Paths.fromDart(config.cacheRoot, config.supportRoot)
            config.exportTexts?.let { Check.notificationTexts(it) }
        }) { done ->
            config.exportTexts?.let { port.setExportTexts(it) }
            port.installRoots(paths, done)
        }
    }

    override fun capabilities(callback: (Result<CapabilitiesMsg>) -> Unit) =
        dispatch.async(threads.io, callback) { done -> port.capabilities(done) }

    override fun compatibility(uri: String, callback: (Result<CompatibilityMsg>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.mediaUri("uri", uri) }) { done -> port.compatibility(uri, done) }

    override fun probe(media: ResolvedMediaMsg, callback: (Result<ProbeMsg>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.media(media) }) { done -> port.probe(media, done) }

    override fun freeBytes(path: String, callback: (Result<Long>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.absolutePath("path", path) }) { done -> port.freeBytes(path, done) }

    /** Synchronous and fire-and-forget: the port posts to the cache owners' lanes; failures are logged. */
    override fun trimCaches(level: CacheTrimLevelMsg) {
        try {
            port.trimCaches(level)
        } catch (t: Throwable) {
            GlueLog.warn("trimCaches", t)
        }
    }
}
