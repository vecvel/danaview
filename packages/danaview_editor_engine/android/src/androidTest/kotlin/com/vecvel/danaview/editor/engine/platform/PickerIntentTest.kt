// OWNER: AND-14
//
// How pick requests become intents and how results are filtered (BUILD_PLAN AND-14): visual-only
// photo requests use the Photo Picker (the platform PICK_IMAGES on API 33+ / SDK-extension devices,
// else Play services' backport, else ACTION_OPEN_DOCUMENT, chosen by androidx.activity), everything
// else SAF OPEN_DOCUMENT with the kind's MIME types; LUTs and subtitles are matched by extension;
// results parse from data / clipData; a cancelled picker yields no URIs; without an activity the
// pick fails with `internal`.

package com.vecvel.danaview.editor.engine.platform

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.activity.result.contract.ActivityResultContracts
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.pigeon.MediaPickKindMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaPickKindMsg.AUDIO
import com.vecvel.danaview.editor.engine.pigeon.MediaPickKindMsg.IMAGE
import com.vecvel.danaview.editor.engine.pigeon.MediaPickKindMsg.LUT
import com.vecvel.danaview.editor.engine.pigeon.MediaPickKindMsg.SUBTITLE
import com.vecvel.danaview.editor.engine.pigeon.MediaPickKindMsg.VIDEO
import com.vecvel.danaview.editor.engine.pigeon.MediaPickRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaPickSourceMsg
import com.vecvel.danaview.editor.engine.pigeon.PickOriginMsg
import com.vecvel.danaview.editor.engine.pigeon.PickedMediaMsg
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class PickerIntentTest {
    private val app get() = PlatformTestEngine.app

    private fun plan(source: MediaPickSourceMsg, vararg kinds: MediaPickKindMsg, multiple: Boolean = true) =
        PickPlan.of(MediaPickRequestMsg(source, kinds.toList(), multiple))

    @Test
    fun visualPhotoRequestsUseThePhotoPicker() {
        val p = plan(MediaPickSourceMsg.PHOTOS, VIDEO, IMAGE)
        assertTrue(p.photoPicker)
        assertEquals(PickOriginMsg.PHOTOS, p.origin)
        assertEquals(ActivityResultContracts.PickVisualMedia.ImageAndVideo, p.visualType)
        assertEquals(ActivityResultContracts.PickVisualMedia.VideoOnly, plan(MediaPickSourceMsg.PHOTOS, VIDEO).visualType)
        assertEquals(ActivityResultContracts.PickVisualMedia.ImageOnly, plan(MediaPickSourceMsg.PHOTOS, IMAGE).visualType)
        val intent = p.intent(app)
        val available = ActivityResultContracts.PickVisualMedia.isPhotoPickerAvailable(app)
        if (Build.VERSION.SDK_INT >= 33) assertTrue(available)
        if (available && Build.VERSION.SDK_INT >= 33) {
            assertEquals(MediaStore.ACTION_PICK_IMAGES, intent.action)
            assertTrue(intent.getIntExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, 0) > 1)
        } else {
            // Documented fallback: Play services' picker or ACTION_OPEN_DOCUMENT with the same types.
            assertTrue(intent.action, intent.action == Intent.ACTION_OPEN_DOCUMENT || intent.action!!.contains("PICK_IMAGES"))
        }
        assertFalse(plan(MediaPickSourceMsg.PHOTOS, IMAGE, multiple = false).intent(app).hasExtra(MediaStore.EXTRA_PICK_IMAGES_MAX))
    }

    @Test
    fun filesAndNonVisualKindsUseSaf() {
        val audio = plan(MediaPickSourceMsg.PHOTOS, AUDIO, IMAGE)
        assertFalse("audio is never in the Photo Picker", audio.photoPicker)
        assertEquals(PickOriginMsg.FILES, audio.origin)
        val i = plan(MediaPickSourceMsg.FILES, VIDEO, AUDIO, IMAGE, LUT, SUBTITLE).intent(app)
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, i.action)
        assertTrue(i.hasCategory(Intent.CATEGORY_OPENABLE))
        assertTrue(i.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
        val types = i.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)!!.toList()
        assertTrue(types.containsAll(listOf("video/*", "audio/*", "image/*", "application/octet-stream", "application/x-subrip", "text/vtt")))
        assertEquals("*/*", i.type)
        val single = plan(MediaPickSourceMsg.FILES, AUDIO, multiple = false).intent(app)
        assertEquals("audio/*", single.type)
        assertFalse(single.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, true))
        assertArrayEquals(arrayOf("audio/*"), single.getStringArrayExtra(Intent.EXTRA_MIME_TYPES))
    }

    @Test
    fun kindsMatchByMimeAndExtension() {
        assertTrue(PickPlan.kindOf(VIDEO, "video/mp4", "a.mp4"))
        assertTrue(PickPlan.kindOf(VIDEO, null, "a.mkv"))
        assertFalse(PickPlan.kindOf(VIDEO, "audio/mp4", "a.m4a"))
        assertTrue(PickPlan.kindOf(AUDIO, "audio/x-wav", "a.wav"))
        assertTrue(PickPlan.kindOf(IMAGE, "image/heic", "a.heic"))
        assertTrue(PickPlan.kindOf(LUT, "application/octet-stream", "Film.CUBE"))
        assertFalse(PickPlan.kindOf(LUT, "application/octet-stream", "notes.bin"))
        assertTrue(PickPlan.kindOf(SUBTITLE, "application/x-subrip", "a.srt"))
        assertTrue(PickPlan.kindOf(SUBTITLE, "text/plain", "a.vtt"))
        assertFalse(PickPlan.kindOf(SUBTITLE, "text/plain", "a.txt"))
        val p = plan(MediaPickSourceMsg.FILES, LUT)
        assertTrue(p.accepts("text/plain", "look.cube"))
        assertFalse(p.accepts("video/mp4", "a.mp4"))
    }

    @Test
    fun resultsParseFromDataAndClipData() {
        val p = plan(MediaPickSourceMsg.FILES, VIDEO)
        val a = Uri.parse("content://x/a")
        val b = Uri.parse("content://x/b")
        val multi = Intent().apply {
            clipData = ClipData.newRawUri("", a).apply { addItem(ClipData.Item(b)) }
        }
        assertEquals(listOf(a, b), p.parse(Activity.RESULT_OK, multi))
        assertEquals(listOf(a), p.parse(Activity.RESULT_OK, Intent().setData(a)))
        assertEquals(emptyList<Uri>(), p.parse(Activity.RESULT_CANCELED, multi))
        assertEquals(emptyList<Uri>(), p.parse(Activity.RESULT_OK, null))
    }

    @Test
    fun describeDropsUnrequestedTypesAndReadsNameAndSize() {
        val ctx = PlatformTestEngine.create()
        try {
            val dir = PlatformTestEngine.providerDir(ctx, "describe")
            val video = File(dir, "clip.mp4").apply { writeBytes(ByteArray(321)) }
            val text = File(dir, "notes.txt").apply { writeBytes(ByteArray(5)) }
            val picker = MediaPicker(ctx)
            val p = plan(MediaPickSourceMsg.FILES, VIDEO)
            val item = picker.describe(PlatformTestEngine.contentUri(ctx, video), p)!!
            assertEquals("clip.mp4", item.displayName)
            assertEquals(321L, item.sizeBytes)
            assertEquals(PickOriginMsg.FILES, item.origin)
            assertNull(picker.describe(PlatformTestEngine.contentUri(ctx, text), p))
        } finally {
            ctx.threads.shutdown()
        }
    }

    @Test
    fun pickWithoutActivityFails() {
        val ctx = PlatformTestEngine.create()
        try {
            val picker = MediaPicker(ctx) // production ActivityHost, no activity attached
            val r = startOnMain<List<PickedMediaMsg>> {
                picker.pick(MediaPickRequestMsg(MediaPickSourceMsg.PHOTOS, listOf(IMAGE), false), it)
            }.await()
            assertEquals(EngineErrorCode.internal, (r.exceptionOrNull() as EngineException).code)
        } finally {
            ctx.threads.shutdown()
        }
    }
}
