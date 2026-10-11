// OWNER: ENG-08
//
// The process-scoped engine (ARCH §4.4, §14.3: ExportCoordinator and the export service outlive the
// activity and the Flutter engine). One EngineContext per process holds the application Context,
// the Dart-supplied roots (Paths), the threads, the event hub, the current activity, and the
// service singletons of ARCH §4.4. Each Flutter engine that attaches the plugin adds its event
// sink and texture registry; services reach each other through this class.
//
// Service classes take `(ctx: EngineContext)` and are created lazily on first use. The glue only
// calls the methods declared in the D-33 placeholders (ENG-08); service tickets (AND-02..AND-17)
// replace the placeholder bodies, keep those signatures, and may add anything else.

package com.vecvel.danaview.editor.engine.core

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.util.Log
import com.vecvel.danaview.editor.engine.export.ExportCoordinator
import com.vecvel.danaview.editor.engine.media.Compatibility
import com.vecvel.danaview.editor.engine.media.DiskCache
import com.vecvel.danaview.editor.engine.media.FreezeFrameJob
import com.vecvel.danaview.editor.engine.media.Probe
import com.vecvel.danaview.editor.engine.media.ProxyJob
import com.vecvel.danaview.editor.engine.media.ProxyRegistry
import com.vecvel.danaview.editor.engine.media.ReverseJob
import com.vecvel.danaview.editor.engine.media.SpeechAudioExtractor
import com.vecvel.danaview.editor.engine.media.ThumbnailService
import com.vecvel.danaview.editor.engine.media.WaveformService
import com.vecvel.danaview.editor.engine.platform.BackgroundGuard
import com.vecvel.danaview.editor.engine.platform.DropTarget
import com.vecvel.danaview.editor.engine.platform.FileHandoff
import com.vecvel.danaview.editor.engine.platform.MediaAccess
import com.vecvel.danaview.editor.engine.platform.MediaPicker
import com.vecvel.danaview.editor.engine.platform.MediaStoreSaver
import com.vecvel.danaview.editor.engine.platform.Permissions
import com.vecvel.danaview.editor.engine.preview.PreviewSessionManager
import com.vecvel.danaview.editor.engine.preview.SourceFrameCache
import com.vecvel.danaview.editor.engine.recording.VoiceRecorder
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.atomic.AtomicInteger

/** Asynchronous completion of a service call. Call exactly once, from any thread. */
typealias Completion<T> = (Result<T>) -> Unit

/** Completes with [value]. */
fun <T> Completion<T>.succeed(value: T) = this(Result.success(value))

/** Completes with [error] (any Throwable; mapped by [EngineErrors.from]). */
fun <T> Completion<T>.fail(error: Throwable) = this(Result.failure(error))

/**
 * What a media job sees of its registry entry (AND-05 JobRegistry; used by AND-04..AND-07 job
 * services). Progress is rate-limited by the [EventHub].
 */
interface JobControl {
    /** The job id Dart received from `startJob`. */
    val jobId: String

    /** Whether the job was cancelled (cancel, pre-emption by export is not a cancel). */
    val isCancelled: Boolean

    /** Reports progress 0..1. */
    fun reportProgress(fraction: Double)

    /** Throws `cancelled` when [isCancelled]. Long loops call it between steps. */
    fun throwIfCancelled() {
        if (isCancelled) throw EngineException(EngineErrorCode.cancelled, "cancelled")
    }
}

/**
 * The activity of the attached Flutter engine, plus activity-result and permission-result routing
 * for pickers, SAF, share and runtime permissions (AND-12..AND-15). The plugin forwards Flutter's
 * callbacks here; services start requests through [startActivityForResult] and
 * [requestPermissions]. Main thread only.
 */
class ActivityHost {
    private var binding: ActivityPluginBinding? = null
    private val nextCode = AtomicInteger(REQUEST_CODE_BASE)
    private val resultCallbacks = HashMap<Int, (Int, Intent?) -> Unit>()
    private val permissionCallbacks = HashMap<Int, (Array<out String>, IntArray) -> Unit>()

    /** The current activity, or null (no UI attached). */
    val activity: Activity? get() = binding?.activity

    /** Flutter's activity-result listener; registered by the plugin. */
    val resultListener = PluginRegistry.ActivityResultListener { requestCode, resultCode, data ->
        val callback = resultCallbacks.remove(requestCode) ?: return@ActivityResultListener false
        callback(resultCode, data)
        true
    }

    /** Flutter's permission-result listener; registered by the plugin. */
    val permissionListener = PluginRegistry.RequestPermissionsResultListener { requestCode, permissions, grantResults ->
        val callback = permissionCallbacks.remove(requestCode) ?: return@RequestPermissionsResultListener false
        callback(permissions, grantResults)
        true
    }

    /** Called by the plugin when an activity attaches. */
    fun attach(binding: ActivityPluginBinding) {
        this.binding = binding
    }

    /**
     * Called by the plugin when the activity detaches. With [cancelPending] (the activity is gone
     * for good) pending requests complete as cancelled; for a configuration change they stay, and
     * the recreated activity delivers their results.
     */
    fun detach(cancelPending: Boolean = true) {
        binding = null
        if (!cancelPending) return
        val results = resultCallbacks.values.toList().also { resultCallbacks.clear() }
        val permissions = permissionCallbacks.values.toList().also { permissionCallbacks.clear() }
        results.forEach { it(Activity.RESULT_CANCELED, null) }
        permissions.forEach { it(emptyArray(), IntArray(0)) }
    }

    /**
     * Starts [intent] for a result. Returns false (and never calls [onResult]) when no activity is
     * attached. A detached activity completes the request with RESULT_CANCELED.
     */
    fun startActivityForResult(intent: Intent, onResult: (resultCode: Int, data: Intent?) -> Unit): Boolean {
        val activity = activity ?: return false
        val code = nextCode()
        resultCallbacks[code] = onResult
        return try {
            activity.startActivityForResult(intent, code)
            true
        } catch (e: RuntimeException) {
            resultCallbacks.remove(code)
            Log.w(TAG, "startActivityForResult failed: ${e.javaClass.simpleName}")
            false
        }
    }

    /** Requests runtime [permissions]. Returns false when no activity is attached. */
    fun requestPermissions(permissions: Array<String>, onResult: (Array<out String>, IntArray) -> Unit): Boolean {
        val activity = activity ?: return false
        val code = nextCode()
        permissionCallbacks[code] = onResult
        activity.requestPermissions(permissions, code)
        return true
    }

    private fun nextCode(): Int {
        val code = nextCode.getAndIncrement()
        if (code > REQUEST_CODE_BASE + 0x0FFF) nextCode.set(REQUEST_CODE_BASE)
        return code
    }

    companion object {
        /** Request codes 0x5650..0x664F (16 bits, as FragmentActivity requires). */
        const val REQUEST_CODE_BASE = 0x5650
    }
}

/**
 * The process-scoped engine context (ARCH §4.4). Obtain with [obtain]; tests construct it directly
 * with fake threads.
 */
class EngineContext(
    /** The application Context (never an Activity). */
    val appContext: Context,
    /** Main thread and engine lanes. */
    val threads: EngineThreads,
    /** The multiplexed event stream. */
    val events: EventHub = EventHub(threads.main),
) {
    /** The current activity and result routing. */
    val activityHost = ActivityHost()

    @Volatile private var paths: Paths? = null

    /** The roots from `initialize`, or null before it. */
    val pathsOrNull: Paths? get() = paths

    /** The roots from `initialize`; throws `internal` before it. */
    fun requirePaths(): Paths = paths ?: throw EngineErrors.notInitialized()

    /**
     * Installs the Dart roots (`EngineHostApi.initialize`; idempotent, a hot restart calls it again)
     * and creates them. Notifies [DiskCache.onRootsReady] when the roots changed. Call on danaview-io.
     */
    fun installRoots(newPaths: Paths) {
        if (!newPaths.ensureRoots()) throw EngineException(EngineErrorCode.io, "cannot create the engine roots")
        val changed = synchronized(this) {
            val old = paths
            paths = newPaths
            old != newPaths
        }
        if (changed) diskCache.onRootsReady()
    }

    /** `FileProvider` authority of the engine (ARCH §14.3, manifest). */
    val fileProviderAuthority: String get() = appContext.packageName + FILE_PROVIDER_SUFFIX

    // ---- service singletons (ARCH §4.4; D-33 placeholders until their tickets land) ----

    /** AND-02. */
    val capabilities: Capabilities by lazy { Capabilities(this) }

    /** AND-02. */
    val deviceProfile: DeviceProfile by lazy { DeviceProfile(this) }

    /** AND-02. */
    val probe: Probe by lazy { Probe(this) }

    /** AND-02. */
    val compatibility: Compatibility by lazy { Compatibility(this) }

    /** AND-03. */
    val thumbnails: ThumbnailService by lazy { ThumbnailService(this) }

    /** AND-03. */
    val diskCache: DiskCache by lazy { DiskCache(this) }

    /** AND-04. */
    val waveforms: WaveformService by lazy { WaveformService(this) }

    /** AND-04. */
    val speechAudio: SpeechAudioExtractor by lazy { SpeechAudioExtractor(this) }

    /** AND-05. */
    val jobs: JobRegistry by lazy { JobRegistry(this) }

    /** AND-05. */
    val proxyJob: ProxyJob by lazy { ProxyJob(this) }

    /** AND-05. */
    val proxies: ProxyRegistry by lazy { ProxyRegistry(this) }

    /** AND-06. */
    val freezeFrames: FreezeFrameJob by lazy { FreezeFrameJob(this) }

    /** AND-06. */
    val sourceFrames: SourceFrameCache by lazy { SourceFrameCache(this) }

    /** AND-07. */
    val reverse: ReverseJob by lazy { ReverseJob(this) }

    /** AND-10 (backed by AND-16 on the AND-01 no-go). */
    val previews: PreviewSessionManager by lazy { PreviewSessionManager(this) }

    /** AND-11. */
    val exports: ExportCoordinator by lazy { ExportCoordinator(this) }

    /** AND-12. */
    val backgroundGuard: BackgroundGuard by lazy { BackgroundGuard(this) }

    /** AND-12. */
    val mediaStore: MediaStoreSaver by lazy { MediaStoreSaver(this) }

    /** AND-12. */
    val fileHandoff: FileHandoff by lazy { FileHandoff(this) }

    /** AND-13. */
    val recorder: VoiceRecorder by lazy { VoiceRecorder(this) }

    /** AND-14. */
    val picker: MediaPicker by lazy { MediaPicker(this) }

    /** AND-14. */
    val mediaAccess: MediaAccess by lazy { MediaAccess(this) }

    /** AND-14. */
    val permissions: Permissions by lazy { Permissions(this) }

    /** AND-15. */
    val dropTarget: DropTarget by lazy { DropTarget(this) }

    companion object {
        /** Log tag of the engine. Logs never contain paths, URIs or user content. */
        const val TAG = "DanaviewEngine"

        /** Appended to the package name for the FileProvider authority. */
        const val FILE_PROVIDER_SUFFIX = ".danaview.editor.files"

        @Volatile private var instance: EngineContext? = null

        /** The process-wide context, created on first use. */
        fun obtain(context: Context): EngineContext =
            instance ?: synchronized(this) {
                instance ?: EngineContext(context.applicationContext, EngineThreads.android()).also { instance = it }
            }

        /** The process-wide context if one was created (ExportService after process restart, AND-12). */
        fun peek(): EngineContext? = instance
    }
}

private const val TAG = EngineContext.TAG
