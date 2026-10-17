// OWNER: INT-07
//
// The INT-07 glue on Android against fake ports: materializePick (intoDir inside `<cache>/work/`,
// danaview-io), isRecording (danaview-io), the localized notification texts of `initialize` and
// `start` (handed to the port before the job starts; M-19: a blank or over-long string falls back to
// its English default for that string only, and a default-config `initialize` keeps the localized
// texts another engine set), the recording bridge (one
// `recordingChanged` event per change, the preview mute), and the notification text formatting.

package com.vecvel.danaview.editor.engine.glue

import android.content.ContextWrapper
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EventHub
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.export.ExportNotification
import com.vecvel.danaview.editor.engine.export.ExportNotificationTexts
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineConfigMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportContainerMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportNotificationTextsMsg
import com.vecvel.danaview.editor.engine.pigeon.VideoCodecMsg
import com.vecvel.danaview.editor.engine.platform.PickMaterializer
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class Int07GlueTest {
    private val fake = FakeThreads()
    private val calls = PortCalls(fake.trace)
    private val pathsFn = { TestRoots.paths }
    private val work = "${TestRoots.CACHE}/work"

    private var recording = false
    private val platformPort = object : PlatformPort by FakePlatformPort(calls) {
        override fun materializePick(uri: String, intoDir: File, done: Completion<String>) =
            calls.call("materializePick", uri, intoDir.invariantSeparatorsPath, done = done)
    }
    private val recorderPort = object : RecorderPort by FakeRecorderPort(calls) {
        override fun isRecording(done: Completion<Boolean>) {
            calls.fire("isRecording")
            done.succeed(recording)
        }
    }
    private val texts = mutableListOf<ExportNotificationTextsMsg>()
    private val exportPort = object : ExportPort by FakeExportPort(calls) {
        override fun setExportTexts(texts: ExportNotificationTextsMsg) {
            calls.fire("setExportTexts")
            this@Int07GlueTest.texts.add(texts)
        }
    }
    private val rootPort = object : EngineRootPort by FakeRootPort(calls) {
        override fun setExportTexts(texts: ExportNotificationTextsMsg) {
            calls.fire("setExportTexts")
            this@Int07GlueTest.texts.add(texts)
        }
    }

    private val platform = PlatformHostApiImpl(fake.threads, platformPort, pathsFn)
    private val recorder = RecorderHostApiImpl(fake.threads, recorderPort, pathsFn)
    private val export = ExportHostApiImpl(fake.threads, exportPort, pathsFn)
    private val engine = EngineHostApiImpl(fake.threads, rootPort)

    private val settings = EncodeSettingsMsg(
        container = ExportContainerMsg.MP4, codec = VideoCodecMsg.H264, width = 1920, height = 1080, fps = 30,
        videoBitrate = 8_000_000, audioBitrate = 192_000, audioSampleRate = 48_000, audioChannels = 2,
        keyframeIntervalMs = 1000, stripLocation = true,
    )

    private fun localized(cancel: String = "Abbrechen") = ExportNotificationTexts.DEFAULTS.copy(
        cancel = cancel, exportingProgress = "Export · {percent} %", more = "+{count} weitere",
    )

    @After
    fun resetTexts() = ExportNotificationTexts.reset()

    private fun <T> call(block: (callback: (Result<T>) -> Unit) -> Unit): Reply<T> {
        val reply = Reply<T>(fake.trace)
        fake.main.onMain { block(reply.callback) }
        fake.settle()
        return reply
    }

    // ---- materializePick ----

    @Test
    fun materializePickRunsOnIoWithTheNormalizedDirectory() {
        calls.answer = { _, args -> Result.success("${args[1]}/u1/clip.mp4") }
        val path = call<String> { platform.materializePick("content://media/external/video/1", "$work/picks/", it) }.value()
        assertEquals("$work/picks/u1/clip.mp4", path)
        val c = calls.log.single { it.name == "materializePick" }
        assertEquals(Where.IO, c.where)
        assertEquals(listOf("content://media/external/video/1", "$work/picks"), c.args)
    }

    @Test
    fun materializePickRefusesDirectoriesOutsideWork() {
        call<String> { platform.materializePick("content://m/1", "${TestRoots.CACHE}/media", it) }.assertError("permissionDenied")
        call<String> { platform.materializePick("content://m/1", "$work/../media", it) }.assertError("internal") // `..` is refused outright
        call<String> { platform.materializePick("content://m/1", "work/picks", it) }.assertError("internal")
        call<String> { platform.materializePick("", "$work/picks", it) }.assertError("internal")
        assertTrue(calls.log.none { it.name == "materializePick" })
    }

    @Test
    fun materializePickDefaultsToNotSupported() {
        val plain = PlatformHostApiImpl(fake.threads, FakePlatformPort(calls), pathsFn)
        call<String> { plain.materializePick("content://m/1", "$work/picks", it) }.assertError("notSupportedOnDevice")
    }

    @Test
    fun pickNamesAreSanitizedLikeDrops() {
        assertEquals("a_b_c.mp4", PickMaterializer.sanitizedName("a/b:c.mp4", "video/mp4"))
        assertEquals("pick", PickMaterializer.sanitizedName("...", null))
    }

    // ---- isRecording ----

    @Test
    fun isRecordingAsksThePortOnIo() {
        assertEquals(false, call<Boolean> { recorder.isRecording(it) }.value())
        recording = true
        assertEquals(true, call<Boolean> { recorder.isRecording(it) }.value())
        assertTrue(calls.log.filter { it.name == "isRecording" }.all { it.where == Where.IO })
        val plain = RecorderHostApiImpl(fake.threads, FakeRecorderPort(calls), pathsFn)
        call<Boolean> { plain.isRecording(it) }.assertError("notSupportedOnDevice")
    }

    // ---- notification texts ----

    @Test
    fun initializeHandsTheTextsToThePortBeforeInstallingTheRoots() {
        val config = EngineConfigMsg(cacheRoot = TestRoots.CACHE, supportRoot = TestRoots.SUPPORT, exportTexts = localized())
        call<Unit> { engine.initialize(config, it) }.value()
        assertEquals(listOf("setExportTexts", "installRoots"), calls.names())
        assertEquals("Abbrechen", texts.single().cancel)
    }

    @Test
    fun initializeFallsBackPerStringInsteadOfFailing() {
        val bad = localized(cancel = " ").copy(more = "", doneChannelName = "x".repeat(257), workTitle = "y".repeat(256))
        val config = EngineConfigMsg(cacheRoot = TestRoots.CACHE, supportRoot = TestRoots.SUPPORT, exportTexts = bad)
        call<Unit> { engine.initialize(config, it) }.value()
        assertEquals(listOf("setExportTexts", "installRoots"), calls.names())
        val got = texts.single()
        assertEquals(ExportNotificationTexts.DEFAULTS.cancel, got.cancel)
        assertEquals(ExportNotificationTexts.DEFAULTS.more, got.more)
        assertEquals(ExportNotificationTexts.DEFAULTS.doneChannelName, got.doneChannelName)
        assertEquals("y".repeat(256), got.workTitle) // the limit itself is accepted
        assertEquals("Export · {percent} %", got.exportingProgress) // the valid strings stay localized
    }

    @Test
    fun aDefaultConfigEngineKeepsTheLocalizedTextsOfAnother() {
        val port = ContextEngineRootPort(EngineContext(ContextWrapper(null), fake.threads))
        port.setExportTexts(ExportNotificationTexts.withFallbacks(localized()))
        assertEquals("Abbrechen", ExportNotificationTexts.current.cancel)
        // A second Flutter engine initializes with the default (English) config: no process-wide reset.
        port.setExportTexts(ExportNotificationTexts.DEFAULTS)
        assertEquals("Abbrechen", ExportNotificationTexts.current.cancel)
        assertEquals(false, ExportNotificationTexts.setFromInitialize(ExportNotificationTexts.DEFAULTS))
        // Other localized texts from an initialize still apply; so do English texts an export start carries.
        assertEquals(true, ExportNotificationTexts.setFromInitialize(localized(cancel = "Annuler")))
        assertEquals("Annuler", ExportNotificationTexts.current.cancel)
        ExportNotificationTexts.set(ExportNotificationTexts.DEFAULTS)
        assertEquals(ExportNotificationTexts.DEFAULTS, ExportNotificationTexts.current)
        // set() applies the per-string fallbacks too.
        ExportNotificationTexts.set(localized(cancel = ""))
        assertEquals(ExportNotificationTexts.DEFAULTS.cancel, ExportNotificationTexts.current.cancel)
        assertEquals("+{count} weitere", ExportNotificationTexts.current.more)
    }

    @Test
    fun startSetsItsTextsBeforeTheJobAndKeepsThemWithoutTexts() {
        calls.answer = { _, _ -> Result.success("export-1") }
        val plan = "{}".toByteArray()
        call<String> { export.start(plan, settings, "$work/e.mp4", "Trip", DetachedHandoffMsg.SAVE_TO_GALLERY, localized(), it) }.value()
        assertEquals(listOf("setExportTexts", "start"), calls.names())
        assertTrue(calls.log.all { it.where == Where.EXPORT })
        call<String> { export.start(plan, settings, "$work/e.mp4", "Trip", DetachedHandoffMsg.SAVE_TO_GALLERY, null, it) }.value()
        assertEquals(listOf("setExportTexts", "start", "start"), calls.names())
        call<String> {
            export.start(plan, settings, "$work/e.mp4", "Trip", DetachedHandoffMsg.SAVE_TO_GALLERY, localized(cancel = "x".repeat(300)), it)
        }.value()
        assertEquals(listOf("setExportTexts", "start", "start", "setExportTexts", "start"), calls.names())
        assertEquals(2, texts.size)
        assertEquals(ExportNotificationTexts.DEFAULTS.cancel, texts[1].cancel) // that string only
        assertEquals("+{count} weitere", texts[1].more)
    }

    @Test
    fun theProcessTextsDriveTheNotificationText() {
        assertEquals("Exporting · 40%", ExportNotification.contentText(ExportNotificationTexts.current, true, 40))
        assertEquals("Working", ExportNotification.contentText(ExportNotificationTexts.current, false, null))
        assertEquals(ExportNotification.CANCEL_LABEL, ExportNotificationTexts.DEFAULTS.cancel)
        assertEquals(ExportNotification.SAVED_TITLE, ExportNotificationTexts.DEFAULTS.savedToGallery)
        assertEquals(ExportNotification.FINISHED_TITLE, ExportNotificationTexts.DEFAULTS.exportFinished)
        assertEquals(ExportNotification.DEFAULT_EXPORT_TITLE, ExportNotificationTexts.DEFAULTS.exportTitle)
        assertEquals(ExportNotification.DEFAULT_WORK_TITLE, ExportNotificationTexts.DEFAULTS.workTitle)
        ExportNotificationTexts.set(localized())
        assertEquals("Export · 7 %", ExportNotification.contentText(ExportNotificationTexts.current, true, 7))
        assertEquals("Exporting", ExportNotification.contentText(ExportNotificationTexts.current, true, null))
        assertEquals("+2 weitere", ExportNotificationTexts.withCount(ExportNotificationTexts.current.more, 2))
    }

    // ---- recording bridge ----

    @Test
    fun theBridgeEmitsOnceperChangeAndMutes() {
        val main = FakeMain(fake.trace)
        val hub = EventHub(main)
        val events = mutableListOf<EngineEventMsg>()
        main.onMain { hub.attach { events.add(it) } }
        val muted = mutableListOf<Boolean>()
        val bridge = RecordingSignals(hub) { muted.add(it) }
        main.onMain {
            bridge.onRecording(true)
            bridge.onRecording(true)
            bridge.onRecording(false)
        }
        main.drain()
        val changes = events.filter { it.kind == EngineEventKindMsg.RECORDING_CHANGED }
        assertEquals(listOf(true, false), changes.map { it.recording })
        assertEquals(listOf(true, false), muted)
    }
}
