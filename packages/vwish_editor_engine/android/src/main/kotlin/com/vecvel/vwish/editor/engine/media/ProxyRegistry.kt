// OWNER: AND-05
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.

package com.vecvel.vwish.editor.engine.media

import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.pigeon.ProxyStatusMsg

/** Proxy status by fingerprint and LRU cap (ARCH §9.5, §15; AND-05). Called on vwish-io. */
class ProxyRegistry(private val ctx: EngineContext) {
    /** The proxy status of the media with [fingerprint]. */
    fun status(fingerprint: String, done: Completion<ProxyStatusMsg>) {
        done.fail(EngineErrors.notSupported("proxies"))
    }
}
