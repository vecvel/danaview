// OWNER: HOM-02A
//
// Pure helpers of the MediaStore library, unit-tested on the JVM without a device: the query
// (selection, sort, page window), cursor row → PhotoAssetMsg mapping (closes the Android half of
// V2-V2: HEIC, AVIF, RAW by MIME/extension; motion photos are not Live Photos in 1.2.0), change
// tokens, change collection from ContentObserver notifications, album aggregation, EXIF dates and
// create-new copy naming (rule 26). Column names are MediaStore's (the `files` table on every API
// level from 24: images and videos are its media_type 1 and 3).

package com.vecvel.danaview.library.photolibrary

import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.pigeon.PhotoAlbumKindMsg
import com.vecvel.danaview.library.pigeon.PhotoAlbumMsg
import com.vecvel.danaview.library.pigeon.PhotoAssetKindMsg
import com.vecvel.danaview.library.pigeon.PhotoAssetMsg
import com.vecvel.danaview.library.pigeon.PhotoMediaFilterMsg
import com.vecvel.danaview.library.pigeon.PhotoSortMsg
import java.util.Calendar
import java.util.TimeZone

/** MediaStore column names (string values, identical on API 24…36). */
object Col {
    const val ID = "_id"
    const val MEDIA_TYPE = "media_type"
    const val MIME_TYPE = "mime_type"
    const val DISPLAY_NAME = "_display_name"
    const val SIZE = "_size"
    const val WIDTH = "width"
    const val HEIGHT = "height"
    const val ORIENTATION = "orientation"
    const val DATE_TAKEN = "datetaken"
    const val DATE_ADDED = "date_added"
    const val DATE_MODIFIED = "date_modified"
    const val DURATION = "duration"
    const val BUCKET_ID = "bucket_id"
    const val BUCKET_DISPLAY_NAME = "bucket_display_name"
    const val RELATIVE_PATH = "relative_path" // API 29+
    const val IS_FAVORITE = "is_favorite" // API 30+

    const val MEDIA_TYPE_IMAGE = 1
    const val MEDIA_TYPE_VIDEO = 3

    /** The grid projection on API [sdk] (columns that don't exist there are left out). */
    fun gridProjection(sdk: Int): Array<String> = buildList {
        addAll(listOf(ID, MEDIA_TYPE, MIME_TYPE, DISPLAY_NAME, SIZE, WIDTH, HEIGHT, DATE_TAKEN, DATE_ADDED, DATE_MODIFIED, DURATION, BUCKET_DISPLAY_NAME))
        if (sdk >= 29) addAll(listOf(ORIENTATION, RELATIVE_PATH))
        if (sdk >= 30) add(IS_FAVORITE)
    }.toTypedArray()
}

/** A SQL selection with its arguments. */
data class Selection(val sql: String, val args: Array<String>) {
    override fun equals(other: Any?): Boolean = other is Selection && other.sql == sql && other.args.contentEquals(args)

    override fun hashCode(): Int = 31 * sql.hashCode() + args.contentHashCode()
}

/** One cursor row by column name (null for a missing column or a NULL value). */
interface MediaRow {
    fun long(column: String): Long?

    fun string(column: String): String?
}

object MediaStoreQuery {
    /** Most assets in one page (the Home grid asks for 200). */
    const val MAX_PAGE = 500

    /** Images and/or videos of [filter], optionally one bucket ([albumId], a decimal BUCKET_ID). */
    fun selection(filter: PhotoMediaFilterMsg, albumId: String?): Selection {
        val types = when (filter) {
            PhotoMediaFilterMsg.ALL -> "${Col.MEDIA_TYPE} IN (${Col.MEDIA_TYPE_IMAGE},${Col.MEDIA_TYPE_VIDEO})"
            PhotoMediaFilterMsg.PHOTOS -> "${Col.MEDIA_TYPE}=${Col.MEDIA_TYPE_IMAGE}"
            PhotoMediaFilterMsg.VIDEOS -> "${Col.MEDIA_TYPE}=${Col.MEDIA_TYPE_VIDEO}"
        }
        if (albumId == null) return Selection(types, emptyArray())
        if (albumId.toLongOrNull() == null) throw LibraryErrors.error(LibraryErrorCode.notFound, "album not found")
        return Selection("$types AND ${Col.BUCKET_ID}=?", arrayOf(albumId))
    }

    /** `_id IN (?,…)` over [ids] (decimal MediaStore ids; others never match). */
    fun idSelection(ids: List<String>): Selection {
        val valid = ids.filter { it.toLongOrNull() != null }
        val marks = valid.joinToString(",") { "?" }
        return Selection(
            "${Col.MEDIA_TYPE} IN (${Col.MEDIA_TYPE_IMAGE},${Col.MEDIA_TYPE_VIDEO}) AND ${Col.ID} IN ($marks)",
            valid.toTypedArray(),
        )
    }

    /** SQL ORDER BY of [sort]; `_id` breaks ties so pages never overlap. */
    fun sortOrder(sort: PhotoSortMsg): String = when (sort) {
        PhotoSortMsg.CREATION_NEWEST_FIRST -> "${Col.DATE_TAKEN} DESC, ${Col.ID} DESC"
        PhotoSortMsg.CREATION_OLDEST_FIRST -> "${Col.DATE_TAKEN} ASC, ${Col.ID} ASC"
        PhotoSortMsg.MODIFICATION_NEWEST_FIRST -> "${Col.DATE_MODIFIED} DESC, ${Col.ID} DESC"
    }

    /** Validated (offset, limit) of a page request: offset ≥ 0, limit clamped to 1…[MAX_PAGE]. */
    fun window(offset: Long, limit: Long): Pair<Int, Int> {
        if (offset < 0) throw LibraryErrors.error(LibraryErrorCode.invalidArgument, "offset < 0")
        if (limit < 1) throw LibraryErrors.error(LibraryErrorCode.invalidArgument, "limit < 1")
        if (offset > Int.MAX_VALUE) throw LibraryErrors.error(LibraryErrorCode.invalidArgument, "offset too large")
        return offset.toInt() to minOf(limit, MAX_PAGE.toLong()).toInt()
    }
}

/** MIME and extension rules of the grid flags. */
object MediaTypes {
    val rawMimes = setOf(
        "image/x-adobe-dng", "image/dng", "image/x-dng", "image/x-canon-cr2", "image/x-canon-cr3", "image/x-canon-crw",
        "image/x-nikon-nef", "image/x-nikon-nrw", "image/x-sony-arw", "image/x-sony-srf", "image/x-sony-sr2",
        "image/x-fuji-raf", "image/x-olympus-orf", "image/x-panasonic-rw2", "image/x-panasonic-raw",
        "image/x-pentax-pef", "image/x-samsung-srw", "image/x-leica-rwl", "image/x-hasselblad-3fr",
    )
    val rawExtensions = setOf("dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "rwl", "3fr", "iiq", "erf", "kdc", "mrw", "x3f")

    private val mimeByExtension = mapOf(
        "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "heic" to "image/heic", "heif" to "image/heif",
        "avif" to "image/avif", "png" to "image/png", "gif" to "image/gif", "webp" to "image/webp",
        "bmp" to "image/bmp", "dng" to "image/x-adobe-dng", "mp4" to "video/mp4", "m4v" to "video/x-m4v",
        "mov" to "video/quicktime", "3gp" to "video/3gpp", "webm" to "video/webm", "mkv" to "video/x-matroska",
    )

    fun extension(name: String?): String? =
        name?.substringAfterLast('.', "")?.lowercase()?.takeIf { it.isNotEmpty() && it.length <= 5 }

    fun isRaw(mime: String?, name: String?): Boolean =
        (mime != null && mime.lowercase() in rawMimes) || extension(name) in rawExtensions

    /** [mime] when MediaStore has a usable one, else the extension's. */
    fun mimeType(mime: String?, name: String?): String? =
        mime?.takeIf { it.isNotBlank() && it != "application/octet-stream" } ?: mimeByExtension[extension(name)]

    /** Screenshots live in a `Screenshots` folder (Pictures/ or DCIM/ on every OEM we know). */
    fun isScreenshot(bucketName: String?, relativePath: String?): Boolean =
        bucketName.equals("Screenshots", ignoreCase = true) ||
            (relativePath?.split('/')?.any { it.equals("Screenshots", ignoreCase = true) } == true)
}

object PhotoAssetMapping {
    /** The grid record of [row]; null for a row that is neither an image nor a video. */
    fun asset(row: MediaRow): PhotoAssetMsg? {
        val id = row.long(Col.ID) ?: return null
        val kind = when (row.long(Col.MEDIA_TYPE)?.toInt()) {
            Col.MEDIA_TYPE_IMAGE -> PhotoAssetKindMsg.PHOTO
            Col.MEDIA_TYPE_VIDEO -> PhotoAssetKindMsg.VIDEO
            else -> return null
        }
        val name = row.string(Col.DISPLAY_NAME)
        val mime = MediaTypes.mimeType(row.string(Col.MIME_TYPE), name)
        var width = row.long(Col.WIDTH)?.coerceAtLeast(0) ?: 0
        var height = row.long(Col.HEIGHT)?.coerceAtLeast(0) ?: 0
        // MediaStore stores stored (unrotated) dimensions and the rotation apart; PhotoKit reports
        // displayed ones, so swap for a quarter turn.
        val orientation = ((row.long(Col.ORIENTATION) ?: 0L) % 360 + 360) % 360
        if (orientation == 90L || orientation == 270L) {
            val t = width; width = height; height = t
        }
        return PhotoAssetMsg(
            localIdentifier = id.toString(),
            kind = kind,
            widthPx = width,
            heightPx = height,
            creationTimeMs = creationTimeMs(row),
            modificationTimeMs = row.long(Col.DATE_MODIFIED)?.takeIf { it > 0 }?.let { it * 1000 },
            durationMs = if (kind == PhotoAssetKindMsg.VIDEO) (row.long(Col.DURATION) ?: 0L).coerceAtLeast(0) else 0L,
            isFavorite = (row.long(Col.IS_FAVORITE) ?: 0L) == 1L,
            isRaw = kind == PhotoAssetKindMsg.PHOTO && MediaTypes.isRaw(mime, name),
            // Ultra HDR needs a decode and HDR video a retriever: the grid stays false; the detail
            // (assetDetail) checks.
            isHdr = false,
            isLivePhoto = false,
            isScreenshot = kind == PhotoAssetKindMsg.PHOTO &&
                MediaTypes.isScreenshot(row.string(Col.BUCKET_DISPLAY_NAME), row.string(Col.RELATIVE_PATH)),
            originalFilename = name,
            uti = null,
            mimeType = mime,
            sizeBytes = row.long(Col.SIZE)?.takeIf { it >= 0 },
        )
    }

    /** DATE_TAKEN (ms) when the file has one, else DATE_ADDED (s): when it entered the device. */
    fun creationTimeMs(row: MediaRow): Long? =
        row.long(Col.DATE_TAKEN)?.takeIf { it > 0 } ?: row.long(Col.DATE_ADDED)?.takeIf { it > 0 }?.let { it * 1000 }
}

/**
 * Change tokens: a fingerprint of the visible images and videos, (count, largest _id). An insert
 * always raises the largest id (MediaStore ids are never reused) and a delete lowers the count or
 * the largest id, so any change that shifts page indices moves the token; an in-place update
 * (favourite, edit) keeps it, as on Apple. A change of the partial-access selection changes the
 * visible set and so the token.
 */
object ChangeTokens {
    fun of(count: Int, maxId: Long?): String = "c$count-m${maxId ?: 0}"

    /** True when [requested] is set and is not [current]. */
    fun isStale(requested: String?, current: String): Boolean = requested != null && requested != current

    /** The largest id [token] saw, or null for a token of another shape. */
    fun maxId(token: String?): Long? = token?.substringAfterLast("-m", "")?.toLongOrNull()

    /**
     * Moves "changed" ids newer than [previous]'s largest id to "inserted": an app that writes a
     * pending item (IS_PENDING, invisible) and then publishes it notifies an UPDATE, not an INSERT.
     */
    fun reclassify(previous: String?, inserted: List<String>, changed: List<String>): Pair<List<String>, List<String>> {
        val max = maxId(previous) ?: return inserted to changed
        val (newer, older) = changed.partition { (it.toLongOrNull() ?: 0) > max }
        return (inserted + newer).distinct() to older
    }
}

/**
 * Collects ContentObserver notifications between two flushes (API 30+ gives each URI's id and
 * INSERT/UPDATE/DELETE flags; older levels give neither, so their changes are never incremental).
 */
class ChangeCollector(private val maxIds: Int = 500) {
    private val inserted = LinkedHashSet<String>()
    private val removed = LinkedHashSet<String>()
    private val changed = LinkedHashSet<String>()
    private var incremental = true
    private var any = false

    /** Records one notification: [id] from the URI's last segment (null for a collection URI). */
    fun add(id: String?, flags: Int) {
        any = true
        if (id == null || id.toLongOrNull() == null || flags and (NOTIFY_INSERT or NOTIFY_UPDATE or NOTIFY_DELETE) == 0) {
            incremental = false
            return
        }
        when {
            flags and NOTIFY_DELETE != 0 -> {
                if (!inserted.remove(id)) removed.add(id)
                changed.remove(id)
            }
            flags and NOTIFY_INSERT != 0 -> {
                if (!removed.remove(id)) inserted.add(id) else changed.add(id)
            }
            else -> if (id !in inserted) changed.add(id)
        }
        if (inserted.size + removed.size + changed.size > maxIds) incremental = false
    }

    /** A notification without details (API ≤ 29, or a bulk change). */
    fun addUnknown() {
        any = true
        incremental = false
    }

    val isEmpty: Boolean get() = !any

    /** What was collected, then empties the collector. */
    fun drain(): Drained {
        val d = if (incremental) Drained(true, inserted.toList(), removed.toList(), changed.toList()) else Drained(false, emptyList(), emptyList(), emptyList())
        inserted.clear(); removed.clear(); changed.clear(); incremental = true; any = false
        return d
    }

    data class Drained(val incremental: Boolean, val inserted: List<String>, val removed: List<String>, val changed: List<String>)

    companion object {
        // ContentResolver.NOTIFY_INSERT / NOTIFY_UPDATE / NOTIFY_DELETE (API 30).
        const val NOTIFY_INSERT = 1 shl 2
        const val NOTIFY_UPDATE = 1 shl 3
        const val NOTIFY_DELETE = 1 shl 4
    }
}

/** Device folders (MediaStore buckets) as albums. */
object Albums {
    /** One counted bucket: [count] photos (the album's size) and [videos] videos. */
    data class Bucket(val id: String, val name: String?, var count: Long = 0, var videos: Long = 0)

    /**
     * Counts one MediaStore row of [mediaType] in bucket [id] (OBS-S2A-3): photos make the album,
     * videos are only tallied, so a video-only bucket is no album (it belongs in Videos).
     */
    fun add(buckets: MutableMap<String, Bucket>, id: String, name: String?, mediaType: Int?) {
        val bucket = buckets.getOrPut(id) { Bucket(id, name) }
        when (mediaType) {
            Col.MEDIA_TYPE_IMAGE -> bucket.count++
            Col.MEDIA_TYPE_VIDEO -> bucket.videos++
        }
    }

    /** Buckets the OS itself fills (camera, screenshots) are `smart`, as PhotoKit's smart albums. */
    fun isSystemBucket(name: String?): Boolean =
        name != null && (name.equals("Camera", ignoreCase = true) || name.equals("Screenshots", ignoreCase = true))

    /**
     * The Photos tab's albums of [buckets]: only buckets holding photos, sized by their photos
     * (OBS-S2A-3); system buckets first (Camera, Screenshots), then by name.
     */
    fun albums(buckets: Collection<Bucket>): List<PhotoAlbumMsg> = buckets
        .filter { it.count > 0 }
        .sortedWith(
            compareBy<Bucket>(
                { if (isSystemBucket(it.name)) 0 else 1 },
                { if (it.name.equals("Camera", ignoreCase = true)) 0 else 1 },
                { (it.name ?: "").lowercase() },
                { it.id },
            ),
        )
        .map {
            PhotoAlbumMsg(
                albumId = it.id,
                title = it.name ?: "",
                kind = if (isSystemBucket(it.name)) PhotoAlbumKindMsg.SMART else PhotoAlbumKindMsg.USER,
                estimatedCount = it.count,
            )
        }
}

/** EXIF date parsing. */
object ExifDates {
    private val dateTime = Regex("""^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})""")
    private val offset = Regex("""^([+-])(\d{2}):?(\d{2})$""")

    /**
     * `DateTimeOriginal` ("yyyy:MM:dd HH:mm:ss") at `OffsetTimeOriginal` ("+05:30") as epoch ms;
     * without an offset the time is read in [fallbackZone] (the device's, as the camera wrote it).
     * Null for a missing or malformed date (all zeros included).
     */
    fun parse(value: String?, offsetValue: String?, fallbackZone: TimeZone = TimeZone.getDefault()): Long? {
        val m = dateTime.find(value?.trim() ?: return null) ?: return null
        val (y, mo, d, h, mi, s) = m.destructured
        val year = y.toInt()
        val month = mo.toInt()
        val day = d.toInt()
        if (year < 1800 || month !in 1..12 || day !in 1..31 || h.toInt() > 23 || mi.toInt() > 59 || s.toInt() > 60) return null
        val zone = offsetValue?.trim()?.let { offset.find(it) }?.let {
            val (sign, oh, om) = it.destructured
            TimeZone.getTimeZone("GMT$sign$oh:$om")
        } ?: fallbackZone
        val cal = Calendar.getInstance(zone)
        cal.clear()
        cal.isLenient = false
        return try {
            cal.set(year, month - 1, day, h.toInt(), mi.toInt(), minOf(s.toInt(), 59))
            cal.timeInMillis
        } catch (e: IllegalArgumentException) {
            null
        }
    }
}

/** Create-new file naming inside an app directory (copies never overwrite, rule 26). */
object CopyNaming {
    /** [name] reduced to one safe path component (no separators, no leading dots), or [fallback]. */
    fun sanitize(name: String?, fallback: String): String {
        var s = (name ?: "").replace('/', '_').replace('\\', '_').replace(':', '_').replace("\u0000", "")
        s = s.trimStart('.').trim()
        if (s.length > 200) {
            val ext = s.substringAfterLast('.', "")
            val base = s.substringBeforeLast('.', s).take(180)
            s = if (ext.isEmpty() || ext.length > 10) base else "$base.$ext"
        }
        return s.ifEmpty { fallback }
    }

    /** The first of `name`, `name (2).ext`, `name (3).ext`, … for which [exists] is false. */
    fun unique(directory: String, name: String, exists: (String) -> Boolean): String? {
        val dir = directory.trimEnd('/')
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot + 1) else ""
        for (n in 1..999) {
            val candidate = if (n == 1) name else if (ext.isEmpty()) "$base ($n)" else "$base ($n).$ext"
            val path = "$dir/$candidate"
            if (!exists(path)) return path
        }
        return null
    }
}
