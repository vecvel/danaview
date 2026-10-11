// OWNER: AND-12
//
// D-33 placeholder created by ENG-08 (BUILD_PLAN ENG-08, ARCH §4.4). It holds only the names the
// glue calls; every call fails with `notSupportedOnDevice` (the Dart side maps that to the editor's
// unsupported state). The owner ticket replaces this file and keeps the signatures the glue uses.
// AND-12: leases hosted by ExportService (foreground service), ctx.events.leaseExpiring. Until
// then no lease is available (acquire completes with null, which the API allows).

package com.vecvel.danaview.editor.engine.platform

import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed

/** Background work leases for captions and jobs (ARCH §12.4, §15; AND-12). Called on main. */
class BackgroundGuard(private val ctx: EngineContext) {
    /** Acquires a lease titled [title]; completes with its id, or null when none is available. */
    fun acquire(title: String, done: Completion<String?>) {
        done.succeed(null)
    }

    /** Updates the lease's progress 0..1. */
    fun update(leaseId: String, progress: Double, done: Completion<Unit>) {
        done.fail(EngineErrors.notSupported("background leases"))
    }

    /** Releases the lease (idempotent). */
    fun release(leaseId: String, done: Completion<Unit>) {
        done.succeed(Unit)
    }
}
