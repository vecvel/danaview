// OWNER: AND-14
//
// Test support of the picker / media access / permission tests: an engine context whose cache root
// is the app's real `<cache>/danaview/editor` (so the engine FileProvider, which shares only
// `cache/danaview/editor/work/`, serves test files as a test content provider), blocking call
// helpers, the core quickHash pattern, and an activity relay: a headless android.app.Fragment in
// androidx.test's EmptyActivity (the library test APK declares no activity of its own) that
// starts activities for a result and requests permissions, so the real Photo Picker, DocumentsUI
// and permission dialogs answer the services under test.

package com.vecvel.danaview.editor.engine.platform

import android.app.Activity
import android.app.Fragment
import android.content.Intent
import androidx.core.content.FileProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Paths
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.regex.Pattern

object PlatformTestEngine {
    val app get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext

    /** A context whose roots are `<cache>/danaview/editor` and `<files>/danaview/editor`. */
    fun create(): EngineContext {
        val ctx = EngineContext(app, EngineThreads.android())
        val cache = File(app.cacheDir, "danaview/editor")
        val support = File(app.filesDir, "danaview/editor")
        ctx.installRoots(Paths.fromDart(cache.absolutePath, support.absolutePath))
        return ctx
    }

    /** A test source directory served by the engine FileProvider. */
    fun providerDir(ctx: EngineContext, name: String): File =
        File(ctx.requirePaths().work, "test-src/$name").also {
            it.deleteRecursively()
            it.mkdirs()
        }

    /** The engine FileProvider's content:// URI of [file]. */
    fun contentUri(ctx: EngineContext, file: File) = FileProvider.getUriForFile(app, ctx.fileProviderAuthority, file)
}

/** The core quickHash fixture pattern (packages/danaview_editor_core/test/fixtures/quickhash/README.md). */
fun quickHashPattern(size: Int) = ByteArray(size) { i -> ((i * 31 + (i shr 8) * 7 + 5) and 0xff).toByte() }

fun <T> awaitResult(timeoutMs: Long = 20_000, block: (Completion<T>) -> Unit): Result<T> {
    val latch = CountDownLatch(1)
    var result: Result<T>? = null
    block { r ->
        result = r
        latch.countDown()
    }
    check(latch.await(timeoutMs, TimeUnit.MILLISECONDS)) { "no completion within $timeoutMs ms" }
    return result!!
}

/** Starts [block] on main; the completion is awaited by the returned latch holder. */
class Pending<T> {
    private val latch = CountDownLatch(1)
    @Volatile private var result: Result<T>? = null

    val completion: Completion<T> = { r ->
        result = r
        latch.countDown()
    }

    fun await(timeoutMs: Long = 30_000): Result<T> {
        check(latch.await(timeoutMs, TimeUnit.MILLISECONDS)) { "no completion within $timeoutMs ms" }
        return result!!
    }

    val isDone: Boolean get() = latch.count == 0L
}

fun <T> startOnMain(block: (Completion<T>) -> Unit): Pending<T> {
    val pending = Pending<T>()
    InstrumentationRegistry.getInstrumentation().runOnMainSync { block(pending.completion) }
    return pending
}

/** [ActivityRequests] through a fragment in EmptyActivity (see the file header). */
class FragmentRequests private constructor(override val activity: Activity, private val fragment: RelayFragment) : ActivityRequests {
    override fun startForResult(intent: Intent, onResult: (Int, Intent?) -> Unit): Boolean {
        fragment.pendingResult = onResult
        @Suppress("DEPRECATION")
        fragment.startActivityForResult(intent, RESULT_CODE)
        return true
    }

    override fun requestPermissions(permissions: Array<String>, onResult: (Array<out String>, IntArray) -> Unit): Boolean {
        fragment.pendingPermissions = onResult
        @Suppress("DEPRECATION")
        fragment.requestPermissions(permissions, PERMISSION_CODE)
        return true
    }

    fun finish() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync { activity.finish() }
    }

    @Suppress("DEPRECATION")
    class RelayFragment : Fragment() {
        var pendingResult: ((Int, Intent?) -> Unit)? = null
        var pendingPermissions: ((Array<out String>, IntArray) -> Unit)? = null

        @Deprecated("android.app.Fragment API")
        override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
            val cb = pendingResult ?: return
            pendingResult = null
            cb(resultCode, data)
        }

        @Deprecated("android.app.Fragment API")
        override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
            val cb = pendingPermissions ?: return
            pendingPermissions = null
            cb(permissions, grantResults)
        }
    }

    companion object {
        private const val RESULT_CODE = 0x5a5b
        private const val PERMISSION_CODE = 0x5a5c
        const val EMPTY_ACTIVITY = "androidx.test.core.app.InstrumentationActivityInvoker\$EmptyActivity"

        @Suppress("DEPRECATION")
        fun launch(): FragmentRequests {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val intent = Intent(Intent.ACTION_MAIN)
                .setClassName(instrumentation.targetContext.packageName, EMPTY_ACTIVITY)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val activity = instrumentation.startActivitySync(intent)
            val fragment = RelayFragment()
            instrumentation.runOnMainSync {
                activity.fragmentManager.beginTransaction().add(fragment, "danaview-relay").commitNow()
            }
            return FragmentRequests(activity, fragment)
        }
    }
}

/** UiAutomator helpers for system UI (picker, DocumentsUI, permission dialogs). */
object SystemUi {
    val device: UiDevice get() = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

    /** Waits up to [timeoutMs] for the first object matching any selector built by [selectors]. */
    fun waitAny(timeoutMs: Long, vararg selectors: () -> UiObject2?): UiObject2? {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            for (s in selectors) s()?.let { return it }
            Thread.sleep(250)
        }
        return null
    }

    fun byText(regex: String): () -> UiObject2? = { device.findObject(By.text(Pattern.compile(regex))) }

    fun byDesc(regex: String): () -> UiObject2? = { device.findObject(By.desc(Pattern.compile(regex))) }

    fun byRes(regex: String): () -> UiObject2? = { device.findObject(By.res(Pattern.compile(regex))) }

    /** The window hierarchy as text (failure diagnostics). */
    fun dump(): String {
        val out = java.io.ByteArrayOutputStream()
        device.dumpWindowHierarchy(out)
        return out.toString("UTF-8")
            .split('<')
            .mapNotNull { node ->
                val t = Regex("text=\"([^\"]+)\"").find(node)?.groupValues?.get(1)
                val r = Regex("resource-id=\"([^\"]+)\"").find(node)?.groupValues?.get(1)
                val d = Regex("content-desc=\"([^\"]+)\"").find(node)?.groupValues?.get(1)
                listOfNotNull(t?.let { "t=$it" }, r?.let { "r=$it" }, d?.let { "d=$it" }).takeIf { it.isNotEmpty() }?.joinToString(" ")
            }
            .joinToString("\n")
    }
}
