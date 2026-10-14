// OWNER: AND-11
//
// ActiveExportStore (D-22, D-39): running records of this process, one-shot interrupted records
// after process death (a record written under another process token), completedWhileDetached
// records, consume, expiry, persistence format and robustness against a corrupt file.

package com.vecvel.danaview.editor.engine.export

import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobStateKindMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportResultMsg
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ActiveExportStoreTest {
    @get:Rule
    val temp = TemporaryFolder()

    private var now = 1_000_000L
    private val file by lazy { File(temp.root, "cache/danaview/editor/${ActiveExportStore.FILE_NAME}") }

    private fun store(token: String = "process-a") = ActiveExportStore(file, token) { now }

    private val output by lazy { File(temp.root, "cache/danaview/editor/work/export-ex_1.mp4") }

    private val result by lazy { ExportResultMsg(output.absolutePath, 4096, 2_000_000, "c2.android.avc.encoder", false) }

    @Test
    fun runningJobIsListedAndFinishRemovesIt() {
        val s = store()
        s.begin("ex_1", output, Settings.msg(), DetachedHandoffMsg.SAVE_TO_GALLERY)
        val msgs = s.recordMsgs()
        assertEquals(1, msgs.size)
        assertEquals(ExportJobStateKindMsg.RUNNING, msgs[0].state)
        assertEquals("ex_1", msgs[0].jobId)
        assertEquals(Settings.msg(), msgs[0].settings)
        assertNull(msgs[0].result)
        assertFalse(msgs[0].savedToGallery)
        // A running record cannot be consumed.
        assertNull(s.consume("ex_1"))
        s.finish("ex_1")
        assertEquals(emptyList<Any>(), s.recordMsgs())
    }

    @Test
    fun processDeathTurnsRunningIntoOneShotInterrupted() {
        store("dead-process").begin("ex_1", output, Settings.msg(), DetachedHandoffMsg.SAVE_TO_GALLERY)
        val next = store("new-process")
        val first = next.recordMsgs()
        assertEquals(listOf(ExportJobStateKindMsg.INTERRUPTED), first.map { it.state })
        // Persisted: still interrupted (not running) until consumed, also for a third process.
        assertEquals(listOf(ExportJobStateKindMsg.INTERRUPTED), store("third").recordMsgs().map { it.state })
        assertEquals(ActiveExportStore.State.INTERRUPTED, next.consume("ex_1")?.state)
        assertEquals(emptyList<Any>(), next.recordMsgs())
        assertNull("consumed once", next.consume("ex_1"))
    }

    @Test
    fun finishOfADeadJobDoesNotEraseTheInterruptedRecord() {
        store("dead").begin("ex_1", output, Settings.msg(), DetachedHandoffMsg.SAVE_TO_GALLERY)
        val s = store("alive")
        s.records()
        s.finish("ex_1")
        assertEquals(listOf(ExportJobStateKindMsg.INTERRUPTED), s.recordMsgs().map { it.state })
    }

    @Test
    fun markInterruptedIsOneShot() {
        val s = store()
        s.begin("ex_1", output, Settings.msg(), DetachedHandoffMsg.KEEP_FOR_LATER)
        s.markInterrupted("ex_1")
        assertEquals(listOf(ExportJobStateKindMsg.INTERRUPTED), s.recordMsgs().map { it.state })
        s.consume("ex_1")
        assertEquals(emptyList<Any>(), s.recordMsgs())
    }

    @Test
    fun completedWhileDetachedCarriesTheResultUntilConsumed() {
        val s = store()
        s.begin("ex_1", output, Settings.msg(), DetachedHandoffMsg.KEEP_FOR_LATER)
        s.recordCompletedWhileDetached("ex_1", result, savedToGallery = false, savedUri = null)
        val m = store("after-relaunch").recordMsgs().single()
        assertEquals(ExportJobStateKindMsg.COMPLETED_WHILE_DETACHED, m.state)
        assertEquals(result, m.result)
        assertFalse(m.savedToGallery)
        assertNull(m.savedUri)
        assertEquals(Settings.msg(), m.settings)
        val consumed = s.consume("ex_1")!!
        assertEquals(DetachedHandoffMsg.KEEP_FOR_LATER, consumed.whenDetached)
        assertEquals(result, consumed.result)
        assertEquals(emptyList<Any>(), s.recordMsgs())
    }

    @Test
    fun galleryHandoffWithoutAKeptFile() {
        val s = store()
        s.recordCompletedWhileDetached("ex_9", null, savedToGallery = true, savedUri = "content://media/external/video/media/42")
        val m = s.recordMsgs().single()
        assertEquals(ExportJobStateKindMsg.COMPLETED_WHILE_DETACHED, m.state)
        assertTrue(m.savedToGallery)
        assertEquals("content://media/external/video/media/42", m.savedUri)
        assertNull(m.result)
    }

    @Test
    fun oneShotRecordsExpireAfterSevenDays() {
        val s = store()
        s.recordCompletedWhileDetached("ex_1", result, savedToGallery = false, savedUri = null)
        now += ActiveExportStore.ONE_SHOT_LIFETIME_MS - 1
        assertEquals(1, s.records().size)
        now += 2
        assertEquals(0, s.records().size)
        // Running records of this process never expire.
        s.begin("ex_2", output, null, DetachedHandoffMsg.SAVE_TO_GALLERY)
        now += 30L * ActiveExportStore.ONE_SHOT_LIFETIME_MS
        assertEquals(listOf("ex_2"), s.records().map { it.jobId })
    }

    @Test
    fun fileFormatV1() {
        val s = store()
        s.begin("ex_1", output, Settings.msg(w = 1080, h = 1920), DetachedHandoffMsg.SAVE_TO_GALLERY)
        val root = JSONObject(file.readText())
        assertEquals(1, root.getInt("v"))
        val job = root.getJSONArray("jobs").getJSONObject(0)
        assertEquals("ex_1", job.getString("id"))
        assertEquals("running", job.getString("state"))
        assertEquals("process-a", job.getString("process"))
        assertEquals(output.absolutePath, job.getString("output"))
        assertEquals("saveToGallery", job.getString("whenDetached"))
        assertEquals(1920, job.getJSONObject("settings").getInt("height"))
        assertEquals("h264", job.getJSONObject("settings").getString("codec"))
        assertFalse("no temp file left", File(file.parentFile, ".${file.name}.tmp").exists())
    }

    @Test
    fun corruptOrForeignFilesReadAsEmpty() {
        file.parentFile!!.mkdirs()
        file.writeText("{not json")
        assertEquals(emptyList<Any>(), store().records())
        file.writeText("""{"v":99,"jobs":[{"id":"x","state":"running"}]}""")
        assertEquals(emptyList<Any>(), store().records())
        file.writeText("""{"v":1,"jobs":[{"id":"x","state":"weird"},{"state":"running"},{"id":"ok","state":"interrupted","updatedMs":1000000}]}""")
        assertEquals(listOf("ok"), store().records().map { it.jobId })
        // Writing after a corrupt read starts a fresh file.
        store().begin("ex_1", output, null, DetachedHandoffMsg.SAVE_TO_GALLERY)
        assertEquals(setOf("ok", "ex_1"), store().records().map { it.jobId }.toSet())
    }

    @Test
    fun twoStoresOnOneFileShareTheRecords() {
        val a = store()
        val b = store()
        a.begin("ex_1", output, null, DetachedHandoffMsg.SAVE_TO_GALLERY)
        b.begin("ex_2", output, null, DetachedHandoffMsg.SAVE_TO_GALLERY)
        assertEquals(setOf("ex_1", "ex_2"), a.records().map { it.jobId }.toSet())
    }
}
