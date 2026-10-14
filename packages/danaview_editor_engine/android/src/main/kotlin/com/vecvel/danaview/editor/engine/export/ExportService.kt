// OWNER: AND-12
//
// The export foreground service (ARCH §14.3, D-22, D-39; BUILD_PLAN AND-12). It keeps the process in
// the foreground while an export runs (AND-11's ExportCoordinator) or a background-work lease is
// held (BackgroundGuard, used by auto captions on Android), with one ongoing notification.
//
// - Start: the coordinator sends ACTION_EXPORT_STARTED (plain startService) when a job starts;
//   BackgroundGuard sends ACTION_WORK when a lease is acquired. onStartCommand calls startForeground
//   with type mediaProcessing on API 35+, dataSync on API 29-34 (none before 29), through the
//   framework call (androidx ServiceCompat 1.13.1 drops the API 35 type). If the system
//   refuses the foreground start (ForegroundServiceStartNotAllowedException), the work still runs as
//   a started service. START_NOT_STICKY: after a process death the job is gone and ActiveExportStore
//   reports it interrupted once (AND-11).
// - The notification (ExportNotification): the first job's title, determinate progress (<= 1 Hz)
//   and Cancel; ACTION_CANCEL cancels the job through the coordinator, with or without an activity.
// - The service stops itself (and removes the notification) when no job and no lease is left.
// - onTaskRemoved (swiped from recents): nothing to do, the service and the export keep running.
// - API 35 onTimeout (the 6 h mediaProcessing / dataSync limit): every running job is interrupted
//   (ExportCoordinator.interrupt → a one-shot `interrupted` record), every lease expires
//   (EventHub.leaseExpiring), and the service stops at once, as the platform requires.
// - Detached completion (D-39): [register] installs [DetachedGalleryHandoff] as the coordinator's
//   detachedHandler. A job that completes with no Dart listener attached (activity destroyed, app
//   swiped away, engine gone) is saved to the gallery natively when its whenDetached is
//   saveToGallery (MediaStoreSaver: Movies/Danaview, IS_PENDING), the completedWhileDetached record
//   is written to ActiveExportStore and the output is exempt from the work/ wipe (it stays for Share /
//   Save to Files until the record is consumed or 7 days pass), and a "Saved to Gallery" notification
//   that opens the app is posted. keepForLater (or a failed gallery insert) keeps the file and posts
//   "Export finished".
// Contexts: the plugin's process-wide EngineContext (EngineContext.peek) is registered when the
// service is created; BackgroundGuard registers its own context, and tests register theirs.
// State is confined to the main thread. Nothing here logs titles, paths or URIs.

package com.vecvel.danaview.editor.engine.export

import android.annotation.SuppressLint
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.annotation.VisibleForTesting
import androidx.core.app.ServiceCompat
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportProgressMsg

/** Export foreground service (file header). */
class ExportService : Service() {
    private lateinit var notifications: ExportNotification
    private lateinit var throttle: NotificationThrottle
    private var lastStartId = 0
    private var refused = false

    /** Whether startForeground succeeded and the service has not left the foreground. */
    @Volatile
    var isForeground: Boolean = false
        private set

    /** Uptime (ms) of each notification post: the startForeground one and every update (tests, <= 1 Hz). */
    private val postTimes = ArrayList<Long>()

    /** [postTimes] snapshot (tests). */
    @VisibleForTesting
    fun notificationPostTimes(): List<Long> = synchronized(postTimes) { postTimes.toList() }

    private fun notePost() = synchronized(postTimes) {
        if (postTimes.size >= 512) postTimes.removeAt(0)
        postTimes += SystemClock.uptimeMillis()
    }

    /** The type passed to the last successful startForeground (0 before API 29). */
    @Volatile
    var requestedForegroundType: Int = 0
        private set

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        notifications = ExportNotification(applicationContext)
        throttle = NotificationThrottle(ExportNotification.MIN_UPDATE_INTERVAL_MS, SystemClock::uptimeMillis) { task, delay ->
            ServiceState.handler.postDelayed(task, delay)
            Cancellable { ServiceState.handler.removeCallbacks(task) }
        }
        instance = this
        EngineContext.peek()?.let(::register)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        refused = false
        when (intent?.action) {
            ACTION_CANCEL -> intent.getStringExtra(ExportCoordinator.EXTRA_JOB_ID)?.let(ServiceState::cancel)
            ExportCoordinator.ACTION_EXPORT_STARTED -> intent.getStringExtra(ExportCoordinator.EXTRA_JOB_ID)?.let(ServiceState::noteStarted)
            else -> Unit
        }
        refresh()
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "export service: task removed; running=${ServiceState.jobIds().size} leases=${ServiceState.leaseCount()}")
        super.onTaskRemoved(rootIntent)
    }

    /** API 35: the foreground time limit of [fgsType] was reached (file header). */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "export service: foreground time limit reached (type $fgsType); interrupting")
        ServiceState.timeout()
        leaveForeground()
        stopSelf()
    }

    override fun onDestroy() {
        if (::throttle.isInitialized) throttle.clear()
        if (isForeground) leaveForeground()
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** Re-evaluates the notification and whether the service still has work (main thread). */
    internal fun refresh() {
        val content = ServiceState.content()
        if (content == null) {
            throttle.clear()
            leaveForeground()
            if (!stopSelfResult(lastStartId)) Log.i(TAG, "export service: a newer start is pending")
            return
        }
        if (!isForeground) {
            if (!refused) enterForeground(content)
            return
        }
        throttle.submit {
            val now = ServiceState.content()
            if (now != null && isForeground) {
                notifications.update(now)
                notePost()
            }
        }
    }

    private fun enterForeground(content: ForegroundContent) {
        val type = foregroundServiceTypeFor(Build.VERSION.SDK_INT)
        try {
            val notification = notifications.foreground(content)
            // Framework call, not ServiceCompat: androidx.core 1.13.1 masks the type with the types it
            // knows (up to API 34), which drops mediaProcessing and makes API 35 refuse the start
            // (InvalidForegroundServiceTypeException, measured on the API 35 emulator).
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(ExportNotification.FOREGROUND_ID, notification, type)
            } else {
                startForeground(ExportNotification.FOREGROUND_ID, notification)
            }
            isForeground = true
            requestedForegroundType = type
            throttle.noteExternalRun()
            notePost()
            Log.i(TAG, "export service: foreground (type $type, API ${Build.VERSION.SDK_INT})")
        } catch (e: RuntimeException) {
            // ForegroundServiceStartNotAllowedException (API 31+) or a SecurityException: the work
            // keeps running as a started service; the next start command tries again.
            refused = true
            Log.w(TAG, "export service: foreground start refused (${e.javaClass.simpleName})")
        }
    }

    private fun leaveForeground() {
        if (!isForeground) return
        isForeground = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    companion object {
        private const val TAG = EngineContext.TAG

        /** Cancel action of the notification (extra EXTRA_JOB_ID). */
        const val ACTION_CANCEL = "com.vecvel.danaview.editor.engine.export.CANCEL"

        /** Sent by BackgroundGuard when a lease is acquired, updated or released. */
        const val ACTION_WORK = "com.vecvel.danaview.editor.engine.export.WORK"

        @Volatile
        private var instance: ExportService? = null

        /** The running service instance, or null (tests). */
        @VisibleForTesting
        fun current(): ExportService? = instance

        /** Foreground service type for API [sdk]: mediaProcessing on 35+, dataSync on 29-34, none before. */
        @SuppressLint("InlinedApi") // constants only; no type is passed before API 29
        fun foregroundServiceTypeFor(sdk: Int): Int = when {
            sdk >= 35 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
            sdk >= 29 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            else -> 0
        }

        /**
         * Lets the service follow [ctx]'s exports and leases: adds the job listener and installs
         * [DetachedGalleryHandoff] as the coordinator's detached handler. Idempotent; any thread.
         */
        fun register(ctx: EngineContext) = ServiceState.register(ctx)

        /** Undoes [register] (tests): removes the listener and restores the default detached handler. */
        fun unregister(ctx: EngineContext) = ServiceState.unregister(ctx)

        /** Job ids the service is showing (tests). */
        @VisibleForTesting
        fun activeJobIds(): List<String> = ServiceState.jobIds()

        /** Asks the running service to re-evaluate (main thread; BackgroundGuard). */
        internal fun requestRefresh() = ServiceState.post { instance?.refresh() }
    }
}

/** Process-wide service state: registered contexts and the jobs being shown. Main thread. */
private object ServiceState {
    val handler = Handler(Looper.getMainLooper())

    private class Hooks(val ctx: EngineContext) : ExportJobListener {
        override fun onJobStarted(job: ExportJobInfo) = post { add(this, job) }

        override fun onJobProgress(jobId: String, progress: ExportProgressMsg) = post {
            jobs[jobId]?.let {
                it.fraction = progress.fraction
                refresh()
            }
        }

        override fun onJobEnded(jobId: String, outcome: ExportOutcome) = post {
            if (jobs.remove(jobId) != null) refresh()
        }
    }

    private class Entry(val hooks: Hooks, val jobId: String, val title: String) {
        var fraction: Double = 0.0
    }

    private val registered = ArrayList<Hooks>()
    private val jobs = LinkedHashMap<String, Entry>()

    fun post(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else handler.post(block)
    }

    fun register(ctx: EngineContext) {
        val hooks = synchronized(registered) {
            if (registered.any { it.ctx === ctx }) return
            Hooks(ctx).also { registered += it }
        }
        val coordinator = ctx.exports
        coordinator.detachedHandler = DetachedGalleryHandoff(ctx)
        coordinator.addJobListener(hooks)
        // Jobs that started before the registration (the service is created after the first start).
        post { coordinator.runningJobs().forEach { if (!jobs.containsKey(it.jobId)) add(hooks, it) } }
    }

    fun unregister(ctx: EngineContext) {
        val hooks = synchronized(registered) {
            val h = registered.firstOrNull { it.ctx === ctx } ?: return
            registered.remove(h)
            h
        }
        ctx.exports.removeJobListener(hooks)
        if (ctx.exports.detachedHandler is DetachedGalleryHandoff) ctx.exports.detachedHandler = DetachedCompletionHandler { it.keepFile() }
        post {
            jobs.values.removeAll { it.hooks === hooks }
            refresh()
        }
    }

    private fun hooks(): List<Hooks> = synchronized(registered) { registered.toList() }

    private fun add(hooks: Hooks, job: ExportJobInfo) {
        jobs[job.jobId] = Entry(hooks, job.jobId, job.title)
        refresh()
    }

    /** ACTION_EXPORT_STARTED: shows [jobId] if a registered coordinator runs it. */
    fun noteStarted(jobId: String) {
        if (jobs.containsKey(jobId)) return
        for (h in hooks()) {
            val job = h.ctx.exports.job(jobId) ?: continue
            jobs[jobId] = Entry(h, jobId, job.title)
            return
        }
    }

    /** Notification Cancel: cancels [jobId] in whichever registered coordinator runs it. */
    fun cancel(jobId: String) {
        Log.i(EngineContext.TAG, "export $jobId: cancel from the notification")
        val owner = jobs[jobId]?.hooks ?: hooks().firstOrNull { it.ctx.exports.job(jobId) != null }
        owner?.ctx?.exports?.cancel(jobId) { }
    }

    /** API 35 onTimeout: interrupt every job and expire every lease. */
    fun timeout() {
        for (h in hooks()) {
            for (job in h.ctx.exports.runningJobs()) h.ctx.exports.interrupt(job.jobId)
            h.ctx.backgroundGuard.expireAll()
        }
        jobs.clear()
    }

    fun jobIds(): List<String> = jobs.keys.toList()

    fun leaseCount(): Int = hooks().sumOf { it.ctx.backgroundGuard.activeLeases().size }

    /** What the notification shows, or null when nothing is running. */
    fun content(): ForegroundContent? {
        val leases = hooks().flatMap { it.ctx.backgroundGuard.activeLeases() }
        val first = jobs.values.firstOrNull()
        if (first != null) return ForegroundContent(first.title, first.fraction, first.jobId, more = jobs.size - 1 + leases.size, isExport = true)
        val lease = leases.firstOrNull() ?: return null
        return ForegroundContent(lease.title, lease.progress, null, more = leases.size - 1, isExport = false)
    }

    private fun refresh() {
        ExportService.current()?.refresh()
    }
}

/**
 * The D-39 handoff of a job that completed with no Dart listener (file header). Runs on
 * danaview-export; blocking MediaStore I/O is fine there (the job is over).
 */
class DetachedGalleryHandoff(private val ctx: EngineContext) : DetachedCompletionHandler {
    override fun onCompletedWhileDetached(completion: DetachedCompletion) {
        val jobId = completion.job.jobId
        var saved: Uri? = null
        if (completion.job.whenDetached == DetachedHandoffMsg.SAVE_TO_GALLERY) {
            saved = try {
                ctx.mediaStore.insert(completion.output)
            } catch (t: Throwable) {
                Log.w(EngineContext.TAG, "export $jobId: gallery insert failed (${t.javaClass.simpleName}); keeping the file")
                null
            }
        }
        if (saved != null) completion.savedToGallery(saved.toString(), keptFile = true) else completion.keepFile()
        val shown = try {
            ExportNotification(ctx.appContext).postCompleted(jobId, completion.job.title, savedToGallery = saved != null)
        } catch (e: RuntimeException) {
            false
        }
        Log.i(EngineContext.TAG, "export $jobId: completed while detached; savedToGallery=${saved != null} notified=$shown")
    }
}
