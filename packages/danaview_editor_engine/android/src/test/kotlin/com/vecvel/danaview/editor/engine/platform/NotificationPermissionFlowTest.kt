// OWNER: AND-14
//
// The notification permission request always completes, exactly once (owner rules 2026-10-16;
// platform/Permissions.kt header): every rule of NotificationPermissionRules, the permanently-denied
// flag, and the flow with a fake platform (pending request, activity destroyed or recreated while
// the dialog is up with the late callback ignored, request that cannot start or throws, cancelled
// result).

package com.vecvel.danaview.editor.engine.platform

import android.content.pm.PackageManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationPermissionFlowTest {
    // ---- rules ----

    private fun decide(
        sdk: Int = 35,
        granted: Boolean = false,
        activity: RequestActivityState = RequestActivityState.RESUMED,
        pending: Boolean = false,
        rationale: Boolean = false,
        permanent: Boolean = false,
    ) = NotificationPermissionRules.decide(sdk, granted, activity, pending, rationale, permanent)

    @Test
    fun belowApi33IsTrueWhateverTheRest() {
        for (sdk in listOf(24, 28, 29, 32)) {
            for (state in RequestActivityState.entries) {
                assertEquals(NotificationDecision.GRANTED, decide(sdk = sdk, activity = state, pending = true, permanent = true))
                assertEquals(NotificationDecision.GRANTED, decide(sdk = sdk, activity = state))
            }
        }
    }

    @Test
    fun alreadyGrantedIsTrueWithoutAnActivity() {
        for (state in RequestActivityState.entries) {
            assertEquals(NotificationDecision.GRANTED, decide(granted = true, activity = state))
            assertEquals(NotificationDecision.GRANTED, decide(sdk = 33, granted = true, activity = state, pending = true, permanent = true))
        }
    }

    @Test
    fun noUsableActivityIsFalse() {
        assertEquals(NotificationDecision.DENIED, decide(activity = RequestActivityState.NONE))
        assertEquals(NotificationDecision.DENIED, decide(activity = RequestActivityState.GONE))
        assertEquals(NotificationDecision.DENIED, decide(activity = RequestActivityState.PAUSED))
    }

    @Test
    fun pendingRequestIsFalse() {
        assertEquals(NotificationDecision.DENIED, decide(pending = true))
    }

    @Test
    fun permanentlyDeniedIsFalseUntilTheRationaleReturns() {
        assertEquals(NotificationDecision.DENIED, decide(permanent = true, rationale = false))
        assertEquals(NotificationDecision.ASK, decide(permanent = true, rationale = true))
        assertEquals(NotificationDecision.ASK, decide(permanent = false, rationale = false))
        assertEquals(NotificationDecision.ASK, decide(permanent = false, rationale = true))
        assertEquals(NotificationDecision.ASK, decide(sdk = 33))
    }

    @Test
    fun permanentFlagFollowsTheRationale() {
        // second denial: rationale true -> false
        assertTrue(NotificationPermissionRules.permanentAfterDenial(previousFlag = false, rationaleBefore = true, rationaleAfter = false))
        // first denial: false -> true
        assertFalse(NotificationPermissionRules.permanentAfterDenial(previousFlag = false, rationaleBefore = false, rationaleAfter = true))
        assertFalse(NotificationPermissionRules.permanentAfterDenial(previousFlag = true, rationaleBefore = false, rationaleAfter = true))
        // dismissed / auto-denied without a state change: unchanged
        assertFalse(NotificationPermissionRules.permanentAfterDenial(previousFlag = false, rationaleBefore = false, rationaleAfter = false))
        assertTrue(NotificationPermissionRules.permanentAfterDenial(previousFlag = true, rationaleBefore = false, rationaleAfter = false))
        assertTrue(NotificationPermissionRules.permanentStillHolds(flag = true, granted = false, rationale = false))
        assertFalse(NotificationPermissionRules.permanentStillHolds(flag = true, granted = true, rationale = false))
        assertFalse(NotificationPermissionRules.permanentStillHolds(flag = true, granted = false, rationale = true))
        assertFalse(NotificationPermissionRules.permanentStillHolds(flag = false, granted = false, rationale = false))
    }

    // ---- flow ----

    private class FakeEnv : NotificationPermissionEnv {
        override var sdkInt = 35
        var isGranted = false
        var current: Any? = Any()
        var state = RequestActivityState.RESUMED
        var rationaleNow = false
        override var permanentlyDeniedFlag = false
        var startResult = true
        var throwOnRequest = false
        var requests = 0
        var pendingResult: ((IntArray) -> Unit)? = null
        val destroyListeners = HashMap<Any, MutableList<() -> Unit>>()

        override fun granted() = isGranted
        override fun activity() = current
        override fun activityState(activity: Any?) = if (activity == null) RequestActivityState.NONE else state
        override fun rationale(activity: Any) = rationaleNow

        override fun request(onResult: (IntArray) -> Unit): Boolean {
            requests++
            if (throwOnRequest) throw IllegalStateException("boom")
            if (!startResult) return false
            pendingResult = onResult
            return true
        }

        override fun watchDestroyed(activity: Any, onDestroyed: () -> Unit): () -> Unit {
            destroyListeners.getOrPut(activity) { ArrayList() }.add(onDestroyed)
            return { destroyListeners[activity]?.remove(onDestroyed) }
        }

        fun answer(vararg results: Int) = pendingResult!!(results)

        fun destroy(activity: Any) {
            state = RequestActivityState.GONE
            destroyListeners.remove(activity)?.toList()?.forEach { it() }
        }
    }

    private class Answers {
        val values = ArrayList<Boolean>()
        val done: (Result<Boolean>) -> Unit = { values.add(it.getOrThrow()) }
        val single: Boolean? get() = values.singleOrNull()
    }

    private fun run(env: FakeEnv, flow: NotificationPermissionFlow = NotificationPermissionFlow(env)) =
        Answers().also { flow.request(it.done) }

    @Test
    fun immediateAnswersNeverRequest() {
        assertEquals(true, run(FakeEnv().apply { sdkInt = 32 }).single)
        assertEquals(true, run(FakeEnv().apply { sdkInt = 28; current = null }).single)
        assertEquals(true, run(FakeEnv().apply { isGranted = true; state = RequestActivityState.PAUSED }).single)
        assertEquals(false, run(FakeEnv().apply { current = null }).single)
        assertEquals(false, run(FakeEnv().apply { state = RequestActivityState.GONE }).single)
        assertEquals(false, run(FakeEnv().apply { state = RequestActivityState.PAUSED }).single)
        assertEquals(false, run(FakeEnv().apply { permanentlyDeniedFlag = true }).single)
        val envs = listOf(
            FakeEnv().apply { sdkInt = 32 },
            FakeEnv().apply { isGranted = true },
            FakeEnv().apply { current = null },
            FakeEnv().apply { state = RequestActivityState.PAUSED },
            FakeEnv().apply { permanentlyDeniedFlag = true },
        )
        for (env in envs) {
            run(env)
            assertEquals(0, env.requests)
        }
    }

    @Test
    fun systemAnswerCompletesOnce() {
        val env = FakeEnv()
        val flow = NotificationPermissionFlow(env)
        val a = run(env, flow)
        assertTrue(a.values.isEmpty())
        assertTrue(flow.isPending)
        env.isGranted = true
        env.answer(PackageManager.PERMISSION_GRANTED)
        assertEquals(true, a.single)
        assertFalse(flow.isPending)
        env.answer(PackageManager.PERMISSION_DENIED) // a duplicate callback is ignored
        assertEquals(listOf(true), a.values)

        val denied = FakeEnv()
        val d = run(denied)
        denied.answer(PackageManager.PERMISSION_DENIED)
        assertEquals(false, d.single)
    }

    @Test
    fun pendingRequestAnswersFalseAndTheFirstStillCompletes() {
        val env = FakeEnv()
        val flow = NotificationPermissionFlow(env)
        val first = run(env, flow)
        val second = run(env, flow)
        assertEquals(false, second.single)
        assertEquals(1, env.requests)
        env.answer(PackageManager.PERMISSION_GRANTED)
        assertEquals(true, first.single)
        // no longer pending: a new request reaches the system again
        val third = run(env, flow)
        assertTrue(third.values.isEmpty())
        assertEquals(2, env.requests)
        env.answer(PackageManager.PERMISSION_DENIED)
        assertEquals(false, third.single)
    }

    @Test
    fun activityDestroyedWhileAskingCompletesFalseOnceAndIgnoresTheLateCallback() {
        val env = FakeEnv()
        val flow = NotificationPermissionFlow(env)
        val owner = env.current!!
        val a = run(env, flow)
        env.destroy(owner) // destroyed, or recreated (the old instance is destroyed)
        assertEquals(false, a.single)
        assertFalse(flow.isPending)
        env.isGranted = true
        env.answer(PackageManager.PERMISSION_GRANTED) // the recreated activity delivers the old result
        assertEquals(listOf(false), a.values)
        assertTrue("listener removed", env.destroyListeners[owner].isNullOrEmpty())
    }

    @Test
    fun answerUnregistersTheDestroyWatch() {
        val env = FakeEnv()
        val owner = env.current!!
        val a = run(env)
        env.answer(PackageManager.PERMISSION_DENIED)
        assertTrue(env.destroyListeners[owner].isNullOrEmpty())
        env.destroy(owner)
        assertEquals(listOf(false), a.values)
    }

    @Test
    fun cancelledNotStartedOrThrowingRequestsAreFalse() {
        val cancelled = FakeEnv()
        val c = run(cancelled)
        cancelled.answer()
        assertEquals(false, c.single)

        val notStarted = FakeEnv().apply { startResult = false }
        val flow = NotificationPermissionFlow(notStarted)
        assertEquals(false, run(notStarted, flow).single)
        assertFalse(flow.isPending)

        val throwing = FakeEnv().apply { throwOnRequest = true }
        val tf = NotificationPermissionFlow(throwing)
        assertEquals(false, run(throwing, tf).single)
        assertFalse(tf.isPending)
    }

    @Test
    fun secondDenialMarksPermanentAndLaterRequestsAnswerAtOnce() {
        val env = FakeEnv()
        val flow = NotificationPermissionFlow(env)
        // first denial: rationale false -> true
        val first = run(env, flow)
        env.rationaleNow = true
        env.answer(PackageManager.PERMISSION_DENIED)
        assertEquals(false, first.single)
        assertFalse(env.permanentlyDeniedFlag)
        // second denial: rationale true -> false
        val second = run(env, flow)
        env.rationaleNow = false
        env.answer(PackageManager.PERMISSION_DENIED)
        assertEquals(false, second.single)
        assertTrue(env.permanentlyDeniedFlag)
        // now: false at once, no request
        val third = run(env, flow)
        assertEquals(false, third.single)
        assertEquals(2, env.requests)
    }

    @Test
    fun dismissedFirstRequestIsNotPermanent() {
        val env = FakeEnv()
        val flow = NotificationPermissionFlow(env)
        val first = run(env, flow)
        env.answer(PackageManager.PERMISSION_DENIED) // dismissed: rationale stays false
        assertEquals(false, first.single)
        assertFalse(env.permanentlyDeniedFlag)
        run(env, flow)
        assertEquals("asked again", 2, env.requests)
    }

    @Test
    fun settingsChangesClearThePermanentFlag() {
        val granted = FakeEnv().apply { permanentlyDeniedFlag = true; isGranted = true; current = null }
        assertEquals(true, run(granted).single)
        assertFalse(granted.permanentlyDeniedFlag)

        val rationale = FakeEnv().apply { permanentlyDeniedFlag = true; rationaleNow = true }
        val r = run(rationale)
        assertFalse(rationale.permanentlyDeniedFlag)
        assertEquals(1, rationale.requests)
        rationale.answer(PackageManager.PERMISSION_GRANTED)
        assertEquals(true, r.single)

        // without a resumed activity the rationale is unknown: the flag stays
        val paused = FakeEnv().apply { permanentlyDeniedFlag = true; rationaleNow = true; state = RequestActivityState.PAUSED }
        assertEquals(false, run(paused).single)
        assertTrue(paused.permanentlyDeniedFlag)
    }
}
