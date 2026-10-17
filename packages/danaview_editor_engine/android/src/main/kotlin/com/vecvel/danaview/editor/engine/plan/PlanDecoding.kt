// OWNER: AND-08
//
// Engine-facing entry points of the plan reader (ARCH §11.2, §11.3, §12.5): decode the Pigeon
// payload bytes and turn every format error or invariant violation into `planInvalid`
// (EngineException; message = the JSON path or violation code plus the layer id, never content).
// Patches additionally check their base revision (`planOutOfSync`). Callers run on danaview-preview /
// danaview-export.

package com.vecvel.danaview.editor.engine.plan

import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException

/** Result of applying a patch: the new plan and how to apply it. */
data class PatchResult(val plan: RenderPlan, val patchClass: PatchClass)

/** Decoding with engine errors (file header). */
object PlanDecoding {
    /** Decodes and validates a full plan. */
    fun plan(bytes: ByteArray): RenderPlan {
        val plan = guard { PlanReader.readPlan(bytes) }
        validate(plan)
        return plan
    }

    /** Decodes a transient (param fields only; no validation beyond the format). */
    fun transient(bytes: ByteArray): PlanTransient = guard { PlanReader.readTransient(bytes) }

    /**
     * Decodes [bytes] as a patch of [current], applies and validates it, and classifies it
     * (ARCH §11.2). `planOutOfSync` when `from` is not `current.rev`.
     */
    fun applyPatch(current: RenderPlan, bytes: ByteArray): PatchResult {
        val patch = guard { PlanReader.readPatch(bytes) }
        val next = try {
            PlanPatches.apply(current, patch)
        } catch (e: PlanOutOfSyncException) {
            throw EngineException(EngineErrorCode.planOutOfSync, "patch from ${e.patchFrom} does not match rev ${e.planRev}")
        }
        validate(next)
        return PatchResult(next, PlanPatches.classify(current, patch))
    }

    /** Throws `planInvalid` for the first violation of [plan]. */
    fun validate(plan: RenderPlan) {
        val v = PlanValidator.validate(plan).firstOrNull() ?: return
        throw EngineException(EngineErrorCode.planInvalid, "plan violates ${v.code.name}", itemId = v.id)
    }

    private inline fun <T> guard(block: () -> T): T = try {
        block()
    } catch (e: PlanFormatException) {
        throw EngineException(EngineErrorCode.planInvalid, "malformed plan at ${e.path.ifEmpty { "<document>" }}", cause = e)
    }
}
