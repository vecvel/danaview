// OWNER: AND-03
//
// Engine disk caches and the launch wipe of work/ (ARCH §15, §18.3, design/native.md §8.1;
// BUILD_PLAN AND-03, same contract as iOS IOS-03). Caches live under <cache>/vwish/editor/ and are
// LRU by access time (a hit touches the file's modification time, which serves as its access time
// because atime is not kept on Android's data partitions):
//
//   thumbs/   300 MB   `.vwth` strips (ThumbnailService)
//   waves/     64 MB   `.vwpk` peaks (WaveformService, AND-04)
//   sprites/  400 MB   sprite atlases (AND-09)
//   looks/     64 MB   look stills
//   proxies/  min(4 GB, 10 % free), enforced by ProxyRegistry (AND-05) through `evict`
//
// Files used by an open session are pinned (never evicted; counted). `trim(clearAll)` ("Clear
// editor cache") is refused while a session or job is active (`beginActivity`/`endActivity`,
// called by the job registry and preview sessions). `trim(background)` evicts every store to half
// its cap; `trim(memoryPressure)` touches no file (ThumbnailService drops its extractors).
//
// Launch wipe (`onRootsReady`, on vwish-io): work/picks and work/drops entries older than 24 h are
// removed; every other entry of work/ is removed except
//   - paths registered as active (`markActive`, running jobs of this process, AND-05..AND-07,
//     AND-11), and
//   - outputs of unconsumed completedWhileDetached export records, registered by AND-11 with
//     `WorkExemptions.add(file, paths)` (7-day expiry; expired ones are wiped). The exemptions are
//     persisted at <cache>/vwish/editor/work-exemptions.json (outside work/), so they survive the
//     process death that a detached completion implies (D-39).
// Android has no resumable jobs (exports and media jobs keep running under the FGS lease, ARCH §15
// 'Job interruption'), so there is no checkpoint exemption as on iOS.
//
// The stores are shared per cache root (`DiskCache.stores(paths)`), so ThumbnailService,
// WaveformService, ProxyRegistry and this glue-facing service see the same pins and LRU state.
// Never logs paths.

package com.vecvel.vwish.editor.engine.media

import android.util.Log
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg
import org.json.JSONObject
import java.io.File
import java.io.IOException

/** One LRU directory of the engine cache. */
class CacheStore(val directory: File, @Volatile var capBytes: Long) {
    private val lock = Any()
    private val pinned = HashMap<String, Int>()

    /** The file for [key] (sanitised file name) with extension [ext]. */
    fun file(key: String, ext: String): File = File(directory, "${fileName(key)}.$ext")

    /** The cached file for [key], touched as most recently used; null on a miss. */
    fun lookup(key: String, ext: String, nowMs: Long = System.currentTimeMillis()): File? {
        val file = file(key, ext)
        if (!file.isFile) return null
        touch(file, nowMs)
        return file
    }

    /** The cached bytes for [key] (touching the file), null on a miss. */
    fun read(key: String, ext: String, nowMs: Long = System.currentTimeMillis()): ByteArray? {
        val file = lookup(key, ext, nowMs) ?: return null
        return try {
            file.readBytes()
        } catch (e: IOException) {
            null
        }
    }

    /** Stores [bytes] atomically under [key] (temp file + rename) and evicts down to the cap. */
    fun write(bytes: ByteArray, key: String, ext: String, nowMs: Long = System.currentTimeMillis()): File {
        ensureDirectory()
        val target = file(key, ext)
        val temp = File(directory, ".${target.name}.${Thread.currentThread().id}.tmp")
        try {
            temp.writeBytes(bytes)
            if (!temp.renameTo(target)) {
                target.delete()
                if (!temp.renameTo(target)) throw IOException("rename failed")
            }
        } catch (e: IOException) {
            temp.delete()
            throw EngineErrors.from(e)
        }
        touch(target, nowMs)
        evict(capBytes)
        return target
    }

    /** Creates [directory] when missing. */
    fun ensureDirectory() {
        if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) {
            throw EngineException(EngineErrorCode.io, "cannot create a cache directory")
        }
    }

    /** Marks [file] as used now. */
    fun touch(file: File, nowMs: Long = System.currentTimeMillis()) {
        file.setLastModified(nowMs)
    }

    // ---- pinning ----

    /** Pins [file] (counted): pinned files are never evicted. */
    fun pin(file: File) = synchronized(lock) { pinned[file.name] = (pinned[file.name] ?: 0) + 1 }

    /** Releases one pin of [file]. */
    fun unpin(file: File) = synchronized(lock) {
        val count = pinned[file.name] ?: return@synchronized
        if (count > 1) pinned[file.name] = count - 1 else pinned.remove(file.name)
    }

    /** Whether [file] is pinned. */
    fun isPinned(file: File): Boolean = synchronized(lock) { pinned.containsKey(file.name) }

    // ---- size and eviction ----

    /** One cached file. */
    data class Entry(val file: File, val bytes: Long, val accessedMs: Long)

    /** The regular files of the store (temp files excluded). */
    fun entries(): List<Entry> =
        directory.listFiles()?.filter { it.isFile && !it.name.startsWith(".") }?.map { Entry(it, it.length(), it.lastModified()) }.orEmpty()

    /** Bytes held by the store. */
    val totalBytes: Long get() = entries().sumOf { it.bytes }

    /** Deletes least recently used, unpinned files until the store holds at most [limit] bytes. Returns the bytes freed. */
    fun evict(limit: Long): Long = synchronized(lock) {
        val all = entries()
        var total = all.sumOf { it.bytes }
        if (total <= limit) return 0L
        var freed = 0L
        for (entry in all.sortedWith(compareBy({ it.accessedMs }, { it.file.name }))) {
            if (total <= limit) break
            if (pinned.containsKey(entry.file.name)) continue
            if (entry.file.delete()) {
                total -= entry.bytes
                freed += entry.bytes
            }
        }
        freed
    }

    /** Deletes every unpinned file. */
    fun clear(): Long = evict(0)

    companion object {
        private val SAFE = Regex("^[A-Za-z0-9._-]+$")

        /** A file-system-safe name: [A-Za-z0-9._-] kept up to 120 characters, otherwise [stableHash] (iOS `CacheStore.fileName`). */
        fun fileName(key: String): String =
            if (key.isNotEmpty() && key.length <= 120 && !key.startsWith(".") && SAFE.matches(key)) key else stableHash(key)

        /** 128-bit FNV-1a style hash as hex, identical to iOS `CacheStore.stableHash` (stable across launches; not cryptographic). */
        fun stableHash(text: String): String {
            var h1 = 0xcbf29ce484222325uL.toLong()
            var h2 = 0x84222325cbf29ce4uL.toLong()
            for (byte in text.toByteArray(Charsets.UTF_8)) {
                val b = byte.toLong() and 0xFF
                h1 = (h1 xor b) * 0x100000001B3L
                h2 = (h2 xor b) * 0x100000001B3L + 0x9E3779B97F4A7C15uL.toLong()
            }
            return String.format("%016x%016x", h1, h2)
        }
    }
}

/**
 * Outputs exempt from the work/ launch wipe until an expiry (completedWhileDetached, D-39), persisted
 * at <cache>/vwish/editor/work-exemptions.json as { "<path relative to work/>": expiryEpochMs }.
 * AND-11 adds an entry when it records a detached completion and removes it when the record is
 * consumed (same API as iOS `WorkExemptions`).
 */
object WorkExemptions {
    const val FILE_NAME = "work-exemptions.json"

    /** Lifetime of a completedWhileDetached output (7 days). */
    const val DETACHED_OUTPUT_LIFETIME_MS = 7L * 24 * 3600 * 1000

    private val lock = Any()

    private fun file(paths: Paths) = File(paths.cacheRoot, FILE_NAME)

    /** Relative path under work/ -> expiry (epoch ms). */
    fun load(paths: Paths): Map<String, Long> = synchronized(lock) { loadLocked(paths) }

    private fun loadLocked(paths: Paths): Map<String, Long> {
        val f = file(paths)
        if (!f.isFile) return emptyMap()
        return try {
            val json = JSONObject(f.readText())
            json.keys().asSequence().associateWith { json.getLong(it) }
        } catch (e: Exception) {
            emptyMap()
        }
    }

    private fun saveLocked(map: Map<String, Long>, paths: Paths) {
        val json = JSONObject()
        for ((k, v) in map.toSortedMap()) json.put(k, v)
        paths.cacheRoot.mkdirs()
        val target = file(paths)
        val temp = File(paths.cacheRoot, ".$FILE_NAME.tmp")
        try {
            temp.writeText(json.toString())
            if (!temp.renameTo(target)) {
                target.delete()
                temp.renameTo(target)
            }
        } catch (e: IOException) {
            temp.delete()
        }
    }

    /** Exempts [file] (inside work/) from the wipe until [expiresMs]. Files outside work/ are ignored. */
    fun add(file: File, paths: Paths, expiresMs: Long = System.currentTimeMillis() + DETACHED_OUTPUT_LIFETIME_MS) {
        val relative = relativePath(file, paths) ?: return
        synchronized(lock) {
            val map = loadLocked(paths).toMutableMap()
            map[relative] = expiresMs
            saveLocked(map, paths)
        }
    }

    /** Ends the exemption of [file] (record consumed). */
    fun remove(file: File, paths: Paths) {
        val relative = relativePath(file, paths) ?: return
        synchronized(lock) {
            val map = loadLocked(paths).toMutableMap()
            if (map.remove(relative) != null) saveLocked(map, paths)
        }
    }

    /** Drops expired entries and returns the live ones (relative paths). */
    fun live(paths: Paths, nowMs: Long = System.currentTimeMillis()): Set<String> = synchronized(lock) {
        val map = loadLocked(paths)
        val alive = map.filterValues { it > nowMs }
        if (alive.size != map.size) saveLocked(alive, paths)
        alive.keys
    }

    /** [file] relative to work/ ("a/b.mp4"), or null when it is not below work/. */
    fun relativePath(file: File, paths: Paths): String? {
        val work = paths.work.absoluteFile.invariantSeparatorsPath.trimEnd('/')
        val path = file.absoluteFile.invariantSeparatorsPath
        if (!path.startsWith("$work/")) return null
        return path.removePrefix("$work/").trimEnd('/').ifEmpty { null }
    }
}

/** Engine disk caches (ARCH §15, §18.3; AND-03). */
class DiskCache(private val ctx: EngineContext) {
    /** Called on vwish-io when `initialize` installed new roots: runs the work/ wipe and enforces the caps. */
    fun onRootsReady() {
        val paths = ctx.pathsOrNull ?: return
        val started = System.nanoTime()
        val removed = wipeWork(paths)
        val stores = stores(paths)
        for (store in stores.capped) store.evict(store.capBytes)
        Log.i(EngineContext.TAG, "caches ready: work wipe removed $removed item(s) in ${(System.nanoTime() - started) / 1_000_000} ms")
    }

    /** Trims per [level] on vwish-io; `clearAll` empties the caches unless a session or job is active. */
    fun trim(level: CacheTrimLevelMsg) {
        val paths = ctx.pathsOrNull ?: return
        trim(level, paths)
    }

    /** Pins [file] in the store that holds it (open sessions; AND-10). Files outside the stores are ignored. */
    fun pin(file: File) {
        val paths = ctx.pathsOrNull ?: return
        stores(paths).owning(file)?.pin(file)
    }

    /** Releases one pin of [file]. */
    fun unpin(file: File) {
        val paths = ctx.pathsOrNull ?: return
        stores(paths).owning(file)?.unpin(file)
    }

    /** The shared stores of one cache root. */
    class Stores(paths: Paths) {
        val thumbs = CacheStore(paths.thumbs, THUMBS_CAP)
        val waves = CacheStore(paths.waves, WAVES_CAP)
        val sprites = CacheStore(paths.sprites, SPRITES_CAP)
        val looks = CacheStore(paths.looks, LOOKS_CAP)

        /** Proxies: the cap (min(4 GB, 10 % free)) is computed and applied by ProxyRegistry (AND-05). */
        val proxies = CacheStore(paths.proxies, Long.MAX_VALUE)

        /** The stores with a fixed cap. */
        val capped: List<CacheStore> get() = listOf(thumbs, waves, sprites, looks)

        /** Every store. */
        val all: List<CacheStore> get() = capped + proxies

        /** The store whose directory directly holds [file], or null. */
        fun owning(file: File): CacheStore? = all.firstOrNull { file.absoluteFile.parentFile == it.directory.absoluteFile }
    }

    companion object {
        const val MB = 1024L * 1024L
        const val THUMBS_CAP = 300 * MB
        const val WAVES_CAP = 64 * MB
        const val SPRITES_CAP = 400 * MB
        const val LOOKS_CAP = 64 * MB

        /** work/picks and work/drops lifetime (24 h). */
        const val PICK_LIFETIME_MS = 24L * 3600 * 1000

        private val registry = HashMap<File, Stores>()
        private var activeCount = 0
        private val activePaths = HashMap<String, Int>()

        /** The stores of [paths] (one instance per cache root, process-wide). */
        fun stores(paths: Paths): Stores = synchronized(registry) { registry.getOrPut(paths.cacheRoot) { Stores(paths) } }

        // ---- activity (sessions and jobs) ----

        /** Marks a session or job active (clear is refused while any is). Balanced by [endActivity]. */
        fun beginActivity() = synchronized(registry) { activeCount++ }

        /** Ends one activity of [beginActivity]. */
        fun endActivity() = synchronized(registry) { activeCount = maxOf(0, activeCount - 1) }

        /** Whether a session or job is active. */
        val isActive: Boolean get() = synchronized(registry) { activeCount > 0 }

        /** Protects a work/ path of a running job from the wipe (balanced by [unmarkActive]). */
        fun markActive(file: File) = synchronized(registry) {
            val key = file.absoluteFile.invariantSeparatorsPath
            activePaths[key] = (activePaths[key] ?: 0) + 1
        }

        /** Ends one [markActive] of [file]. */
        fun unmarkActive(file: File) = synchronized(registry) {
            val key = file.absoluteFile.invariantSeparatorsPath
            val count = activePaths[key] ?: return@synchronized
            if (count > 1) activePaths[key] = count - 1 else activePaths.remove(key)
        }

        /** The paths marked active. */
        val activeWorkPaths: Set<String> get() = synchronized(registry) { activePaths.keys.toSet() }

        /**
         * memoryPressure: no disk work (in-memory caches are trimmed by their owners); background:
         * evict every store to half its cap; clearAll: delete every unpinned cached file (proxies
         * included), refused while a session or job is active. Returns false when a clear was refused.
         */
        fun trim(level: CacheTrimLevelMsg, paths: Paths): Boolean {
            val stores = stores(paths)
            when (level) {
                CacheTrimLevelMsg.MEMORY_PRESSURE -> Unit
                CacheTrimLevelMsg.BACKGROUND -> for (store in stores.capped) store.evict(store.capBytes / 2)
                CacheTrimLevelMsg.CLEAR_ALL -> {
                    if (isActive) {
                        Log.i(EngineContext.TAG, "clear refused: a session or job is active")
                        return false
                    }
                    for (store in stores.all) store.clear()
                }
            }
            return true
        }

        // ---- work/ wipe ----

        /** The launch wipe of work/ (see the file comment). Returns the number of removed entries. */
        fun wipeWork(paths: Paths, nowMs: Long = System.currentTimeMillis()): Int {
            val work = paths.work
            val names = work.list() ?: return 0
            val active = activeWorkPaths
            val exempt = WorkExemptions.live(paths, nowMs)
            var removed = 0

            fun isProtected(file: File): Boolean {
                val path = file.absoluteFile.invariantSeparatorsPath
                if (active.any { it == path || it.startsWith("$path/") || path.startsWith("$it/") }) return true
                val relative = WorkExemptions.relativePath(file, paths) ?: return false
                return exempt.any { it == relative || it.startsWith("$relative/") }
            }

            for (name in names) {
                val entry = File(work, name)
                if (name == "picks" || name == "drops") {
                    removed += wipeOld(entry, nowMs - PICK_LIFETIME_MS, ::isProtected)
                    continue
                }
                if (isProtected(entry)) continue
                if (entry.deleteRecursively()) removed++
            }
            return removed
        }

        /** Removes the entries of [directory] last modified before [cutoffMs] (unless protected). */
        private fun wipeOld(directory: File, cutoffMs: Long, isProtected: (File) -> Boolean): Int {
            var removed = 0
            for (entry in directory.listFiles().orEmpty()) {
                if (isProtected(entry)) continue
                if (newestModification(entry) < cutoffMs && entry.deleteRecursively()) removed++
            }
            return removed
        }

        /** The newest modification time below [file] (a pick directory holds the picked file). */
        private fun newestModification(file: File): Long =
            if (file.isDirectory) maxOf(file.lastModified(), file.listFiles().orEmpty().maxOfOrNull { newestModification(it) } ?: 0L)
            else file.lastModified()
    }
}
