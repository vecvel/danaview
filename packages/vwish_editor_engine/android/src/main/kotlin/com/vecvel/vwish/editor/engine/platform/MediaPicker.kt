// OWNER: AND-14
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.

package com.vecvel.vwish.editor.engine.platform

import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.pigeon.MediaPickRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.PickedMediaMsg

/** Photo Picker and SAF pickers (ARCH §15 Pickers; AND-14). Called on main. */
class MediaPicker(private val ctx: EngineContext) {
    /** Shows the picker; an empty list means cancelled. */
    fun pick(request: MediaPickRequestMsg, done: Completion<List<PickedMediaMsg>>) {
        done.fail(EngineErrors.notSupported("pickers"))
    }
}
