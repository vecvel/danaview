// OWNER: HOM-22A
//
// The three Flutter-free flows of getting files out on Android (ARCH v1.2 §8, rule 26, V2-117,
// V2-118; BUILD_PLAN HOM-22A; a5c4c4d answers 9-11) over AndroidFileOut. The host APIs
// (exportout/, share/, openin/) are thin wrappers; the instrumented tests drive these flows with
// their own Activity relay. No storage permission is used anywhere.
//
// * SaveOutFlow
//   - downloads: API 29+ new MediaStore.Downloads items in `Download/<subdirectory>/`; API 24-28
//     the system "save as" (answer 9).
//   - photos: API 29+ new MediaStore Images / Video items (`Pictures/Danaview/`,
//     `Movies/Danaview/`), add-only; API 24-28 the system "save as". Items that aren't photos or
//     videos count as failed, as on Apple.
//   - files: the system "save as": ACTION_CREATE_DOCUMENT for one file, ACTION_OPEN_DOCUMENT_TREE
//     once for several, each created new inside the chosen folder (answer 10). Closing the dialog
//     answers cancelled; a document whose copy failed is deleted again.
// * ShareFlow: TempCopyStore batch -> ACTION_SEND(_MULTIPLE) in the system chooser, read grants
//   only. The chooser reports the chosen target through an IntentSender broadcast (completed =
//   a target was chosen, activityType = its package); the reply comes when the chooser closes.
// * OpenInFlow: a one-copy batch -> ACTION_VIEW with a read grant; true when an app or the system
//   resolver opened, false (batch removed) when no installed app takes the type.
//
// Batches stay after the reply (no reliable "receiver finished" signal on Android, answer 11);
// TempCopyStore sweeps them after a day. One operation per flow at a time (`busy`). Work runs on
// [worker]; [post] delivers every reply on the main thread. Nothing is logged (rule 30).

package com.vecvel.danaview.library.exportout

import android.app.Activity
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import androidx.core.content.ContextCompat
import com.vecvel.danaview.library.pigeon.SaveOutDestinationMsg
import com.vecvel.danaview.library.pigeon.SaveOutResultMsg
import java.util.UUID
import java.util.concurrent.Executor

/** Starts an Intent for a result on the current Activity; false when there is none (or one runs). */
fun interface OutLauncher {
    fun start(intent: Intent, done: (resultCode: Int, data: Intent?) -> Unit): Boolean
}

/** Shared plumbing of the flows. */
abstract class OutFlow(protected val out: AndroidFileOut, protected val worker: Executor, protected val post: (() -> Unit) -> Unit) {
    protected var running = false // main thread

    protected fun <T> finish(callback: (Result<T>) -> Unit, result: Result<T>) {
        running = false
        callback(result)
    }

    /** Runs [work] on the worker and answers on the main thread. */
    protected fun <T> background(callback: (Result<T>) -> Unit, work: () -> T) {
        try {
            worker.execute {
                val r = runCatching(work)
                post { finish(callback, r) }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            finish(callback, Result.failure(OutFailure.io("plugin detached")))
        }
    }
}

class SaveOutFlow(out: AndroidFileOut, worker: Executor, post: (() -> Unit) -> Unit) : OutFlow(out, worker, post) {
    /** Saves copies of [files] to [destination]; failures are OutFailure. Main thread. */
    fun save(files: List<OutFile>, destination: SaveOutDestinationMsg, subdirectory: String?, launcher: OutLauncher, callback: (Result<SaveOutResultMsg>) -> Unit) {
        if (running) return callback(Result.failure(OutFailure.busy("a save is running")))
        try {
            FileOut.validate(files)
        } catch (f: OutFailure) {
            return callback(Result.failure(f))
        }
        running = true
        val mediaStore = Build.VERSION.SDK_INT >= 29
        when (destination) {
            SaveOutDestinationMsg.DOWNLOADS ->
                if (mediaStore) background(callback) { saveAll(files, false, subdirectory ?: "Danaview", 0) } else saveAs(files, 0, launcher, callback)
            SaveOutDestinationMsg.PHOTOS -> {
                val media = files.filter { FileOut.mediaKind(it) != OutMediaKind.OTHER }
                val rejected = files.size - media.size
                when {
                    media.isEmpty() -> finish(callback, Result.success(SaveOutResultMsg(false, emptyList(), rejected.toLong())))
                    mediaStore -> background(callback) { saveAll(media, true, null, rejected) }
                    else -> saveAs(media, rejected, launcher, callback)
                }
            }
            SaveOutDestinationMsg.FILES -> saveAs(files, 0, launcher, callback)
        }
    }

    private fun saveAll(files: List<OutFile>, photos: Boolean, subdirectory: String?, rejected: Int): SaveOutResultMsg {
        val saved = ArrayList<String>()
        var failed = rejected.toLong()
        for (f in files) {
            try {
                if (Build.VERSION.SDK_INT >= 29) saved += out.saveToMediaStore(f, photos, subdirectory).toString() else failed++
            } catch (t: Throwable) {
                failed++
            }
        }
        return SaveOutResultMsg(false, saved, failed)
    }

    private fun saveAs(files: List<OutFile>, rejected: Int, launcher: OutLauncher, callback: (Result<SaveOutResultMsg>) -> Unit) {
        val single = files.size == 1
        val intent = if (single) out.createDocumentIntent(files[0]) else out.openTreeIntent()
        val started = try {
            launcher.start(intent) { code, data ->
                val uri = data?.data
                if (code != Activity.RESULT_OK || uri == null) {
                    finish(callback, Result.success(SaveOutResultMsg(true, emptyList(), rejected.toLong())))
                } else {
                    background(callback) {
                        if (single) {
                            try {
                                out.writeDocument(uri, files[0])
                                SaveOutResultMsg(false, listOf(uri.toString()), rejected.toLong())
                            } catch (t: Throwable) {
                                out.deleteDocument(uri)
                                SaveOutResultMsg(false, emptyList(), rejected + 1L)
                            }
                        } else {
                            val (saved, failed) = out.saveIntoTree(uri, files)
                            SaveOutResultMsg(false, saved, (failed + rejected).toLong())
                        }
                    }
                }
            }
        } catch (e: RuntimeException) {
            false // no app answers the save dialog
        }
        if (!started) finish(callback, Result.failure(OutFailure.busy("no Activity for the save dialog")))
    }
}

/** What the share sheet did. */
data class ShareOutcome(val completed: Boolean, val activityType: String?)

class ShareFlow(private val context: Context, out: AndroidFileOut, worker: Executor, post: (() -> Unit) -> Unit) : OutFlow(out, worker, post) {
    /** Grace after the chooser closes for its "chosen target" broadcast to arrive. */
    var chosenGraceMs = 600L

    /** Shows the system share sheet for copies of [files]. Main thread. */
    fun share(files: List<OutFile>, subject: String?, launcher: OutLauncher, delay: (Long, () -> Unit) -> Unit, callback: (Result<ShareOutcome>) -> Unit) {
        if (running) return callback(Result.failure(OutFailure.busy("a share sheet is open")))
        running = true
        try {
            worker.execute {
                val batch = runCatching { out.store.makeBatch(files) }
                post {
                    batch.fold({ present(it, files, subject, launcher, delay, callback) }, { finish(callback, Result.failure(it)) })
                }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            finish(callback, Result.failure(OutFailure.io("plugin detached")))
        }
    }

    private fun present(batch: TempBatch, files: List<OutFile>, subject: String?, launcher: OutLauncher, delay: (Long, () -> Unit) -> Unit, callback: (Result<ShareOutcome>) -> Unit) {
        val send = out.shareIntent(batch, files.map { FileOut.mimeType(it.mimeType, it.displayName) }, subject)
        val action = "${context.packageName}.danaview.library.SHARE_CHOSEN.${UUID.randomUUID()}"
        var chosen: String? = null
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                @Suppress("DEPRECATION")
                val component: ComponentName? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_CHOSEN_COMPONENT, ComponentName::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_CHOSEN_COMPONENT)
                }
                chosen = component?.packageName ?: chosen ?: ""
            }
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
        val pending = PendingIntent.getBroadcast(context, 0, Intent(action).setPackage(context.packageName), flags)
        val chooser = Intent.createChooser(send, null, pending.intentSender).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        var closed = false
        fun close() {
            if (closed) return
            closed = true
            runCatching { context.unregisterReceiver(receiver) }
            pending.cancel()
            finish(callback, Result.success(ShareOutcome(chosen != null, chosen?.ifEmpty { null })))
        }
        val started = try {
            launcher.start(chooser) { _, _ -> delay(chosenGraceMs) { close() } }
        } catch (e: RuntimeException) {
            false
        }
        if (!started) {
            runCatching { context.unregisterReceiver(receiver) }
            pending.cancel()
            out.store.remove(batch)
            finish(callback, Result.failure(OutFailure.busy("no Activity for the share sheet")))
        }
    }
}

class OpenInFlow(out: AndroidFileOut, worker: Executor, post: (() -> Unit) -> Unit) : OutFlow(out, worker, post) {
    /** Opens a copy of [file] in another app; true when one (or the system resolver) opened. Main thread. */
    fun openIn(file: OutFile, activity: () -> Activity?, callback: (Result<Boolean>) -> Unit) {
        if (running) return callback(Result.failure(OutFailure.busy("open in is running")))
        running = true
        try {
            worker.execute {
                val batch = runCatching { out.store.makeBatch(listOf(file)) }
                post {
                    batch.fold({ b ->
                        val act = activity()
                        if (act == null) {
                            out.store.remove(b)
                            finish(callback, Result.failure(OutFailure.busy("no Activity")))
                        } else {
                            val opened = try {
                                act.startActivity(out.viewIntent(b, FileOut.mimeType(file.mimeType, file.displayName)))
                                true
                            } catch (e: ActivityNotFoundException) {
                                false
                            }
                            if (!opened) out.store.remove(b)
                            finish(callback, Result.success(opened))
                        }
                    }, { finish(callback, Result.failure(it)) })
                }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            finish(callback, Result.failure(OutFailure.io("plugin detached")))
        }
    }
}
