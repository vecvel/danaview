// OWNER: AND-10
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-10: sessions over a SurfaceProducer (resetInBackground), the PreviewBackend interface (backed
// by AND-16 on the AND-01 no-go), suspension during export on minimal/low/mid tiers (ARCH §14.3).

package com.vecvel.vwish.editor.engine.preview

import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.vwish.editor.engine.pigeon.PreviewConfigMsg
import com.vecvel.vwish.editor.engine.pigeon.PreviewOpenedMsg
import io.flutter.view.TextureRegistry

/** Preview sessions of the process (ARCH §12.2, §13; AND-10). Called on vwish-preview. */
class PreviewSessionManager(private val ctx: EngineContext) {
    /**
     * Opens a session whose texture comes from [textures] (the registry of the Flutter engine that
     * called) and completes with its session and texture ids.
     */
    fun open(config: PreviewConfigMsg, textures: TextureRegistry, done: Completion<PreviewOpenedMsg>) {
        done.fail(EngineErrors.notSupported("preview"))
    }

    /** The open session [sessionId], or null. */
    fun get(sessionId: String): PreviewSession? = null

    /** Disposes every session whose texture came from [textures] (that Flutter engine detached). */
    fun releaseAll(textures: TextureRegistry) = Unit

    /** Drops caches per [level] (`EngineHostApi.trimCaches`, memory warnings); called on vwish-preview. */
    fun trim(level: CacheTrimLevelMsg) = Unit
}
