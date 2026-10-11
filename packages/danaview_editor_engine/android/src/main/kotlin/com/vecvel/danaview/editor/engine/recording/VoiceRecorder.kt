// OWNER: AND-13
//
// Android voice recorder (ARCH §12.4, §15, D-25; BUILD_PLAN AND-13).
//
// - Capture: AudioRecord(MIC, 48 kHz, mono, PCM 16-bit) read on its own thread ("danaview-recorder",
//   THREAD_PRIORITY_URGENT_AUDIO) in 50 ms blocks, written straight to the WAV at the Dart path
//   (inside the engine roots; the glue checks it). The RIFF/data sizes are patched every 0.5 s and
//   on finish, so the file is a valid WAV at any moment (a crash loses at most 0.5 s).
// - Levels: one RMS level per 50 ms block (20 Hz), dBFS mapped linearly from -60..0 dB to 0..1,
//   sent as `recorderLevel` events keyed by the recording id (EventHub rate-limits to 50 ms).
// - Start latency: the time from the startRecording() call to the capture time of frame 0, from
//   AudioRecord.getTimestamp(TIMEBASE_MONOTONIC); when the timestamp is unavailable, the return
//   time of the first read minus that block's duration. Never negative. Dart places the clip at
//   playhead + latency.
// - Interruptions keep the file: audio-focus loss (the recorder holds
//   AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE, as Android recommends for voice memos), removal of the
//   routed input device, or a dead AudioRecord stop the capture, finalize the WAV, then emit an
//   `interruption` event (interrupted | deviceRemoved). stop() afterwards returns the kept asset.
// - Permission (RECORD_AUDIO, requested in context; the rationale UI is Dart's):
//   granted → granted; never requested, or only dismissed → undetermined; denied with the rationale
//   flag set → denied; denied again without the rationale flag (the system no longer prompts) →
//   permanentlyDenied. Android has no direct "permanently denied" query, so the recorder remembers
//   in its own SharedPreferences whether it asked and whether a denial with rationale was seen; a
//   one-time grant that the system revoked reads as undetermined again.
// - Preview playback is muted while recording (ARCH §15): the recorder exposes [isRecording] and
//   [addRecordingListener] for the preview engine (AND-10/AND-16) to mute its audio output.
// - Nothing here logs paths or audio content.

package com.vecvel.danaview.editor.engine.recording

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.util.Log
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.pigeon.MicPermissionMsg
import com.vecvel.danaview.editor.engine.pigeon.RecordedAssetMsg
import com.vecvel.danaview.editor.engine.pigeon.RecordingInterruptionMsg
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Voice recorder (ARCH §12.4, §15; AND-13). `permission`, `start`, `stop` and `cancel` are called on
 * danaview-io; `requestPermission` and `openSettings` on main (they need the activity).
 */
class VoiceRecorder(private val ctx: EngineContext) {

    // ---- seams (production defaults; instrumented tests substitute them) ----

    /** Whether RECORD_AUDIO is granted. */
    internal var isGranted: () -> Boolean = {
        ctx.appContext.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    }

    /** shouldShowRequestPermissionRationale(RECORD_AUDIO) of the current activity; null without one. */
    internal var showRationale: () -> Boolean? = {
        ctx.activityHost.activity?.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)
    }

    /** Starts the runtime request; false when no activity is attached. Main thread. */
    internal var requestPermissions: (Array<String>, (Array<out String>, IntArray) -> Unit) -> Boolean =
        { permissions, onResult -> ctx.activityHost.requestPermissions(permissions, onResult) }

    /** Starts an activity (the app's settings page). */
    internal var startActivity: (Intent) -> Unit = { intent ->
        val activity = ctx.activityHost.activity
        if (activity != null) activity.startActivity(intent)
        else ctx.appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private val prefs by lazy { ctx.appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE) }
    private val audioManager by lazy { ctx.appContext.getSystemService(AudioManager::class.java) }
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val lock = Any()
    private val recordings = HashMap<String, Recording>()
    private val listeners = CopyOnWriteArrayList<(Boolean) -> Unit>()

    // ---- permission ----

    /** The microphone permission state. */
    fun permission(done: Completion<MicPermissionMsg>) = done.succeed(currentPermission())

    /** Requests the microphone permission in context. */
    fun requestPermission(done: Completion<MicPermissionMsg>) {
        if (isGranted()) {
            remember(granted = true)
            return done.succeed(MicPermissionMsg.GRANTED)
        }
        prefs.edit().putBoolean(KEY_ASKED, true).apply()
        val started = requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO)) { _, results ->
            if (results.isEmpty()) {
                // The activity went away before an answer: report the state as it stands.
                done.succeed(currentPermission())
                return@requestPermissions
            }
            if (results[0] == PackageManager.PERMISSION_GRANTED || isGranted()) {
                remember(granted = true)
                done.succeed(MicPermissionMsg.GRANTED)
            } else {
                done.succeed(afterDenial())
            }
        }
        if (!started) done.fail(EngineException(EngineErrorCode.internal, "no activity attached"))
    }

    /** Opens the app's system settings (permanently denied). */
    fun openSettings(done: Completion<Unit>) {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.appContext.packageName, null))
        try {
            startActivity(intent)
            done.succeed(Unit)
        } catch (e: RuntimeException) {
            done.fail(EngineException(EngineErrorCode.notSupportedOnDevice, "settings unavailable", cause = e))
        }
    }

    private fun currentPermission(): MicPermissionMsg {
        if (isGranted()) return MicPermissionMsg.GRANTED
        if (!prefs.getBoolean(KEY_ASKED, false)) return MicPermissionMsg.UNDETERMINED
        // Granted earlier (e.g. "only this time") and revoked by the system: the system asks again.
        if (prefs.getBoolean(KEY_LAST_GRANTED, false)) return MicPermissionMsg.UNDETERMINED
        val deniedOnce = prefs.getBoolean(KEY_DENIED_WITH_RATIONALE, false)
        return when (showRationale()) {
            true -> MicPermissionMsg.DENIED
            false -> if (deniedOnce) MicPermissionMsg.PERMANENTLY_DENIED else MicPermissionMsg.UNDETERMINED
            null -> stored() ?: if (deniedOnce) MicPermissionMsg.DENIED else MicPermissionMsg.UNDETERMINED
        }
    }

    /** Classifies a denial that just came back from the system dialog. */
    private fun afterDenial(): MicPermissionMsg {
        val rationale = showRationale()
        val deniedOnce = prefs.getBoolean(KEY_DENIED_WITH_RATIONALE, false)
        val state = when {
            rationale == true -> MicPermissionMsg.DENIED
            deniedOnce -> MicPermissionMsg.PERMANENTLY_DENIED
            // First answer without the rationale flag: the dialog was dismissed (API 30+), or a
            // device policy denies it. Report denied; the next denial decides.
            else -> MicPermissionMsg.DENIED
        }
        prefs.edit()
            .putBoolean(KEY_LAST_GRANTED, false)
            .putBoolean(KEY_DENIED_WITH_RATIONALE, deniedOnce || rationale == true)
            .putInt(KEY_LAST_STATE, state.raw)
            .apply()
        return state
    }

    private fun remember(granted: Boolean) {
        prefs.edit().putBoolean(KEY_LAST_GRANTED, granted).putInt(KEY_LAST_STATE, MicPermissionMsg.GRANTED.raw).apply()
    }

    private fun stored(): MicPermissionMsg? =
        MicPermissionMsg.ofRaw(prefs.getInt(KEY_LAST_STATE, -1))?.takeIf { it != MicPermissionMsg.GRANTED }

    // ---- recording ----

    /** Whether a recording is capturing now (the preview mutes its audio meanwhile). */
    val isRecording: Boolean get() = synchronized(lock) { recordings.values.any { it.isCapturing } }

    /** Adds a listener told (on main) when capture starts (true) and ends (false). */
    fun addRecordingListener(listener: (Boolean) -> Unit) {
        listeners += listener
    }

    /** Removes a listener added with [addRecordingListener]. */
    fun removeRecordingListener(listener: (Boolean) -> Unit) {
        listeners -= listener
    }

    /** Starts recording to [outputPath] (inside the engine roots); completes with the recording id. */
    fun start(outputPath: String, done: Completion<String>) {
        try {
            done.succeed(startNow(outputPath))
        } catch (e: Throwable) {
            done.fail(e)
        }
    }

    /** Stops [recordingId] and completes with the recorded asset. */
    fun stop(recordingId: String, done: Completion<RecordedAssetMsg>) {
        val recording = synchronized(lock) { recordings.remove(recordingId) }
            ?: return done.fail(EngineException(EngineErrorCode.internal, "unknown recording"))
        try {
            recording.finish()
            done.succeed(recording.asset())
        } catch (e: Throwable) {
            done.fail(e)
        }
    }

    /** Cancels [recordingId] and deletes its file. */
    fun cancel(recordingId: String, done: Completion<Unit>) {
        val recording = synchronized(lock) { recordings.remove(recordingId) }
            ?: return done.fail(EngineException(EngineErrorCode.internal, "unknown recording"))
        try {
            recording.finish()
        } catch (_: Throwable) {
            // The file is deleted anyway.
        }
        recording.file.delete()
        done.succeed(Unit)
    }

    @SuppressLint("MissingPermission") // isGranted() is checked first; a SecurityException is mapped.
    private fun startNow(outputPath: String): String {
        if (!isGranted()) throw EngineException(EngineErrorCode.permissionDenied, "microphone permission not granted")
        synchronized(lock) {
            if (recordings.values.any { it.isCapturing }) throw EngineException(EngineErrorCode.busy, "a recording is already running")
        }
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuffer <= 0) throw EngineException(EngineErrorCode.notSupportedOnDevice, "48 kHz mono capture unsupported")
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuffer * 2, BLOCK_BYTES * 4),
            )
        } catch (e: SecurityException) {
            throw EngineException(EngineErrorCode.permissionDenied, "microphone access denied", cause = e)
        } catch (e: IllegalArgumentException) {
            throw EngineException(EngineErrorCode.notSupportedOnDevice, "capture format unsupported", cause = e)
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw EngineException(EngineErrorCode.busy, "microphone unavailable")
        }
        val file = File(outputPath)
        val writer = try {
            file.parentFile?.mkdirs()
            WavWriter(file)
        } catch (e: IOException) {
            record.release()
            throw EngineException(EngineErrorCode.io, "cannot create the recording file", cause = e)
        }
        val id = "rec-" + UUID.randomUUID().toString()
        val recording = Recording(id, file, record, writer)
        try {
            recording.begin()
        } catch (e: Throwable) {
            recording.abandon()
            file.delete()
            throw e
        }
        synchronized(lock) { recordings[id] = recording }
        return id
    }

    private fun notifyListeners(active: Boolean) {
        mainHandler.post { listeners.forEach { it(active) } }
    }

    /** One capture. Its thread owns the AudioRecord and the writer. */
    private inner class Recording(
        val id: String,
        val file: File,
        private val record: AudioRecord,
        private val writer: WavWriter,
    ) : Runnable {
        @Volatile private var stopRequested = false
        @Volatile private var interruption: RecordingInterruptionMsg? = null
        @Volatile var isCapturing = false
            private set
        @Volatile private var failure: Throwable? = null
        private var thread: Thread? = null
        private var startCallNs = 0L
        @Volatile private var latencyUs = 0L
        @Volatile private var frames = 0L
        private var focusRequest: AudioFocusRequest? = null
        private var routedDeviceId: Int? = null
        private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
            if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                interrupt(RecordingInterruptionMsg.INTERRUPTED)
            }
        }

        /** Exposed to tests: the routed-device watcher (onAudioDevicesRemoved stops and keeps the file). */
        val deviceCallback = object : AudioDeviceCallback() {
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                val routed = routedDeviceId ?: record.routedDevice?.id ?: return
                if (removedDevices.any { it.id == routed }) interrupt(RecordingInterruptionMsg.DEVICE_REMOVED)
            }
        }

        fun begin() {
            requestFocus()
            audioManager.registerAudioDeviceCallback(deviceCallback, mainHandler)
            startCallNs = System.nanoTime()
            try {
                record.startRecording()
            } catch (e: IllegalStateException) {
                throw EngineException(EngineErrorCode.busy, "microphone unavailable", cause = e)
            }
            if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                throw EngineException(EngineErrorCode.busy, "microphone unavailable")
            }
            routedDeviceId = record.routedDevice?.id
            isCapturing = true
            notifyListeners(true)
            thread = Thread(this, "danaview-recorder").also { it.start() }
        }

        private fun requestFocus() {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                    .setAudioAttributes(attributes)
                    .setOnAudioFocusChangeListener(focusListener, mainHandler)
                    .build()
                focusRequest = request
                audioManager.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            }
            if (granted == AudioManager.AUDIOFOCUS_REQUEST_FAILED) {
                abandonFocus()
                throw EngineException(EngineErrorCode.busy, "audio focus denied (call in progress)")
            }
        }

        private fun abandonFocus() {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(focusListener)
            }
            focusRequest = null
        }

        fun interrupt(kind: RecordingInterruptionMsg) {
            if (stopRequested) return
            interruption = kind
            stopRequested = true
        }

        override fun run() {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val block = ByteArray(BLOCK_BYTES)
            var sinceHeader = 0L
            try {
                while (!stopRequested) {
                    val n = record.read(block, 0, block.size, AudioRecord.READ_BLOCKING)
                    if (n < 0) {
                        interruption = RecordingInterruptionMsg.INTERRUPTED
                        break
                    }
                    if (n == 0) continue
                    if (frames == 0L) latencyUs = measureLatencyUs(n / BYTES_PER_FRAME)
                    writer.append(block, n)
                    frames += n / BYTES_PER_FRAME
                    sinceHeader += n / BYTES_PER_FRAME
                    if (sinceHeader >= HEADER_REFRESH_FRAMES) {
                        writer.patchHeader()
                        sinceHeader = 0
                    }
                    ctx.events.recorderLevel(id, level(block, n))
                }
            } catch (e: IOException) {
                failure = EngineException(EngineErrorCode.io, "recording write failed", cause = e)
                interruption = RecordingInterruptionMsg.INTERRUPTED
            } catch (e: Throwable) {
                failure = e
                interruption = RecordingInterruptionMsg.INTERRUPTED
            } finally {
                close()
            }
            val kind = interruption
            if (kind != null) {
                Log.i(TAG, "recording interrupted: ${kind.name}")
                ctx.events.interruption(id, kind)
            }
        }

        private fun close() {
            try {
                record.stop()
            } catch (_: IllegalStateException) {
            }
            record.release()
            try {
                writer.finish()
            } catch (e: IOException) {
                if (failure == null) failure = EngineException(EngineErrorCode.io, "recording write failed", cause = e)
            }
            mainHandler.post {
                audioManager.unregisterAudioDeviceCallback(deviceCallback)
                abandonFocus()
            }
            if (isCapturing) {
                isCapturing = false
                notifyListeners(false)
            }
        }

        /** frame-0 capture time minus the startRecording() call, in µs (>= 0). */
        private fun measureLatencyUs(firstBlockFrames: Int): Long {
            val now = System.nanoTime()
            val ts = AudioTimestamp()
            val frame0Ns = if (record.getTimestamp(ts, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS && ts.nanoTime > 0) {
                ts.nanoTime - ts.framePosition * 1_000_000_000L / SAMPLE_RATE
            } else {
                now - firstBlockFrames * 1_000_000_000L / SAMPLE_RATE
            }
            lastLatencySource = if (ts.nanoTime > 0) "timestamp" else "firstRead"
            return ((frame0Ns - startCallNs) / 1_000L).coerceAtLeast(0L)
        }

        /** Waits for the capture thread (stop requested if still running); rethrows a write failure. */
        fun finish() {
            stopRequested = true
            val t = thread
            if (t != null && t !== Thread.currentThread()) t.join(JOIN_TIMEOUT_MS)
            failure?.let { throw it }
        }

        /** Releases what begin() acquired when it failed half-way. */
        fun abandon() {
            stopRequested = true
            if (thread == null) {
                try {
                    record.stop()
                } catch (_: IllegalStateException) {
                }
                record.release()
                try {
                    writer.finish()
                } catch (_: IOException) {
                }
                audioManager.unregisterAudioDeviceCallback(deviceCallback)
                abandonFocus()
                if (isCapturing) {
                    isCapturing = false
                    notifyListeners(false)
                }
            }
        }

        fun asset(): RecordedAssetMsg = RecordedAssetMsg(
            path = file.absolutePath,
            durationUs = (frames * 1_000_000L + SAMPLE_RATE / 2) / SAMPLE_RATE,
            startLatencyUs = latencyUs,
        )
    }

    /** Test hook: the device callback of the running recording [recordingId]. */
    internal fun deviceCallbackOf(recordingId: String): AudioDeviceCallback? = synchronized(lock) { recordings[recordingId]?.deviceCallback }

    /** Test/diagnostic: where the last start latency came from ("timestamp" or "firstRead"). */
    @Volatile internal var lastLatencySource: String = "none"

    companion object {
        /** Capture rate (D-25). */
        const val SAMPLE_RATE = 48_000

        /** Mono s16. */
        const val BYTES_PER_FRAME = 2

        /** 50 ms blocks: one level per block (20 Hz). */
        const val BLOCK_FRAMES = SAMPLE_RATE / 20
        const val BLOCK_BYTES = BLOCK_FRAMES * BYTES_PER_FRAME

        /** The WAV header sizes are refreshed every 0.5 s of audio. */
        const val HEADER_REFRESH_FRAMES = SAMPLE_RATE / 2L

        /** Level floor: -60 dBFS maps to 0. */
        const val LEVEL_FLOOR_DB = -60.0

        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val PREFS = "danaview_editor_recorder"
        private const val KEY_ASKED = "mic.asked"
        private const val KEY_LAST_GRANTED = "mic.lastGranted"
        private const val KEY_DENIED_WITH_RATIONALE = "mic.deniedWithRationale"
        private const val KEY_LAST_STATE = "mic.lastState"
        private const val TAG = EngineContext.TAG

        /** RMS level of [n] bytes of s16 little-endian PCM, mapped -60..0 dBFS → 0..1. */
        fun level(pcm: ByteArray, n: Int): Double {
            val samples = n / 2
            if (samples == 0) return 0.0
            var sum = 0.0
            var i = 0
            while (i + 1 < n) {
                val s = ((pcm[i + 1].toInt() shl 8) or (pcm[i].toInt() and 0xff)).toShort().toDouble()
                sum += s * s
                i += 2
            }
            val rms = sqrt(sum / samples) / 32768.0
            if (rms <= 0.0) return 0.0
            val db = 20.0 * log10(rms)
            return ((db - LEVEL_FLOOR_DB) / -LEVEL_FLOOR_DB).coerceIn(0.0, 1.0)
        }

        /** Clears the remembered permission answers (tests). */
        internal fun resetPermissionMemory(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().commit()
        }
    }
}

/**
 * A WAV (RIFF, PCM s16, 48 kHz, mono) written in place. The header is written first with zero
 * sizes and patched by [patchHeader] / [finish], so the file is always parseable.
 */
internal class WavWriter(file: File) {
    private val raf = RandomAccessFile(file, "rw")
    private var dataBytes = 0L

    init {
        raf.setLength(0)
        raf.write(header(0))
    }

    fun append(bytes: ByteArray, n: Int) {
        raf.write(bytes, 0, n)
        dataBytes += n
    }

    fun patchHeader() {
        val end = raf.filePointer
        raf.seek(0)
        raf.write(header(dataBytes))
        raf.seek(end)
    }

    fun finish() {
        try {
            patchHeader()
            raf.fd.sync()
        } finally {
            raf.close()
        }
    }

    companion object {
        const val HEADER_BYTES = 44

        fun header(dataBytes: Long): ByteArray {
            val rate = VoiceRecorder.SAMPLE_RATE
            val b = java.nio.ByteBuffer.allocate(HEADER_BYTES).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            b.put("RIFF".toByteArray(Charsets.US_ASCII))
            b.putInt((36 + dataBytes).toInt())
            b.put("WAVE".toByteArray(Charsets.US_ASCII))
            b.put("fmt ".toByteArray(Charsets.US_ASCII))
            b.putInt(16)
            b.putShort(1) // PCM
            b.putShort(1) // mono
            b.putInt(rate)
            b.putInt(rate * VoiceRecorder.BYTES_PER_FRAME)
            b.putShort(VoiceRecorder.BYTES_PER_FRAME.toShort())
            b.putShort(16)
            b.put("data".toByteArray(Charsets.US_ASCII))
            b.putInt(dataBytes.toInt())
            return b.array()
        }
    }
}
