// OWNER: AND-12
//
// Save to Files and Share (ARCH §12.4, §14.1 step 6, §14.3; BUILD_PLAN AND-12). Main thread; copies
// run on danaview-io.
// - saveToFiles(path, name): SAF ACTION_CREATE_DOCUMENT (CATEGORY_OPENABLE, the file's MIME type,
//   EXTRA_TITLE = name). The user picks the place; the file is copied into the returned document
//   (truncating). Back / cancel → FileHandoffOutcome.cancelled. A failed copy deletes the half-written
//   document. Answers the document URI in savedUri.
// - share(path): ACTION_SEND with EXTRA_STREAM and ClipData of a content:// URI from the engine
//   FileProvider (`<applicationId>.danaview.editor.files`, which serves only
//   `<cache>/danaview/editor/work/`; a file elsewhere in the roots is first staged into
//   work/handoff/<token>/, which the next launch's work wipe removes), FLAG_GRANT_READ_URI_PERMISSION
//   only (never write), wrapped in Intent.createChooser. The grant travels with the intent, so only
//   the target the user chooses (and the system chooser itself, for its preview) can read the file;
//   no grantUriPermission is made to any package. The chooser's IntentSender callback
//   (EXTRA_CHOSEN_COMPONENT, a non-exported dynamic receiver) tells whether a target was chosen:
//   done as soon as one is chosen (the chooser's own result may only come back when the target
//   finishes), cancelled when the chooser closed without one.
// - Without an attached activity both fail with `internal` ("no activity attached"), like the
//   pickers (AND-14).
// Nothing logs paths, URIs or names.

package com.vecvel.danaview.editor.engine.platform

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipDescription
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.content.IntentCompat
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.pigeon.FileHandoffOutcomeMsg
import com.vecvel.danaview.editor.engine.pigeon.FileHandoffResultMsg
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID

/** Save to Files and Share (ARCH §12.4, §14.3; AND-12). Called on main. */
class FileHandoff(private val ctx: EngineContext) {
    /** Activity seam (tests substitute a relay that lets the real system UI answer). */
    internal var requests: ActivityRequests = HostActivityRequests(ctx.activityHost)

    /** How long to wait for the chooser's chosen-target callback after the chooser returns. */
    internal var chosenGraceMs: Long = 1_500L

    /** The package of the last chosen share target (tests; never logged). */
    @Volatile
    internal var lastChosenPackage: String? = null
        private set

    /** The last share intent handed to the chooser (tests). */
    @Volatile
    internal var lastShareIntent: Intent? = null
        private set

    /** Lets the user save a copy of [path] (inside the engine roots) as [suggestedName]. */
    fun saveToFiles(path: String, suggestedName: String, done: Completion<FileHandoffResultMsg>) {
        val file = File(path)
        if (!file.isFile) return done.fail(EngineErrors.from(FileNotFoundException("file missing")))
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mimeTypeOf(file.name))
            .putExtra(Intent.EXTRA_TITLE, suggestedName)
        val started = requests.startForResult(intent) { resultCode, data ->
            val target = data?.data
            if (resultCode != Activity.RESULT_OK || target == null) {
                Log.i(TAG, "save to files: cancelled")
                return@startForResult done.succeed(FileHandoffResultMsg(FileHandoffOutcomeMsg.CANCELLED))
            }
            ctx.threads.io.execute {
                try {
                    copyInto(file, target)
                    Log.i(TAG, "save to files: done (${file.length()} bytes)")
                    done.succeed(FileHandoffResultMsg(FileHandoffOutcomeMsg.DONE, target.toString()))
                } catch (t: Throwable) {
                    deleteQuietly(target)
                    Log.w(TAG, "save to files: copy failed (${t.javaClass.simpleName})")
                    done.fail(EngineErrors.from(t))
                }
            }
        }
        if (!started) done.fail(noActivity())
    }

    /** Opens the share sheet for [path] (inside the engine roots). */
    fun share(path: String, done: Completion<FileHandoffResultMsg>) {
        val file = File(path)
        if (!file.isFile) return done.fail(EngineErrors.from(FileNotFoundException("file missing")))
        providerUri(file)?.let { return startShare(file.name, it, done) }
        // Outside the FileProvider's work/ tree: stage a copy there first.
        ctx.threads.io.execute {
            val staged = try {
                stage(file)
            } catch (t: Throwable) {
                return@execute done.fail(EngineErrors.from(t))
            }
            ctx.threads.main.execute {
                val uri = providerUri(staged) ?: return@execute done.fail(EngineException(EngineErrorCode.internal, "the staged file is not shareable"))
                startShare(staged.name, uri, done)
            }
        }
    }

    private fun startShare(name: String, uri: Uri, done: Completion<FileHandoffResultMsg>) {
        val app = ctx.appContext
        val mime = mimeTypeOf(name)
        val send = Intent(Intent.ACTION_SEND)
            .setType(mime)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData(ClipDescription(name, arrayOf(mime)), ClipData.Item(uri))
        lastShareIntent = send
        lastChosenPackage = null

        val action = ACTION_CHOSEN_PREFIX + UUID.randomUUID().toString().replace("-", "")
        var chosen: ComponentName? = null
        var finished = false
        var finish: () -> Unit = {}
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                chosen = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_CHOSEN_COMPONENT, ComponentName::class.java)
                    ?: ComponentName("", "")
                lastChosenPackage = chosen?.packageName
                finish()
            }
        }
        ContextCompat.registerReceiver(app, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val callback = PendingIntent.getBroadcast(app, SHARE_CALLBACK_REQUEST, Intent(action).setPackage(app.packageName), PendingIntent.FLAG_UPDATE_CURRENT or mutable)
        val chooser = Intent.createChooser(send, null, callback.intentSender)

        finish = finish@{
            if (finished) return@finish
            finished = true
            try {
                app.unregisterReceiver(receiver)
            } catch (e: IllegalArgumentException) {
                // already unregistered
            }
            callback.cancel()
            val outcome = if (chosen != null) FileHandoffOutcomeMsg.DONE else FileHandoffOutcomeMsg.CANCELLED
            Log.i(TAG, "share: ${if (chosen != null) "target chosen" else "cancelled"}")
            done.succeed(FileHandoffResultMsg(outcome))
        }

        val started = requests.startForResult(chooser) { _, _ ->
            if (chosen != null) finish() else ctx.threads.main.postDelayed(Runnable { finish() }, chosenGraceMs)
        }
        if (!started) {
            finished = true
            app.unregisterReceiver(receiver)
            callback.cancel()
            done.fail(noActivity())
        }
    }

    /** The engine FileProvider URI of [file], or null when the provider does not serve it. */
    internal fun providerUri(file: File): Uri? = try {
        FileProvider.getUriForFile(ctx.appContext, ctx.fileProviderAuthority, file)
    } catch (e: IllegalArgumentException) {
        null
    }

    private fun stage(file: File): File {
        val dir = File(ctx.requirePaths().work, "handoff/" + UUID.randomUUID().toString().replace("-", "").take(12))
        if (!dir.mkdirs() && !dir.isDirectory) throw IOException("cannot create the handoff directory")
        val out = File(dir, file.name)
        file.copyTo(out, overwrite = true, bufferSize = BUFFER)
        return out
    }

    private fun copyInto(source: File, target: Uri) {
        val resolver = ctx.appContext.contentResolver
        val stream = try {
            resolver.openOutputStream(target, "wt")
        } catch (e: IllegalArgumentException) {
            null
        } catch (e: FileNotFoundException) {
            null
        } ?: resolver.openOutputStream(target, "w") ?: throw IOException("document not writable")
        stream.use { out -> FileInputStream(source).use { input -> input.copyTo(out, BUFFER) } }
    }

    private fun deleteQuietly(uri: Uri) {
        try {
            DocumentsContract.deleteDocument(ctx.appContext.contentResolver, uri)
        } catch (e: Exception) {
            Log.w(TAG, "save to files: cleanup failed (${e.javaClass.simpleName})")
        }
    }

    private fun noActivity() = EngineException(EngineErrorCode.internal, "no activity attached")

    companion object {
        private const val TAG = EngineContext.TAG
        private const val BUFFER = 1 shl 16
        private const val SHARE_CALLBACK_REQUEST = 0x0D48
        private const val ACTION_CHOSEN_PREFIX = "com.vecvel.danaview.editor.engine.platform.SHARE_CHOSEN."

        /** MIME type of a handed-off file by extension. */
        fun mimeTypeOf(name: String): String = when (val ext = name.substringAfterLast('.', "").lowercase()) {
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "srt" -> "application/x-subrip"
            "vtt" -> "text/vtt"
            else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        }
    }
}
