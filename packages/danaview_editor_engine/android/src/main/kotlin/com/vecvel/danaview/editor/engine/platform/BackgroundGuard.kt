// OWNER: AND-12
//
// Background-work leases (ARCH §12.4 BackgroundWorkGuard, §14.3, §15; D-22, D-28; BUILD_PLAN AND-12).
// Android keeps long work (auto captions) running under the export foreground service: a lease is
// one entry the service shows in its notification (title + progress) while it stays in the
// foreground. Lifecycle:
// - acquire(title): registers the context with ExportService and starts it (ACTION_WORK). Completes
//   with the lease id, or with null when the service cannot be started (the app is in the
//   background on API 26+, where a plain start is refused): the API allows null, the caller then
//   runs without a lease.
// - update(id, progress 0..1): updates the notification (<= 1 Hz through the service throttle). An
//   unknown, released or expired lease is ignored (the caller may race an expiry).
// - release(id): idempotent; the service stops when no job and no lease is left.
// - expiry: when the service hits the API 35 foreground time limit (onTimeout) every lease expires:
//   EventHub.leaseExpiring(id) is emitted and the lease is dropped (iOS: the background task's
//   expiration handler, same event).
// Main thread only (the glue calls acquire/update/release on main). Titles are user content and are
// never logged.

package com.vecvel.danaview.editor.engine.platform

import android.content.Intent
import android.util.Log
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.export.ExportService
import java.util.UUID

/** Background work leases for captions and jobs (ARCH §12.4, §15; AND-12). Called on main. */
class BackgroundGuard(private val ctx: EngineContext) {
    /** One lease as the service shows it. */
    data class Lease(val id: String, val title: String, val progress: Double)

    private val leases = LinkedHashMap<String, Lease>()

    /** Starts the service (tests replace it); false when the platform refuses the start. */
    internal var startService: (Intent) -> Boolean = { intent ->
        try {
            ctx.appContext.startService(intent) != null
        } catch (e: IllegalStateException) {
            // Background start not allowed (API 26+).
            false
        } catch (e: SecurityException) {
            false
        }
    }

    /** Acquires a lease titled [title]; completes with its id, or null when none is available. */
    fun acquire(title: String, done: Completion<String?>) {
        val id = "bg_" + UUID.randomUUID().toString().replace("-", "").take(16)
        leases[id] = Lease(id, title, 0.0)
        ExportService.register(ctx)
        if (!startService(Intent(ctx.appContext, ExportService::class.java).setAction(ExportService.ACTION_WORK))) {
            leases.remove(id)
            Log.w(TAG, "background lease refused: the service cannot start now")
            return done.succeed(null)
        }
        Log.i(TAG, "background lease $id acquired (${leases.size} held)")
        done.succeed(id)
    }

    /** Updates the lease's progress 0..1 (ignored for an unknown lease). */
    fun update(leaseId: String, progress: Double, done: Completion<Unit>) {
        val lease = leases[leaseId]
        if (lease != null) {
            leases[leaseId] = lease.copy(progress = progress.coerceIn(0.0, 1.0))
            ExportService.requestRefresh()
        }
        done.succeed(Unit)
    }

    /** Releases the lease (idempotent). */
    fun release(leaseId: String, done: Completion<Unit>) {
        if (leases.remove(leaseId) != null) {
            Log.i(TAG, "background lease $leaseId released (${leases.size} held)")
            ExportService.requestRefresh()
        }
        done.succeed(Unit)
    }

    /** Leases held now, oldest first (main thread). */
    fun activeLeases(): List<Lease> = leases.values.toList()

    /** Expires every lease (ExportService onTimeout): emits leaseExpiring for each and drops it. */
    internal fun expireAll() {
        val expired = leases.keys.toList()
        leases.clear()
        for (id in expired) {
            Log.w(TAG, "background lease $id expired")
            ctx.events.leaseExpiring(id)
        }
    }

    private companion object {
        const val TAG = EngineContext.TAG
    }
}
