// OWNER: AND-13
//
// Voice recorder on the emulator (BUILD_PLAN AND-13): the WAV format (RIFF PCM s16 48 kHz mono,
// sizes consistent with the file and the reported duration), 20 Hz levels, the start latency
// (logged under DanaviewRecorderTest; an emulator number, its virtual microphone has no real
// input path), interruptions that keep a valid file (a real audio-focus loss from a competing focus
// request; the routed-input removal through the recorder's AudioDeviceCallback with the device list
// from AudioManager), cancel, and the permission states (undetermined / denied /
// permanently denied / granted) through the recorder's seams. MicPermissionDialogTest covers the
// real system dialog.

package com.vecvel.danaview.editor.engine.recording

import android.Manifest
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.provider.Settings
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.MicPermissionMsg
import com.vecvel.danaview.editor.engine.pigeon.RecordedAssetMsg
import com.vecvel.danaview.editor.engine.pigeon.RecordingInterruptionMsg
import com.vecvel.danaview.editor.engine.harness.PerfGate
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import org.junit.After
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin

@RunWith(AndroidJUnit4::class)
class VoiceRecorderTest {
    companion object {
        private const val TAG = "DanaviewRecorderTest"
        private lateinit var ctx: EngineContext
        private val collector = EventCollector()
        private var foreground: PermissionRelay? = null

        @BeforeClass
        @JvmStatic
        fun setUpClass() {
            ctx = RecorderTestEngine.create("recorder-test")
            collector.attach(ctx)
        }

        @AfterClass
        @JvmStatic
        fun tearDownClass() {
            ctx.threads.shutdown()
        }
    }

    private lateinit var recorder: VoiceRecorder
    private val app get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext

    @Before
    fun setUp() {
        InstrumentationRegistry.getInstrumentation().uiAutomation
            .grantRuntimePermission(app.packageName, Manifest.permission.RECORD_AUDIO)
        recorder = VoiceRecorder(ctx)
        collector.clear()
        // Audio focus is granted only to an app in the foreground (Android 12+), as the editor is.
        // The runner finishes activities around every test, so each test brings its own.
        foreground = PermissionRelay.launch()
    }

    @After
    fun tearDown() {
        foreground?.finish()
        VoiceRecorder.resetPermissionMemory(app)
    }

    private fun output(name: String) = File(ctx.requirePaths().projects, "p1/assets/recordings/$name.wav")

    private fun start(file: File): String = awaitResult<String> { recorder.start(file.absolutePath, it) }.getOrThrow()

    private fun stop(id: String): RecordedAssetMsg = awaitResult<RecordedAssetMsg> { recorder.stop(id, it) }.getOrThrow()

    private fun assertValidWav(file: File): WavHeader {
        val h = WavHeader.read(file)
        assertEquals("RIFF", h.riff)
        assertEquals("WAVE", h.wave)
        assertEquals("fmt ", h.fmt)
        assertEquals(16, h.fmtSize)
        assertEquals("PCM", 1, h.format)
        assertEquals("mono", 1, h.channels)
        assertEquals(48_000, h.sampleRate)
        assertEquals(96_000, h.byteRate)
        assertEquals(2, h.blockAlign)
        assertEquals(16, h.bits)
        assertEquals("data", h.data)
        assertEquals("data size = file - 44", file.length() - 44, h.dataSize)
        assertEquals(36 + h.dataSize, h.riffSize)
        assertEquals("whole frames", 0L, h.dataSize % 2)
        return h
    }

    @Test
    fun recordsWavS16Mono48kWithLevelsAndLatency() {
        val file = output("take1")
        val id = start(file)
        assertTrue(recorder.isRecording)
        Thread.sleep(1_500)
        val asset = stop(id)
        assertFalse(recorder.isRecording)
        assertEquals(file.absolutePath, asset.path)
        val h = assertValidWav(file)
        val frames = h.dataSize / 2
        assertEquals("duration from frames", (frames * 1_000_000L + 24_000) / 48_000, asset.durationUs)
        // A 1.5 s recording: at least 1 s in both modes; the upper bounds and the start latency are
        // timing (as written with DV_PERF_STRICT=1, 4x on a loaded emulator).
        assertTrue("duration ${asset.durationUs} µs (${PerfGate.mode})", asset.durationUs in 1_000_000L..PerfGate.boundMs(3_000) * 1_000)
        assertTrue("latency ${asset.startLatencyUs} µs (${PerfGate.mode})", asset.startLatencyUs in 0L..PerfGate.boundMs(1_000) * 1_000)
        val levels = collector.snapshot().filter { it.kind == EngineEventKindMsg.RECORDER_LEVEL && it.jobId == id }
        val minLevels = PerfGate.atLeast(10, 3)
        assertTrue("levels ${levels.size} in 1.5 s (need $minLevels, ${PerfGate.mode})", levels.size >= minLevels)
        assertTrue(levels.all { (it.recorderLevel ?: -1.0) in 0.0..1.0 })
        Log.i(
            TAG,
            "AND-13 emulator: startLatencyUs=${asset.startLatencyUs} source=${recorder.lastLatencySource} " +
                "durationUs=${asset.durationUs} levels=${levels.size} maxLevel=${levels.maxOf { it.recorderLevel ?: 0.0 }}",
        )
    }

    @Test
    fun levelMapsRmsDbfsToUnitRange() {
        assertEquals(0.0, VoiceRecorder.level(ByteArray(4800), 4800), 0.0)
        val full = ByteBuffer.allocate(4800).order(ByteOrder.LITTLE_ENDIAN)
        repeat(2400) { full.putShort(if (it % 2 == 0) Short.MAX_VALUE else Short.MIN_VALUE) }
        assertEquals(1.0, VoiceRecorder.level(full.array(), 4800), 0.001)
        // A -20 dBFS sine has RMS -23 dBFS -> (60 - 23) / 60.
        val sine = ByteBuffer.allocate(4800).order(ByteOrder.LITTLE_ENDIAN)
        repeat(2400) { sine.putShort((3276.8 * sin(2 * PI * 1000 * it / 48_000.0)).toInt().toShort()) }
        assertEquals((60 - 23.01) / 60, VoiceRecorder.level(sine.array(), 4800), 0.01)
    }

    @Test
    fun audioFocusLossStopsAndKeepsValidFile() {
        val file = output("focus")
        val id = start(file)
        Thread.sleep(700)
        val audio = app.getSystemService(AudioManager::class.java)
        val competitor = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
            .setOnAudioFocusChangeListener { }
            .build()
        try {
            assertEquals(AudioManager.AUDIOFOCUS_REQUEST_GRANTED, audio.requestAudioFocus(competitor))
            val event = collector.await(3_000) { it.kind == EngineEventKindMsg.INTERRUPTION && it.jobId == id }
            assertNotNull("interruption event", event)
            assertEquals(RecordingInterruptionMsg.INTERRUPTED, event!!.interruption)
            assertFalse(recorder.isRecording)
            // The file is complete before stop is called.
            val h = assertValidWav(file)
            assertTrue("kept audio", h.dataSize > 48_000)
            val asset = stop(id)
            assertEquals((h.dataSize / 2 * 1_000_000L + 24_000) / 48_000, asset.durationUs)
            assertEquals(h.dataSize, WavHeader.read(file).dataSize)
        } finally {
            audio.abandonAudioFocusRequest(competitor)
        }
    }

    @Test
    fun routedInputRemovalStopsAndKeepsValidFile() {
        val file = output("removed")
        val id = start(file)
        Thread.sleep(600)
        val callback = recorder.deviceCallbackOf(id)
        assertNotNull(callback)
        val audio = app.getSystemService(AudioManager::class.java)
        val inputs = audio.getDevices(AudioManager.GET_DEVICES_INPUTS)
        assertTrue("input devices", inputs.isNotEmpty())
        val routedId = recorder.routedDeviceIdOf(id)
        assertNotNull("routed input device", routedId)
        val routed = inputs.filter { it.id == routedId }
        assertEquals("routed device listed", 1, routed.size)
        // An unrelated device first: nothing happens.
        val others = inputs.filter { it.id != routedId }
        InstrumentationRegistry.getInstrumentation().runOnMainSync { callback!!.onAudioDevicesRemoved(others.toTypedArray()) }
        Thread.sleep(200)
        assertTrue("unrelated removal ignored", recorder.isRecording)
        InstrumentationRegistry.getInstrumentation().runOnMainSync { callback!!.onAudioDevicesRemoved(routed.toTypedArray()) }
        val event = collector.await(3_000) { it.kind == EngineEventKindMsg.INTERRUPTION && it.jobId == id }
        assertNotNull("interruption event", event)
        assertEquals(RecordingInterruptionMsg.DEVICE_REMOVED, event!!.interruption)
        val h = assertValidWav(file)
        assertTrue(h.dataSize > 0)
        val asset = stop(id)
        assertTrue(asset.durationUs > 0)
    }

    @Test
    fun cancelDeletesTheFile() {
        val file = output("cancelled")
        val id = start(file)
        Thread.sleep(300)
        assertTrue(file.isFile)
        awaitResult<Unit> { recorder.cancel(id, it) }.getOrThrow()
        assertFalse(file.exists())
        assertFalse(recorder.isRecording)
        val unknown = awaitResult<RecordedAssetMsg> { recorder.stop(id, it) }
        assertEquals(EngineErrorCode.internal, (unknown.exceptionOrNull() as EngineException).code)
    }

    @Test
    fun secondConcurrentRecordingIsBusy() {
        val id = start(output("first"))
        try {
            val second = awaitResult<String> { recorder.start(output("second").absolutePath, it) }
            assertEquals(EngineErrorCode.busy, (second.exceptionOrNull() as EngineException).code)
        } finally {
            stop(id)
        }
    }

    @Test
    fun recordingListenersSeeStartAndEnd() {
        val seen = java.util.Collections.synchronizedList(ArrayList<Boolean>())
        val listener: (Boolean) -> Unit = { seen.add(it) }
        recorder.addRecordingListener(listener)
        val id = start(output("listened"))
        Thread.sleep(200)
        stop(id)
        Thread.sleep(200)
        recorder.removeRecordingListener(listener)
        assertEquals(listOf(true, false), seen.toList())
    }

    @Test
    fun startWithoutPermissionIsPermissionDenied() {
        recorder.isGranted = { false }
        val r = awaitResult<String> { recorder.start(output("denied").absolutePath, it) }
        assertEquals(EngineErrorCode.permissionDenied, (r.exceptionOrNull() as EngineException).code)
    }

    // ---- permission states (seams: grant state, rationale flag, system answer) ----

    private var granted = false
    private var rationale: Boolean? = false

    private fun fakePermissions(answer: () -> Int?) {
        VoiceRecorder.resetPermissionMemory(app)
        recorder.isGranted = { granted }
        recorder.showRationale = { rationale }
        recorder.requestPermissions = { _, onResult ->
            val a = answer()
            if (a == null) false
            else {
                if (a == android.content.pm.PackageManager.PERMISSION_GRANTED) granted = true
                onResult(arrayOf(Manifest.permission.RECORD_AUDIO), intArrayOf(a))
                true
            }
        }
    }

    private fun permission() = awaitResult<MicPermissionMsg> { recorder.permission(it) }.getOrThrow()

    private fun request() = awaitResult<MicPermissionMsg> { recorder.requestPermission(it) }.getOrThrow()

    @Test
    fun deniedThenPermanentlyDenied() {
        val denied = android.content.pm.PackageManager.PERMISSION_DENIED
        fakePermissions { denied }
        assertEquals(MicPermissionMsg.UNDETERMINED, permission())
        rationale = true // after the first denial the system sets the rationale flag
        assertEquals(MicPermissionMsg.DENIED, request())
        assertEquals(MicPermissionMsg.DENIED, permission())
        rationale = false // second denial: the system stops asking
        assertEquals(MicPermissionMsg.PERMANENTLY_DENIED, request())
        assertEquals(MicPermissionMsg.PERMANENTLY_DENIED, permission())
        rationale = null // no activity attached: the remembered answer
        assertEquals(MicPermissionMsg.PERMANENTLY_DENIED, permission())
    }

    @Test
    fun dismissedFirstDialogIsNotPermanent() {
        fakePermissions { android.content.pm.PackageManager.PERMISSION_DENIED }
        rationale = false
        assertEquals(MicPermissionMsg.DENIED, request())
        assertEquals(MicPermissionMsg.UNDETERMINED, permission())
    }

    @Test
    fun grantedAndSystemRevokedOneTimeGrant() {
        fakePermissions { android.content.pm.PackageManager.PERMISSION_GRANTED }
        assertEquals(MicPermissionMsg.GRANTED, request())
        assertEquals(MicPermissionMsg.GRANTED, permission())
        granted = false // a one-time grant revoked by the system: the system asks again
        rationale = false
        assertEquals(MicPermissionMsg.UNDETERMINED, permission())
    }

    @Test
    fun requestWithoutActivityFails() {
        fakePermissions { null }
        val r = awaitResult<MicPermissionMsg> { recorder.requestPermission(it) }
        assertEquals(EngineErrorCode.internal, (r.exceptionOrNull() as EngineException).code)
    }

    @Test
    fun openSettingsShowsTheAppDetailsPage() {
        var launched: Intent? = null
        recorder.startActivity = { launched = it }
        awaitResult<Unit> { recorder.openSettings(it) }.getOrThrow()
        assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, launched!!.action)
        assertEquals("package:${app.packageName}", launched!!.data.toString())
    }

    @Test
    fun openSettingsWithoutActivityStartsSettingsTask() {
        // Production path without an activity: started from the application context in a new task.
        awaitOnMain<Unit> { recorder.openSettings(it) }.getOrThrow()
        val device = androidx.test.uiautomator.UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val settingsUp = device.wait(Until.hasObject(By.pkg("com.android.settings")), 10_000)
        device.pressBack()
        device.wait(Until.gone(By.pkg("com.android.settings")), 5_000)
        assertTrue("settings shown", settingsUp == true)
    }
}
