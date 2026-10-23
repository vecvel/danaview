package com.vecvel.danaview

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.JUnit4

/**
 * INT-104/HOM-21A flag-off parity: the document/photo/text VIEW, SEND and SEND_MULTIPLE filters
 * live on IncomingDocumentsAlias, which follows DANAVIEW_FILES_HOME (BuildConfig, decoded from the
 * dart-defines). A flag-off build resolves none of those intents to Danaview, a flag-on build
 * resolves all of them; the 1.1 video/audio VIEW and danaview:// filters on MainActivity resolve in
 * both. MainActivity corrects a state left by a build with the other flag value at startup.
 */
@RunWith(JUnit4::class)
class IncomingDocumentsAliasTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val pm = context.packageManager
    private val alias = ComponentName(context, "${context.packageName}.IncomingDocumentsAlias")
    private val flag = BuildConfig.DANAVIEW_FILES_HOME

    private val content = Uri.parse("content://com.example.provider/doc")

    /** Document/photo/text intents that only the alias accepts. */
    private fun aliasIntents(): List<Pair<String, Intent>> = listOf(
        "VIEW pdf" to Intent(Intent.ACTION_VIEW).setDataAndType(content, "application/pdf"),
        "VIEW docx" to Intent(Intent.ACTION_VIEW).setDataAndType(
            content, "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ),
        "VIEW image" to Intent(Intent.ACTION_VIEW).setDataAndType(content, "image/jpeg"),
        "VIEW text" to Intent(Intent.ACTION_VIEW).setDataAndType(content, "text/plain"),
        "SEND pdf" to Intent(Intent.ACTION_SEND).setType("application/pdf"),
        "SEND image" to Intent(Intent.ACTION_SEND).setType("image/png"),
        "SEND text" to Intent(Intent.ACTION_SEND).setType("text/plain"),
        "SEND video" to Intent(Intent.ACTION_SEND).setType("video/mp4"),
        "SEND_MULTIPLE pdf" to Intent(Intent.ACTION_SEND_MULTIPLE).setType("application/pdf"),
        "SEND_MULTIPLE image" to Intent(Intent.ACTION_SEND_MULTIPLE).setType("image/*"),
        "SEND_MULTIPLE text" to Intent(Intent.ACTION_SEND_MULTIPLE).setType("text/plain"),
        "SEND_MULTIPLE video" to Intent(Intent.ACTION_SEND_MULTIPLE).setType("video/mp4"),
    )

    /** 1.1 intents on MainActivity, offered whatever the flag. */
    private fun mainIntents(): List<Pair<String, Intent>> = listOf(
        "VIEW video content" to Intent(Intent.ACTION_VIEW).setDataAndType(content, "video/mp4"),
        "VIEW video https" to Intent(Intent.ACTION_VIEW)
            .setDataAndType(Uri.parse("https://example.com/a.mp4"), "video/mp4"),
        "VIEW audio" to Intent(Intent.ACTION_VIEW).setDataAndType(content, "audio/mpeg"),
        "VIEW danaview://" to Intent(Intent.ACTION_VIEW).setData(Uri.parse("danaview://open?url=x")),
    )

    @Suppress("DEPRECATION")
    private fun resolvesToDanaview(intent: Intent): Boolean =
        pm.queryIntentActivities(Intent(intent).setPackage(context.packageName), 0).isNotEmpty()

    private fun assertResolution(expectAlias: Boolean) {
        for ((name, intent) in aliasIntents()) {
            assertEquals("$name resolves to Danaview (DANAVIEW_FILES_HOME=$flag)", expectAlias, resolvesToDanaview(intent))
        }
        for ((name, intent) in mainIntents()) {
            assertTrue("$name no longer resolves to Danaview", resolvesToDanaview(intent))
        }
    }

    @After
    fun tearDown() {
        // Back to the manifest default (the value the build's flag declares).
        pm.setComponentEnabledSetting(alias, PackageManager.COMPONENT_ENABLED_STATE_DEFAULT, PackageManager.DONT_KILL_APP)
    }

    @Test
    fun filtersFollowTheFlag() {
        assertResolution(expectAlias = flag)
    }

    @Test
    fun startupCorrectsAStateLeftByTheOtherFlagValue() {
        // As if a build with the other flag value had run: its explicit state persists.
        pm.setComponentEnabledSetting(
            alias,
            if (flag) PackageManager.COMPONENT_ENABLED_STATE_DISABLED else PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        assertResolution(expectAlias = !flag)

        val intent = Intent(Intent.ACTION_MAIN)
            .setClassName(context, MainActivity::class.java.name)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        val activity = instrumentation.startActivitySync(intent)
        try {
            val end = SystemClock.uptimeMillis() + 10_000
            while (SystemClock.uptimeMillis() < end && resolvesToDanaview(aliasIntents().first().second) != flag) {
                SystemClock.sleep(200)
            }
            assertResolution(expectAlias = flag)
        } finally {
            activity.finish()
        }
    }
}
