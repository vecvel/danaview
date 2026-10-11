// OWNER: AND-15
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.

package com.vecvel.vwish.editor.engine.platform

import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.fail

/** External drop target on the FlutterView (ARCH §15 External drop, D-18; AND-15). Called on main. */
class DropTarget(private val ctx: EngineContext) {
    /** Enables or disables the drop target; drops arrive as ctx.events.drop. */
    fun setEnabled(enabled: Boolean, done: Completion<Unit>) {
        done.fail(EngineErrors.notSupported("external drop"))
    }
}
