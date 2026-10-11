// OWNER: AND-03
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-03: LRU-by-access-time caches under <cache>/vwish/editor/{thumbs,waves,proxies,sprites,...}
// with size caps, pinning, trim/clear (refused while active) and the work/ wipe at launch with the
// IOS-03 exemptions (ARCH §15).

package com.vecvel.vwish.editor.engine.media

import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg

/** Engine disk caches (ARCH §15, §18.3; AND-03). */
class DiskCache(private val ctx: EngineContext) {
    /** Called on vwish-io when `initialize` installed new roots (runs the work/ wipe at launch). */
    fun onRootsReady() = Unit

    /** Trims per [level] on vwish-io; `clearAll` empties the caches unless a session or job is active. */
    fun trim(level: CacheTrimLevelMsg) = Unit
}
