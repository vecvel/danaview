// OWNER: AND-12
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-12: SAF ACTION_CREATE_DOCUMENT copy and ACTION_SEND through the engine FileProvider
// (ctx.fileProviderAuthority), granting read access only to the chosen target.

package com.vecvel.danaview.editor.engine.platform

import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.pigeon.FileHandoffResultMsg

/** Save to Files and Share (ARCH §12.4, §14.3; AND-12). Called on main. */
class FileHandoff(private val ctx: EngineContext) {
    /** Lets the user save a copy of [path] (inside the engine roots) as [suggestedName]. */
    fun saveToFiles(path: String, suggestedName: String, done: Completion<FileHandoffResultMsg>) {
        done.fail(EngineErrors.notSupported("save to files"))
    }

    /** Opens the share sheet for [path] (inside the engine roots). */
    fun share(path: String, done: Completion<FileHandoffResultMsg>) {
        done.fail(EngineErrors.notSupported("share"))
    }
}
