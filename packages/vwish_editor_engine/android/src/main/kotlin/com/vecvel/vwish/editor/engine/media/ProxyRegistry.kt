// OWNER: AND-05
//
// Proxy status by fingerprint and the proxies/ LRU cap (ARCH §9.5, §15; BUILD_PLAN AND-05, same
// contract as iOS IOS-05 ProxyRegistry). Proxies live in `<cache>/vwish/editor/proxies/
// <quickHash>-540.mp4` (the fingerprint is the quickHash, made file-safe by
// `CacheStore.fileName`). Status: `ready` when the file exists, otherwise what the JobRegistry
// recorded for the fingerprint (queued, running, failed), otherwise `noProxy`. The directory is the
// shared DiskCache proxies store, capped at min(4 GB, 10 % of the free space) by access time;
// pinned proxies (open preview sessions) and the proxy just written are never evicted.
// Never logs paths or fingerprints.

package com.vecvel.vwish.editor.engine.media

import android.util.Log
import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.core.succeed
import com.vecvel.vwish.editor.engine.pigeon.ProxyStatusMsg
import java.io.File

/** Proxy status by fingerprint and LRU cap (ARCH §9.5, §15; AND-05). Called on vwish-io. */
class ProxyRegistry(private val ctx: EngineContext) {
    /** The proxy status of the media with [fingerprint]. */
    fun status(fingerprint: String, done: Completion<ProxyStatusMsg>) {
        val paths = ctx.pathsOrNull
        if (paths == null) {
            done.fail(EngineErrors.notInitialized())
            return
        }
        try {
            done.succeed(status(fingerprint, paths))
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t))
        }
    }

    companion object {
        /** The absolute cap of proxies/ (4 GB). */
        const val ABSOLUTE_CAP_BYTES = 4L * 1024 * 1024 * 1024

        /** The share of the free space proxies/ may use. */
        const val FREE_FRACTION = 0.10

        /** File name suffix and extension: `<quickHash>-540.mp4`. */
        const val SUFFIX = "-540"
        const val EXTENSION = "mp4"

        private val lock = Any()
        private val tracked = HashMap<String, ProxyStatusMsg>()

        /** The status of [fingerprint]: ready (file exists), the tracked job state, or noProxy. */
        fun status(fingerprint: String, paths: Paths): ProxyStatusMsg {
            if (proxyFile(fingerprint, paths).isFile) return ProxyStatusMsg.READY
            return synchronized(lock) { tracked[fingerprint] } ?: ProxyStatusMsg.NO_PROXY
        }

        /** Records the job state of [fingerprint] (JobRegistry); null forgets it (done or cancelled). */
        fun mark(fingerprint: String, status: ProxyStatusMsg?) {
            synchronized(lock) {
                if (status == null) tracked.remove(fingerprint) else tracked[fingerprint] = status
            }
        }

        /** The cache key of [fingerprint]'s proxy. */
        fun key(fingerprint: String): String = CacheStore.fileName(fingerprint) + SUFFIX

        /** The shared proxies/ store of [paths]. */
        fun store(paths: Paths): CacheStore = DiskCache.stores(paths).proxies

        /** `proxies/<quickHash>-540.mp4` (may not exist). */
        fun proxyFile(fingerprint: String, paths: Paths): File = store(paths).file(key(fingerprint), EXTENSION)

        /** The proxy of [fingerprint] when it exists, touched as recently used; else null. */
        fun readyProxy(fingerprint: String, paths: Paths): File? = store(paths).lookup(key(fingerprint), EXTENSION)

        /** Pins a proxy used by a preview session (AND-10), balanced by [unpin]. */
        fun pin(file: File, paths: Paths) = store(paths).pin(file)

        /** Releases one pin of [file]. */
        fun unpin(file: File, paths: Paths) = store(paths).unpin(file)

        /** min(4 GB, 10 % of [freeBytes]) (the free space of proxies/ when null). */
        fun capBytes(paths: Paths, freeBytes: Long? = null): Long {
            val free = freeBytes ?: freeSpace(paths)
            return minOf(ABSOLUTE_CAP_BYTES, (maxOf(0L, free) * FREE_FRACTION).toLong())
        }

        /**
         * Evicts least recently used, unpinned proxies above the cap. [keep] (a fresh proxy) is never
         * evicted. Returns the bytes freed.
         */
        fun enforceCap(paths: Paths, keep: File? = null, freeBytes: Long? = null): Long {
            val store = store(paths)
            val cap = capBytes(paths, freeBytes)
            store.capBytes = cap
            if (keep != null) store.pin(keep)
            try {
                val freed = store.evict(cap)
                if (freed > 0) Log.i(EngineContext.TAG, "proxies: evicted ${freed / 1024} KB (cap ${cap / (1024 * 1024)} MB)")
                return freed
            } finally {
                if (keep != null) store.unpin(keep)
            }
        }

        private fun freeSpace(paths: Paths): Long {
            var dir: File? = paths.proxies
            while (dir != null && !dir.exists()) dir = dir.parentFile
            return dir?.usableSpace ?: 0L
        }
    }
}
