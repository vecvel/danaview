// OWNER: AND-14
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.

package com.vecvel.danaview.editor.engine.platform

import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.fail

/** Runtime permissions other than the microphone (ARCH §15; AND-14). Called on main. */
class Permissions(private val ctx: EngineContext) {
    /** Requests POST_NOTIFICATIONS in context (API 33+); true when granted. */
    fun requestNotificationPermission(done: Completion<Boolean>) {
        done.fail(EngineErrors.notSupported("notification permission"))
    }
}
