// OWNER: HOM-02A
//
// Media the instrumented tests seed into MediaStore and remove again: JPEGs with EXIF (written with
// ExifInterface) and a short H.264 MP4 encoded on the device (MediaCodec + MediaMuxer), all in one
// fresh folder DCIM/DanaviewTest-<uuid>/ (DCIM takes images and videos on API 29) so the tests list only their own bucket. Generated on
// the device: no fixture files, no download.
// Clean-up: deleteAll() removes the rows and then the folder itself, through the shell user (on API 29
// deleting the rows leaves the folder on disk and as a MediaStore folder row, format 0x3001 with no
// owner, that the test APK can neither see nor delete). sweepLeftovers() removes DanaviewTest-<8 hex>
// folders an aborted earlier run left in DCIM, Pictures or Movies (nothing else is touched).

package com.vecvel.danaview.library.photolibrary

import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID

class SeededMedia(private val context: Context) {
    private val resolver: ContentResolver = context.contentResolver
    val folder = "DCIM/DanaviewTest-${UUID.randomUUID().toString().take(8)}/"
    private val created = ArrayList<Uri>()
    private var folderMade = false

    /** Inserts a JPEG taken at [takenUtc] ("yyyy:MM:dd HH:mm:ss", UTC) with camera EXIF; returns its id. */
    fun addPhoto(name: String, takenUtc: String, color: Int = Color.rgb(200, 60, 40)): Long {
        val tmp = File(context.cacheDir, "seed-${UUID.randomUUID()}.jpg")
        try {
            val bitmap = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).apply { eraseColor(color) }
            tmp.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
            bitmap.recycle()
            ExifInterface(tmp).apply {
                setAttribute(ExifInterface.TAG_MAKE, "DanaviewTest")
                setAttribute(ExifInterface.TAG_MODEL, "Seed Cam 1")
                setAttribute(ExifInterface.TAG_LENS_MODEL, "Seed Lens 24mm")
                setAttribute(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, "200")
                setAttribute(ExifInterface.TAG_F_NUMBER, "1.8")
                setAttribute(ExifInterface.TAG_EXPOSURE_TIME, "0.01")
                setAttribute(ExifInterface.TAG_FOCAL_LENGTH, "24/1")
                setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, takenUtc)
                setAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL, "+00:00")
                saveAttributes()
            }
            return insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, name, "image/jpeg", tmp)
        } finally {
            tmp.delete()
        }
    }

    /** Inserts a 1 s 160×120 H.264 MP4; returns its id. */
    fun addVideo(name: String): Long {
        val tmp = File(context.cacheDir, "seed-${UUID.randomUUID()}.mp4")
        try {
            encodeMp4(tmp)
            return insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, name, "video/mp4", tmp)
        } finally {
            tmp.delete()
        }
    }

    private fun insert(collection: Uri, name: String, mime: String, file: File): Long {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        folderMade = true
        val uri = resolver.insert(collection, values) ?: error("insert failed")
        created.add(uri)
        resolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
        resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        return ContentUris.parseId(uri)
    }

    /** Deletes one seeded item now. */
    fun delete(id: Long) {
        val uri = created.firstOrNull { ContentUris.parseId(it) == id } ?: return
        resolver.delete(uri, null, null)
        created.remove(uri)
    }

    /** The MediaStore bucket of the seed folder. */
    fun bucketId(anyId: Long): String {
        resolver.query(
            MediaStore.Files.getContentUri("external"), arrayOf(MediaStore.MediaColumns.BUCKET_ID),
            "${MediaStore.MediaColumns._ID}=?", arrayOf(anyId.toString()), null,
        )!!.use { c ->
            check(c.moveToFirst()) { "seeded item not found" }
            return c.getLong(0).toString()
        }
    }

    /** Deletes every seeded item, then the seed folder (on disk and its MediaStore row). */
    fun deleteAll() {
        for (uri in created) runCatching { resolver.delete(uri, null, null) }
        created.clear()
        @Suppress("DEPRECATION")
        if (folderMade) removeShared(File(Environment.getExternalStorageDirectory(), folder).absolutePath)
        folderMade = false
    }

    companion object {
        private val testFolder = Regex("^DanaviewTest-[0-9a-f]{8}$")

        /**
         * Runs [command] as the shell user, which can change shared storage on every API level without
         * the test APK holding a storage permission (no shell parsing: arguments are split on spaces).
         */
        fun shell(command: String): String = runCatching {
            val fd = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
            android.os.ParcelFileDescriptor.AutoCloseInputStream(fd).use { it.readBytes().toString(Charsets.UTF_8) }
        }.getOrDefault("")

        /**
         * Removes a test folder in shared storage: from disk, its MediaStore row and any rows still
         * pointing inside it (an aborted run's items).
         */
        fun removeShared(path: String) {
            shell("rm -r $path")
            shell("content delete --uri content://media/external/file --where (_data)LIKE('$path/%')")
            shell("content delete --uri content://media/external/file --where _data='$path'")
        }

        /**
         * Removes the DanaviewTest-<8 hex> folders an aborted earlier run left in DCIM, Pictures or
         * Movies, on disk and as stale MediaStore folder rows; only names these tests create.
         */
        @Suppress("DEPRECATION")
        fun sweepLeftovers() {
            val root = Environment.getExternalStorageDirectory()
            val bases = listOf(Environment.DIRECTORY_DCIM, Environment.DIRECTORY_PICTURES, Environment.DIRECTORY_MOVIES)
                .map { File(root, it).absolutePath }
            val found = HashSet<String>()
            for (base in bases) {
                shell("ls -1 $base").lineSequence().map { it.trim() }.filter { testFolder.matches(it) }.forEach { found += "$base/$it" }
            }
            shell("content query --uri content://media/external/file --projection _data --where format=12289")
                .lineSequence().mapNotNull { Regex("_data=(.*)$").find(it.trim())?.groupValues?.get(1) }
                .filter { it.substringBeforeLast('/') in bases && testFolder.matches(it.substringAfterLast('/')) }
                .forEach { found += it }
            found.forEach { removeShared(it) }
        }

        /** Encodes [frames] gray frames at 15 fps as H.264 into [out]. */
        fun encodeMp4(out: File, width: Int = 160, height: Int = 120, frames: Int = 15) {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                setInteger(MediaFormat.KEY_BIT_RATE, 250_000)
                setInteger(MediaFormat.KEY_FRAME_RATE, 15)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            val muxer = MediaMuxer(out.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            try {
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                codec.start()
                val info = MediaCodec.BufferInfo()
                var track = -1
                var sent = 0
                var done = false
                val deadline = System.currentTimeMillis() + 20_000
                while (!done) {
                    check(System.currentTimeMillis() < deadline) { "encoder timed out" }
                    if (sent <= frames) {
                        val inIndex = codec.dequeueInputBuffer(10_000)
                        if (inIndex >= 0) {
                            if (sent == frames) {
                                codec.queueInputBuffer(inIndex, 0, 0, sent * 1_000_000L / 15, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            } else {
                                val image = codec.getInputImage(inIndex)!!
                                for ((p, plane) in image.planes.withIndex()) {
                                    val w = if (p == 0) width else width / 2
                                    val h = if (p == 0) height else height / 2
                                    val value = (if (p == 0) 60 + sent * 8 else 128).toByte()
                                    val buf = plane.buffer
                                    for (y in 0 until h) for (x in 0 until w) {
                                        buf.put(y * plane.rowStride + x * plane.pixelStride, value)
                                    }
                                }
                                codec.queueInputBuffer(inIndex, 0, width * height * 3 / 2, sent * 1_000_000L / 15, 0)
                            }
                            sent++
                        }
                    }
                    val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                    when {
                        outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            track = muxer.addTrack(codec.outputFormat)
                            muxer.start()
                        }
                        outIndex >= 0 -> {
                            val data = codec.getOutputBuffer(outIndex)!!
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0 && track >= 0) {
                                data.position(info.offset)
                                data.limit(info.offset + info.size)
                                muxer.writeSampleData(track, data, info)
                            }
                            codec.releaseOutputBuffer(outIndex, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
                        }
                    }
                }
            } finally {
                codec.stop()
                codec.release()
                try {
                    muxer.stop()
                } catch (e: IllegalStateException) {
                    // never started
                }
                muxer.release()
            }
        }
    }
}
