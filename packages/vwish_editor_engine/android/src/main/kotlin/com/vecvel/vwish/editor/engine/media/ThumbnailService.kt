// OWNER: AND-03
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-03: JPEG strips of framesPerTile frames via FrameExtractor (CLOSEST_SYNC) on vwish-jobs,
// priorities, cancellation by requestId, <= 8 concurrent.

package com.vecvel.vwish.editor.engine.media

import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbPriorityMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbnailRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbnailTileMsg

/** Thumbnail strips (ARCH §12.3, §15; AND-03). Called on vwish-jobs. */
class ThumbnailService(private val ctx: EngineContext) {
    /** Produces the tile for [request]; a cancelled request completes with `cancelled`. */
    fun requestTile(requestId: String, request: ThumbnailRequestMsg, priority: ThumbPriorityMsg, done: Completion<ThumbnailTileMsg>) {
        done.fail(EngineErrors.notSupported("thumbnails"))
    }

    /** Cancels the pending tile [requestId]. Unknown ids are ignored. */
    fun cancel(requestId: String) = Unit

    /** Drops in-memory state per [level] (`EngineHostApi.trimCaches`, memory warnings). */
    fun trim(level: CacheTrimLevelMsg) = Unit
}
