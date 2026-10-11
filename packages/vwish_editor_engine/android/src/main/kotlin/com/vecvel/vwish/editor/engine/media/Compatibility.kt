// OWNER: AND-02
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.

package com.vecvel.vwish.editor.engine.media

import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.pigeon.CompatibilityMsg

/** Edit compatibility, <= 300 ms (ARCH §15; AND-02). Called on vwish-io. */
class Compatibility(private val ctx: EngineContext) {
    /** Whether [uri] is editable on this device. */
    fun check(uri: String, done: Completion<CompatibilityMsg>) {
        done.fail(EngineErrors.notSupported("compatibility"))
    }
}
