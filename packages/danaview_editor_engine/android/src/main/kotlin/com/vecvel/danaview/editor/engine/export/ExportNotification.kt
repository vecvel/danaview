// OWNER: AND-12
//
// Notifications of the export foreground service (ARCH §14.3, D-22, D-39; BUILD_PLAN AND-12).
// - Channels (API 26+): `danaview_editor_export` (low importance, silent) for the ongoing progress
//   notification of ExportService, `danaview_editor_export_done` (default importance) for "Saved to
//   Gallery" / "Export finished" after a detached completion.
// - The ongoing notification: the job's title (from Dart; user content, shown but never logged),
//   determinate progress 0..100 and a Cancel action. Cancel is a PendingIntent to ExportService
//   (ACTION_CANCEL + job id), so it works with the activity destroyed or the app swiped away. With
//   only background-work leases it shows the lease title and progress, without Cancel (the
//   captions flow cancels in the app). Tapping it opens the app (launch intent), when the host has
//   a launcher activity.
// - Updates are limited to <= 1 Hz by [NotificationThrottle] (trailing update kept).
// - POST_NOTIFICATIONS is requested in context by Dart (AND-14 Permissions). Without it nothing is
//   shown, but the service still runs in the foreground and the export still completes (the
//   system lists the app in the foreground-services task manager).
// Strings come from Dart (INT-07): ExportNotificationTexts.current holds the localized texts that
// `initialize` and `start` carried, with the English defaults (the constants below) until then.

package com.vecvel.danaview.editor.engine.export

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.vecvel.danaview.editor.engine.R
import com.vecvel.danaview.editor.engine.core.Cancellable
import kotlin.math.roundToInt

/** What the ongoing notification shows. */
data class ForegroundContent(
    /** Title (user content from Dart: never log it). Blank → a default title. */
    val title: String,
    /** Progress 0..1, or null for indeterminate. */
    val fraction: Double?,
    /** The job the Cancel action cancels; null → no Cancel action (leases only). */
    val cancelJobId: String?,
    /** Further jobs or leases not shown. */
    val more: Int = 0,
    /** True when the primary item is an export (else a background-work lease). */
    val isExport: Boolean = true,
) {
    /** Whole percent shown (0..100), or null. */
    val percent: Int? get() = fraction?.let { (it.coerceIn(0.0, 1.0) * 100).roundToInt() }
}

/** Builds and posts the export notifications (file header). */
class ExportNotification(private val context: Context) {
    private val manager = NotificationManagerCompat.from(context)

    /** Creates the channels (idempotent; no-op before API 26). */
    fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val texts = ExportNotificationTexts.current
        val system = context.getSystemService(NotificationManager::class.java) ?: return
        system.createNotificationChannel(
            NotificationChannel(CHANNEL_PROGRESS, texts.progressChannelName, NotificationManager.IMPORTANCE_LOW).apply {
                description = texts.progressChannelDescription
                setShowBadge(false)
            },
        )
        system.createNotificationChannel(
            NotificationChannel(CHANNEL_DONE, texts.doneChannelName, NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = texts.doneChannelDescription
            },
        )
    }

    /** The ongoing foreground notification for [content]. */
    fun foreground(content: ForegroundContent): Notification {
        ensureChannels()
        val texts = ExportNotificationTexts.current
        val title = content.title.trim().ifEmpty { if (content.isExport) texts.exportTitle else texts.workTitle }
        val percent = content.percent
        val text = contentText(texts, content.isExport, percent)
        val b = NotificationCompat.Builder(context, CHANNEL_PROGRESS)
            .setSmallIcon(R.drawable.danaview_export_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setProgress(100, percent ?: 0, percent == null)
        if (content.more > 0) b.setSubText(ExportNotificationTexts.withCount(texts.more, content.more))
        openAppIntent()?.let { b.setContentIntent(it) }
        content.cancelJobId?.let { jobId ->
            b.addAction(NotificationCompat.Action.Builder(R.drawable.danaview_export_notification, texts.cancel, cancelIntent(jobId)).build())
        }
        return b.build()
    }

    /** Re-posts the ongoing notification (the service is already in the foreground with [FOREGROUND_ID]). */
    fun update(content: ForegroundContent) {
        notify(FOREGROUND_ID, foreground(content))
    }

    /**
     * Posts the notification of a detached completion (D-39): "Saved to Gallery" when
     * [savedToGallery], else "Export finished"; tapping it opens the app. Returns false when
     * notifications are disabled or not permitted (the record in ActiveExportStore is the source
     * of truth either way).
     */
    fun postCompleted(jobId: String, title: String, savedToGallery: Boolean): Boolean {
        ensureChannels()
        val texts = ExportNotificationTexts.current
        val b = NotificationCompat.Builder(context, CHANNEL_DONE)
            .setSmallIcon(R.drawable.danaview_export_notification)
            .setContentTitle(if (savedToGallery) texts.savedToGallery else texts.exportFinished)
            .setContentText(title.trim().ifEmpty { texts.exportTitle })
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
        openAppIntent()?.let { b.setContentIntent(it) }
        return notify(completionId(jobId), b.build())
    }

    /** Removes the completion notification of [jobId]. */
    fun cancelCompleted(jobId: String) = manager.cancel(completionId(jobId))

    /** Removes the ongoing notification (after the service left the foreground). */
    fun cancelForeground() = manager.cancel(FOREGROUND_ID)

    private fun notify(id: Int, notification: Notification): Boolean {
        if (!manager.areNotificationsEnabled()) return false
        return try {
            manager.notify(id, notification)
            true
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted (API 33+): nothing is shown, the work still runs.
            false
        }
    }

    /** Cancel action: ExportService ACTION_CANCEL for [jobId] (works without an activity). */
    fun cancelIntent(jobId: String): PendingIntent {
        val intent = Intent(context, ExportService::class.java)
            .setAction(ExportService.ACTION_CANCEL)
            .putExtra(ExportCoordinator.EXTRA_JOB_ID, jobId)
        return PendingIntent.getService(context, requestCodeOf(jobId), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Opens the host app (its launch activity), or null when it has none (e.g. a test APK). */
    private fun openAppIntent(): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return PendingIntent.getActivity(context, OPEN_APP_REQUEST, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    companion object {
        const val CHANNEL_PROGRESS = "danaview_editor_export"
        const val CHANNEL_DONE = "danaview_editor_export_done"

        /** Id of the ongoing foreground notification. */
        const val FOREGROUND_ID = 0x0D45_0001

        /** At most one progress update per second (ARCH §14.3). */
        const val MIN_UPDATE_INTERVAL_MS = 1_000L

        const val CANCEL_LABEL = "Cancel"
        const val SAVED_TITLE = "Saved to Gallery"
        const val FINISHED_TITLE = "Export finished"
        const val DEFAULT_EXPORT_TITLE = "Exporting video"
        const val DEFAULT_WORK_TITLE = "Working in the background"

        private const val OPEN_APP_REQUEST = 0x0D45

        /** The ongoing notification's text: "Exporting" / "Working", with the percent when known (INT-07 texts). */
        fun contentText(texts: com.vecvel.danaview.editor.engine.pigeon.ExportNotificationTextsMsg, isExport: Boolean, percent: Int?): String =
            when {
                percent == null -> if (isExport) texts.exporting else texts.working
                isExport -> ExportNotificationTexts.withPercent(texts.exportingProgress, percent)
                else -> ExportNotificationTexts.withPercent(texts.workingProgress, percent)
            }

        /** Notification id of [jobId]'s completion notification. */
        fun completionId(jobId: String): Int = 0x0D46_0000 + (jobId.hashCode() and 0xFFFF)

        private fun requestCodeOf(jobId: String): Int = 0x0D47_0000 + (jobId.hashCode() and 0xFFFF)
    }
}

/**
 * Limits updates to one per [intervalMs] with a trailing update: [submit] runs [action] at once
 * when the last run is at least [intervalMs] ago, otherwise it replaces the pending action, which
 * runs [intervalMs] after the last run. [flush] runs the pending action now; [clear] drops it.
 * Single-threaded (the service uses the main thread).
 */
class NotificationThrottle(
    private val intervalMs: Long,
    private val nowMs: () -> Long,
    private val schedule: (Runnable, Long) -> Cancellable,
) {
    /** When the last action ran ([nowMs] clock; Long.MIN_VALUE before the first). */
    var lastRunMs: Long = Long.MIN_VALUE
        private set
    private var pending: (() -> Unit)? = null
    private var timer: Cancellable? = null

    /** Number of actions run (tests). */
    var runs: Int = 0
        private set

    fun submit(action: () -> Unit) {
        val now = nowMs()
        if (pending == null && (lastRunMs == Long.MIN_VALUE || now - lastRunMs >= intervalMs)) {
            run(action, now)
            return
        }
        pending = action
        if (timer == null) {
            val delay = (lastRunMs + intervalMs - now).coerceAtLeast(0L)
            timer = schedule(Runnable { flush() }, delay)
        }
    }

    /** Counts a post made outside the throttle (the startForeground notification) as the last run. */
    fun noteExternalRun(): Long {
        lastRunMs = nowMs()
        return lastRunMs
    }

    /** Runs the pending action now (if any). */
    fun flush() {
        timer?.cancel()
        timer = null
        val action = pending ?: return
        pending = null
        run(action, nowMs())
    }

    /** Drops the pending action. */
    fun clear() {
        timer?.cancel()
        timer = null
        pending = null
    }

    private fun run(action: () -> Unit, now: Long) {
        lastRunMs = now
        runs++
        action()
    }
}
