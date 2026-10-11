// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// `PlatformHostApi` glue (ARCH §9, §12.4, §12.6, §15). UI flows (pick, saveToFiles, share,
// notification permission, background leases, drop target) run on main; saveToPhotos, URI grants,
// stat and quickHash on vwish-io. Android-specific answers handled here:
// - createBookmark / resolveBookmark: iOS security-scoped bookmarks do not exist on Android →
//   `notSupportedOnDevice` (Android persists URI grants instead).
// - excludeFromBackup: Android excludes the whole `files/vwish/editor/` and `files/vwish/speech/`
//   trees through the app manifest's backup rules (ARCH §8.1, CORE-28), so there is nothing to do
//   per directory; paths outside the editor and speech roots are still refused (D-44).

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.EngineThreads
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.core.succeed
import com.vecvel.vwish.editor.engine.pigeon.FileHandoffResultMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaPickRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaRefMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaStatMsg
import com.vecvel.vwish.editor.engine.pigeon.PickedMediaMsg
import com.vecvel.vwish.editor.engine.pigeon.PlatformHostApi
import com.vecvel.vwish.editor.engine.pigeon.ResolvedBookmarkMsg

/** `PlatformHostApi` handlers. [paths] gives the installed roots (file and backup checks). */
class PlatformHostApiImpl(
    private val threads: EngineThreads,
    private val port: PlatformPort,
    private val paths: () -> Paths?,
    private val dispatch: GlueDispatcher = GlueDispatcher(threads.main),
) : PlatformHostApi {
    override fun pick(request: MediaPickRequestMsg, callback: (Result<List<PickedMediaMsg>>) -> Unit) =
        dispatch.async(threads.main, callback, check = {
            if (request.kinds.isEmpty()) Check.fail("kinds", "empty")
        }) { done -> port.pick(request, done) }

    override fun saveToPhotos(path: String, callback: (Result<FileHandoffResultMsg>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.ownedFile("path", path, paths()) }) { done -> port.saveToPhotos(path, done) }

    override fun saveToFiles(path: String, suggestedName: String, callback: (Result<FileHandoffResultMsg>) -> Unit) =
        dispatch.async(threads.main, callback, check = {
            Check.ownedFile("path", path, paths())
            Check.fileName("suggestedName", suggestedName)
        }) { done -> port.saveToFiles(path, suggestedName, done) }

    override fun share(path: String, callback: (Result<FileHandoffResultMsg>) -> Unit) =
        dispatch.async(threads.main, callback, check = { Check.ownedFile("path", path, paths()) }) { done -> port.share(path, done) }

    override fun createBookmark(uri: String, callback: (Result<ByteArray>) -> Unit) =
        dispatch.reply(callback, Result.failure(noBookmarks()))

    override fun resolveBookmark(bookmark: ByteArray, callback: (Result<ResolvedBookmarkMsg>) -> Unit) =
        dispatch.reply(callback, Result.failure(noBookmarks()))

    override fun persistUriGrant(uri: String, callback: (Result<Unit>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.contentUri("uri", uri) }) { done -> port.persistUriGrant(uri, done) }

    override fun releaseUriGrant(uri: String, callback: (Result<Unit>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.contentUri("uri", uri) }) { done -> port.releaseUriGrant(uri, done) }

    override fun remainingGrantBudget(callback: (Result<Long>) -> Unit) =
        dispatch.async(threads.io, callback) { done -> port.remainingGrantBudget(done) }

    override fun stat(media: MediaRefMsg, callback: (Result<MediaStatMsg?>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.mediaRef(media) }) { done -> port.stat(media, done) }

    override fun quickHash(media: MediaRefMsg, callback: (Result<String>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.mediaRef(media) }) { done -> port.quickHash(media, done) }

    override fun excludeFromBackup(path: String, callback: (Result<Unit>) -> Unit) =
        dispatch.async(threads.io, callback, check = { Check.backupDir(path, paths()) }) { done -> done.succeed(Unit) }

    override fun requestNotificationPermission(callback: (Result<Boolean>) -> Unit) =
        dispatch.async(threads.main, callback) { done -> port.requestNotificationPermission(done) }

    override fun acquireBackground(title: String, callback: (Result<String?>) -> Unit) =
        dispatch.async(threads.main, callback, check = { Check.title("title", title) }) { done -> port.acquireBackground(title, done) }

    override fun updateBackground(leaseId: String, progress: Double, callback: (Result<Unit>) -> Unit) =
        dispatch.async(threads.main, callback, check = {
            Check.id("leaseId", leaseId)
            Check.unit("progress", progress)
        }) { done -> port.updateBackground(leaseId, progress, done) }

    override fun releaseBackground(leaseId: String, callback: (Result<Unit>) -> Unit) =
        dispatch.async(threads.main, callback, check = { Check.id("leaseId", leaseId) }) { done -> port.releaseBackground(leaseId, done) }

    override fun setDropTargetEnabled(enabled: Boolean, callback: (Result<Unit>) -> Unit) =
        dispatch.async(threads.main, callback) { done -> port.setDropTargetEnabled(enabled, done) }

    private fun noBookmarks() = EngineException(EngineErrorCode.notSupportedOnDevice, "security-scoped bookmarks are iOS only")
}
