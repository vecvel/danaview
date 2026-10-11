// OWNER: AND-12
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.

package com.vecvel.vwish.editor.engine.platform

import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.pigeon.FileHandoffResultMsg

/** Gallery insert through MediaStore with IS_PENDING (ARCH §14.3; AND-12). Called on vwish-io. */
class MediaStoreSaver(private val ctx: EngineContext) {
    /** Inserts the video at [path] (inside the engine roots) into Movies/Vwish. */
    fun saveToPhotos(path: String, done: Completion<FileHandoffResultMsg>) {
        done.fail(EngineErrors.notSupported("save to gallery"))
    }
}
