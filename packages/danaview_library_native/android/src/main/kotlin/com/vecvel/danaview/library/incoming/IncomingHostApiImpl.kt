// OWNER: HOM-21A
//
// IncomingHostApi on Android (BUILD_PLAN HOM-21A; ARCH v1.2 §5.6, INT-104): ACTION_VIEW,
// ACTION_SEND and ACTION_SEND_MULTIPLE intents handled in the plugin through ActivityAware and the
// binding's new-intent listener, with no MainActivity edit.
//
// - Cold start: the plugin is attached to the Activity inside FlutterActivity.onCreate, before
//   MainActivity's 1.1 handler reads getIntent(). A claimed intent (IncomingRouting) is marked
//   handled at once (so the 1.1 player path skips it) and processed after onCreate, unless the
//   Activity is being re-created (the saved state carries KEY_HANDLED: the intent was handled
//   before the configuration change or process death) or was relaunched from Recents
//   (FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY). Each intent therefore becomes one batch, once.
// - Warm start (singleTop): the new-intent listener runs inside super.onNewIntent, before
//   MainActivity's handler, with the same claim-and-mark.
// - Video and audio (VIEW, single SEND), and every non-file scheme, are left untouched for the
//   1.1 path: MainActivity copies the item and hands it to incoming_media_bridge (P-7, P-8).
// - A claimed intent is described on one background thread (provider queries never run on the
//   main thread for SEND_MULTIPLE), then queued and announced with an `incoming` library event.
//   It stays pending until takePending returns it or Dart acknowledges it (the event alone does not
//   count: Dart may not be listening), so cold- and warm-start intents both reach Dart once.
// - acknowledge(batchId) releases what the batch held: persistable read grants taken because the
//   sender offered them, and the text file of a text share. Unknown ids are ignored.
//
// Logs carry counts only, never a name, a path or a URI (rule 30).

package com.vecvel.danaview.library.incoming

import android.content.Intent
import android.os.Bundle
import android.util.Log
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.IncomingBatchMsg
import com.vecvel.danaview.library.pigeon.IncomingHostApi
import com.vecvel.danaview.library.pigeon.LibraryEventKindMsg
import com.vecvel.danaview.library.pigeon.LibraryEventMsg
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class IncomingHostApiImpl(private val context: LibraryPluginContext) : IncomingHostApi {
    private val intents = IncomingIntents(context.appContext)
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "danaview-library-incoming") }

    // Main thread only below.
    private val queue = IncomingQueue<IncomingBatchMsg> { it.batchId }
    private val grants = HashMap<String, List<String>>()
    private var binding: ActivityPluginBinding? = null
    private var restoredHandled = false
    private var disposed = false

    private val newIntentListener = PluginRegistry.NewIntentListener { intent -> onIntent(intent, coldStart = false) }

    private val saveStateListener = object : ActivityPluginBinding.OnSaveInstanceStateListener {
        override fun onSaveInstanceState(bundle: Bundle) {
            bundle.putBoolean(KEY_HANDLED, true)
        }

        override fun onRestoreInstanceState(bundle: Bundle?) {
            restoredHandled = bundle?.getBoolean(KEY_HANDLED, false) == true
        }
    }

    init {
        context.addBindingListener(::onBinding)
        worker.execute { intents.sweep(System.currentTimeMillis()) }
    }

    private fun onBinding(newBinding: ActivityPluginBinding?) {
        binding?.let {
            it.removeOnNewIntentListener(newIntentListener)
            it.removeOnSaveStateListener(saveStateListener)
        }
        binding = newBinding
        if (newBinding == null) return
        newBinding.addOnNewIntentListener(newIntentListener)
        newBinding.addOnSaveStateListener(saveStateListener)
        // A re-attach after a configuration change sees the intent already marked handled.
        onIntent(newBinding.activity.intent, coldStart = true)
    }

    /** Claims [intent] when it is ours; true when it was (the 1.1 path then skips it). Main thread. */
    private fun onIntent(intent: Intent?, coldStart: Boolean): Boolean {
        if (intent == null || disposed) return false
        val (snapshot, route) = intents.route(intent)
        if (route === IncomingRoute.Refused) {
            intents.markHandled(intent)
            Log.w(TAG, "incoming: refused a file URI inside the app's private storage")
            return true
        }
        if (route !is IncomingRoute.Incoming) return false
        intents.markHandled(intent)
        if (coldStart) {
            restoredHandled = false
            // Runs after onCreate, so the restored state (if any) has been seen.
            context.main.post {
                if (restoredHandled || snapshot.fromHistory) {
                    Log.i(TAG, "incoming: launch intent already handled; skipped")
                } else {
                    process(route, snapshot.persistableGrant)
                }
            }
        } else {
            process(route, snapshot.persistableGrant)
        }
        return true
    }

    private fun process(route: IncomingRoute.Incoming, persistable: Boolean) {
        if (disposed) return
        worker.execute {
            val kept = ArrayList<String>()
            val batch = try {
                intents.describe(route, persistable, System.currentTimeMillis()) { kept.add(it) }
            } catch (e: RuntimeException) {
                Log.w(TAG, "incoming: describing failed (${e.javaClass.simpleName})")
                null
            }
            context.main.post {
                if (batch == null) {
                    kept.forEach(intents::releaseGrant)
                    Log.i(TAG, "incoming: nothing usable in the intent")
                    return@post
                }
                if (disposed) {
                    release(batch.batchId, kept)
                    return@post
                }
                if (kept.isNotEmpty()) grants[batch.batchId] = kept
                queue.add(batch)
                Log.i(TAG, "incoming: ${route.action.name.lowercase()} batch, ${batch.items.size} item(s), ${route.dropped} dropped")
                context.events.emit(LibraryEventMsg(kind = LibraryEventKindMsg.INCOMING, incoming = batch))
            }
        }
    }

    override fun takePending(): List<IncomingBatchMsg> = queue.takePending()

    override fun acknowledge(batchId: String) {
        if (queue.acknowledge(batchId) == null) return
        release(batchId, grants.remove(batchId).orEmpty())
    }

    private fun release(batchId: String, kept: List<String>) {
        val work = Runnable {
            kept.forEach(intents::releaseGrant)
            intents.deleteBatchFiles(batchId)
        }
        try {
            worker.execute(work)
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            work.run() // after dispose
        }
    }

    /** Detaches from the Activity and stops the worker; outstanding grants are released. Main thread. */
    fun dispose() {
        disposed = true
        onBinding(null)
        val held = grants.toMap()
        grants.clear()
        held.forEach { (id, kept) -> release(id, kept) }
        worker.shutdown()
    }

    /** Test hooks. */
    internal val pendingCount: Int get() = queue.pendingCount

    private companion object {
        const val TAG = "DanaviewIncoming"
        const val KEY_HANDLED = "com.vecvel.danaview.library.incoming.handled"
    }
}
