// OWNER: AND-06
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-06: source frames for showSourceFrame, sampleColor (pre-key, 3x3 average) and look stills.

package com.vecvel.danaview.editor.engine.preview

import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg

/** Source-frame cache (ARCH §12.2, §15; AND-06). */
class SourceFrameCache(private val ctx: EngineContext) {
    /** Drops cached frames per [level] (`EngineHostApi.trimCaches`, memory warnings); called on danaview-preview. */
    fun trim(level: CacheTrimLevelMsg) = Unit
}
