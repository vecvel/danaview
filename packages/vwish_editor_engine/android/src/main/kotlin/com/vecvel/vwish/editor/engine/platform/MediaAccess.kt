// OWNER: AND-14
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-14: takePersistableUriPermission / release, grant budget (512 on API 30+, 128 before),
// ContentResolver stat and quickHash (same algorithm as the core fixtures).

package com.vecvel.vwish.editor.engine.platform

import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.pigeon.MediaRefMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaStatMsg

/** URI grants and media access (ARCH §9, §15; AND-14). Called on vwish-io. */
class MediaAccess(private val ctx: EngineContext) {
    private fun <T> unavailable(done: Completion<T>) = done.fail(EngineErrors.notSupported("media access"))

    /** Persists read access to the content [uri]. */
    fun persistUriGrant(uri: String, done: Completion<Unit>) = unavailable(done)

    /** Releases a persisted grant of [uri]. */
    fun releaseUriGrant(uri: String, done: Completion<Unit>) = unavailable(done)

    /** Persisted grants still available. */
    fun remainingGrantBudget(done: Completion<Long>) = unavailable(done)

    /** Size and modification time; null when missing, `permissionDenied` when access was lost. */
    fun stat(media: MediaRefMsg, done: Completion<MediaStatMsg?>) = unavailable(done)

    /** quickHash of the media (the fingerprint of ARCH §9). */
    fun quickHash(media: MediaRefMsg, done: Completion<String>) = unavailable(done)
}
