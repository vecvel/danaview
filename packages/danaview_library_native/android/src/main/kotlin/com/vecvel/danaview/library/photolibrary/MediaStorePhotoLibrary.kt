// OWNER: HOM-02A
//
// The MediaStore photo library (ARCH v1.2 §8, V2-103, V2-111): access state, paged fetches with
// change tokens, albums (device folders), EXIF basics, create-new copies of originals, and a
// ContentObserver → change events. Flutter-free: the glue (glue/PhotoLibraryHostApiImpl.kt) calls
// these blocking methods on its background executor and replies on the main thread; instrumented
// tests call them directly. Paging uses the ContentResolver query Bundle (QUERY_ARG_LIMIT/OFFSET) on
// API 30+, and a moved cursor below (a LIMIT clause in the sort order is rejected from API 30 on).
// Sources are opened read-only (rule 27), copies are create-new (rule 26), nothing touches the
// network (rule 21), and no name, path or id is logged (rule 30).

package com.vecvel.danaview.library.photolibrary

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import androidx.annotation.RequiresApi
import androidx.exifinterface.media.ExifInterface
import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.pigeon.PhotoAlbumMsg
import com.vecvel.danaview.library.pigeon.PhotoAssetDetailMsg
import com.vecvel.danaview.library.pigeon.PhotoAssetKindMsg
import com.vecvel.danaview.library.pigeon.PhotoAssetMsg
import com.vecvel.danaview.library.pigeon.PhotoAuthorizationMsg
import com.vecvel.danaview.library.pigeon.PhotoCopyRequestMsg
import com.vecvel.danaview.library.pigeon.PhotoCopyResultMsg
import com.vecvel.danaview.library.pigeon.PhotoFetchRequestMsg
import com.vecvel.danaview.library.pigeon.PhotoLibraryChangeMsg
import com.vecvel.danaview.library.pigeon.PhotoMediaFilterMsg
import com.vecvel.danaview.library.pigeon.PhotoPageMsg
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream

/** Where the library's events go (the glue forwards them to the Dart event stream). */
interface PhotoLibraryEvents {
    fun libraryChanged(change: PhotoLibraryChangeMsg)

    fun authorizationChanged(status: PhotoAuthorizationMsg)

    fun copyProgress(requestId: String, bytesDone: Long, bytesTotal: Long?)
}

class MediaStorePhotoLibrary(
    context: Context,
    private val events: PhotoLibraryEvents,
    /** Whether a runtime permission is granted (tests inject one). */
    private val granted: (String) -> Boolean = { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED },
    /** Debounce of change notifications (bursts of one import arrive within a few ms). */
    private val changeDelayMs: Long = 300,
) {
    private val appContext = context.applicationContext ?: context
    private val resolver: ContentResolver = appContext.contentResolver
    private val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val lock = Any()

    // Guarded by `lock`.
    private var lastAuthorization: PhotoAuthorizationMsg? = null
    private val runningCopies = HashSet<String>()
    private val cancelledCopies = HashSet<String>()
    private var observer: ContentObserver? = null
    private var observerThread: HandlerThread? = null
    private var lastToken: String? = null
    private val collector = ChangeCollector()
    private var flushScheduled = false

    /** The images and videos of every external volume (the `files` table). */
    private val collection: Uri = Uris.files()

    // ---------------------------------------------------------------------------------------------
    // Authorization

    /** Current access, without prompting. [deniedOnce]: the Activity's rationale flag. */
    fun authorizationStatus(deniedOnce: Boolean = false): PhotoAuthorizationMsg =
        PhotoPermissions.status(Build.VERSION.SDK_INT, granted, prefs.getBoolean(KEY_ASKED, false), deniedOnce)

    /** Remembers that the system dialog was shown once (Android has no "not determined" state). */
    fun markAsked() {
        prefs.edit().putBoolean(KEY_ASKED, true).apply()
    }

    /**
     * Records [status] and sends `photoAuthorizationChanged` when it differs from the last one
     * seen (after a request, on resume from the system settings).
     */
    fun noteAuthorization(status: PhotoAuthorizationMsg = authorizationStatus()) {
        val previous = synchronized(lock) {
            val p = lastAuthorization
            lastAuthorization = status
            p
        }
        if (previous != null && previous != status) events.authorizationChanged(status)
    }

    private fun requireRead() {
        val status = authorizationStatus()
        synchronized(lock) { if (lastAuthorization == null) lastAuthorization = status }
        if (!PhotoPermissions.canRead(status)) throw LibraryErrors.error(LibraryErrorCode.permissionDenied, "no photo library access")
    }

    // ---------------------------------------------------------------------------------------------
    // Fetching

    /** One page of the library or of a device folder. */
    fun fetchPage(request: PhotoFetchRequestMsg): PhotoPageMsg {
        requireRead()
        val (offset, limit) = MediaStoreQuery.window(request.offset, request.limit)
        val selection = MediaStoreQuery.selection(request.filter, request.albumId)
        val token = currentToken()
        val total = count(selection)
        if (total == 0 && request.albumId != null && count(MediaStoreQuery.selection(PhotoMediaFilterMsg.ALL, request.albumId)) == 0) {
            throw LibraryErrors.error(LibraryErrorCode.notFound, "album not found")
        }
        val assets = ArrayList<PhotoAssetMsg>(minOf(limit, maxOf(total - offset, 0)))
        if (offset < total) {
            val projection = Col.gridProjection(Build.VERSION.SDK_INT)
            val sort = MediaStoreQuery.sortOrder(request.sort)
            if (Build.VERSION.SDK_INT >= 30) {
                queryPage(projection, selection, sort, offset, limit)?.use { c -> readRows(c, limit, assets) }
            } else {
                resolver.query(collection, projection, selection.sql, selection.args, sort)?.use { c ->
                    if (c.moveToPosition(offset - 1) || offset == 0) readRows(c, limit, assets)
                }
            }
        }
        return PhotoPageMsg(assets, offset.toLong(), total.toLong(), token, ChangeTokens.isStale(request.changeToken, token))
    }

    /** Assets by id in the given order; unknown or invisible ids are left out. */
    fun fetchAssets(ids: List<String>): List<PhotoAssetMsg> {
        requireRead()
        val byId = HashMap<String, PhotoAssetMsg>()
        for (chunk in ids.distinct().chunked(400)) {
            val selection = MediaStoreQuery.idSelection(chunk)
            if (selection.args.isEmpty()) continue
            resolver.query(collection, Col.gridProjection(Build.VERSION.SDK_INT), selection.sql, selection.args, null)?.use { c ->
                val row = CursorRow(c)
                while (c.moveToNext()) PhotoAssetMapping.asset(row)?.let { byId[it.localIdentifier] = it }
            }
        }
        return ids.mapNotNull { byId[it] }
    }

    /** Device folders that hold images or videos. */
    fun fetchAlbums(): List<PhotoAlbumMsg> {
        requireRead()
        val buckets = LinkedHashMap<String, Albums.Bucket>()
        val selection = MediaStoreQuery.selection(PhotoMediaFilterMsg.ALL, null)
        resolver.query(collection, arrayOf(Col.BUCKET_ID, Col.BUCKET_DISPLAY_NAME), selection.sql, selection.args, null)?.use { c ->
            val row = CursorRow(c)
            while (c.moveToNext()) {
                val id = row.long(Col.BUCKET_ID)?.toString() ?: continue
                buckets.getOrPut(id) { Albums.Bucket(id, row.string(Col.BUCKET_DISPLAY_NAME)) }.count++
            }
        }
        return Albums.albums(buckets.values)
    }

    /** Every id the app can see now (the partial-access selection after a re-request). */
    fun visibleIds(): List<String> {
        requireRead()
        val ids = ArrayList<String>()
        val selection = MediaStoreQuery.selection(PhotoMediaFilterMsg.ALL, null)
        resolver.query(collection, arrayOf(Col.ID), selection.sql, selection.args, "${Col.ID} ASC")?.use { c ->
            while (c.moveToNext()) ids.add(c.getLong(0).toString())
        }
        return ids
    }

    /** The current change token of the visible images and videos. */
    fun currentToken(): String {
        val selection = MediaStoreQuery.selection(PhotoMediaFilterMsg.ALL, null)
        resolver.query(collection, arrayOf(Col.ID), selection.sql, selection.args, "${Col.ID} DESC")?.use { c ->
            val count = c.count
            val maxId = if (c.moveToFirst()) c.getLong(0) else null
            return ChangeTokens.of(count, maxId)
        }
        return ChangeTokens.of(0, null)
    }

    private fun count(selection: Selection): Int =
        resolver.query(collection, arrayOf(Col.ID), selection.sql, selection.args, null)?.use { it.count } ?: 0

    @RequiresApi(30)
    private fun queryPage(projection: Array<String>, selection: Selection, sort: String, offset: Int, limit: Int): Cursor? {
        val args = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection.sql)
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selection.args)
            putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, sort)
            putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
            putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
        }
        return resolver.query(collection, projection, args, null)
    }

    /** Reads up to [limit] rows from the cursor's next position. */
    private fun readRows(c: Cursor, limit: Int, out: MutableList<PhotoAssetMsg>) {
        val row = CursorRow(c)
        while (out.size < limit && c.moveToNext()) PhotoAssetMapping.asset(row)?.let(out::add)
    }

    // ---------------------------------------------------------------------------------------------
    // Detail

    /** EXIF basics and format flags of one asset; `notFound` when it is gone. */
    fun assetDetail(id: String): PhotoAssetDetailMsg {
        requireRead()
        val asset = fetchAssets(listOf(id)).firstOrNull() ?: throw LibraryErrors.error(LibraryErrorCode.notFound, "asset not found")
        val uri = contentUri(asset)
        var detail = PhotoAssetDetailMsg(
            localIdentifier = asset.localIdentifier,
            takenAtMs = asset.creationTimeMs,
            isRaw = asset.isRaw,
            isHdr = false,
            isLivePhoto = false,
            mimeType = asset.mimeType,
            originalFilename = asset.originalFilename,
            sizeBytes = asset.sizeBytes,
            locallyAvailable = true,
        )
        if (asset.kind == PhotoAssetKindMsg.PHOTO) {
            detail = withExif(detail, uri)
            detail = withImageFormat(detail, uri, asset)
        } else {
            detail = detail.copy(isHdr = videoIsHdr(uri))
        }
        return detail
    }

    private fun withExif(detail: PhotoAssetDetailMsg, uri: Uri): PhotoAssetDetailMsg = try {
        openRead(uri).use { stream ->
            val exif = ExifInterface(stream)
            val iso = exif.getAttributeInt(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, 0).takeIf { it > 0 }?.toLong()
            fun dbl(tag: String) = exif.getAttributeDouble(tag, -1.0).takeIf { it > 0 }
            fun str(tag: String) = exif.getAttribute(tag)?.trim()?.trimEnd('\u0000')?.takeIf { it.isNotEmpty() }
            val taken = ExifDates.parse(str(ExifInterface.TAG_DATETIME_ORIGINAL), str(ExifInterface.TAG_OFFSET_TIME_ORIGINAL))
            // No latitude/longitude: no ACCESS_MEDIA_LOCATION (owner), and MediaStore redacts GPS without it.
            detail.copy(
                iso = iso,
                aperture = dbl(ExifInterface.TAG_F_NUMBER),
                exposureSeconds = dbl(ExifInterface.TAG_EXPOSURE_TIME),
                focalLengthMm = dbl(ExifInterface.TAG_FOCAL_LENGTH),
                cameraMake = str(ExifInterface.TAG_MAKE),
                cameraModel = str(ExifInterface.TAG_MODEL),
                lensModel = str(ExifInterface.TAG_LENS_MODEL),
                takenAtMs = taken ?: detail.takenAtMs,
            )
        }
    } catch (e: IOException) {
        detail // unreadable or unsupported metadata: the basics stay
    } catch (e: RuntimeException) {
        detail
    }

    /** Colour space, bit depth and Ultra HDR (gain map, API 34+) from a header or tiny decode. */
    private fun withImageFormat(detail: PhotoAssetDetailMsg, uri: Uri, asset: PhotoAssetMsg): PhotoAssetDetailMsg = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        openRead(uri).use { BitmapFactory.decodeStream(it, null, bounds) }
        var out = detail
        if (Build.VERSION.SDK_INT >= 26) {
            out = out.copy(colorProfile = bounds.outColorSpace?.name, bitDepth = bitDepth(bounds.outConfig))
        }
        if (Build.VERSION.SDK_INT >= 34 && (asset.mimeType == "image/jpeg" || asset.mimeType == "image/heic" || asset.mimeType == "image/avif")) {
            out = out.copy(isHdr = hasGainmap(uri, maxOf(bounds.outWidth, bounds.outHeight)))
        }
        out
    } catch (e: IOException) {
        detail
    } catch (e: RuntimeException) {
        detail
    }

    @RequiresApi(26)
    private fun bitDepth(config: Bitmap.Config?): Long? = when {
        config == null -> null
        config == Bitmap.Config.RGBA_F16 -> 16
        Build.VERSION.SDK_INT >= 33 && config == Bitmap.Config.RGBA_1010102 -> 10
        else -> 8
    }

    @RequiresApi(34)
    private fun hasGainmap(uri: Uri, longSide: Int): Boolean {
        val options = BitmapFactory.Options().apply { inSampleSize = Integer.highestOneBit(maxOf(1, longSide / 64)) }
        val bitmap = openRead(uri).use { BitmapFactory.decodeStream(it, null, options) } ?: return false
        return try {
            bitmap.hasGainmap()
        } finally {
            bitmap.recycle()
        }
    }

    /** HDR video: PQ (ST 2084) or HLG transfer, from the container (API 30+). */
    private fun videoIsHdr(uri: Uri): Boolean {
        if (Build.VERSION.SDK_INT < 30) return false
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(appContext, uri)
            val transfer = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_COLOR_TRANSFER)?.toIntOrNull()
            transfer == TRANSFER_ST2084 || transfer == TRANSFER_HLG
        } catch (e: RuntimeException) {
            false
        } finally {
            try {
                retriever.release()
            } catch (e: IOException) {
                // nothing to do
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Copy

    /**
     * Streams the original into [PhotoCopyRequestMsg.destinationDirectory] under a new name (never
     * overwrites), with `copyProgress` events at most every 250 ms. Android has no paired movies
     * (motion photos are not Live Photos in 1.2.0), so `pairedVideo` answers `notFound`.
     */
    fun copyAsset(request: PhotoCopyRequestMsg): PhotoCopyResultMsg {
        requireRead()
        synchronized(lock) {
            if (!runningCopies.add(request.requestId)) throw LibraryErrors.error(LibraryErrorCode.busy, "request id in use")
            cancelledCopies.remove(request.requestId)
        }
        var target: File? = null
        try {
            val dir = File(request.destinationDirectory)
            if (!dir.isDirectory) throw LibraryErrors.error(LibraryErrorCode.invalidArgument, "destination is not a directory")
            val asset = fetchAssets(listOf(request.localIdentifier)).firstOrNull()
                ?: throw LibraryErrors.error(LibraryErrorCode.notFound, "asset not found")
            if (request.pairedVideo) throw LibraryErrors.error(LibraryErrorCode.notFound, "no paired video on Android")
            val fallback = if (asset.kind == PhotoAssetKindMsg.VIDEO) "Video.mp4" else "Photo.jpg"
            val name = CopyNaming.sanitize(asset.originalFilename, fallback)
            val file = createNew(dir, name)
            target = file
            val total = asset.sizeBytes
            var done = 0L
            var lastEvent = 0L
            val source = try {
                openRead(contentUri(asset))
            } catch (e: FileNotFoundException) {
                throw LibraryErrors.error(LibraryErrorCode.notFound, "original not found")
            }
            source.use { input ->
                FileOutputStream(file).use { output ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        if (isCancelled(request.requestId)) throw LibraryErrors.error(LibraryErrorCode.cancelled, "copy cancelled")
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                        done += n
                        val now = System.nanoTime() / 1_000_000
                        if (now - lastEvent >= 250) {
                            lastEvent = now
                            events.copyProgress(request.requestId, done, total)
                        }
                    }
                    output.fd.sync()
                }
            }
            if (isCancelled(request.requestId)) throw LibraryErrors.error(LibraryErrorCode.cancelled, "copy cancelled")
            events.copyProgress(request.requestId, done, done)
            target = null // keep it
            return PhotoCopyResultMsg(path = file.absolutePath, mimeType = asset.mimeType, sizeBytes = done)
        } catch (e: IOException) {
            throw LibraryErrors.error(LibraryErrorCode.ioError, "copy failed (${e.javaClass.simpleName})")
        } finally {
            target?.delete()
            synchronized(lock) {
                runningCopies.remove(request.requestId)
                cancelledCopies.remove(request.requestId)
            }
        }
    }

    /** Cancels a running [copyAsset]; it then fails with `cancelled`. */
    fun cancelCopy(requestId: String) {
        synchronized(lock) { if (requestId in runningCopies) cancelledCopies.add(requestId) }
    }

    private fun isCancelled(requestId: String): Boolean = synchronized(lock) { requestId in cancelledCopies }

    /** Creates a new, empty file named after [name] in [dir] (`name (2).ext`, … on a clash). */
    private fun createNew(dir: File, name: String): File {
        var start = name
        repeat(3) {
            val path = CopyNaming.unique(dir.path, start) { File(it).exists() }
                ?: throw LibraryErrors.error(LibraryErrorCode.ioError, "no free name")
            val file = File(path)
            if (file.createNewFile()) return file
            start = file.name // lost a race: try the next free name
        }
        throw LibraryErrors.error(LibraryErrorCode.ioError, "no free name")
    }

    // ---------------------------------------------------------------------------------------------
    // Observing

    /**
     * Starts the ContentObserver (after access was granted; idempotent). Changes are collected for
     * [changeDelayMs] and sent as one `photoLibraryChanged` when the visible set changed (new token)
     * or visible assets changed in place (API 30+ only: older levels don't say which).
     */
    fun startObserving() {
        if (!PhotoPermissions.canRead(authorizationStatus())) return
        val token = currentToken()
        synchronized(lock) {
            if (observer != null) return
            lastToken = token
            val thread = HandlerThread("danaview-library-observer").also { it.start() }
            val handler = Handler(thread.looper)
            val obs = object : ContentObserver(handler) {
                // API 30+: every URI with its INSERT/UPDATE/DELETE flags.
                override fun onChange(selfChange: Boolean, uris: Collection<Uri>, flags: Int) {
                    val external = uris.filter(::isExternal)
                    if (external.isEmpty()) return
                    synchronized(lock) { for (uri in external) collector.add(mediaId(uri), flags) }
                    scheduleFlush(handler)
                }

                // API ≤ 29: no flags, so never incremental.
                override fun onChange(selfChange: Boolean, uri: Uri?) {
                    if (uri != null && !isExternal(uri)) return
                    synchronized(lock) { collector.addUnknown() }
                    scheduleFlush(handler)
                }
            }
            observerThread = thread
            observer = obs
            resolver.registerContentObserver(Uris.root(), true, obs)
        }
    }

    fun stopObserving() {
        synchronized(lock) {
            observer?.let { resolver.unregisterContentObserver(it) }
            observer = null
            observerThread?.quitSafely()
            observerThread = null
            collector.drain()
            flushScheduled = false
            lastToken = null
        }
    }

    /** True for a URI of an external volume (`external`, `external_primary`, an SD card's id). */
    private fun isExternal(uri: Uri): Boolean {
        val volume = uri.pathSegments.firstOrNull() ?: return true // the root: unknown change
        return volume != "internal"
    }

    /** The decimal id of a media URI, or null for a collection URI. */
    private fun mediaId(uri: Uri): String? = uri.lastPathSegment?.takeIf { it.toLongOrNull() != null }

    private fun scheduleFlush(handler: Handler) {
        synchronized(lock) {
            if (flushScheduled) return
            flushScheduled = true
        }
        handler.postDelayed({ flush() }, changeDelayMs)
    }

    /** Sends what the collected notifications changed (observer thread). */
    private fun flush() {
        val drained = synchronized(lock) {
            flushScheduled = false
            if (observer == null || collector.isEmpty) return
            collector.drain()
        }
        if (!PhotoPermissions.canRead(authorizationStatus())) return
        val token = currentToken()
        val previous = synchronized(lock) {
            val p = lastToken
            lastToken = token
            p
        }
        val tokenMoved = previous != token
        // Inserted and changed ids are kept only when they are visible images or videos; removed
        // ids can't be checked any more (a visible removal always moves the token).
        val visible = if (drained.incremental) fetchAssetsUnchecked(drained.inserted + drained.changed).toHashSet() else emptySet()
        val (inserted, changed) = ChangeTokens.reclassify(
            previous,
            drained.inserted.filter { it in visible },
            drained.changed.filter { it in visible },
        )
        val removed = if (tokenMoved) drained.removed else emptyList()
        if (!tokenMoved && changed.isEmpty() && inserted.isEmpty()) return
        events.libraryChanged(
            PhotoLibraryChangeMsg(
                changeToken = token,
                incremental = drained.incremental,
                inserted = inserted,
                removed = removed,
                changed = changed,
            ),
        )
    }

    private fun fetchAssetsUnchecked(ids: List<String>): List<String> {
        if (ids.isEmpty()) return emptyList()
        val out = ArrayList<String>()
        for (chunk in ids.distinct().chunked(400)) {
            val selection = MediaStoreQuery.idSelection(chunk)
            if (selection.args.isEmpty()) continue
            resolver.query(collection, arrayOf(Col.ID), selection.sql, selection.args, null)?.use { c ->
                while (c.moveToNext()) out.add(c.getLong(0).toString())
            }
        }
        return out
    }

    // ---------------------------------------------------------------------------------------------

    /** The typed content URI of [asset] (opened read-only only). */
    private fun contentUri(asset: PhotoAssetMsg): Uri {
        val base = if (asset.kind == PhotoAssetKindMsg.VIDEO) Uris.videos() else Uris.images()
        return ContentUris.withAppendedId(base, asset.localIdentifier.toLong())
    }

    private fun openRead(uri: Uri): InputStream =
        resolver.openInputStream(uri) ?: throw FileNotFoundException("no stream")

    /** A cursor row by column name (column indices cached). */
    private class CursorRow(private val c: Cursor) : MediaRow {
        private val indices = HashMap<String, Int>()

        private fun index(column: String): Int = indices.getOrPut(column) { c.getColumnIndex(column) }

        override fun long(column: String): Long? {
            val i = index(column)
            return if (i < 0 || c.isNull(i)) null else c.getLong(i)
        }

        override fun string(column: String): String? {
            val i = index(column)
            return if (i < 0 || c.isNull(i)) null else c.getString(i)
        }
    }

    /** MediaStore URIs (the "external" volume name covers every external volume on API 29+). */
    private object Uris {
        fun root(): Uri = Uri.parse("content://media")

        fun files(): Uri = android.provider.MediaStore.Files.getContentUri("external")

        fun images(): Uri = android.provider.MediaStore.Images.Media.getContentUri("external")

        fun videos(): Uri = android.provider.MediaStore.Video.Media.getContentUri("external")
    }

    companion object {
        private const val PREFS = "danaview_library_native"
        private const val KEY_ASKED = "photo_access_asked"

        // MediaFormat.COLOR_TRANSFER_ST2084 / COLOR_TRANSFER_HLG.
        private const val TRANSFER_ST2084 = 6
        private const val TRANSFER_HLG = 7
    }
}
