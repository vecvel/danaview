// OWNER: AND-13
//
// The real RECORD_AUDIO dialog (BUILD_PLAN AND-13: permission denied / permanently denied states).
// The recorder's request goes through a fragment relay in androidx.test's EmptyActivity, so the
// system permission controller shows its dialog and UiAutomator answers it: deny → denied, deny
// again → permanently denied (API 30+: the second denial; API 29: "Deny & don't ask again"), a
// third request comes back at once still permanently denied; then a grant (shell) → granted.
//
// It needs RECORD_AUDIO not granted and never asked, which a normal connected run cannot give (the
// test APK is installed with its runtime permissions granted, and revoking one kills the test
// process). It runs only when the instrumentation argument danaviewMicDialog=true is passed, after
//   adb shell pm revoke <test pkg> android.permission.RECORD_AUDIO
//   adb shell pm clear-permission-flags <test pkg> android.permission.RECORD_AUDIO user-set user-fixed
// (scripted in the AND-13 hand-off). Without the argument the test is skipped (assumption), so a
// normal connected run does not count it; its evidence comes from the scripted run.

package com.vecvel.danaview.editor.engine.recording

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.vecvel.danaview.editor.engine.pigeon.MicPermissionMsg
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.regex.Pattern

@RunWith(AndroidJUnit4::class)
class MicPermissionDialogTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val app get() = instrumentation.targetContext.applicationContext

    @Test
    fun realDialogDeniedThenPermanentlyDeniedThenGranted() {
        val enabled = InstrumentationRegistry.getArguments().getString("danaviewMicDialog") == "true"
        assumeTrue("run with -e danaviewMicDialog true after revoking RECORD_AUDIO", enabled)
        assertEquals(
            "RECORD_AUDIO must start revoked",
            PackageManager.PERMISSION_DENIED,
            app.checkSelfPermission(Manifest.permission.RECORD_AUDIO),
        )
        VoiceRecorder.resetPermissionMemory(app)
        val ctx = RecorderTestEngine.create("recorder-dialog")
        val recorder = VoiceRecorder(ctx)
        val relay = PermissionRelay.launch()
        recorder.showRationale = { relay.activity.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) }
        recorder.requestPermissions = { p, cb -> relay.request(p, cb) }
        val device = UiDevice.getInstance(instrumentation)
        try {
            assertEquals(MicPermissionMsg.UNDETERMINED, awaitResult<MicPermissionMsg> { recorder.permission(it) }.getOrThrow())

            val first = requestAndDeny(recorder, device, permanent = false)
            assertEquals(MicPermissionMsg.DENIED, first)
            assertEquals(MicPermissionMsg.DENIED, awaitResult<MicPermissionMsg> { recorder.permission(it) }.getOrThrow())

            val second = requestAndDeny(recorder, device, permanent = true)
            assertEquals(MicPermissionMsg.PERMANENTLY_DENIED, second)
            assertEquals(MicPermissionMsg.PERMANENTLY_DENIED, awaitResult<MicPermissionMsg> { recorder.permission(it) }.getOrThrow())

            // The system no longer prompts: the answer comes straight back.
            val third = awaitOnMain<MicPermissionMsg>(10_000) { recorder.requestPermission(it) }.getOrThrow()
            assertEquals(MicPermissionMsg.PERMANENTLY_DENIED, third)

            instrumentation.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.RECORD_AUDIO)
            assertEquals(MicPermissionMsg.GRANTED, awaitResult<MicPermissionMsg> { recorder.permission(it) }.getOrThrow())
            Log.i("DanaviewRecorderTest", "AND-13 real dialog on API ${Build.VERSION.SDK_INT}: denied, permanentlyDenied, granted")
        } finally {
            relay.finish()
            ctx.threads.shutdown()
        }
    }

    private fun requestAndDeny(recorder: VoiceRecorder, device: UiDevice, permanent: Boolean): MicPermissionMsg {
        var answer: Result<MicPermissionMsg>? = null
        instrumentation.runOnMainSync { recorder.requestPermission { answer = it } }
        // API 29 offers "Deny & don't ask again" on the second request; API 30+ "Don't allow".
        val patterns = if (permanent && Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            listOf("(?i)deny.*don.t ask again", "(?i)don.t allow", "(?i)^deny$")
        } else {
            listOf("(?i)don.t allow", "(?i)^deny$")
        }
        var clicked = false
        val end = System.currentTimeMillis() + 15_000
        while (!clicked && System.currentTimeMillis() < end) {
            for (p in patterns) {
                val button = device.findObject(By.text(Pattern.compile(p)).clickable(true))
                    ?: device.findObject(By.text(Pattern.compile(p)))
                if (button != null) {
                    button.click()
                    clicked = true
                    break
                }
            }
            if (!clicked) device.wait(Until.hasObject(By.pkg(Pattern.compile(".*permissioncontroller.*"))), 1_000)
        }
        check(clicked) { "no permission dialog" }
        val until = System.currentTimeMillis() + 10_000
        while (answer == null && System.currentTimeMillis() < until) Thread.sleep(50)
        return answer!!.getOrThrow()
    }
}
