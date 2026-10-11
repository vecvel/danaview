// OWNER: ENG-08
//
// The handler contract of ARCH §12.6: validate on main, work on an engine lane, reply on main
// exactly once, never block, map every error to an EnginePigeonError.

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.LaneSpec
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.core.succeed
import com.vecvel.vwish.editor.engine.pigeon.EnginePigeonError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class GlueDispatcherTest {
    private val fake = FakeThreads()
    private val dispatch = GlueDispatcher(fake.main)
    private val io get() = fake.lane(LaneSpec.IO)

    @Test
    fun workRunsOnTheLaneAndTheReplyOnMain() {
        val reply = Reply<Int>(fake.trace)
        val ranOn = mutableListOf<Where?>()
        fake.main.onMain {
            dispatch.async(io, reply.callback) { done ->
                ranOn.add(fake.trace.current)
                done.succeed(42)
            }
        }
        assertTrue("the handler returns before any work runs", reply.results.isEmpty())
        assertEquals(1, io.pending)
        fake.settle()
        assertEquals(listOf(Where.IO), ranOn)
        assertEquals(42, reply.value())
    }

    @Test
    fun failedValidationRepliesWithoutHopping() {
        val reply = Reply<Int>(fake.trace)
        fake.main.onMain {
            dispatch.async(io, reply.callback, check = { Check.id("sessionId", "") }) { _ -> fail("work must not run") }
        }
        assertEquals(0, io.pending)
        fake.settle()
        assertEquals(0, io.executed)
        assertEquals("internal", reply.error().code)
    }

    @Test
    fun asynchronousCompletionFromAnotherThreadStillRepliesOnMain() {
        val reply = Reply<String>(fake.trace)
        var later: ((Result<String>) -> Unit)? = null
        fake.main.onMain { dispatch.async(io, reply.callback) { done -> later = done } }
        fake.settle()
        assertTrue(reply.results.isEmpty())
        // Completed from a "worker" (no thread tag), e.g. a codec callback.
        later!!(Result.success("job-1"))
        assertTrue("not delivered until main runs", reply.results.isEmpty())
        fake.settle()
        assertEquals("job-1", reply.value())
    }

    @Test
    fun throwsAndFailuresMapToPigeonErrors() {
        val thrown = Reply<Unit>(fake.trace)
        val failed = Reply<Unit>(fake.trace)
        fake.main.onMain {
            dispatch.async(io, thrown.callback) { _ -> throw IllegalStateException("at /data/user/0/x") }
            dispatch.async(io, failed.callback) { done ->
                done.fail(EngineException(EngineErrorCode.planOutOfSync, "rev 3 != 4", retryable = true))
            }
        }
        fake.settle()
        val internal = thrown.assertError("internal")
        assertTrue(!internal.message!!.contains("/data"))
        val sync = failed.assertError("planOutOfSync")
        assertEquals(true, (sync.details as Map<*, *>)["retryable"])
    }

    @Test
    fun aSecondCompletionIsIgnored() {
        val reply = Reply<Int>(fake.trace)
        fake.main.onMain {
            dispatch.async(io, reply.callback) { done ->
                done.succeed(1)
                done.succeed(2)
                done.fail(RuntimeException())
            }
        }
        fake.settle()
        assertEquals(1, reply.value())
    }

    @Test
    fun aQuitLaneRepliesBusy() {
        io.rejecting = true
        val reply = Reply<Int>(fake.trace)
        fake.main.onMain { dispatch.async(io, reply.callback) { done -> done.succeed(1) } }
        fake.settle()
        val error = reply.assertError("busy")
        assertEquals(true, (error.details as Map<*, *>)["retryable"])
    }

    @Test
    fun fireAndForgetThrowsOnBadArgumentsAndSwallowsWorkFailures() {
        try {
            fake.main.onMain { dispatch.fireAndForget(io, "cancelJob", check = { Check.id("jobId", "") }) { fail("must not run") } }
            fail("expected EnginePigeonError")
        } catch (e: EnginePigeonError) {
            assertEquals("internal", e.code)
        }
        var ran = false
        fake.main.onMain {
            dispatch.fireAndForget(io, "cancelJob") {
                ran = true
                throw IllegalStateException("boom")
            }
        }
        fake.settle()
        assertTrue(ran)
    }

    @Test
    fun immediateRepliesAreDeliveredOnMain() {
        val reply = Reply<String>(fake.trace)
        dispatch.reply(reply.callback, Result.failure(EngineException(EngineErrorCode.notSupportedOnDevice, "x")))
        fake.settle()
        reply.assertError("notSupportedOnDevice")
    }
}
