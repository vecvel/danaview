// OWNER: AND-14
//
// MediaAccess on the emulator (BUILD_PLAN AND-14): quickHash equals the core fixtures
// (packages/danaview_editor_core/test/fixtures/quickhash/quickhash_vectors.json, packed by the ENG-09
// harness; the files are regenerated from the documented pattern) for file paths, file:// URIs,
// content:// URIs of a test content provider (the engine FileProvider) and a non-seekable stream;
// stat (size, modification time, missing → null); the grant budget (512 on API 30+, 128 before,
// minus the persisted grants); a URI without a persistable grant fails persistUriGrant with
// permissionDenied (Dart then makes a managed copy); releasing a grant that is not held succeeds.
// Persisting real Photo Picker / SAF grants is covered by PickerFlowTest.

package com.vecvel.danaview.editor.engine.platform

import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.pigeon.MediaRefMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaStatMsg
import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.concurrent.thread

@RunWith(AndroidJUnit4::class)
class MediaAccessTest {
    companion object {
        private lateinit var ctx: EngineContext
        private lateinit var access: MediaAccess

        @BeforeClass
        @JvmStatic
        fun setUp() {
            ctx = PlatformTestEngine.create()
            access = MediaAccess(ctx)
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            ctx.threads.shutdown()
        }
    }

    private data class Vector(val name: String, val size: Int, val hash: String)

    private fun vectors(): List<Vector> {
        val doc = JSONObject(TestFixtures.readText(FixtureTree.CORE, "quickhash/quickhash_vectors.json"))
        val cases = doc.getJSONArray("cases")
        return (0 until cases.length()).map { i ->
            val c = cases.getJSONObject(i)
            Vector(c.getString("name"), c.getInt("size"), c.getString("quickHash"))
        }
    }

    private fun hash(uri: String): String = awaitResult<String> { access.quickHash(MediaRefMsg(uri), it) }.getOrThrow()

    private fun stat(uri: String): MediaStatMsg? = awaitResult<MediaStatMsg?> { access.stat(MediaRefMsg(uri), it) }.getOrThrow()

    @Test
    fun quickHashEqualsCoreFixturesForPathsFileUrisAndContentUris() {
        val dir = PlatformTestEngine.providerDir(ctx, "quickhash")
        val all = vectors()
        assertEquals(7, all.size)
        for (v in all) {
            val file = File(dir, "${v.name}.bin").apply { writeBytes(quickHashPattern(v.size)) }
            assertEquals("${v.name} path", v.hash, hash(file.absolutePath))
            assertEquals("${v.name} file uri", v.hash, hash(android.net.Uri.fromFile(file).toString()))
            val content = PlatformTestEngine.contentUri(ctx, file).toString()
            assertTrue(content.startsWith("content://"))
            assertEquals("${v.name} content uri", v.hash, hash(content))
            // The streamed path (pipes / non-seekable providers).
            assertEquals("${v.name} stream", v.hash, file.inputStream().use(MediaAccess::hashStream))
        }
    }

    @Test
    fun quickHashOfANonSeekablePipe() {
        val v = vectors().first { it.name == "3mib" }
        val bytes = quickHashPattern(v.size)
        val (read, write) = ParcelFileDescriptor.createPipe()
        val writer = thread {
            ParcelFileDescriptor.AutoCloseOutputStream(write).use { out ->
                // Odd chunk sizes exercise the ring buffer.
                var i = 0
                var step = 1
                while (i < bytes.size) {
                    val n = minOf(step, bytes.size - i)
                    out.write(bytes, i, n)
                    i += n
                    step = (step * 7 + 13) % 200_000 + 1
                }
            }
        }
        val got = ParcelFileDescriptor.AutoCloseInputStream(read).use(MediaAccess::hashStream)
        writer.join()
        assertEquals(v.hash, got)
    }

    @Test
    fun statOfFilesAndContentAndMissing() {
        val dir = PlatformTestEngine.providerDir(ctx, "stat")
        val file = File(dir, "clip.mp4").apply { writeBytes(ByteArray(12_345) { it.toByte() }) }
        file.setLastModified(1_700_000_000_000)
        val s = stat(file.absolutePath)!!
        assertEquals(12_345L, s.sizeBytes)
        assertEquals(1_700_000_000_000, s.modifiedMs)
        assertEquals(12_345L, stat(android.net.Uri.fromFile(file).toString())!!.sizeBytes)
        val content = PlatformTestEngine.contentUri(ctx, file).toString()
        assertEquals(12_345L, stat(content)!!.sizeBytes)
        assertNull(stat(File(dir, "gone.mp4").absolutePath))
        val goneContent = PlatformTestEngine.contentUri(ctx, File(dir, "gone2.mp4")).toString()
        assertNull(stat(goneContent))
        val missingHash = awaitResult<String> { access.quickHash(MediaRefMsg(File(dir, "gone.mp4").absolutePath), it) }
        assertEquals(EngineErrorCode.mediaOffline, (missingHash.exceptionOrNull() as EngineException).code)
    }

    @Test
    fun grantBudgetAndNonPersistableUris() {
        val limit = if (Build.VERSION.SDK_INT >= 30) 512 else 128
        assertEquals(limit, access.grantLimit)
        val persisted = ctx.appContext.contentResolver.persistedUriPermissions.size
        val budget = awaitResult<Long> { access.remainingGrantBudget(it) }.getOrThrow()
        assertEquals((limit - persisted).toLong(), budget)

        val dir = PlatformTestEngine.providerDir(ctx, "grants")
        val file = File(dir, "a.png").apply { writeBytes(ByteArray(10)) }
        val uri = PlatformTestEngine.contentUri(ctx, file).toString()
        val r = awaitResult<Unit> { access.persistUriGrant(uri, it) }
        assertEquals(EngineErrorCode.permissionDenied, (r.exceptionOrNull() as EngineException).code)
        // Releasing a grant that is not held is a no-op.
        awaitResult<Unit> { access.releaseUriGrant(uri, it) }.getOrThrow()
        assertEquals(budget, awaitResult<Long> { access.remainingGrantBudget(it) }.getOrThrow())
    }
}
