// OWNER: AND-11 (QA-05 D8, Android half)
//
// StorageLoss on the JVM: an export failure whose cause chain reports a missing file below the
// cache root (the chain QA-05 D8 logged on the emulator: ExportException[ERROR_CODE_IO_UNSPECIFIED]
// from the image asset loader ← FileDataSourceException ← FileNotFoundException "…: open failed:
// ENOENT") is a storage failure, diskFull on a low volume and io otherwise; a missing file outside
// the cache root, a full volume, a refused open, cancellation and interruption are not; Android's
// low-storage rule; no paths in messages.

package com.vecvel.danaview.editor.engine.export

import androidx.media3.common.PlaybackException
import androidx.media3.datasource.FileDataSource
import androidx.media3.transformer.ExportException
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

class StorageLossTest {
    private val root = File("/data/user/0/com.vecvel.danaview/cache/danaview/editor")

    /** The chain of QA-05 D8 (run a, 02:15:15.477) for [path]. */
    private fun imageLoaderEnoent(path: String): ExportException {
        val fnf = FileNotFoundException("$path: open failed: ENOENT (No such file or directory)")
        val source = FileDataSource.FileDataSourceException(fnf, PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND)
        return ExportException.createForAssetLoader(source, ExportException.ERROR_CODE_IO_UNSPECIFIED)
    }

    private val generatedPng = "$root/engine/dv_opaque_ff000000_1280x720.png"

    @Test
    fun theD8ChainIsAStorageLoss() {
        val e = imageLoaderEnoent(generatedPng)
        assertTrue(StorageLoss.lostBelow(e, root))
        assertEquals(EngineErrorCode.io, StorageLoss.classify(e, root) { false }!!.code)
        assertEquals(EngineErrorCode.diskFull, StorageLoss.classify(e, root) { true }!!.code)
        // Before: ExportErrors alone answers io, which Dart shows as exportFailed.unknown.
        assertEquals(EngineErrorCode.io, ExportErrors.map(e).code)
    }

    @Test
    fun anAlreadyMappedFailureIsClassifiedThroughItsCause() {
        val mapped = ExportErrors.map(imageLoaderEnoent(generatedPng))
        val lost = StorageLoss.classify(mapped, root) { true }
        assertNotNull(lost)
        assertEquals(EngineErrorCode.diskFull, lost!!.code)
        assertSame(mapped, lost.cause)
        assertTrue(lost.retryable)
    }

    @Test
    fun workFilesAndTheOutputCountToo() {
        assertTrue(StorageLoss.lostBelow(IOException(FileNotFoundException("$root/work/export-ex_1/pass0.mp4: open failed: ENOENT (No such file or directory)")), root))
        assertTrue(StorageLoss.lostBelow(FileNotFoundException("$root/work/export-ex_1.mp4 (No such file or directory)"), root))
    }

    @Test
    fun missingFilesOutsideTheCacheRootAreNotStorageLosses() {
        val user = imageLoaderEnoent("/data/user/0/com.vecvel.danaview/files/danaview/editor/media/photo.png")
        assertFalse(StorageLoss.lostBelow(user, root))
        assertNull(StorageLoss.classify(user, root) { true })
        // A sibling whose name only starts like the root.
        assertFalse(StorageLoss.lostBelow(imageLoaderEnoent("${root}2/engine/x.png"), root))
        assertFalse(StorageLoss.lostBelow(imageLoaderEnoent("/sdcard/DCIM/a.png"), root))
    }

    @Test
    fun fullVolumesRefusedOpensAndOtherErrorsAreNot() {
        assertFalse(StorageLoss.lostBelow(FileNotFoundException("$root/work/x.mp4: open failed: ENOSPC (No space left on device)"), root))
        assertFalse(StorageLoss.lostBelow(FileNotFoundException("$root/work/x.mp4: open failed: EACCES (Permission denied)"), root))
        assertFalse(StorageLoss.lostBelow(IOException("$root/work/x.mp4: read failed: EIO (I/O error)"), root))
        assertFalse(StorageLoss.lostBelow(IllegalStateException("codec"), root))
    }

    @Test
    fun cancellationInterruptionAndDiskFullStay() {
        val cause = imageLoaderEnoent(generatedPng)
        for (code in listOf(EngineErrorCode.cancelled, EngineErrorCode.interrupted, EngineErrorCode.diskFull)) {
            assertNull(code.name, StorageLoss.classify(EngineException(code, "x", cause = cause), root) { false })
        }
    }

    @Test
    fun lowIsAskedOnlyForALoss() {
        var asked = 0
        StorageLoss.classify(IllegalStateException("x"), root) { asked++; true }
        assertEquals(0, asked)
        StorageLoss.classify(imageLoaderEnoent(generatedPng), root) { asked++; true }
        assertEquals(1, asked)
    }

    @Test
    fun androidsLowStorageRule() {
        val gb = 1024L * 1024 * 1024
        // 5 % of the volume, at most 500 MiB.
        assertTrue(StorageLoss.isLow(199L * 1024 * 1024, 6 * gb)) // QA-05 op #75: 199 MB free
        assertFalse(StorageLoss.isLow(600L * 1024 * 1024, 64 * gb))
        assertTrue(StorageLoss.isLow(499L * 1024 * 1024, 64 * gb))
        assertTrue(StorageLoss.isLow(90L * 1024 * 1024, 2 * gb)) // 5 % of 2 GiB = 102.4 MiB
        assertFalse(StorageLoss.isLow(110L * 1024 * 1024, 2 * gb))
        assertFalse("unknown volume", StorageLoss.isLow(0, 0))
    }

    @Test
    fun messagesNeverCarryPaths() {
        for (low in listOf(true, false)) {
            val e = StorageLoss.classify(imageLoaderEnoent(generatedPng), root) { low }!!
            assertFalse(e.message!!.contains("/"))
        }
    }
}
